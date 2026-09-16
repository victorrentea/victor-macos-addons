# 🖱️ Mouse Auto-Reconnect

`MouseAutoReconnect` re-connects Victor's own Bluetooth mouse whenever it
sits paired-but-not-connected while nearby and switched on — the case
observed 15 Sep 2026: System Settings › Bluetooth showed it "Not Connected"
with the mouse awake on the desk, macOS's own auto-reconnect simply not
firing.

## Why CoreBluetooth, and not `IOBluetoothDevice.openConnection()`

The first version called `IOBluetoothDevice.openConnection` — the same call
`HotspotFallback` uses for the phone. **It does not work here, and not in a
"returns failure" way — it hangs forever.** Measured 15 Sep 2026: the call
never returned at all, well past its own page timeout, and `blueutil
--connect <address>` against the same device hung identically — which rules
out "our code called it wrong", since blueutil is a separate, mature binary
hitting the same underlying IOBluetooth API. The reason: that call issues a
classic HCI `CREATE_CONNECTION` (a BR/EDR baseband **page**), and the M650 L
is BLE-only (`system_profiler` shows `Services: <BLE>`, no BR/EDR) — there is
no classic radio on the other end to page. So the whole class now runs on
`CBCentralManager`, the API family LE peripherals actually connect through,
and there is no page-timeout hang risk left: `connect()` is properly
asynchronous, answered by a delegate callback.

**The cost of the first version's bug**: once the mouse was disconnected,
every 20 s poll queued another `openConnection()` call onto the same
dedicated thread behind the one already hung — the feature went
permanently inert after the very first miss, silently (no crash, no busy
loop, just one thread parked forever in a blocking HCI call). Caught before
the planned test tonight, from the disconnected-mouse state that happened to
already exist when this was checked.

## The allow-list, and why it lives one layer down from CoreBluetooth

`blueutil --paired` on this Mac shows **six different physical mice all
named "Logi M650 L"** — the same model bought more than once over time, plus
possibly one paired during a demo with a trainee's identical mouse.
Reconnecting on a name match would happily grab any of the other five:
someone else's mouse, or a dead one from a drawer.

CoreBluetooth itself never reveals a peripheral's Bluetooth **address** —
only a per-app `CBPeripheral.identifier` UUID, for privacy — so a
CoreBluetooth-only allow-list isn't possible. Instead, `bootstrap()` only
ever captures a `CBPeripheral` identity at the moment the **classic**
`IOBluetoothDevice` for a trusted address (`MouseAutoReconnect.trustedAddresses`,
an explicit `Set<String>`, the same allow-list shape `HotspotFallback` uses
for the phone) reports itself connected — i.e. only while the address is
already known to be Victor's own mouse. From then on the captured
`CBPeripheral.identifier` is reused directly
(`retrievePeripherals(withIdentifiers:)`), so every later reconnect targets
that exact peripheral and never has to guess which of the six advertising
"Logi M650 L" peripherals is his. The identifier is also persisted
(`UserDefaults`), so bootstrap only ever has to happen once across the app's
whole life, not once per launch.

**The address survives a factory reset.** Resetting the mouse (to pair it
elsewhere, then back to this Mac) clears the *bond*, not the address — a BLE
peripheral's address is fixed in the chip at manufacture. So one entry
covers that physical mouse forever; only a genuinely different unit needs a
new one. `logUnknownMice()` prints the address of any other paired
"Logi"-named device it sees, once each, so the value to add is never a
guess — it is in the log the first time this app notices it.

## How the reconnect itself works

1. **Bootstrap** (until it succeeds once, then never again): every poll,
   check whether any trusted address's classic `IOBluetoothDevice` reports
   `isConnected()`. If so, ask CoreBluetooth for
   `retrieveConnectedPeripherals(withServices:)` and take the first match —
   that peripheral is trusted by construction, since the classic address
   just proved it. **Not the HID-over-GATT service (0x1812)**: verified live
   16 Sep 2026 with the mouse genuinely connected, that lookup came back
   empty — macOS's own HID stack apparently keeps that GATT service to
   itself, invisible to a third-party `CBCentralManager`. Battery Service
   (0x180F) and Device Information (0x180A) both found it in the same test;
   `bootstrapServiceUUIDs` tries 0x180F first, since practically every BLE
   mouse reports its battery level.
2. **Reconnect**: once bootstrapped, every 20 s check
   `knownPeripheral.state`; if not `.connected`, call
   `central.connect(peripheral, options: nil)`. CoreBluetooth answers
   asynchronously via `centralManager(_:didConnect:)` /
   `centralManager(_:didFailToConnect:error:)` — no blocking, no page
   timeout, no thread that can get stuck.

No push notification exists for "a specific already-paired device is back
in range but not connected" — CoreAudio has one for the device *list*
(`BluetoothAutoOutput` rides it for the JBL speakers), but a mouse is not an
audio device — so this still polls on a 20 s timer rather than reacting to
an event. That part hasn't changed from the first version.

## Menu & test hook

- **🖱️ Mouse Auto-Reconnect** — checkbox in the 👩🏻‍💻 Extra submenu
  (`MouseAutoReconnectSettings.isEnabled`, default on).
- `GET /test/mouse-reconnect` — kicks off one round now and returns the
  **previous** round's snapshot: `{"enabled":…, "bootstrapped":…,
  "state":"…"}` — `state` is a free-text readout (`"not bootstrapped yet — …"`,
  `"connecting…"`, `"already connected"`, `"connected"`, `"connect failed: …"`)
  meant to be read by a human mid-test, not parsed. Call it twice, like
  `HotspotFallback`'s hook: CoreBluetooth's callback lands after the HTTP
  response.

## Adding a mouse

1. Pair it normally through System Settings › Bluetooth.
2. Check the log for a line like `🖱️ Unfamiliar 'Logi M650 L' paired
   (d8-2e-4e-7e-57-xx) — add it to MouseAutoReconnect.trustedAddresses if
   it's Victor's` — that address is what to add.
3. Add it to `MouseAutoReconnect.trustedAddresses`, push, `./build-app.sh`,
   restart.

If the *same* mouse is ever un-paired and re-paired for real (not just a
reset-and-reconnect), delete `MouseAutoReconnect.peripheralUUID` from
`UserDefaults` (or just wait — `bootstrap()` re-runs automatically whenever
`knownPeripheral` is `nil`, which a fresh pairing's new identifier will
trigger the next time the address is seen connected).

## Verified live (16 Sep 2026)

With the mouse connected, bootstrap captured its identity
(`retrieveConnectedPeripherals` under 0x180F/Battery Service) and
`GET /test/mouse-reconnect` moved `bootstrapped:false → true`, `state`
`"connecting…" → "already connected"` within one poll — confirming
`central.connect()` doesn't hang and correctly recognizes an already-live
connection. **Not yet verified**: the actual out-of-range → back-in-range
reconnect, since that needs the mouse physically moved away, which wasn't
done in this pass. Next test: disconnect/move the mouse out of range and
watch `GET /test/mouse-reconnect` (`state` should go to `"connecting…"`
then `"connected"`) plus the log line `🖱️ Mouse reconnected`.
