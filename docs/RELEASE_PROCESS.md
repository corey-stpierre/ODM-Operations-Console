# Release Process

## Prepare

1. Start from a clean `release/<version>` branch.
2. Confirm all intended changes are committed and reviewed.
3. Update all coordinated version markers, including `VERSION.txt`, `Config/BuildInfo.json`, the README heading, release notes, and version-specific validation expectations.
4. Confirm no local settings, logs, customer data, tokens, or generated reports are present.

## Validate

Run the repository workflow checks locally where possible:

```powershell
python .\Tests\StaticValidation.py
python .\Tests\RuntimeSourceAudit.py
python .\MappingCollisionUtility\Tests\StaticValidation.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-StaticValidation.ps1 -SkipWpfSmokeTest -SkipGovernanceTests
```

On a Windows release-test workstation, run:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Run-V1Acceptance.ps1
```

For RC1, also run `Tests/Run-RcAcceptance.ps1 -ModuleManifest <OdmApi 2.1.401 manifest>` on PS5.1 and PS7. It isolates native backend fixtures from the normal suite. Connected Quest pilot acceptance and Authenticode remain release gates. No live test is implied by a local pass. Record outcomes in Samples/PilotAcceptance.csv.

## Generate the internal manifest

Generate the manifest only after the release tree is final:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tools\New-ReleaseManifest.ps1
```

Verify it from the application root:

```powershell
Get-Content .\MANIFEST.sha256 | ForEach-Object {
    $hash, $relativePath = $_ -split '\s{2}', 2
    $actual = (Get-FileHash -LiteralPath $relativePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $hash) { throw "Hash mismatch: $relativePath" }
}
```

## Package and publish

1. Package a clean extraction, not a working directory containing `.git` or local files.
2. Generate the ZIP SHA-256 separately.
3. Create an annotated Git tag matching `VERSION.txt`.
4. Publish the ZIP and its checksum as GitHub Release assets.
5. Mark preview versions as prereleases.
6. Retain the prior stable release for rollback.

Do not commit generated ZIP, MSI, EXE, or support-bundle artifacts to normal Git history.
