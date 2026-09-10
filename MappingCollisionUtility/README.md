# Quest ODM Mapping Collision Utility — Preview 6

The Mapping Collision Utility is a separate, read-only Windows application packaged with the Quest ODM Operations Console. It compares normalized user identity inventories from a source directory and target directory before migration mappings are created.

It does **not** connect to Quest ODM and does **not** modify Active Directory, Microsoft Entra ID, or migration mappings.

## Theme and log retention

Use the **Dark mode** checkbox in the footer to switch themes. On first launch, the utility reads the main console theme; after its own settings file is created, the preference is independent.

The **Run log** tab provides:

- A 7/14/30/60/90/180-day retention selector.
- **Apply retention** for immediate expiration cleanup.
- **Clear stored logs** to remove all prior utility session logs while preserving the active session.
- **Open logs** and **Clear view** actions.

Retention also runs when the utility starts. The default is 30 days.

## Current collector scope

The packaged collectors export **user objects only**, including enabled and disabled users returned by `Get-ADUser` or Microsoft Graph `/users`. They do not include groups, contacts, applications/service principals, devices, deleted objects, or Exchange-only recipient types.

## Workflow

1. Launch the utility from **Bulk Operations**, or run `Start-MappingCollisionUtility.cmd`.
2. Export both collector scripts.
3. Run the source collector in the source environment.
4. Run the target collector in the target environment.
5. Select **Active Directory** or **Microsoft Entra ID** in each collector.
6. Transfer both CSV files to the analysis workstation.
7. Load them and select **Analyze inventories**.
8. Review collisions and ambiguous candidates before using `MappingCandidates.csv` downstream.

## Collector prerequisites

| Directory | Prerequisite | Access |
|---|---|---|
| Active Directory | RSAT `ActiveDirectory` module | Read access to exported user attributes |
| Microsoft Entra ID | `Microsoft.Graph.Authentication` | Interactive sign-in with `Directory.Read.All` and `User.Read.All` consent available |

## Anchors analyzed

- UPN, primary SMTP, `mail`, `targetAddress`, other mail, sign-in names, and SMTP proxies.
- `sAMAccountName`, `mailNickname`, and optional `employeeId`.
- Object GUID, `mS-DS-ConsistencyGuid`, Base64 representations, and `onPremisesImmutableId`.
- Object SID and `onPremisesSecurityIdentifier`.
- SIP, X500, and other proxy types.

## Output

Each run creates `CollisionDetails.csv`, `MappingCandidates.csv`, `AmbiguousMappings.csv`, `InventoryQualityIssues.csv`, `UnmatchedSourceObjects.csv`, `MappingCollisionSummary.html`, and `RunManifest.json`.

`Recommended` is advisory. `Blocked - Ambiguous` indicates duplicate, split-anchor, or many-to-one evidence that must be resolved before mapping.

## Testing

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-MappingCollisionTests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Run-WpfSmokeTest.ps1
```

Use **Load sample** for a known-collision demonstration.
