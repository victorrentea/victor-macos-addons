-- "Conversations Backup.app": the app macOS grants removable-drive access to.
-- Opened by the ro.victorrentea.conversations-backup LaunchAgent, it runs
-- conversations-backup.sh and posts a notification only when something
-- happened (a backup ran, or it failed). Built by install-conversations-backup.sh.
on run
	set backupScript to "/Users/victorrentea/workspace/victor-macos-addons/conversations-backup.sh"
	try
		set summary to do shell script "/bin/bash " & quoted form of backupScript
		if summary is not "" then display notification summary with title "🗄️ Conversații salvate pe Vic"
	on error errText
		display notification errText with title "🗄️ Backup conversații a eșuat"
	end try
end run
