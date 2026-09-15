# 🖱️ Mouse Auto-Reconnect

`MouseAutoReconnect` re-connects Victor's own Bluetooth mouse whenever it
sits paired-but-not-connected while nearby and switched on — the case
observed 15 Sep 2026: System Settings › Bluetooth showed it "Not Connected"
with the mouse awake on the desk, macOS's own auto-reconnect simply not
firing.

## The allow-list, and why it exists

`blueutil --paired` on this Mac shows **six different physical mice all
named "Logi M650 L"** (same vendor/product ID, 0x046D/0xB02A) — the same
model bought more than once over time, plus possibly one paired during a
demo with a trainee's identical mouse. Reconnecting on a name match would
happily grab any of the other five: someone else's mouse, or a dead one from
a drawer. So the class only ever acts on an explicit `Set<String>` of
addresses (`MouseAutoReconnect.trustedAddresses`), the same allow-list shape
`HotspotFallback` uses for the phone — never a name, never "whatever showed
up".

**The address survives a factory reset.** Resetting the mouse (to pair it
elsewhere, then back to this Mac) clears the *bond*, not the address — a
BLE peripheral's address is fixed in the chip at manufacture. So one entry
covers that physical mouse forever; only a genuinely different unit needs a
new one. `logUnknownMice()` prints the address of any other paired
"Logi"-named device it sees, once each, so the value to add is never a
guess — it is in the log the first time this app notices it.

## How the reconnect itself works

No push notification exists for "a specific already-paired device is back
in range but not connected" — CoreAudio has one for the device *list*
(`BluetoothAutoOutput` rides it for the JBL speakers), but a mouse is not an
audio device and IOBluetooth has nothing equivalent for arbitrary peripherals.
So this polls: every 20 s, for each trusted address, `IOBluetoothDevice.isConnected()`
is checked and, if false, `openConnection(_:withPageTimeout:authenticationRequired:)`
is called with a short bound (`0x0800` ≈ 1.28 s) rather than the ~5 s
default — an absent mouse costs a fraction of a second per poll, not a
noticeable stall, and there is no scan running between polls at all.

Like `HotspotFallback`'s RFCOMM open, the call runs on a dedicated
`RunLoopThread` rather than a bare `DispatchQueue`: IOBluetooth's synchronous
calls still lean on the calling thread's run loop being pumped, which a
`DispatchQueue` does not have.

## Menu & test hook

- **🖱️ Mouse Auto-Reconnect** — checkbox in the 👩🏻‍💻 Extra submenu
  (`MouseAutoReconnectSettings.isEnabled`, default on).
- `GET /test/mouse-reconnect` — run one round now and return
  `{"enabled":…, "connected":{"<address>":true|false, …}}` for every trusted
  address. Fast enough to answer synchronously (bounded by the page timeout),
  unlike the phone's RFCOMM open.

## Adding a mouse

1. Pair it normally through System Settings › Bluetooth.
2. Check the log for a line like `🖱️ Unfamiliar 'Logi M650 L' paired
   (d8-2e-4e-7e-57-xx) — add it to MouseAutoReconnect.trustedAddresses if
   it's Victor's` — that address is what to add.
3. Add it to `MouseAutoReconnect.trustedAddresses`, push, `./build-app.sh`,
   restart.

## Open question

Whether `openConnection()` genuinely forces a reconnect for a BLE-only
peripheral (the M650 L advertises `< BLE >` in `system_profiler`, not
BR/EDR) the way it does for the phone's classic ACL link is **not yet
proven live** — it was written and built, not exercised with the mouse
actually out of range. Victor's plan: test tonight around 18:00 with the
mouse deliberately disconnected/out of range, watching `GET
/test/mouse-reconnect` and the log for a real reconnect. If `openConnection()`
turns out not to do anything for a BLE peripheral, the fallback is shelling
out to `blueutil --connect <address>` instead (already installed, already
proven to work for this exact family of device in manual testing during
`HotspotFallback` development).
