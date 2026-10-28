# Preview 7 - Workload console extension (2026-10-15)

- Added Teams/groups/chats, SharePoint, and Power BI typed object inventory with CSV export.
- Added complete-file CSV validation, collection population, and ten task creation routes.
- Migration templates are checked for project ownership and exact task type.
- Power BI uses explicit workspace settings and an operator-supplied target administrator.
- New tasks use an unscheduled start; creation never calls Start-OdmTask.
- Existing task names are skipped. Ambiguity, foreign IDs, and inconsistent task groups block writes.
- Typed membership verification covers groups, chats, gateways, and connections without falling back to the default object type.
- Results include object/entity IDs, settings, row status, errors, and report paths.
- Added offline engine, WPF controller, and installed API contract tests.

Validation and known baseline failures are recorded in WORKLOAD_VALIDATION.txt.

---

# Quest ODM Operations Console 1.1.0-preview.6 Release Notes

**Build:** `V1.1-PREVIEW-20260817.6`  
**Immediate baseline:** `1.1.0-preview.5`  
**Stable baseline:** `1.0.3`

## Corrected Bulk Operations success callback

A Bulk operation could finish successfully in the engine and then fail only while updating the UI. The observed **Create collections and add users** failure reported that `Get-BulkResultRows` was not recognized.

The operation itself was not rolled back. Preview 6 corrects the callback boundary by keeping callback context in script-scoped UI state and invoking result helpers from the original UI script session state.

## Broader callback audit

The same detached `GetNewClosure()` pattern was removed from every production UI callback:

- Bulk Operations result rendering
- Configuration-profile Safe Mode reset
- OdmApi install/update completion
- Task-detail failure handling
- Support-error dialog buttons

A new callback-scope regression test and platform-neutral static guards prevent the pattern from returning.

## Retained corrections

- Preview 5 Mapping Collision zero-row report safety and spaced `SMTP:` normalization.
- Preview 4 startup theme correction and log maintenance.
- Preview 3 card contrast and dual Light/Dark themes.
- Preview 2 task/collection CSV membership action layout and execution controls.
- Stable V1 tabs, Quest logo, Safe Mode, compatibility policy, Task Factory, bulk workflows, diagnostics, and support-bundle behavior.

## Validation status

Platform-neutral source, XAML, JSON, resource, checksum, package, callback-scope, and clean-extraction checks are recorded in `BUILD_VALIDATION.txt` and `V1_RELEASE_VALIDATION.json`. Native Windows PowerShell/WPF and live Quest tests are included but were not executable on the Linux build host.
