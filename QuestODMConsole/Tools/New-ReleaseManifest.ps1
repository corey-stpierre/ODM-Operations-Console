[CmdletBinding()]
param(
    [Parameter()][string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [Parameter()][string]$ManifestPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$resolvedRoot = (Resolve-Path -LiteralPath $RootPath -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $resolvedRoot 'MANIFEST.sha256' }
$manifestFullPath = [IO.Path]::GetFullPath($ManifestPath)
$lines = [System.Collections.Generic.List[string]]::new()
$files = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -ErrorAction Stop |
    Where-Object {
        $_.FullName -ne $manifestFullPath -and
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and
        $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and
        $_.Extension -ne '.pyc'
    } | Sort-Object FullName
foreach ($file in $files) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $relative = $file.FullName.Substring($resolvedRoot.Length).TrimStart('\\','/').Replace('\\','/')
    $lines.Add("$hash  $relative") | Out-Null
}
[IO.File]::WriteAllLines($manifestFullPath,$lines.ToArray(),[Text.UTF8Encoding]::new($false))
Write-Output "RELEASE MANIFEST: PASS ($($lines.Count) entries)"
Write-Output "Manifest: $manifestFullPath"
