<#
QuestODM-CreateCollections-AndAddUsers.ps1

Reads a CSV with:
  CollectionName,SourceUPN

Creates collections if they do not already exist, then adds the specified users
to those collections.

- DRY-RUN by default
- Use -Execute to actually create collections and add users
- Exports a detailed report

Requirements:
- Windows PowerShell 5.1
- OdmApi module
- Correct Org / Project / Accounts workload context

HOW TO RUN THE SCRIPT:

cd C:\Temp

.\QuestODM-CreateCollections-AndAddUsers.ps1 `
  -CsvPath "C:\Temp\UsersToBatch.csv" `
  -OrganizationId "11111111-1111-1111-1111-111111111111" `
  -ProjectId "PROJECT_ID_HERE" `
  -AccountsProjectWorkloadId "ACCOUNTS_WORKLOAD_ID_HERE" `
  -Region US `
  -Execute

#>

[CmdletBinding(SupportsShouldProcess = $true)]
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

  [Parameter(Mandatory)]
  [string]$CsvPath,

  [switch]$Execute,

  [string]$OutDir = "C:\Temp\ODM_Reports"
)

function Normalize-Upn {
  param([string]$s)
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  return $s.Trim().ToLower()
}

function Normalize-Name {
  param([string]$s)
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  return $s.Trim()
}

function Get-ObjSourceUpn {
  param($Obj)

  $v = $null
  if ($Obj.PSObject.Properties.Name -contains "SourceUserPrincipalName") {
    $v = $Obj.SourceUserPrincipalName
  }
  if ([string]::IsNullOrWhiteSpace($v) -and ($Obj.PSObject.Properties.Name -contains "SourceEmail")) {
    $v = $Obj.SourceEmail
  }

  return (Normalize-Upn $v)
}

if ($PSVersionTable.PSVersion.Major -ne 5) {
  throw "Run this in Windows PowerShell 5.1."
}

if (-not ("OdmCollection" -as [type])) {
  throw "OdmCollection type is not loaded. Run this in Windows PowerShell 5.1 and ensure OdmApi is installed correctly."
}

if (-not (Test-Path $CsvPath)) {
  throw "CSV not found: $CsvPath"
}

if (-not (Test-Path $OutDir)) {
  New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $OutDir "CreateCollections_AddUsers_Report_$stamp.csv"

Connect-OdmService -Region $Region.ToLower() | Out-Null
Select-OdmOrganization -OrganizationId $OrganizationId | Out-Null

$proj = Get-OdmProject | Where-Object { $_.Id -eq $ProjectId }
if (-not $proj) {
  throw "Project with Id '$ProjectId' not found."
}

Select-OdmProjectWorkload -ProjectWorkloadId $AccountsProjectWorkloadId | Out-Null

$rows = Import-Csv -Path $CsvPath
if (-not $rows) {
  throw "CSV is empty or unreadable: $CsvPath"
}

$headers = $rows[0].PSObject.Properties.Name
if (-not ($headers -contains "CollectionName")) {
  throw "CSV must contain header: CollectionName"
}
if (-not ($headers -contains "SourceUPN")) {
  throw "CSV must contain header: SourceUPN"
}

$requests = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
  $cn  = Normalize-Name $r.CollectionName
  $upn = Normalize-Upn  $r.SourceUPN

  if ($cn -and $upn) {
    $requests.Add([pscustomobject]@{
      CollectionName = $cn
      SourceUPN      = $upn
    }) | Out-Null
  }
}

if ($requests.Count -eq 0) {
  throw "No valid rows found in CSV."
}

Write-Host ("Rows loaded: {0}" -f $requests.Count)
Write-Host ("Mode: {0}" -f ($(if ($Execute) { "EXECUTE" } else { "DRY-RUN" })))
Write-Host ""

Write-Host "Loading ODM objects..." -ForegroundColor Cyan
$allObjects = @()
try {
  $allObjects = Get-OdmObject -All
}
catch {
  $allObjects = Get-OdmObject
}

if (-not $allObjects -or $allObjects.Count -eq 0) {
  throw "Get-OdmObject returned 0 objects. Verify context."
}

$objLookup = @{}
foreach ($o in $allObjects) {
  $upn = Get-ObjSourceUpn $o
  if ($upn -and -not $objLookup.ContainsKey($upn)) {
    $objLookup[$upn] = $o
  }
}

