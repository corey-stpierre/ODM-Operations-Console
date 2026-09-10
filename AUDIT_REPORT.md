# Audit Report — 1.1.0-preview.6

> **Repository preparation note (2026-08-25):** This file records the original `1.1.0-preview.6` release audit. The GitHub-ready tree adds repository controls and sanitizes legacy usage examples; counts describing the original release archive remain historical. See `docs/REPOSITORY_PREPARATION.md`.


## Scope

This audit compares Preview 6 with `1.1.0-preview.5` and addresses the observed post-success Bulk Operations UI callback failure.

## Findings

- The Quest engine returned a successful Bulk result before the UI exception occurred.
- `Invoke-BulkFromUi` wrapped its success callback in `GetNewClosure()`, which created a detached dynamic module.
- That detached callback could not resolve `Get-BulkResultRows` or other helper functions defined in the UI script scope.
- The backend operation was not rolled back; only result rendering and subsequent refresh failed.
- Preview 6 stores the operation display name and execute state in script-scoped UI state and executes the callback without a detached closure.
- All other production `GetNewClosure()` uses were audited and removed to prevent equivalent latent failures.
- Support-dialog event context is now attached to each button's `Tag`; asynchronous profile/module/bulk context is stored in the single-operation UI state.
- Callback failure messaging now explicitly instructs the operator to verify reports and Quest state before retrying an executed write.

## Regression posture

- Preview 5 Mapping Collision engine corrections are retained.
- Preview 4 theme and log-retention corrections are retained.
- Preview 2 CSV membership action containment and execution controls are retained.
- Engine/Bulk.ps1, membership logic, task factory logic, collectors, sample inventories, and all 16 legacy scripts are unchanged except for release markers outside those preserved implementations.

## Build-host limits

Platform-neutral validation can verify source structure, AST/lexical balance, callback markers, absence of production `GetNewClosure()`, XAML/JSON parsing, resource references, manifests, and archive integrity. Native PowerShell callback execution, WPF rendering, installed `OdmApi`, live Quest, and live collector checks require Windows and are not represented as passed on the Linux build host.

## Platform-neutral result

Static validation, runtime source audit, callback-scope validation, main/utility XAML parsing, JSON parsing, resource resolution, UTF-8/BOM checks, sample validation, internal-manifest verification, ZIP CRC testing, and clean-extraction byte comparison passed. The package contains 106 files, including a 105-entry internal SHA-256 manifest.
