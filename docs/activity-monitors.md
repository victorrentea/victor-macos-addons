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

## Bottom-left flash: once per file, not once per open

Both editors POST to the same `/intellij/file-opened` on the add-on (the VS Code
side is `victor-vsc/open-file-reporter.js`), and while a session is live the
add-on flashes `📄 <basename>` bottom-left. The editors' own dedup only skips a
file that repeats **consecutively**, which misses the way files are actually
re-opened: A, B, back to A — and A flashed again. That second flash carries no
information and pulls the eye away mid-sentence.

`OpenedFileBannerLog` gates the banner on a path→timestamp log kept in
`UserDefaults` (a plist on disk, so a `build-app.sh` restart doesn't hand back
announcements already made this morning). A file flashes the first time it is
seen and then stays silent for 20h — longer than a training day, short enough
that tomorrow starts clean. Keyed by **full path**, since the banner shows only
the basename and two modules' `pom.xml` are two different files. The log prunes
expired entries on every write and caps at 500 paths, newest kept.

The WebSocket push to the daemon is **not** gated — it still gets every open, so
the participants' git-repo list is unaffected. `OpenedFileBannerLog.reset()`
forgets everything if the flashes are ever wanted back.
