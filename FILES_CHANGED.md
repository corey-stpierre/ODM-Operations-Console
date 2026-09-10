# Files Changed for 1.1.0-preview.6

Baseline: Quest ODM Operations Console `1.1.0-preview.5`

## Runtime changes

- `QuestODMConsole.UI.ps1`: removes detached production callbacks; adds script-scoped bulk/profile/module context, sender-bound support-dialog context, explicit callback cleanup, and safer callback-failure guidance.
- `Engine/Common.ps1` and `Engine/Context.ps1`: release-version marker updates only.

## Test changes

- Added `Tests/Run-UiCallbackScopeTests.ps1`.
- Expanded native and platform-neutral validation to reject production `GetNewClosure()` calls and require the corrected Bulk callback markers.
- Updated the complete acceptance suite documentation.

## Metadata and documentation

Version, build, compatibility, release, support, audit, feature, signing, validation, and manifest records were updated for Preview 6.

## Preserved implementation

`Engine/Bulk.ps1`, the Mapping Collision analysis engine, both collectors, packaged sample inventories, Quest membership implementation, task factory logic, local preflight logic, Quest logo, launcher scripts, and all 16 legacy scripts are unchanged from Preview 5.

Use the complete Preview 6 package. Do not overlay individual files onto an older extraction.
