# Rollback

Keep the last build your team accepted before evaluating RC1. Extract RC1 into a separate folder and avoid mixing release files.

Close the console and utility, preserve reports and logs from `%LOCALAPPDATA%\QuestODMConsole`, then launch the previously accepted build from its own folder. Verify its version and settings before connecting. Back up per-user settings before changing them for compatibility.

Changing application versions does not undo submitted Quest operations, schedules, template imports or acknowledgements. Inspect service state separately. Never retry a write merely because a UI error or timeout occurred.
