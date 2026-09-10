# Quest ODM Operations Console — 1.1.0-preview.6

Quest ODM Operations Console is a portable WPF administration application for governed Quest On Demand Migration workflows. Preview 6 is a corrective release based on `1.1.0-preview.5`. It fixes the post-operation UI callback failure reported by **Create collections and add users** and removes the same detached-closure pattern from every production UI callback.

## Preview 6 bulk-operation callback correction

The Quest engine operation could complete successfully, generate its report, and apply requested changes, but the UI could then fail while displaying the result with:

```text
The term 'Get-BulkResultRows' is not recognized as a name of a cmdlet, function, script file, or executable program.
```

The issue was caused by `GetNewClosure()` creating a detached dynamic module for callbacks that needed helper functions defined in `QuestODMConsole.UI.ps1`. Preview 6 now:

- Stores callback context in the existing script-scoped UI state rather than a detached closure module.
- Restores result-grid rendering for all Bulk Operations, including **Create collections and add users**.
- Preserves the operation name and execute state through asynchronous completion.
- Clears callback context on both success and failure.
- Removes `GetNewClosure()` from all production UI callbacks, including profile loading, OdmApi module actions, task-detail failures, and support-dialog actions.
- Warns that a backend operation is not rolled back when only its success callback fails.
- Adds `Tests\Run-UiCallbackScopeTests.ps1` and static regression guards.

Because the original error occurred after the engine returned success, do not rerun an executed write solely because that UI message appeared. Review the generated report and Quest state first.

## Preview 5 Mapping Collision correction retained

- Empty result categories produce header-only CSVs and valid `No rows.` HTML sections instead of failing parameter binding.
- `SMTP: user@example.com` proxy values are trimmed after the prefix and treated as valid anchors.

## Theme, log maintenance, and membership controls retained

- Main-console and Mapping Collision Utility Light/Dark themes remain persistent.
- The corrected safe brush-mutation implementation remains in place.
- Automatic and manual log retention remains available in both applications.
- Tasks and Collections retain pinned **Add CSV users** and **Remove CSV users** action footers.
- A write still requires global changes enabled, the local execute checkbox, one selected entity, and explicit confirmation.

## Mapping Collision Utility

The separate read-only utility does not require a Quest connection. It exports Active Directory or Entra user inventory collectors, compares normalized identity anchors, and reports internal duplicates, cross-attribute conflicts, one-to-many and many-to-one ambiguity, split anchors, malformed values, inventory-quality issues, and unmatched source objects.

Generated reports include:

- `CollisionDetails.csv`
- `MappingCandidates.csv`
- `AmbiguousMappings.csv`
- `InventoryQualityIssues.csv`
- `UnmatchedSourceObjects.csv`
- `MappingCollisionSummary.html`
- `RunManifest.json`

The collectors currently inventory **user objects only**. See [Mapping Collision Utility](MappingCollisionUtility/README.md).

## Supported baseline

- Windows x64 with WPF.
- Main console: Windows PowerShell 5.1 or PowerShell 7, x64 STA.
- Mapping Collision Utility UI: Windows PowerShell 5.1 x64 STA.
- Quest interactive authentication.
- Validated `OdmApi`: `2.1.396`.
- Per-user data root: `%LOCALAPPDATA%\QuestODMConsole`.

## Installation and launch

1. Extract the complete ZIP into a new directory. Do not overlay Preview 6 onto an older extraction.
2. Confirm `VERSION.txt` contains `1.1.0-preview.6`.
3. Launch `Start-QuestODMConsole.cmd`.
4. Keep global changes disabled until the active Quest organization, project, and workload are verified.

## Validation

Run on a Windows test workstation:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Run-V1Acceptance.ps1
```

Focused tests:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-UiCallbackScopeTests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-LogMaintenanceTests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Run-WpfSmokeTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MappingCollisionUtility\Tests\Run-MappingCollisionTests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\MappingCollisionUtility\Tests\Run-WpfSmokeTest.ps1
```

This package is unsigned. Live Quest writes, AD collection, Entra collection, installed-production-`OdmApi` preflight, and native Windows WPF acceptance remain environment-specific release gates.

## Repository development

The application root is intentionally also the repository root because launchers, tests, governance checks, and release tools use root-relative paths. Do not move the package into a new `src` directory without a coordinated path refactor and full validation.

See:

- `REPOSITORY_SETUP.md` for the initial private GitHub import
- `CONTRIBUTING.md` for branch, validation, and data-handling requirements
- `SECURITY.md` for vulnerability and sensitive-data handling
- `docs/ARCHITECTURE.md` for component boundaries
- `docs/RELEASE_PROCESS.md` for tagging and packaging

No public redistribution license is granted by this private internal source repository. Branding and third-party notices remain governed by `NOTICE.md` and `Resources/BRANDING.md`.
