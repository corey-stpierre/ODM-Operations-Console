#using module OdmApi

param(
  [Parameter(Mandatory)] [string]$Region,
  [Parameter(Mandatory)] [string]$OrganizationId,
  [Parameter(Mandatory)] [string]$ProjectId,
  [Parameter(Mandatory)] [string]$AccountsProjectWorkloadId,
  [Parameter(Mandatory)] [string]$TaskName,
  [Parameter(Mandatory)] [string]$UserCsvPath
)

Connect-OdmService -Region $Region | Out-Null
Select-OdmOrganization -OrganizationId $OrganizationId | Out-Null
Select-OdmProject $ProjectId | Out-Null
Select-OdmProjectWorkload -ProjectWorkloadId $AccountsProjectWorkloadId | Out-Null

# Find task
$task = Get-OdmTask -All | Where-Object { $_.Name -eq $TaskName } | Select-Object -First 1
if (-not $task) { throw "Task not found: $TaskName" }

# Load source UPNs
$upns = (Import-Csv $UserCsvPath).SourceUPN | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ } | Sort-Object -Unique
if (-not $upns) { throw "No SourceUPN values found in $UserCsvPath" }

# Build object lookup from Accounts workload
$all = Get-OdmObject -All
$lookup = @{}
foreach ($o in $all) {
  foreach ($p in @("SourceUserPrincipalName","SourceEmail")) {
    $v = $o.$p
    if ($v) {
      $k = $v.Trim().ToLower()
      if (-not $lookup.ContainsKey($k)) { $lookup[$k] = $o }
    }
  }
}

# Resolve objects to remove
$objsToRemove = foreach ($u in $upns) { if ($lookup.ContainsKey($u)) { $lookup[$u] } }

if (-not $objsToRemove) { throw "None of the UPNs resolved to ODM objects in Accounts workload." }

# Remove from task (no deletion of task)
Remove-OdmObject -From $task -Objects $objsToRemove -Confirm $false
"Removed $($objsToRemove.Count) object(s) from task '$TaskName'."
