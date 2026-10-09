#!/bin/bash
# Copies every local AI-agent conversation (Claude Code, Claude desktop, Copilot
# CLI/JetBrains/VS Code, Codex) onto the external drive "Vic", at most once a day,
# as soon as the drive shows up. Kept for studying the sessions later.
#
# Merge, never mirror: nothing is ever deleted on the drive, so sessions that
# Claude Code's cleanupPeriodDays (or any other tool) prunes locally stay in the
# backup forever. A file that got SHORTER locally (rewritten, compacted) would
# overwrite the longer copy, so that older copy is first set aside under
# _shrunk/<date>/ — no conversation text is ever lost to a sync.
#
# Fired by ro.victorrentea.conversations-backup: on every volume mount
# (StartOnMount) plus hourly, so a drive left plugged in still gets its daily run.
#
#   conversations-backup.sh          # back up if the drive is here and >20h passed
#   conversations-backup.sh --force  # back up now regardless of the last run
#
# Env: CONV_BACKUP_VOLUME (default /Volumes/Vic), CONV_BACKUP_MIN_HOURS (20).

set -u

VOLUME="${CONV_BACKUP_VOLUME:-/Volumes/Vic}"
MIN_HOURS="${CONV_BACKUP_MIN_HOURS:-20}"
DEST="$VOLUME/ai-conversations"
STATE="$HOME/.conversations-backup"
LOG="$STATE/backup.log"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$STATE"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Keep the log small: last 2000 lines.
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 4000 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# The drive must be a real mount, not a leftover empty folder under /Volumes
# (writing there would silently fill the internal disk).
[ -d "$VOLUME" ] || exit 0
mount | grep -q " on $VOLUME (" || exit 0

STAMP="$DEST/.last-success"
if [ "$FORCE" = 0 ] && [ -f "$STAMP" ]; then
    age_h=$(( ( $(date +%s) - $(stat -f %m "$STAMP") ) / 3600 ))
    [ "$age_h" -lt "$MIN_HOURS" ] && exit 0
fi

# One run at a time: StartOnMount fires for every mount, DMGs included.
LOCK="$STATE/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    # A lock older than 6h is from a run that died (drive yanked, Mac slept).
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +360 2>/dev/null)" ]; then
        rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

mkdir -p "$DEST" || { log "cannot create $DEST"; exit 1; }
TODAY=$(date +%Y-%m-%d)
SHRUNK="$DEST/_shrunk/$TODAY"
FAILED=0
COPIED=0
START=$(date +%s)
log "start → $DEST"

# Before overwriting, move aside any backed-up file that is bigger than its
# local source: the local one lost content, the backup still has it.
# Sizes are listed in one stat batch per side and joined in awk — a per-file
# stat would fork tens of thousands of times over ~/.claude/projects.
sizes() {  # <dir> → "size<TAB>relative path" for every file under it
    (cd "$1" 2>/dev/null && find . -type f -exec stat -f '%z%t%N' {} + 2>/dev/null) | sed 's|	\./|	|'
}
protect_shrunk() {  # <src dir|file> <dest dir|file>
    local src="$1" dst="$2" rel
    [ -e "$dst" ] || return 0
    if [ -f "$src" ]; then
        [ "$(stat -f %z "$dst")" -gt "$(stat -f %z "$src")" ] || return 0
        rel="${dst#"$DEST"/}"
        mkdir -p "$SHRUNK/$(dirname "$rel")" && cp -p "$dst" "$SHRUNK/$rel"
        log "shrunk locally, kept old copy: _shrunk/$TODAY/$rel"
        return 0
    fi
    sizes "$src" > "$STATE/src.sizes"
    sizes "$dst" > "$STATE/dst.sizes"
    awk -F'\t' 'NR==FNR { s[$2]=$1; next } ($2 in s) && $1+0 > s[$2]+0 { print $2 }' \
        "$STATE/src.sizes" "$STATE/dst.sizes" |
    while IFS= read -r f; do
        rel="${dst#"$DEST"/}/$f"
        mkdir -p "$SHRUNK/$(dirname "$rel")" && cp -p "$dst/$f" "$SHRUNK/$rel"
        log "shrunk locally, kept old copy: _shrunk/$TODAY/$rel"
    done
}

