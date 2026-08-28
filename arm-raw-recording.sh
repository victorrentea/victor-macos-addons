#!/bin/bash
# Arm the raw-audio capture for a session nobody will be at a laptop to start.
#
# Two steps, and the second is the one that is easy to forget: whisper reads
# WHISPER_RECORD_RAW *at launch*, so creating the flag file changes nothing
# until the process restarts. Killing it is the restart — TranscriptionController
# has a 60 s heartbeat that brings whisper back whenever it finds it dead while
# still on AC, so the recording begins within a minute and nothing else has to
# know this script exists.
#
# On battery there is no whisper to kill and none to restart; the flag simply
# waits, and recording starts when the laptop is plugged in. That is the right
# behaviour, not a gap: the corpus is worth having only when the room is.
set -u

OUT="/Users/victorrentea/workspace/victor-macos-addons/addons-output"
FLAG="$OUT/.record-raw-audio"
LABEL="ro.victorrentea.arm-raw-recording"

mkdir -p "$OUT"
date -u +"%Y-%m-%dT%H:%M:%SZ armed by $LABEL" > "$FLAG"
echo "$(date '+%F %T') armed: $FLAG"

if pkill -f "whisper-transcribe/whisper_runner.py"; then
  echo "$(date '+%F %T') killed whisper; the 60s heartbeat restarts it with recording on"
else
  echo "$(date '+%F %T') whisper was not running (battery?) — the flag stands, recording starts on AC"
fi

# One-shot. This was scheduled for one specific morning, and a job that quietly
# comes back a year later to record a room is precisely what this feature is
# careful not to be.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "$(date '+%F %T') unscheduled itself"
