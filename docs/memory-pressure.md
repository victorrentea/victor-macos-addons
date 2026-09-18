# 🟥 Memory pressure — the red plate under the menu bar icon

When paging starts costing real CPU, the 💬 menu bar icon starts flashing on a
red plate, and a row appears at the top of the menu naming the counter that
crossed. Clicking it opens Activity Monitor.

- `MemoryPressurePolicy` — the thresholds and the state machine, pure and tested
- `MemoryPressureMonitor` — one `host_statistics64` call every 5 s
- `MenuBarManager.setMemoryPressure(_:detail:)` — the plate and its blink

## Why the compressor and not the swap file

This was calibrated on 2026-09-17 on a Mac that was genuinely thrashing: load
average **274** on 10 cores, `kernel_task` at 31%, `WindowServer` at 42%, 143 MB
of 64 GB unused, 23 days of uptime. Sampled over 30 s:

| counter | rate |
|---|---|
| Swapouts | **0/s** |
| Swapins | ~1/s |
| **Decompressions** | **~1000/s** |
| Pageins | ~700/s |

`vm.swapusage` read **30.1 GB of 31.7 GB used** and did not move once.

Both obvious signals are wrong, in opposite directions:

- **Swap used** would have been screaming for days. A warning that is always on
  is the same as no warning, except it costs you a red menu bar.
- **Swapins/sec** would have stayed dark through the worst thrash in weeks.

What actually burns the CPU on Apple Silicon is the **compressor**. 25 GB of RAM
was being held compressed, and every touch of a compressed page is a synchronous
decompress on a core. That is the counter that moved, and it is literally CPU
spent in the kernel on nothing — which is exactly what the plate is for.

Swapins stay in the rule at a much lower threshold (50/s vs 400/s): a page that
has to come back from the encrypted swap file costs a disk read plus a decrypt,
an order of magnitude more per page than a decompress, so a fraction of the rate
earns the same alarm.

## Why the compressor rate alone is not enough

The rate on its own lit the plate on a machine that was *fine*. Measured
2026-09-18: **353 decompressions/s with 53% of the CPU idle**, nothing feeling
slow, the plate flicking on and off around the 400 line for no reason a human
could see.

The compressor working is not the complaint. The complaint is the compressor
working while there are no cycles left for anything else — the plate's own claim
is "this is costing you CPU", and it costs you nothing while half the box is
idle. So decompressions only light it when **the CPU is saturated at the same
time**; under that line the kernel is decompressing in slack the machine had to
spare, which is what slack is for.

Swapins keep their unconditional threshold: that one is a stall on disk, not a
cycle cost, so an idle CPU is no consolation.

A CPU read that fails or does not move scores as **fully busy** — a missing
reading must not be the thing that quietly silences a real alarm.

## Thresholds

| | warn above | clear below |
|---|---|---|
| decompressions/s **and** CPU busy % | 400 **and** 80% | 150 **or** 65% |
| swapins/s | 50 | 10 |

The compressor rule needs both halves to light it, and either half dropping out
clears it — the load easing while the compressor stays busy is how this plate
goes out most often.

Between the two lines the sample says **nothing** and the plate keeps whatever
state it had — that band is what stops a rate hovering at one number from
strobing the menu bar. The band does not *reset* the sustain streak either: a
rate drifting up through it would otherwise never accumulate enough samples and
the plate could never light.

**Three consecutive qualifying samples** (15 s at the 5 s cadence) flip the state,
in both directions. That is what absorbs an app launch or a swapped-out Chrome
window waking up — both spike the compressor for a second or two and both are
none of your business.

## Why the menu bar and not an overlay

Every other warning in this app that matters — hands-off, the silent
transcription warning — puts something on the screen. This one deliberately does
not. It fires precisely when the Mac is already struggling, so a full-screen
panel would be one more surface for a choking WindowServer to composite; and
during a workshop the built-in retina is projected to the room, which is the last
place to flash red about the trainer's RAM.

## Why the plate is drawn, not a layer

`platedForMemoryPressure` composites the red rounded rect into the icon bitmap
rather than setting `statusItem.button.layer?.backgroundColor`.
`NSStatusBarButton` redraws itself on appearance changes, on every menu open and
on menu bar relayout, and each of those quietly drops a background colour set
from outside. A baked bitmap survives all three — the same reason every badge in
`MenuBarManager` is drawn rather than attached.

The blink is **0.9 s**, faster than the 2 s transcription-stopped blink, so when
both happen to run the quicker pulse reads as the more urgent one.

## Testing

```
curl -s 127.0.0.1:55123/test/memory-pressure               # live rates + cpuBusyPercent + streak + thresholds
curl -s 127.0.0.1:55123/test/memory-pressure/simulate/1    # force the plate on (2 min)
curl -s 127.0.0.1:55123/test/memory-pressure/simulate/0    # force it off
curl -s 127.0.0.1:55123/test/memory-pressure/simulate/auto # hand it back to the measurement
```

A live simulation owns the plate: a real flip underneath it is recorded in
`measuredHurting` but not painted, so the override is never half-honoured. It
expires by itself after two minutes, so a forgotten test cannot leave the menu
bar lying.
