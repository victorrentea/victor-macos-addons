# 🗄️ Conversations backup to the "Vic" drive

`conversations-backup.sh` + LaunchAgent `ro.victorrentea.conversations-backup`
(no Swift, no menu row). Asked for on 2026-10-09: keep every AI-agent
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
- **Mount check** (`mount | grep " on /Volumes/Vic ("`) — an empty leftover
  `/Volumes/Vic` folder would otherwise fill the internal disk.
- **macOS's `/usr/bin/rsync` is openrsync**: `--include='*/'` filters do not
  recurse, so the VS Code subset goes through `--files-from`.

## Operating

```
~/.conversations-backup/backup.log                 # local log (copied to the drive on success)
bash conversations-backup.sh --force               # run now, ignore the 20 h gate
CONV_BACKUP_VOLUME=/Volumes/Other bash conversations-backup.sh --force
launchctl kickstart gui/$(id -u)/ro.victorrentea.conversations-backup
```

Install: `ln -sf "$PWD/ro.victorrentea.conversations-backup.plist" ~/Library/LaunchAgents/`
then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ro.victorrentea.conversations-backup.plist`.
