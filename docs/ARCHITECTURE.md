# Architecture

## Repository-layout invariant

The repository root is also the deployable application root. This is deliberate: launchers, validation scripts, the release manifest generator, resources, and tests use root-relative paths. A future `src` migration must be treated as a coordinated refactor rather than a file-management cleanup.

## Main console

| Component | Responsibility |
|---|---|
| `Start-QuestODMConsole*.cmd` | Selects and launches the supported PowerShell host. |
| `QuestODMConsole.ps1` | Bootstrap, host checks, source loading, and application startup. |
| `QuestODMConsole.UI.ps1` | WPF control wiring, asynchronous operation coordination, and result rendering. |
| `Resources/QuestODMConsole.xaml` | Main WPF window, controls, styles, and theme resources. |
| `Engine/QuestODMConsole.Engine.psm1` | Loads the operation-engine implementation. |
| `Engine/*.ps1` | Context, inventory, membership, accounts, bulk, task factory, governance, and preflight operations. |
| `Shared/LogMaintenance.ps1` | Shared retention and historical-log cleanup behavior. |
| `Config/*.json` | Shipped defaults, build metadata, and validated OdmApi compatibility information. |

## Mapping Collision Utility

The utility is packaged inside `MappingCollisionUtility` but remains operationally separate from the Quest-connected console. Its collectors export source and target identity inventories, while `MappingCollisionEngine.psm1` performs normalization, collision analysis, candidate generation, and reporting.

The utility is read-only with respect to source and target directories. Inventory CSV files and generated reports contain sensitive identity metadata.

## Legacy scripts

`LegacyScripts` contains the original standalone operational scripts retained for reference and controlled use. They are excluded from several production parser and signing gates. New console behavior should be implemented in the engine rather than by adding more direct UI-to-legacy-script coupling.

## Tests and release tools

- `Tests` contains parser, static, mock-engine, governance, callback-scope, WPF, and acceptance validation.
- `Tools/New-ReleaseManifest.ps1` produces the internal SHA-256 manifest.
- `Tools/Invoke-CodeSigning.ps1` and `Tools/Test-CodeSigning.ps1` support the future signed-release path.
- `.github/workflows/validate.yml` runs non-interactive repository checks on pushes and pull requests.

## Runtime data

The supported per-user data root is `%LOCALAPPDATA%\QuestODMConsole`. Runtime logs, local settings, reports, support bundles, and customer data must remain outside source control.

## Security boundary

Interactive Quest authentication remains external to the repository. Tokens and credentials must never be serialized into source, settings, test fixtures, issue attachments, or release archives. Write operations remain subject to global change enablement, local execute controls, selected context, and explicit operator confirmation.


## Active Directory workspace (RC2)

`ContextMode` distinguishes Microsoft365 from organization-scoped ActiveDirectory. AD entry clears M365 project/workload selection, rotates a context epoch and resets Safe Mode. M365 selection returns to its context mode and invalidates AD previews. `Engine/ActiveDirectory.ps1` uses the fixed `Config/ActiveDirectoryCatalog.json`, loaded-module command metadata, exact primary-ID resolution, flat credential-safe snapshots, typed settings, preview binding and a journal before every write. A single `Invoke-QOdmAdNative` boundary invokes module-exported commands; offline tests replace that boundary and retain the real console logic. Mutations never retry automatically. SDK objects are passed to object-valued vendor parameters; opaque self-service IDs are passed without altering their case/encoding. Service result counts/errors are checked for self-service. Shared-profile changes and returned job/workflow IDs require operator readback. AD readiness leaves tenant prerequisites unverified and skips M365-specific context/subscription checks.
