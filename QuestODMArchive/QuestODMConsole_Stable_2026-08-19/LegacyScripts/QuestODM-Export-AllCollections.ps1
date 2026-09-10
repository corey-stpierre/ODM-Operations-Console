<#
QuestODM-Export-AllCollections.ps1

Exports all collections from the current ODM workload context to CSV.

Requirements:
- Windows PowerShell 5.1
- OdmApi module
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("US","EU","AU","CA","UK","us","eu","au","ca","uk")]
  [string]$Region,

  [Parameter(Mandatory)]
  [string]$OrganizationId,

  [Parameter(Mandatory)]
  [string]$ProjectId,

  [Parameter(Mandatory)]
  [string]$AccountsProjectWorkloadId,

  [string]$OutDir = "C:\Temp\ODM_Reports"
)

if ($PSVersionTable.PSVersion.Major -ne 5) {
  throw "Run this in Windows PowerShell 5.1."
}

if (-not (Test-Path $OutDir)) {
  New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $OutDir "AllCollections_$stamp.csv"

Connect-OdmService -Region $Region.ToLower() | Out-Null
Select-OdmOrganization -OrganizationId $OrganizationId | Out-Null

$proj = Get-OdmProject | Where-Object { $_.Id -eq $ProjectId }
if (-not $proj) {
  throw "Project with Id '$ProjectId' not found."
}

Select-OdmProjectWorkload -ProjectWorkloadId $AccountsProjectWorkloadId | Out-Null

$collections = @()
try {
  $collections = Get-OdmCollection -All
}
catch {
  $collections = Get-OdmCollection
}

if (-not $collections -or $collections.Count -eq 0) {
  throw "No collections returned in the current workload context."
}

$rows = foreach ($c in ($collections | Sort-Object Name)) {
  $objectCount = $null
  try {
    $objs = $c | Get-OdmObject -All
    if ($objs) { $objectCount = $objs.Count } else { $objectCount = 0 }
  }
  catch {
    $objectCount = $null
  }

  [pscustomobject]@{
    CollectionName = $c.Name
    CollectionId   = $c.Id
    ObjectCount    = $objectCount
    Description    = $c.Description
  }
}

$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $outFile

Write-Host ""
Write-Host "Export complete: $outFile" -ForegroundColor Green
Write-Host "Collections exported: $($rows.Count)"