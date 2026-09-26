#!/usr/bin/env python3
"""Read the DJI Mic Mini receiver's own status stream: is a transmitter linked, and its battery.

Prototype for "watch the TX battery instead of guessing from silence" (2026-09-26,
the transmitter died after ~5 h of teaching). NOT wired into the app yet — it was
written while the receiver was not plugged in, so it has never been run against
the hardware. Run it with the receiver on USB and the TX on, then off:

    python3 -m venv /tmp/djivenv && /tmp/djivenv/bin/pip install pyusb
    DYLD_LIBRARY_PATH=/opt/homebrew/lib /tmp/djivenv/bin/python tools/dji-rx-status.py

The protocol is not DJI's public API; it is the community reverse-engineering in
https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md, which
MicShift (https://github.com/dvnkshl/MicShift, a macOS menu-bar app) runs live
on a Mic Mini 2 receiver on macOS:

  * USB 0x2ca3:0x4011, vendor interface 6, bulk IN 0x86 (bulk OUT 0x06 is for
    commands; nothing has to be sent to get the status stream).
  * Frames: 0x55, total length, 0x04, header CRC-8 ... CRC-16. Heartbeats carry
    `5b 03` at offset 9 and a version marker at 11: 0x00 = v1 firmware, 0x03 = v2.
  * v2 status push (54/86/118 bytes, ~10 Hz): byte 44 = linked-TX mask
    (0x01 TX1, 0x02 TX2); one 32-byte slot per linked TX from offset 52, where
    slot+1 = physical unit and slot+7 carries charging (0x02) and the battery
    gauge `(b >> 2) & 7`: 1 = full ... 6 = DJI's own low warning ... 7 = about to
    shut off. An ordinal, not a percentage.
  * v1 heartbeat (56/70/84 bytes): presence only (slot flag 0x20 present, 0x40
    absent stub); battery is not decoded on v1 firmware.
"""
import sys
import time

import usb.core
import usb.util

VID, PID, IFACE, EP_IN = 0x2CA3, 0x4011, 6, 0x86
BATTERY = {1: "full", 2: "high", 3: "high", 4: "medium", 5: "low", 6: "LOW (DJI warns)", 7: "EMPTY — shutting off"}


def frames(buf: bytearray):
    """Pop every complete 0x55 ... frame off the front of `buf`."""
    while True:
        i = buf.find(0x55)
        if i < 0:
            buf.clear()
            return
        del buf[:i]
        if len(buf) < 3:
            return
        if buf[2] != 0x04 or buf[1] < 14:
            del buf[:1]
            continue
        n = buf[1]
        if len(buf) < n:
            return
        yield bytes(buf[:n])
        del buf[:n]


def decode(f: bytes) -> str | None:
    if len(f) < 14 or f[9:11] != b"\x5b\x03":
        return None  # ACK, identity or level push
    if f[11] == 0x03 and len(f) in (54, 86, 118):
        mask = f[44]
        parts = [f"v2 linked-mask=0x{mask:02x}"]
        for i in range((len(f) - 54) // 32):
            s = f[52 + 32 * i: 52 + 32 * (i + 1)]
            if s[0] != 0x02:
                continue
            gauge = (s[7] >> 2) & 0x07
            charging = bool(s[7] & 0x02)
            parts.append(f"TX{s[1]} battery={gauge} ({BATTERY.get(gauge, '?')}){' charging' if charging else ''}")
        if mask == 0:
            parts.append("NO TRANSMITTER LINKED")
        return "  ".join(parts)
    if f[11] == 0x00 and len(f) in (56, 70, 84):
        present, off = [], 14
        for unit in (1, 2):
            flags = f[off + 1]
            if flags & 0x20:
                present.append(f"TX{unit}")
                off += 23
            else:
                off += 9
        return f"v1 linked={present or 'NONE'} (battery not decoded on v1 firmware)"
    return None


def main() -> int:
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        print("DJI receiver 2ca3:4011 not on USB")
        return 1
    print(f"found {usb.util.get_string(dev, dev.iProduct)!r} by {usb.util.get_string(dev, dev.iManufacturer)!r}")
    for cfg in dev:
        for intf in cfg:
            eps = ", ".join(f"0x{e.bEndpointAddress:02x}" for e in intf)
            print(f"  interface {intf.bInterfaceNumber} alt {intf.bAlternateSetting} class 0x{intf.bInterfaceClass:02x} endpoints [{eps}]")
    usb.util.claim_interface(dev, IFACE)
    buf, last = bytearray(), ""
    try:
        deadline = time.time() + float(sys.argv[1]) if len(sys.argv) > 1 else None
        while deadline is None or time.time() < deadline:
            try:
                buf += dev.read(EP_IN, 512, timeout=1500)
            except usb.core.USBTimeoutError:
                print("no status packet for 1.5 s — receiver stopped streaming")
                continue
            for f in frames(buf):
                line = decode(f)
                if line and line != last:
                    print(time.strftime("%H:%M:%S"), line, flush=True)
                    last = line
    finally:
        usb.util.release_interface(dev, IFACE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
