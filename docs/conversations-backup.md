# 🗄️ Conversations backup to the "Vic" drive

`conversations-backup.sh`, run by `/Applications/Conversations Backup.app`
(an AppleScript applet, `conversations-backup.applescript`), opened by the
LaunchAgent `ro.victorrentea.conversations-backup`. Not part of the Victor
Addons app: no Swift, no menu row. A macOS notification "🗄️ Conversații
salvate pe Vic" appears when a backup ran (or "…a eșuat" when it failed). Asked for on 2026-10-09: keep every AI-agent
conversation, forever, to study later.

## What it does

When `/Volumes/Vic` is mounted and the last good run is older than 20 h, it
merges onto `/Volumes/Vic/ai-conversations/`:

| on the drive | from |
|---|---|
| `claude-code/projects/` | `~/.claude/projects` (transcripts, subagents, tool results, memory) |
| `claude-code/history.jsonl` | `~/.claude/history.jsonl` (every typed prompt) |
| `claude-desktop/local-agent-mode-sessions/` | Claude desktop app's agent sessions |
| `copilot-cli/` | `~/.copilot/session-state`, `session-store.db`, usage summaries, command history |
| `copilot-jetbrains/` | `~/.copilot/jb`, `~/.config/github-copilot/copilot-intellij.db` |
| `vscode-copilot/` | only `chatSessions/`, `chatEditingSessions/` and `workspace.json` from each `workspaceStorage/<hash>/`, plus `emptyWindowChatSessions` |
| `codex/` | `~/.codex/sessions`, `archived_sessions`, `history.jsonl` |

claude.ai web/mobile chats are not on this Mac and are not covered.

## Decisions

- **Merge, never mirror** — rsync without `--delete`. Claude Code prunes
  sessions older than `cleanupPeriodDays` (365); the drive keeps them.
- **A file that shrank locally never erases the longer copy**: before syncing,
  any backed-up file larger than its source is copied to `_shrunk/<date>/`.
- **SQLite stores** go through `sqlite3 .backup` (consistent while being
  written); one current copy, the db already holds the history.
- **Triggers**: `StartOnMount` (any volume mount — plugging the drive in) +
  hourly + at load. Every trigger without the drive, or within 20 h, exits at
  once. The 20 h gate lives on the drive (`.last-success`), so a failed run
  retries on the next trigger.
- **Why an app, not `/bin/bash` straight from launchd** (2026-10-10): the
  first version ran the script from the LaunchAgent and every run died with
  `mkdir: /Volumes/Vic/ai-conversations: Operation not permitted`. TCC only
  grants *Removable Volumes* to an app; a bare shell under launchd has no one
  to grant it to. The applet is that app (bundle id
  `ro.victorrentea.conversations-backup`, signed with the stable
  "Victor Addons Local Code Signing" identity so the grant survives rebuilds,
  `LSUIElement` so it never shows in the Dock). Granted 2026-10-10 17:33.
- **Mount check** (`mount | grep " on /Volumes/Vic ("`) — an empty leftover
  `/Volumes/Vic` folder would otherwise fill the internal disk.
- **macOS's `/usr/bin/rsync` is openrsync**: `--include='*/'` filters do not
  recurse, so the VS Code subset goes through `--files-from`.

## Operating

```
~/.conversations-backup/backup.log                 # local log (copied to the drive on success)
bash conversations-backup.sh --force               # run now, ignore the 20 h gate
CONV_BACKUP_VOLUME=/Volumes/Other bash conversations-backup.sh --force
launchctl kickstart gui/$(id -u)/ro.victorrentea.conversations-backup   # the real path: agent → app → script
```

Install / rebuild the app and reload the agent: `./install-conversations-backup.sh`.
After editing `conversations-backup.sh`, never while a run is going: bash reads
the script as it executes, and an edit mid-run cut the 2026-10-10 first run short.
