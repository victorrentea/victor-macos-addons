# 🖱️ Reconnect Mouse

A single menu row, **👩🏻‍💻 Extra → 🖱️ Reconnect Mouse** (`MouseReconnect`),
that connects a Logi mouse which is switched on and nearby but left sitting
"Not Connected" in System Settings › Bluetooth — something macOS does from
time to time.

## Manual on purpose

There is **no automatic path** — no timer, no watcher, no setting. An
automatic version was built first (16 Sep 2026) and deliberately thrown
away: a mouse that reconnects the instant it is seen is exactly wrong when
the reason it is disconnected is that Victor has just put it on another
computer. The click *is* the intent, and it is the only trigger.

## Why CoreBluetooth, and not `IOBluetoothDevice.openConnection()`

The first implementation called `IOBluetoothDevice.openConnection` — the
same call `HotspotFallback` uses for the phone. **It does not merely fail,
it hangs forever.** Measured 15 Sep 2026: the call never returned, well past
its own page timeout, and `blueutil --connect <address>` against the same
device hung identically — which rules out "our code called it wrong", since
blueutil is a separate, mature binary hitting the same IOBluetooth API. The
reason: that call issues a classic HCI `CREATE_CONNECTION` (a BR/EDR
**page**), and the M650 L is BLE-only (`system_profiler` shows `Services:
<BLE>`). A classic page has nothing to page.

`CBCentralManager` is the API family LE peripherals actually connect
through; its `connect` is asynchronous and answered by a delegate callback,
so nothing can block. Note it also has **no timeout of its own** — an
attempt against a peripheral that stops answering stays pending forever — so
`MouseReconnect` carries its own deadline and calls
`cancelPeripheralConnection` when it expires.

## Why any Logi mouse, and not one specific address

An earlier version kept an allow-list of Bluetooth addresses so it could
never grab a stranger's identical mouse — this Mac is paired with **seven**
different addresses, all named "Logi M650 L". That turned out to be both
unworkable and unnecessary:

- **Unworkable**: the addresses drift. Victor confirmed 16 Sep 2026 that at
  least two of them (`…57-ff` and `…58-00`, consecutive) are the *same
  physical mouse* — it comes back under a new address after being paired to
  another computer and back. A pinned address therefore goes stale exactly
  when the button is needed. (An earlier version of this file claimed the
  opposite — "the address survives a factory reset" — which was wrong.)
- **Unnecessary**: the click is the consent. The scan picks the **strongest
  RSSI**, which is the mouse on this desk rather than one across a training
  room, and if the wrong one ever answered, the person holding the mouse
  finds out within a second and clicks again.

## What the click does

1. If a Logi mouse is **already connected**, say so and stop
   (`retrieveConnectedPeripherals`). **Not** under the HID service (0x1812):
   measured 16 Sep 2026 with the mouse genuinely connected, that lookup came
   back empty — macOS's own HID stack keeps that GATT service to itself.
   Battery Service (0x180F) and Device Information (0x180A) both find it.
2. Otherwise scan for **6 s** (`scanForPeripherals(withServices: nil)`),
   keeping every peripheral whose advertised name contains "Logi".
3. Connect the strongest-signal candidate, with an **8 s** deadline.
4. Report the verdict to Notification Center — the answer arrives long after
   the menu has closed, exactly like the 📱 hotspot row.

## Test hook

`GET /test/mouse-reconnect` — the same thing without the menu, and it waits
for the verdict: `{"ok":true,"message":"Logi M650 L e deja conectat"}`.
Takes up to ~14 s when it has to scan and connect; instant when a mouse is
already connected.

## Not yet exercised

The **scan → connect** branch has not run against a genuinely disconnected
mouse — every test so far happened with one connected, which short-circuits
at step 1. Worth one run with the mouse switched off or out of range: the
hook should answer `"niciun mouse Logi nu e disponibil în apropiere"`, and
with it switched back on but not connected, it should actually connect.

## Leftover: the six stale pairings

System Settings › Bluetooth still lists **seven** "Logi M650 L" entries, six
of them dead addresses of the same mouse. They cannot be removed
programmatically: `blueutil --unpair` returns exit 0 and changes nothing
(verified 16 Sep 2026 against both `blueutil --paired` and
`system_profiler`) — the same silent no-op already documented for
`blueutil --disconnect` in [hotspot-fallback.md](hotspot-fallback.md).
Removing them means System Settings › Bluetooth → right-click each →
Forget This Device, or a Codex GUI run. They are harmless to the button
above, which matches by name and signal, not by address.
