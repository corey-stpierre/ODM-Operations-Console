<#
QuestODM-Remove-OdmUsersFromCollections.ps1  (PS 5.1 safe)

Removes specific users from specific collections based on CSV rows:
  CollectionName,SourceUPN

- Does NOT delete tasks/collections
- DRY-RUN by default; use -Execute to actually remove
- Exports a report CSV with per-row outcome

Requirements:
- Windows PowerShell 5.1
- OdmApi module
- Correct Org/Project/Accounts workload context
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
  if ($Obj.PSObject.Properties.Name -contains "SourceUserPrincipalName") { $v = $Obj.SourceUserPrincipalName }
  if ([string]::IsNullOrWhiteSpace($v) -and ($Obj.PSObject.Properties.Name -contains "SourceEmail")) { $v = $Obj.SourceEmail }
  return (Normalize-Upn $v)
}

# ---- Preflight ----
if ($PSVersionTable.PSVersion.Major -ne 5) { throw "Run in Windows PowerShell 5.1." }
if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
if (-not (Test-Path $OutDir)) { New-Item -Path $OutDir -ItemType Directory -Force | Out-Null }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $OutDir "RemoveFromCollections_Report_$stamp.csv"

# ---- Connect + context ----
Connect-OdmService -Region $Region.ToLower() | Out-Null
Select-OdmOrganization -OrganizationId $OrganizationId | Out-Null

$proj = Get-OdmProject | Where-Object { $_.Id -eq $ProjectId }
if (-not $proj) { throw "Project with Id '$ProjectId' not found." }

Select-OdmProjectWorkload -ProjectWorkloadId $AccountsProjectWorkloadId | Out-Null

# ---- Load CSV ----
$rows = Import-Csv -Path $CsvPath
if (-not $rows) { throw "CSV is empty or unreadable: $CsvPath" }

# Validate headers
$headers = $rows[0].PSObject.Properties.Name
if (-not ($headers -contains "CollectionName")) { throw "CSV must contain header: CollectionName" }
if (-not ($headers -contains "SourceUPN")) { throw "CSV must contain header: SourceUPN" }

# Normalize and keep only valid rows
$requests = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
  $cn  = Normalize-Name $r.CollectionName
  $upn = Normalize-Upn  $r.SourceUPN
  if ($cn -and $upn) {
    $requests.Add([pscustomobject]@{ CollectionName = $cn; SourceUPN = $upn }) | Out-Null
  }
}

if ($requests.Count -eq 0) { throw "No valid rows found. Ensure CollectionName and SourceUPN have values." }

Write-Host ("Rows loaded: {0}" -f $requests.Count)
Write-Host ("Mode: {0}" -f ($(if ($Execute) { "EXECUTE" } else { "DRY-RUN" })))
Write-Host ""

# ---- Build object lookup (SourceUPN -> ODM object) ----
Write-Host "Loading ODM objects (Accounts workload)..." -ForegroundColor Cyan
$allObjects = @()
try { $allObjects = Get-OdmObject -All } catch { $allObjects = Get-OdmObject }
if (-not $allObjects -or $allObjects.Count -eq 0) { throw "Get-OdmObject returned 0 objects. Wrong context?" }

$lookup = @{}
foreach ($o in $allObjects) {
  $k = Get-ObjSourceUpn $o
  if ($k -and -not $lookup.ContainsKey($k)) { $lookup[$k] = $o }
}

# ---- Build collection lookup (CollectionName -> collection object) ----
Write-Host "Loading collections..." -ForegroundColor Cyan
$collections = @()
try { $collections = Get-OdmCollection -All } catch { $collections = Get-OdmCollection }
if (-not $collections) { throw "No collections returned in this workload context." }

$collLookup = @{}
foreach ($c in $collections) {
  if ($c.Name -and -not $collLookup.ContainsKey($c.Name)) { $collLookup[$c.Name] = $c }
}

# ---- Group removals by collection ----
$byCollection = $requests | Group-Object CollectionName

$report = New-Object System.Collections.Generic.List[object]

foreach ($grp in $byCollection) {
  $cn = $grp.Name

  if (-not $collLookup.ContainsKey($cn)) {
    foreach ($row in $grp.Group) {
      $report.Add([pscustomobject]@{
        CollectionName = $cn
        SourceUPN      = $row.SourceUPN
        Status         = "FAILED"
        Details        = "Collection not found in current workload context"
      }) | Out-Null
    }
    continue
  }

  $coll = $collLookup[$cn]

  # Resolve objects for this collection
  $objsToRemove = @()
  foreach ($row in $grp.Group) {
    if ($lookup.ContainsKey($row.SourceUPN)) {
      $objsToRemove += $lookup[$row.SourceUPN]
    } else {
      $report.Add([pscustomobject]@{
        CollectionName = $cn
        SourceUPN      = $row.SourceUPN
        Status         = "FAILED"
        Details        = "SourceUPN not found in Accounts workload objects"
      }) | Out-Null
    }
  }

  # Dedup by Id
  $objsToRemove = $objsToRemove |
    Where-Object { $_ -and $_.Id } |
    Group-Object Id |
    ForEach-Object { $_.Group | Select-Object -First 1 }

  if (-not $objsToRemove -or $objsToRemove.Count -eq 0) { continue }

  $actionLabel = ("Remove {0} object(s) from collection '{1}'" -f $objsToRemove.Count, $cn)

  if (-not $Execute) {
    Write-Host ("[DRYRUN] {0}" -f $actionLabel)
    foreach ($o in $objsToRemove) {
      $report.Add([pscustomobject]@{
        CollectionName = $cn
        SourceUPN      = (Get-ObjSourceUpn $o)
        Status         = "DRYRUN"
        Details        = "Would remove from collection"
      }) | Out-Null
    }
    continue
  }

  try {
    if ($PSCmdlet.ShouldProcess($cn, $actionLabel)) {
      Remove-OdmObject -From $coll -Objects $objsToRemove -Confirm:$false
    }

    foreach ($o in $objsToRemove) {
      $report.Add([pscustomobject]@{
        CollectionName = $cn
        SourceUPN      = (Get-ObjSourceUpn $o)
        Status         = "REMOVED"
        Details        = "Removed from collection"
      }) | Out-Null
    }
  }
  catch {
    foreach ($o in $objsToRemove) {
      $report.Add([pscustomobject]@{
        CollectionName = $cn
        SourceUPN      = (Get-ObjSourceUpn $o)
        Status         = "FAILED"
        Details        = $_.Exception.Message
      }) | Out-Null
    }
  }
}

# ---- Export report ----
$report | Sort-Object CollectionName, SourceUPN | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $reportPath

Write-Host ""
Write-Host ("Report exported: {0}" -f $reportPath) -ForegroundColor Green
if (-not $Execute) {
  Write-Host "No changes made. Re-run with -Execute to remove." -ForegroundColor Cyan
}