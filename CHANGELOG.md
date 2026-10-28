# RC2 — 1.1.0-rc.2 (2026-10-28)

Added the organization-scoped Active Directory/device workspace, 27 inventory types, 20 guarded action forms, AD-specific readiness, exact-ID/CSV targeting, redacted SDK snapshots, one-use previews, partial-failure journals and three AD guide chapters. Added real SDK identity and metadata tests plus light/dark WPF coverage on both supported PowerShell hosts. Live Quest acceptance remains deferred by the user. Environment/workflow design, agent deployment, new profiles and unexported operations remain explicit web-console handoffs.

# 1.1.0-rc.2 — 2026-10-28

Added Operations Center create/update forms, typed inventories, management actions, guides and pilot evidence. Fixed CSV validation, context/reporting, empty response handling, credential redaction and WPF usability. See RELEASE_NOTES.md and AUDIT_REPORT.md. Live Quest acceptance and signing remain pending.

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

# Changelog

## 1.1.0-preview.6

- Corrected Bulk Operations success callbacks that could lose access to UI helper functions after the Quest engine completed.
- Restored result-grid rendering for **Create collections and add users** and all other Bulk Operations.
- Replaced detached `GetNewClosure()` callbacks with script-scoped context or sender-bound event context.
- Applied the same correction to profile loading, OdmApi module actions, task-detail failures, and support-dialog actions.
- Added a warning that callback failure does not roll back an already completed backend operation.
- Added callback-scope regression tests and static guards.
- Retained all Preview 5 Mapping Collision corrections and Preview 4 theme/log-maintenance changes.

## 1.1.0-preview.5

- Corrected the Preview 3 WPF `BorderBrush` startup failure.
- Explicitly kept runtime theme brushes unfrozen in both production XAML files.
- Reworked theme updates to mutate `SolidColorBrush.Color` in place, with a typed `IDictionary` clone fallback.
- Made individual theme-brush failures non-fatal so the application can fall back to its XAML Light palette.
- Added configurable startup retention and manual historical-log clearing to the main console and Mapping Collision Utility.
- Added pruning for `OperationHistory.jsonl`, bounded bootstrap-log handling, and active-session protection.
- Added dedicated log-maintenance tests and frozen-brush WPF regression coverage.
- Retained Preview 3 contrast/dark-mode behavior and Preview 2 CSV membership action layout.

## 1.1.0-preview.3

- Corrected Mapping Collision Utility card foreground contrast.
- Added persistent Light/Dark themes to the main console and Mapping Collision Utility.

## 1.1.0-preview.2

- Restored visible task and collection CSV membership action controls with pinned action footers.

## 1.1.0-preview.1

- Integrated the separate Mapping Collision Utility and user inventory collectors.

## 1.0.3

- Stable V1 layout with Quest logo and accepted tab geometry.
