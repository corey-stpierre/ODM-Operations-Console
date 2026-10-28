# RC1 test entry point

Use `Run-RcAcceptance.ps1 -ModuleManifest <installed OdmApi.psd1>` with Windows PowerShell 5.1 and PowerShell 7 in x64 STA. It runs the ordinary full acceptance suite, then isolated native-command metadata/behavior tests. No authentication or service mutations are performed. Native tests require a locally installed vendor module; 2.1.401 is the full catalog baseline. Older modules are tested for correct unavailability gating.

`Run-OperationsWpfTests.ps1` tests dynamic fields, gates, context resets, callbacks, themes and layout. Optional `-ScreenshotDirectory` saves rendered UI evidence. `Run-OperationsCenterTests.ps1` tests catalog contracts, choices, guarded creation, token expiry/invalidation/replay, CSV structure and ambiguous writes. `Run-ManagementTests.ps1` exercises actual vendor setters, schedule/hold, rename, template serialization and event acknowledgement with backend fixtures.

Use an accessible temporary directory when the default OS temporary location is restricted. Test reports use synthetic identifiers only. Tests do not establish migration correctness or production readiness. Record live acceptance separately in `Samples/PilotAcceptance.csv`.

## Prior test documentation

# Test Suite

## Complete Windows acceptance

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Run-V1Acceptance.ps1
```

Expected final marker: `V1 ACCEPTANCE: PASS`.

The suite performs native PowerShell parsing, production XAML/UI validation, callback-scope and parser/cardinality regressions, mock-engine and worker tests, main-console WPF tests, Overview persistence, branding/tab geometry, governance tests, Mapping Collision Utility engine/WPF tests, log-maintenance tests, and installed production `OdmApi` preflight.

## Preview 6 callback and theme regression

`Run-WpfSmokeTest.ps1` loads the production main-console XAML, confirms theme brushes are unfrozen, executes the production Dark and Light palette functions, and forces the previously failing frozen-brush fallback path through a typed `IDictionary`. It also retains the minimum-size CSV-action containment checks.

`MappingCollisionUtility\Tests\Run-WpfSmokeTest.ps1` applies the equivalent checks to the utility.


## UI callback-scope regression

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-UiCallbackScopeTests.ps1
```

This test parses the production UI controller and verifies that asynchronous and WPF event callbacks do not use `GetNewClosure()`. Detached closure modules cannot resolve helper functions defined in the UI script scope, which caused the successful **Create collections and add users** operation to fail only while rendering its result grid.

## Log-maintenance tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-LogMaintenanceTests.ps1
```

The test creates isolated console and utility log stores and verifies retention cutoffs, active-session preservation, bootstrap reset, operation-history pruning, malformed-line preservation, clear-all behavior, and utility log cleanup.

## Mapping Collision Utility tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MappingCollisionUtility\Tests\Run-MappingCollisionTests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\MappingCollisionUtility\Tests\Run-WpfSmokeTest.ps1
```

## Platform-neutral checks

```text
python Tests\StaticValidation.py
python Tests\RuntimeSourceAudit.py
python MappingCollisionUtility\Tests\StaticValidation.py
```
# Preview 7 workload tests

`Run-ContentWorkloadTests.ps1` runs all ten task routes with the offline Quest mock,
including exact-ID resolution, duplicate input, Safe Mode, typed membership checks,
held tasks, reruns, invalid CSVs, template type/ownership, and partial writes.
`Run-ContentWpfTests.ps1` requires Windows x64 STA and checks the actual content
controller, single-row result rendering, context reset, and write gates.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-ContentWorkloadTests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Run-ContentWpfTests.ps1
```

`Run-ContentApiContractTests.ps1 -ModuleManifest <absolute OdmApi.psd1 path>` checks
the installed parameters and configured default values without service calls.
The feature tests also run from the full acceptance runner. Known existing baseline
acceptance failures are listed in `WORKLOAD_VALIDATION.txt`; these tests do not waive them.
Python checks require Pygments (the CI workflow installs version 2.21.0).



RC2 adds `Run-ActiveDirectoryTests.ps1` to the isolated RC acceptance runner and `Run-ActiveDirectoryWpfTests.ps1` to static acceptance. The AD suite reads installed metadata for 27 getters and 20 actions, uses a real SDK Device model, and replaces only the console service-call boundary. It validates parameter conversions and console behavior without invoking compiled Quest AD cmdlets or authenticating. WPF tests exercise org-only AD entry, previews, context isolation, write gates, input invalidation and light/dark layout at 1180x760. Connected outcomes belong in `Samples/ActiveDirectoryPilotAcceptance.csv`.
