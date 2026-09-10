# Rollback Guide

## Recommended rollback target

The stable rollback target is **Quest ODM Operations Console 1.0.3**. Preview 3 is not recommended as a rollback target because the supplied startup log demonstrated its theme-resource startup failure. Preview 2 may be retained only as a controlled test fallback when the Mapping Collision Utility is required without dark mode.

## Procedure

1. Close the main console and Mapping Collision Utility.
2. Preserve any required reports or logs from `%LOCALAPPDATA%\QuestODMConsole`.
3. Rename or remove the extracted Preview 6 application directory.
4. Extract the selected rollback archive into a clean directory.
5. Do not merge files from different releases.
6. Launch the rollback build and verify `VERSION.txt` before connecting to Quest.

Per-user settings are forward-compatible for common fields. A rollback build will ignore unknown `LogRetentionDays` data where applicable. Deleting `%LOCALAPPDATA%\QuestODMConsole\Config\QuestODMConsole.settings.json` resets main-console preferences; deleting the utility settings file resets only the Mapping Collision Utility preferences.

Rollback does not reverse Quest operations already submitted. Review and reverse those migration changes separately when required.
