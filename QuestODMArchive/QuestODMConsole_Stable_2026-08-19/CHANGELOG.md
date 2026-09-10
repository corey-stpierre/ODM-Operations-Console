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