# sync <label> <source> <dest-relative> [extra rsync args...]
# A source dir is copied as its contents into dest; a source file into dest/.
sync() {
    local label="$1" src="$2" rel="$3"; shift 3
    [ -e "$src" ] || return 0
    local dst="$DEST/$rel" out="$STATE/rsync.out" n rc
    mkdir -p "$dst"
    if [ -d "$src" ]; then
        protect_shrunk "$src" "$dst"
        /usr/bin/rsync -rtl --out-format='%n' "$@" "$src/" "$dst/" > "$out" 2>>"$LOG"
    else
        protect_shrunk "$src" "$dst/$(basename "$src")"
        /usr/bin/rsync -tl --out-format='%n' "$@" "$src" "$dst/" > "$out" 2>>"$LOG"
    fi
    rc=$?
    n=$(grep -vc '/$' "$out")
    if [ "$rc" -ne 0 ]; then FAILED=1; log "  $label: rsync exit $rc"; fi
    COPIED=$((COPIED + n))
    [ "$n" -gt 0 ] && log "  $label: $n file(s)"
    return 0
}

# SQLite stores are copied through the online-backup API, so a db being written
# to right now still lands consistent. One current copy is enough: the db itself
# accumulates the whole history.
sync_db() {  # <label> <db> <dest-relative>
    local label="$1" src="$2" rel="$3"
    [ -f "$src" ] || return 0
    mkdir -p "$DEST/$rel"
    local tmp="$STATE/$(basename "$src").snapshot"
    rm -f "$tmp"
    if /usr/bin/sqlite3 "$src" ".backup '$tmp'" 2>>"$LOG"; then
        sync "$label" "$tmp" "$rel"
        mv -f "$DEST/$rel/$(basename "$tmp")" "$DEST/$rel/$(basename "$src")" 2>/dev/null
        rm -f "$tmp"
    else
        FAILED=1; log "  $label: sqlite backup failed"
    fi
}

C="$HOME/.claude"
sync "claude-code transcripts" "$C/projects"        claude-code/projects
sync "claude-code prompts"     "$C/history.jsonl"   claude-code
sync "claude-desktop agent"    "$HOME/Library/Application Support/Claude/local-agent-mode-sessions" \
                                                    claude-desktop/local-agent-mode-sessions

sync "copilot-cli sessions"    "$HOME/.copilot/session-state" copilot-cli/session-state
sync "copilot-cli summaries"   "$HOME/.copilot/usage-session-summaries.json" copilot-cli
sync "copilot-cli history"     "$HOME/.copilot/command-history-state.json"   copilot-cli
sync_db "copilot-cli store"    "$HOME/.copilot/session-store.db"             copilot-cli
sync "copilot-jetbrains"       "$HOME/.copilot/jb"                           copilot-jetbrains/jb
sync_db "copilot-intellij db"  "$HOME/.config/github-copilot/copilot-intellij.db" copilot-jetbrains

# VS Code Copilot Chat: only the chat sessions, plus workspace.json so each
# hashed folder can be traced back to the project it belongs to. A file list,
# because macOS's openrsync does not recurse through --include='*/' filters.
VSC="$HOME/Library/Application Support/Code/User"
if [ -d "$VSC/workspaceStorage" ]; then
    (cd "$VSC/workspaceStorage" && find . -type f \( -name workspace.json \
        -o -path '*/chatSessions/*' -o -path '*/chatEditingSessions/*' \) | sed 's|^\./||') \
        > "$STATE/vscode.files"
    sync "vscode chat (workspaces)" "$VSC/workspaceStorage" vscode-copilot/workspaceStorage \
        --files-from="$STATE/vscode.files"
fi
sync "vscode chat (no folder)"  "$VSC/globalStorage/emptyWindowChatSessions" \
                                vscode-copilot/emptyWindowChatSessions

sync "codex sessions"          "$HOME/.codex/sessions"          codex/sessions
sync "codex archived"          "$HOME/.codex/archived_sessions" codex/archived_sessions
sync "codex prompts"           "$HOME/.codex/history.jsonl"     codex

took=$(( $(date +%s) - START ))
if [ "$FAILED" = 0 ]; then
    date '+%Y-%m-%d %H:%M:%S' > "$STAMP"
    cp "$LOG" "$DEST/backup.log" 2>/dev/null
    log "done: $COPIED file(s) new/updated in ${took}s, $(du -sh "$DEST" 2>/dev/null | cut -f1) on drive"
else
    log "finished WITH ERRORS in ${took}s ($COPIED file(s) copied) — will retry on the next trigger"
    exit 1
fi
