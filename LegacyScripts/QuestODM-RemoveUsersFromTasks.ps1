[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory)] [string]$Region,
  [Parameter(Mandatory)] [string]$OrganizationId,
  [Parameter(Mandatory)] [string]$ProjectId,
  [Parameter(Mandatory)] [string]$AccountsProjectWorkloadId,
  [Parameter(Mandatory)] [string]$RemovalPlanCsv,
  [switch]$Execute
)

Connect-OdmService -Region $Region.ToLower() | Out-Null
Select-OdmOrganization -OrganizationId $OrganizationId | Out-Null
Select-OdmProject $ProjectId | Out-Null
Select-OdmProjectWorkload -ProjectWorkloadId $AccountsProjectWorkloadId | Out-Null

$rows = Import-Csv $RemovalPlanCsv
if (-not $rows) { throw "Removal plan CSV empty: $RemovalPlanCsv" }

# Cache tasks + objects so we don't re-fetch repeatedly
$tasks = @{}
foreach ($t in (Get-OdmTask -All)) { $tasks[[string]$t.Id] = $t }

$objs = @{}
foreach ($o in (Get-OdmObject -All)) { if ($o.Id) { $objs[[string]$o.Id] = $o } }

foreach ($r in $rows) {
  $tid = [string]$r.TaskId
  $oid = [string]$r.ObjectId

  if (-not $tasks.ContainsKey($tid)) { Write-Warning "TaskId not found: $tid"; continue }
  if (-not $objs.ContainsKey($oid))  { Write-Warning "ObjectId not found: $oid"; continue }

  $task = $tasks[$tid]
  $obj  = $objs[$oid]

  if ($Execute) {
    Remove-OdmObject -From $task -Objects @($obj) -Confirm:$false
    Write-Host "Removed $($r.SourceUPN) from '$($task.Name)'" -ForegroundColor Green
  } else {
    Write-Host "[DRYRUN] Would remove $($r.SourceUPN) from '$($task.Name)'"
  }
}
