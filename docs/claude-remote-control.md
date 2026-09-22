# 🛰️ Claude RC in background

The row under 👩🏻‍💻 **Extra** that keeps `claude remote-control` — the persistent
server Victor's phone opens new Claude Code sessions against — alive in a
detached tmux session, and, for the first time, gives it an off switch.

Code: `ClaudeRemoteControl.swift` (settings, policy, watcher), the row in
`MenuBarManager`, armed from `AppDelegate`. Script: `~/workspace/claude-rc.sh`.

## What it does

| | |
|---|---|
| **default** | **on** — see below, it is not a preference |
| **tick on** | start `claude-rc.sh` if the tmux session is down, then watch |
| **tick off** | `tmux kill-session -t claude-rc`, stop watching |
| **while ticked** | every **60 s**: session alive? → nothing. Dead? → start it |
| **at app launch** | the same check runs **immediately**, not a minute later |
| **proof** | `GET http://127.0.0.1:55123/test/claude-rc` |

The last two rows are the same request Victor made twice, in his words: *"poll la
1 min ca ce pornit. daca nu: start in bg"* and *"dupa restart app ma astept sa
reporneasca claude rc automat"*. The tmux server double-forks away from whoever
spawned it, so Remote Control normally survives the rebuild loop (`pkill` +
`open`) untouched — the launch-time check is for the case where it did **not**.

## Why it moved out of launchd

The behaviour is older than this row: since 14 Aug 2026
`~/Library/LaunchAgents/ro.victorrentea.claude-rc.plist` ran the script at login
and re-checked every 5 minutes (`StartInterval 300`; no `KeepAlive`, because
`tmux new-session -d` exits immediately and launchd would have looped it).

That watchdog had no way to be told *no*. Killing the tmux session bought at most
five minutes of quiet before launchd put it back, so the only real off switch was
`launchctl bootout` — not something to reach for mid-workshop, and nothing on
screen ever said whether the server was up.

**The LaunchAgent is therefore booted out and `launchctl disable`d** (22 Sep
2026) rather than left alongside:

```
launchctl bootout  gui/501/ro.victorrentea.claude-rc
launchctl disable  gui/501/ro.victorrentea.claude-rc   # persists across login
```

Two watchdogs racing over one tmux session would make the tick a lie — untick,
and five minutes later the thing is back with the row still saying off. The plist
is left on disk, disabled, with a comment at the top pointing here; re-enabling it
is `launchctl enable` + `bootstrap`, and if that ever happens this row should be
turned off in the same breath.

Nothing is lost by the move: this app is itself a LaunchAgent that is up from
login to shutdown, which is the same lifetime launchd was giving the script.

## Why the script stays

`claude-rc.sh` is launched as-is rather than re-expressed as a Swift `Process`,
because it holds the distinction that cost a fortnight once:

- **`claude remote-control`** (alias `claude rc`) is the **server** — capacity 32,
  and the phone can **create new sessions** against it.
- **`claude --remote-control "<name>"`** is a **flag** that exposes one existing
  interactive session. Until 30 Aug 2026 the script used the flag: the Mac showed
  up on the phone, but the "new session" button had nothing to start.

Plus `--permission-mode auto` (Victor asked explicitly for the classifier, **not**
`--dangerously-skip-permissions` — anything risky becomes a prompt he approves
from the phone) and the `ComputerName` prefix the sessions are named with. One
copy of that command, in the file that has always held it.

## The two shapes of the decision

`ClaudeRemoteControlPolicy.decide(enabled:sessionAlive:)` is a two-bit truth
table, and the asymmetry in it is deliberate: **armed + dead → start**,
**disarmed + alive → kill**, everything else → leave alone. The *tick* never
kills — only the toggle's own edge does, once. An unticked row means "the app is
not minding this", not "the app forbids it", so a session Victor starts by hand
afterwards survives; the alternative would make the off state more intrusive than
the on state.

## Traps

- **tmux is found by path** (`/opt/homebrew/bin/tmux` first). Under launchd this
  process has `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — a bare `tmux` would never be
  found, silently, once a minute, forever.
- **`ANTHROPIC_API_KEY` is stripped from the child**, the Swift spelling of the
  `env -u ANTHROPIC_API_KEY` that fronts every other `claude` launcher here: the
  key in `~/.training-assistants-secrets.env` is out of credit and, exported, it
  shadows the subscription and fails auth. The RC server must not inherit it.
- **tmux is not decoration.** Remote Control needs a real PTY, and neither
  launchd nor an `NSTask` gives one. That is why the session exists at all, and
  also why the server outlives the app that started it.
- **"Alive" is `tmux has-session`, not "connected".** The old watchdog had the
  same blind spot and it bit: 25–30 Aug 2026 it ran five days with *"Remote
  Control disconnected — login expired"* in the pane while the session itself was
  perfectly alive, so nothing restarted it. If the phone cannot open sessions and
  `/test/claude-rc` says `alive:true`, read the pane —
  `tmux capture-pane -p -t claude-rc` — and look for `Connected · Capacity: N/32`.
  Missing banner ⇒ untick the row and tick it back (that kills and restarts).

## Seeing it

```
tmux attach -t claude-rc          # detach with Ctrl-B then D
tmux capture-pane -p -t claude-rc # the banner, without attaching
curl -s 127.0.0.1:55123/test/claude-rc
```
