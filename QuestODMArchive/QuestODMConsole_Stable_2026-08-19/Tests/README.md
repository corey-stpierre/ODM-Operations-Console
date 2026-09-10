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
