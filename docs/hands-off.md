# ✋ Hands off — the frame an agent raises while it drives the GUI
`HandsOffOverlay` + the pure `HandsOffSession`. Amber border on **every** screen
plus a badge riding the cursor (`✋ codex — click pe Restart to Update`); on release
the border turns green for 0.5s, fades over 0.25s and a `Tink` plays. Raised over the
existing HTTP door, so any agent — codex, claude, a shell script — uses the same two calls:

```sh
curl "localhost:55123/hands-off/start?agent=claude&what=click%20pe%20Restart&ttl=120"
# … the GUI dance …
curl localhost:55123/hands-off/end
```
`GET /hands-off/state` is the read-only snapshot (`{"active":true,"agent":…,"label":…,"remainingSec":…}`),
which is how the behaviour is asserted from a script rather than from a screenshot.

**Why the frame is on every screen, not the cursor's:** automation *moves* the pointer, and a
warning that migrates between displays while you're looking at the other one is the one you miss.

**Why the ttl is not shown as a countdown:** it is a watchdog, not an estimate. An agent that
crashes or forgets `/hands-off/end` would otherwise leave the frame up all afternoon, and a
warning that never clears stops being read — so it releases itself (default 120s, capped 900s).
A number on screen would read as "this is how long it will take", and it only means "from here
on I stop believing you".

**Announce, not auto-detect** — deliberately. An event tap *could* spot synthetic input (the
posting PID rides on the event), but it would then fire for **codex too**, which does not
interrupt anything (see below), and a frame that cries wolf is ignored when it matters.

**Who actually needs this:** whoever drives the GUI the crude way — `osascript … activate` plus
`CGEventPost(kCGHIDEventTap, …)`, which physically moves Victor's pointer and pulls another app
to the front. That is Claude Code's only available path, and shell/AppleScript automation in
general. **Codex does not need it**: measured 22 Aug 2026 while codex clicked `7 × 6 =` in
Calculator through `@oai/sky` (its SkyLight-based computer-use client, installed at
`~/.codex/computer-use/`), sampling the real cursor and the frontmost app every 200 ms for 200 s —
the cursor never left the spot it was parked at, Terminal stayed frontmost throughout, and the
Calculator window sat at coordinates that on screen still showed Terminal. It also draws its own
indicator ("ChatGPT is using your computer · Esc to cancel", from
`~/.codex/computer-use/config.json`), so raising ours for it would double up.
