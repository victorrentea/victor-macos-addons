#!/bin/bash
# Builds "/Applications/Conversations Backup.app" from conversations-backup.applescript
# and (re)loads the LaunchAgent that opens it. Signed with the same stable local
# identity as Victor Addons, so the removable-volume grant survives a rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/Conversations Backup.app"
IDENTITY="Victor Addons Local Code Signing"
PLIST="$HOME/Library/LaunchAgents/ro.victorrentea.conversations-backup.plist"

rm -rf "$APP"
osacompile -o "$APP" conversations-backup.applescript
INFO="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$INFO"           # no Dock icon
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ro.victorrentea.conversations-backup" "$INFO" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ro.victorrentea.conversations-backup" "$INFO"
/usr/libexec/PlistBuddy -c "Add :NSRemovableVolumesUsageDescription string 'Copies your AI conversations onto the Vic drive.'" "$INFO"
if security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi

ln -sf "$PWD/ro.victorrentea.conversations-backup.plist" "$PLIST"
launchctl bootout "gui/$(id -u)/ro.victorrentea.conversations-backup" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $APP + LaunchAgent"
