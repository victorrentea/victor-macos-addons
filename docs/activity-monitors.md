# Activity Monitors (PowerPoint, IntelliJ)

Python sidecars feeding the training-assistant daemon.

## powerpoint-monitor
Polls PowerPoint via osascript every 3s, writes `activity-slides-YYYY-MM-DD.md`:
- Activity lines with per-slide timings: `10:51:00 AI Coding.pptx - s12:10s, s13:20s`
- Pointer last line: `AI Coding.pptx:15` (read by training-assistant daemon every 0.5s)
- New line only on deck change, timings accumulate on same line
- Always runs (no toggle)

**Tech**: Python 3.12, osascript
**Output**: `TRANSCRIPTION_FOLDER/activity-slides-YYYY-MM-DD.md`

## intellij-monitor
Polls IntelliJ via osascript every 10s (only when frontmost), sends `git_file_opened` WS message to daemon when the open file changes (deduplicates against last sent value):
- Skips duplicate consecutive lines
- Training-assistant daemon reads this to provide git repos list to session participants
- Always runs (no toggle)

**Tech**: Python 3.12, osascript, git CLI
**Output**: WS message `{"type": "git_file_opened", "url": "...", "branch": "...", "file": "..."}`

## Who deduplicates an opened file (three layers, one identity)

The same event passes three filters, and they are deliberately not the same
filter:

| layer | key | scope | what it protects |
|---|---|---|---|
| editors (`live-coding` `OpenFileReporter.kt`, `victor-vsc/open-file-reporter.js`) | `rawRemoteUrl\|relPath` | **consecutive only** | a ⌘P walked through ten files flooding the wire |
| add-on, banner only (`OpenedFileBannerLog`) | canonical repo + relPath | 20h, on disk | the bottom-left flash repeating for a file already announced |
| daemon (`training-assistant` `files_md._record_into_folder`) | canonical repo + relPath | the whole session | `opened-files.md` growing duplicate rows |

**The WebSocket push is never gated on the banner log.** A repeat still carries
information to the daemon: it refreshes the entry's timestamp, follows a branch
switch, and retries a link that came back `rate-limited`, `unknown` or
`not-pushed` the first time. Muting the banner must not cost the list an event —
so `AppDelegate` pushes first and consults the log only for the flash.

`files_md`'s key is the authoritative definition of "the same file", and
`OpenedFileBannerLog.identity(url:file:)` mirrors its `_canonical_repo_url`:
host lowercased, `.git` and trailing slash gone, everything past `owner/repo`
dropped. The repo has to be in the key because `file` is **repo-relative** — a
path-only key mutes `pom.xml` in every repo but the first one opened that day.
Non-GitHub remotes still flash (the daemon refuses to list those, but the banner
is local awareness); `(none)`, the sentinel for "project open, no file
selected", flashes in neither.

The banner window is 20h: longer than a training day, so a file opened at 9:00
never flashes again at 16:00, short enough that tomorrow starts clean. It lives
in `UserDefaults` so a `build-app.sh` restart doesn't replay the morning; the log
prunes expired entries on every write and caps at 500 paths, newest kept.
`OpenedFileBannerLog.reset()` forgets everything.
