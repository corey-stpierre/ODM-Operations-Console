# Support Guide

## Build identification

- Product: Quest ODM Operations Console
- Release: `1.1.0-rc.2`
- Build: `V1.1-RC2-20261028`
- Offline-validated `OdmApi`: `2.1.396` and `2.1.401`; full catalog baseline `2.1.401`
- Main UI host: Windows PowerShell 5.1 or PowerShell 7 x64 STA
- Utility UI host: Windows PowerShell 5.1 x64 STA

Include `VERSION.txt`, `Config\BuildInfo.json`, the current session log, and a sanitized support bundle with an issue report.

## Bulk callback troubleshooting

| Symptom | Action |
|---|---|
| `Get-BulkResultRows` is not recognized after **Create collections and add users** | The machine is running Preview 5 or mixed files. The Quest operation already returned success before the UI callback failed. Review the generated `CreateCollections_AddUsers_Report_*.csv` and verify Quest state before retrying. Extract the complete RC1 package into a new directory. |
| A success-callback message appears for another operation | Do not assume the backend operation failed or was rolled back. Review reports and current Quest state first, then capture the session log. Preview 6 removes all known detached production callback closures. |
| Result grid does not update but the report exists | Run `Tests\Run-UiCallbackScopeTests.ps1`, confirm `VERSION.txt`, and use a clean extraction. |

## Startup and theme troubleshooting

| Symptom | Action |
|---|---|
| `'#FF62C0DA' is not a valid value for property 'BorderBrush'` | The machine is running Preview 3 or mixed files. Extract the complete RC1 ZIP into a new directory and confirm `VERSION.txt`. Do not overlay files. |
| Console opens but a theme brush is unchanged | Review the current session log for a non-fatal theme warning. The application should remain open using the XAML fallback palette. |
| Dark mode does not persist | Verify write access to the applicable per-user `Config` directory and inspect the saved `Theme` value. |
| Utility opens Light while the console is Dark | The utility inherits the console theme only before its own settings file exists. Toggle the utility theme or remove only its settings file. |
| Task/collection Add/Remove buttons are not visible | Confirm the complete RC1 package and run `Tests\Run-WpfSmokeTest.ps1`. |
| Mapping analysis fails because `Rows` is an empty array | Extract RC1 into a clean directory. Preview 5 and later permit legitimate zero-row report categories. |

## Log maintenance

Main-console controls are under **Diagnostics > Support and local preflight**. Utility controls are under **Run log**.

- **Apply retention now** removes only data older than the selected retention period.
- **Clear stored logs** removes prior session files and clears historical stores while preserving the active session log.
- **Clear view** affects only the visible text pane.
- Main and utility logs are maintained independently.

Focused validation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-UiCallbackScopeTests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-LogMaintenanceTests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Run-WpfSmokeTest.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\MappingCollisionUtility\Tests\Run-WpfSmokeTest.ps1
```

The build is unsigned. Authenticode, live Quest, live AD/Entra collector, and installed-production-`OdmApi` validation remain environment-specific gates.
