[CmdletBinding()]
param(
    [Parameter()][string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [switch]$RequireSigned
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Authenticode signature validation requires Windows.' }
$resolvedRoot = (Resolve-Path -LiteralPath $RootPath -ErrorAction Stop).Path
$files = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -ErrorAction Stop |
    Where-Object {
        $_.Extension -in @('.ps1','.psm1','.psd1') -and
        $_.FullName -notmatch '[\\/]LegacyScripts[\\/]' -and
        $_.FullName -notmatch '[\\/]Tests[\\/]Mocks[\\/]'
    } | Sort-Object FullName
$results = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName -ErrorAction Stop
    $results.Add([pscustomobject]@{
        File=$file.FullName.Substring($resolvedRoot.Length).TrimStart('\\','/')
        Status=[string]$signature.Status
        StatusMessage=[string]$signature.StatusMessage
        Thumbprint=if ($null -ne $signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { $null }
    }) | Out-Null
}
$invalid = @($results.ToArray() | Where-Object { $_.Status -notin @('Valid','NotSigned') })
$unsigned = @($results.ToArray() | Where-Object { $_.Status -eq 'NotSigned' })
if ($invalid.Count -gt 0) { throw "SIGNATURE VALIDATION: FAIL - $($invalid.Count) file(s) have invalid signatures." }
if ($RequireSigned -and $unsigned.Count -gt 0) { throw "SIGNATURE VALIDATION: FAIL - $($unsigned.Count) file(s) are unsigned." }
Write-Output "SIGNATURE VALIDATION: PASS (files=$($results.Count), unsigned=$($unsigned.Count))"
$results.ToArray()
