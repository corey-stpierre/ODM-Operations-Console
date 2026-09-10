[CmdletBinding(DefaultParameterSetName = 'Store')]
param(
    [Parameter()][string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true, ParameterSetName = 'Store')][string]$CertificateThumbprint,
    [Parameter(Mandatory = $true, ParameterSetName = 'Pfx')][string]$PfxPath,
    [Parameter(ParameterSetName = 'Pfx')][Security.SecureString]$PfxPassword,
    [Parameter()][string]$TimestampServer = 'http://timestamp.digicert.com',
    [Parameter()][string]$ReportPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'Authenticode signing requires Windows.' }
$resolvedRoot = (Resolve-Path -LiteralPath $RootPath -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $resolvedRoot 'SIGNING_REPORT.json'
}

$certificate = $null
if ($PSCmdlet.ParameterSetName -eq 'Store') {
    $normalized = ($CertificateThumbprint -replace '\s','').ToUpperInvariant()
    $certificate = Get-ChildItem -Path Cert:\CurrentUser\My,Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { ($_.Thumbprint -replace '\s','').ToUpperInvariant() -eq $normalized } |
        Select-Object -First 1
    if ($null -eq $certificate) { throw "A code-signing certificate with thumbprint '$CertificateThumbprint' was not found." }
}
else {
    if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw "PFX file not found: $PfxPath" }
    if ($null -eq $PfxPassword) { $PfxPassword = Read-Host -Prompt 'Enter the PFX password' -AsSecureString }
    $resolvedPfx = (Resolve-Path -LiteralPath $PfxPath -ErrorAction Stop).Path
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($resolvedPfx,$PfxPassword,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet)
}

if (-not $certificate.HasPrivateKey) { throw 'The selected certificate does not have an accessible private key.' }
$now = Get-Date
if ($certificate.NotBefore -gt $now -or $certificate.NotAfter -lt $now) { throw 'The selected certificate is outside its validity period.' }
$codeSigningOid = '1.3.6.1.5.5.7.3.3'
$ekuOk = $false
foreach ($extension in $certificate.Extensions) {
    if ($extension -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
        foreach ($oid in $extension.EnhancedKeyUsages) { if ($oid.Value -eq $codeSigningOid) { $ekuOk = $true } }
    }
}
if (-not $ekuOk) { throw 'The selected certificate does not contain the Code Signing EKU.' }

$files = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -ErrorAction Stop |
    Where-Object {
        $_.Extension -in @('.ps1','.psm1','.psd1') -and
        $_.FullName -notmatch '[\\/]LegacyScripts[\\/]' -and
        $_.FullName -notmatch '[\\/]Tests[\\/]Mocks[\\/]'
    } | Sort-Object FullName

$results = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $signature = Set-AuthenticodeSignature -LiteralPath $file.FullName -Certificate $certificate -TimestampServer $TimestampServer -HashAlgorithm SHA256 -ErrorAction Stop
    $results.Add([pscustomobject]@{
        File=$file.FullName.Substring($resolvedRoot.Length).TrimStart('\\','/')
        Status=[string]$signature.Status
        StatusMessage=[string]$signature.StatusMessage
        SignerThumbprint=if ($null -ne $signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { $null }
        TimeStamper=if ($null -ne $signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Subject } else { $null }
    }) | Out-Null
}

$failed = @($results.ToArray() | Where-Object { $_.Status -ne 'Valid' })
$report = [pscustomobject]@{
    Product='Quest ODM Operations Console'
    SignedAt=(Get-Date).ToString('o')
    RootPath=$resolvedRoot
    CertificateSubject=$certificate.Subject
    CertificateThumbprint=$certificate.Thumbprint
    CertificateNotAfter=$certificate.NotAfter
    TimestampServer=$TimestampServer
    FileCount=$results.Count
    FailedCount=$failed.Count
    Results=$results.ToArray()
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
if ($failed.Count -gt 0) { throw "Code signing completed with $($failed.Count) invalid signature(s). Review $ReportPath." }
Write-Output "CODE SIGNING: PASS ($($results.Count) files)"
Write-Output "Report: $ReportPath"