Write-Host "Loading existing collections..." -ForegroundColor Cyan
$existingCollections = @()
try {
  $existingCollections = Get-OdmCollection -All
}
catch {
  $existingCollections = Get-OdmCollection
}

$collectionLookup = @{}
foreach ($c in $existingCollections) {
  if ($c.Name -and -not $collectionLookup.ContainsKey($c.Name)) {
    $collectionLookup[$c.Name] = $c
  }
}

$grouped = $requests | Group-Object CollectionName
$report = New-Object System.Collections.Generic.List[object]

foreach ($grp in $grouped) {
  $collectionName = $grp.Name
  $collection = $null
  $createdNow = $false

  if ($collectionLookup.ContainsKey($collectionName)) {
    $collection = $collectionLookup[$collectionName]
  }
  else {
    if (-not $Execute) {
      Write-Host ("[DRYRUN] Would create collection '{0}'" -f $collectionName)
    }
    else {
      try {
        if ($PSCmdlet.ShouldProcess($collectionName, "Create collection")) {
          $collection = New-OdmCollection -Name $collectionName
        }

        if (-not $collection) {
          throw "New-OdmCollection did not return a collection object."
        }

        $collectionLookup[$collectionName] = $collection
        $createdNow = $true
        Write-Host ("Created collection '{0}'" -f $collectionName) -ForegroundColor Green
      }
      catch {
        foreach ($row in $grp.Group) {
          $report.Add([pscustomobject]@{
            CollectionName    = $collectionName
            SourceUPN         = $row.SourceUPN
            CollectionCreated = $false
            UserAdded         = $false
            Status            = "FAILED"
            Details           = "Failed creating collection: $($_.Exception.Message)"
          }) | Out-Null
        }
        continue
      }
    }
  }

  $objsToAdd = @()
  foreach ($row in $grp.Group) {
    if ($objLookup.ContainsKey($row.SourceUPN)) {
      $objsToAdd += $objLookup[$row.SourceUPN]
    }
    else {
      $report.Add([pscustomobject]@{
        CollectionName    = $collectionName
        SourceUPN         = $row.SourceUPN
        CollectionCreated = $createdNow
        UserAdded         = $false
        Status            = "FAILED"
        Details           = "SourceUPN not found in Accounts workload objects"
      }) | Out-Null
    }
  }

  $objsToAdd = $objsToAdd |
    Where-Object { $_ -and $_.Id } |
    Group-Object Id |
    ForEach-Object { $_.Group | Select-Object -First 1 }

  if (-not $objsToAdd -or $objsToAdd.Count -eq 0) {
    continue
  }

  if (-not $Execute) {
    Write-Host ("[DRYRUN] Would add {0} user(s) to collection '{1}'" -f $objsToAdd.Count, $collectionName)
    foreach ($o in $objsToAdd) {
      $report.Add([pscustomobject]@{
        CollectionName    = $collectionName
        SourceUPN         = (Get-ObjSourceUpn $o)
        CollectionCreated = $createdNow
        UserAdded         = $false
        Status            = "DRYRUN"
        Details           = "Would add user to collection"
      }) | Out-Null
    }
    continue
  }

  try {
    if ($PSCmdlet.ShouldProcess($collectionName, ("Add {0} user(s) to collection" -f $objsToAdd.Count))) {
      $collection | Add-OdmObject -Object $objsToAdd
    }

    foreach ($o in $objsToAdd) {
      $report.Add([pscustomobject]@{
        CollectionName    = $collectionName
        SourceUPN         = (Get-ObjSourceUpn $o)
        CollectionCreated = $createdNow
        UserAdded         = $true
        Status            = "ADDED"
        Details           = "User added to collection"
      }) | Out-Null
    }
  }
  catch {
    foreach ($o in $objsToAdd) {
      $report.Add([pscustomobject]@{
        CollectionName    = $collectionName
        SourceUPN         = (Get-ObjSourceUpn $o)
        CollectionCreated = $createdNow
        UserAdded         = $false
        Status            = "FAILED"
        Details           = $_.Exception.Message
      }) | Out-Null
    }
  }
}

$report |
  Sort-Object CollectionName, SourceUPN |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path $reportPath

Write-Host ""
Write-Host ("Report exported: {0}" -f $reportPath) -ForegroundColor Green
if (-not $Execute) {
  Write-Host "No changes made. Re-run with -Execute to create collections and add users." -ForegroundColor Cyan
}