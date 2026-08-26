# Deployment & App Lifecycle

- **App bundle**: `./build-app.sh` creates `/Applications/Victor Addons.app` (Spotlight-searchable)
- **LaunchAgent**: `./install-startup.sh` symlinks plist, loads LaunchAgent for login auto-start
- Re-run `build-app.sh` after changes to `start.sh`, icons, or app identity
- `start.sh` exports `VICTOR_ADDONS_ROOT` so the app can resolve `whisper-transcribe/whisper_runner.py` reliably when launched from `/Applications` bundle.

**Operational note (2026-04):** To avoid repeated Accessibility re-prompts across deploys, app builds should be signed with a stable identity. `build-app.sh` auto-detects and uses `Victor Addons Local Code Signing` from `login.keychain-db` when available (or `CODESIGN_IDENTITY` if set), otherwise falls back to ad-hoc signing.

**Operational note (2026-04):** On app launch, Accessibility is checked without forcing a system prompt (`AXIsProcessTrusted()`). Missing permission is reported in-app; prompting/opening System Settings should be user-initiated.

**Operational note (2026-05):** Single-instance lock + uniform launch behavior:
- `/tmp/VictorAddons.pid` lock with `proc-name` verification before SIGTERM (avoids killing unrelated PIDs after a stale PID file from a hard crash).
- SIGTERM is delivered via `DispatchSource.makeSignalSource` (not raw `signal()`), so the handler can call `AppDelegate.tearDownForReplacement()` which `SIGKILL`s the Whisper subprocess synchronously. Previous design left whisper orphan until its parent-watch sentinel noticed (up to 2s).
- New-instance grace timeout extended from 200ms to ~1s before falling back to SIGKILL on the previous instance.
- On launch, if stderr is not already a regular file (i.e. not piped by `start.sh`), `main.swift` redirects stdout/stderr to `/tmp/victor-macos-addons.log` itself — so launching via `open` (Spotlight, Login Items) logs to the same file as a LaunchAgent boot.
- Result: `pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"` and `launchctl kickstart -k gui/$UID/ro.victorrentea.macos-addons` are now behavioral equivalents.

**Operational note (2026-07): clicking the app again replaces it (`AppRelaunch`).** The hand-over above was always correct — and almost never ran. LaunchServices treats `open` of an already-running bundle as an **activation, not a launch**: no second process starts, so nothing ever writes a new pid, and clicking "Victor Addons" in Spotlight while it was wedged did *precisely nothing*. The only way out was `pkill` in a terminal. Two entry points now close that from the other side, both funnelling into `AppRelaunch.relaunch`:
- `AppDelegate.applicationShouldHandleReopen` — the reopen event macOS *does* deliver to the running instance. For a menu-bar app with no windows, "I opened it again" only ever means "give me a fresh one". Reopens within 5 s of launch are ignored (AppKit can deliver one as part of our own launch; restarting on that would loop).
- ~~the 🔁 Restart menu item~~ — **removed 2026-08-14**: reopening the app *is* the gesture you reach for when something is wedged, so the row was a second way to say it. `applicationShouldHandleReopen` remains the whole story.

The relaunch is performed by a **detached `/bin/sh` helper**, not by us, because the one thing that must survive is the relaunch itself: it polls until our pid is gone (10 s ceiling, then launches anyway) and only then runs `open -n`, so it behaves identically whether we exit cleanly, are SIGKILLed, or crash on the way out. `-n` forces a genuinely new process even if LaunchServices still counts the dying one as running. The target path travels in the **environment, not argv**, so the helper's command line never contains "Victor Addons" — otherwise the deploy habit of `pkill -f "Victor Addons"` would kill the very helper meant to bring the app back. We then `tearDownForReplacement()` (SIGKILLing whisper) and `exit(0)`, so the new instance inherits a Mac with no orphan fighting it for the microphone. A re-entrancy flag collapses a burst of reopen events into one helper; a failed spawn leaves the old instance up rather than killing it with nothing to replace it.

**Operational note (2026-06):** `TerminalTiler` reads/writes Terminal window geometry through the in-process **Accessibility API** (`AXUIElement`), relying only on this app's own Accessibility grant (the same one behind the global event tap). It previously shelled out to `osascript` + "System Events" UI scripting, which needs a *separate* Automation (Apple Events) grant; after a re-sign that grant's stored code requirement no longer matched the running binary, so the Apple Event blocked on a consent prompt a headless `osascript` subprocess can't surface and tiling silently hit the 5s timeout (symptom: `AppleScript failed: Timed out after 5.0s` in the log; ⌘⌃A and the menu item both no-op). The AX path needs no Automation permission and never spawns a subprocess.
