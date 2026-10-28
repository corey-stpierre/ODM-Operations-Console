using module OdmApi
<#
QuestODM-Create-TemplateTasks-FromCollectionCsv.ps1

Reads a CSV with:
  CollectionName,SourceUPN

For each unique CollectionName:
  - Resolves the SourceUPNs to ODM account objects
  - Creates 4 ODM tasks from saved templates:
      <CollectionName> - Mail
      <CollectionName> - OneDrive
      <CollectionName> - Meeting Link Migration
      <CollectionName> - Mailbox Switch
  - Adds the resolved objects to each task
  - Verifies task membership after adding objects
  - Exports detailed object-to-task verification reports

Requirements:
- Windows PowerShell 5.1
- OdmApi module
- Correct Org / Project / Accounts workload context
- Four saved ODM task templates:
    Mail migration template
    OneDrive migration template
    Meeting link migration template
    Mailbox switch template

CSV format:
CollectionName,SourceUPN
Wave001_04-27-26,user1@source.com
Wave001_04-27-26,user2@source.com
Wave002_04-28-26,user3@source.com

How to Run the Script:

cd C:\Temp

.\QuestODM-Create-TemplateTasks-FromCollectionCsv.ps1 `
  -CsvPath "C:\Temp\UsersToBatch.csv" `
  -OrganizationId "11111111-1111-1111-1111-111111111111" `
  -ProjectId "PROJECT_ID_HERE" `
  -AccountsProjectWorkloadId "ACCOUNTS_WORKLOAD_ID_HERE" `
  -MailTemplateId "MAIL_TEMPLATE_ID_HERE" `
  -OneDriveTemplateId "ONEDRIVE_TEMPLATE_ID_HERE" `
  -MeetingLinkTemplateId "MEETING_LINK_TEMPLATE_ID_HERE" `
  -MailboxSwitchTemplateId "MAILBOX_SWITCH_TEMPLATE_ID_HERE" `
  -Region US `
  -LinkTasksToCollections
  
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$CsvPath,

  [Parameter(Mandatory)]
  [string]$OrganizationId,

  [Parameter(Mandatory)]
  [string]$ProjectId,

  [Parameter(Mandatory)]
  [string]$AccountsProjectWorkloadId,

  [Parameter(Mandatory)]
  [string]$MailTemplateId,

  [Parameter(Mandatory)]
  [string]$OneDriveTemplateId,

  [Parameter(Mandatory)]
  [string]$MeetingLinkTemplateId,

  [Parameter(Mandatory)]
  [string]$MailboxSwitchTemplateId,

  [Parameter()]
  [ValidateSet("US","EU","AU","CA","UK","us","eu","au","ca","uk")]
  [string]$Region = "US",

  [Parameter()]
  [string]$OutDir = "C:\Temp\ODM_Reports",

  # Optional: link created tasks back to a matching ODM collection for UI visibility
  [switch]$LinkTasksToCollections,

  # Verification retry behavior after Add-OdmObject
  [int]$VerificationRetries = 6,

  [int]$VerificationDelaySeconds = 5,

  # If a collection group exceeds this number, the script will skip it.
  # Change if your ODM task limit is different.
  [int]$MaxUsersPerTask = 1000
)

# -----------------------------
# Preflight
# -----------------------------
if ($PSVersionTable.PSVersion.Major -ne 5) {
  throw "Run this script in Windows PowerShell 5.1."
}

if (-not (Test-Path $CsvPath)) {
  throw "CSV not found: $CsvPath"
}

if (-not (Test-Path $OutDir)) {
  New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
}

$requiredCommands = @(
  "New-OdmMailMigrationTask",
  "New-OdmOneDriveMigrationTask",
  "New-OdmMeetingLinkMigrationTask",
  "New-OdmMailSwitchTask"
)

foreach ($cmd in $requiredCommands) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    throw "$cmd was not found in the OdmApi module."
  }
}

# These two are known class requirements in your environment.
if (-not ("OdmMailMigrationTask" -as [type])) {
  throw "OdmMailMigrationTask type is not loaded. Run this in Windows PowerShell 5.1 and make sure 'using module OdmApi' is the first statement."
}

if (-not ("OdmOneDriveMigrationTask" -as [type])) {
  throw "OdmOneDriveMigrationTask type is not loaded. Run this in Windows PowerShell 5.1 and make sure 'using module OdmApi' is the first statement."
}

# -----------------------------
# Helpers
# -----------------------------
function Normalize-Upn {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  return $Value.Trim().ToLower()
}

function Normalize-Name {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  return $Value.Trim()
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

function Add-LookupEntry {
  param(
    [hashtable]$Lookup,
    [string]$Key,
    $Obj
  )

  if ([string]::IsNullOrWhiteSpace($Key)) {
    return
  }

  $k = $Key.Trim().ToLower()

  if (-not $Lookup.ContainsKey($k)) {
    $Lookup[$k] = $Obj
  }
}

function Get-CommandParamNames {
  param([Parameter(Mandatory)][string]$Name)

  $cmd = Get-Command $Name -ErrorAction Stop

  if ($cmd.Parameters -and $cmd.Parameters.Count -gt 0) {
    return @($cmd.Parameters.Keys)
  }

  if ($cmd.ScriptBlock -and $cmd.ScriptBlock.Ast -and $cmd.ScriptBlock.Ast.ParamBlock) {
    return @(
      $cmd.ScriptBlock.Ast.ParamBlock.Parameters.Name.VariablePath.UserPath |
      Where-Object { $_ } |
      Sort-Object -Unique
    )
  }

  return @()
}

function Assert-TemplateSupport {
  param(
    [string]$CommandName
  )

  $params = Get-CommandParamNames -Name $CommandName

  if (-not ($params -contains "TemplateId")) {
    throw "$CommandName does not expose a TemplateId parameter in this OdmApi version."
  }
}

function New-OdmTaskFromTemplateSafe {
  param(
    [Parameter(Mandatory)][string]$CommandName,
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][string]$TemplateId
  )

  $params = @{
    Name       = $TaskName
    TemplateId = $TemplateId
  }

  return (& $CommandName @params)
}

function Get-TaskObjectsWithRetry {
  param(
    [Parameter(Mandatory)]$Task,
    [Parameter(Mandatory)][hashtable]$ExpectedIdLookup,
    [int]$Retries = 6,
    [int]$DelaySeconds = 5
  )

  $lastObjects = @()

  for ($i = 1; $i -le $Retries; $i++) {
    try {
      $lastObjects = @($Task | Get-OdmObject -All)
    }
    catch {
      $lastObjects = @()
    }

    $matched = 0
    foreach ($obj in $lastObjects) {
      if ($obj.Id -and $ExpectedIdLookup.ContainsKey([string]$obj.Id)) {
        $matched++
      }
    }

    if ($matched -ge $ExpectedIdLookup.Count) {
      return $lastObjects
    }

    if ($i -lt $Retries) {
      Start-Sleep -Seconds $DelaySeconds
    }
  }

  return $lastObjects
}

function New-TaskVerificationRows {
  param(
    [Parameter(Mandatory)][string]$CollectionName,
    [Parameter(Mandatory)][string]$TaskType,
    [Parameter(Mandatory)][string]$TaskName,
    [string]$TaskId,
    [Parameter(Mandatory)][string]$TemplateId,
    [Parameter(Mandatory)]$CollectionObjects,
    [Parameter(Mandatory)]$VerifiedTaskObjects,
    [bool]$TaskCreated,
    [bool]$AddCommandSucceeded,
    [string]$Details
  )

  $verifiedLookup = @{}

  foreach ($obj in $VerifiedTaskObjects) {
    if ($obj.Id -and -not $verifiedLookup.ContainsKey([string]$obj.Id)) {
      $verifiedLookup[[string]$obj.Id] = $true
    }
  }

  foreach ($item in $CollectionObjects) {
    $objectId = [string]$item.ObjectId
    $verified = $false

    if ($objectId -and $verifiedLookup.ContainsKey($objectId)) {
      $verified = $true
    }

    $status = "NOT_VERIFIED"
    if (-not $TaskCreated) {
      $status = "TASK_CREATE_FAILED"
    }
    elseif (-not $AddCommandSucceeded) {
      $status = "ADD_COMMAND_FAILED"
    }
    elseif ($verified) {
      $status = "VERIFIED_ADDED"
    }

    [pscustomobject]@{
      CollectionName      = $CollectionName
      SourceUPN           = $item.SourceUPN
      ObjectId            = $objectId
      TaskType            = $TaskType
      TaskName            = $TaskName
      TaskId              = $TaskId
      TemplateId          = $TemplateId
      TaskCreated         = $TaskCreated
      AddCommandSucceeded = $AddCommandSucceeded
      VerifiedInTask      = $verified
      Status              = $status
      Details             = $Details
    }
  }
}

# -----------------------------
# Validate template support
# -----------------------------
Assert-TemplateSupport -CommandName "New-OdmMailMigrationTask"
Assert-TemplateSupport -CommandName "New-OdmOneDriveMigrationTask"
Assert-TemplateSupport -CommandName "New-OdmMeetingLinkMigrationTask"
Assert-TemplateSupport -CommandName "New-OdmMailSwitchTask"

# -----------------------------
# Output files
# -----------------------------
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

$assignmentReportPath = Join-Path $OutDir "TemplateTasks_UserAssignmentVerification_$stamp.csv"
$summaryReportPath    = Join-Path $OutDir "TemplateTasks_TaskSummary_$stamp.csv"
$unresolvedPath       = Join-Path $OutDir "TemplateTasks_UnresolvedUPNs_$stamp.csv"
$skippedPath          = Join-Path $OutDir "TemplateTasks_SkippedCollections_$stamp.csv"

# -----------------------------
# Connect + context
# -----------------------------
Connect-OdmService -Region $Region.ToLower() | Out-Null
Select-OdmOrganization -OrganizationId $OrganizationId | Out-Null

$proj = Get-OdmProject | Where-Object { $_.Id -eq $ProjectId }
if (-not $proj) {
  throw "Project with Id '$ProjectId' not found."
}

Select-OdmProjectWorkload -ProjectWorkloadId $AccountsProjectWorkloadId | Out-Null

# -----------------------------
# Load CSV
# -----------------------------
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

foreach ($row in $rows) {
  $collectionName = Normalize-Name $row.CollectionName
  $sourceUpn      = Normalize-Upn $row.SourceUPN

  if ($collectionName -and $sourceUpn) {
    $requests.Add([pscustomobject]@{
      CollectionName = $collectionName
      SourceUPN      = $sourceUpn
    }) | Out-Null
  }
}

if ($requests.Count -eq 0) {
  throw "No valid rows found in CSV."
}

Write-Host "Rows loaded: $($requests.Count)"
Write-Host ""

# -----------------------------
# Load all ODM objects once
# -----------------------------
Write-Host "Loading ODM objects (Accounts workload)..." -ForegroundColor Cyan

$allObjects = @()

try {
  $allObjects = Get-OdmObject -All
}
catch {
  $allObjects = Get-OdmObject
}

if (-not $allObjects -or $allObjects.Count -eq 0) {
  throw "Get-OdmObject returned 0 objects. Verify the project/workload context."
}

Write-Host "Objects returned: $($allObjects.Count)"

# Build lookup using source UPN fields first.
$objLookup = @{}

foreach ($obj in $allObjects) {
  foreach ($prop in @("SourceUserPrincipalName", "SourceEmail")) {
    if ($obj.PSObject.Properties.Name -contains $prop) {
      $value = $obj.$prop

      if ($value) {
        Add-LookupEntry -Lookup $objLookup -Key $value -Obj $obj
      }
    }
  }
}

Write-Host "Source UPN lookup entries created: $($objLookup.Count)"
Write-Host ""

# -----------------------------
# Resolve input rows
# -----------------------------
$resolvedRows   = New-Object System.Collections.Generic.List[object]
$unresolvedRows = New-Object System.Collections.Generic.List[object]

foreach ($req in $requests) {
  if ($objLookup.ContainsKey($req.SourceUPN)) {
    $resolvedObj = $objLookup[$req.SourceUPN]

    $resolvedRows.Add([pscustomobject]@{
      CollectionName = $req.CollectionName
      SourceUPN      = $req.SourceUPN
      Object         = $resolvedObj
      ObjectId       = $resolvedObj.Id
    }) | Out-Null
  }
  else {
    $unresolvedRows.Add([pscustomobject]@{
      CollectionName = $req.CollectionName
      SourceUPN      = $req.SourceUPN
    }) | Out-Null
  }
}

Write-Host "Resolved rows:   $($resolvedRows.Count)" -ForegroundColor Green
Write-Host "Unresolved rows: $($unresolvedRows.Count)" -ForegroundColor Yellow

if ($unresolvedRows.Count -gt 0) {
  $unresolvedRows |
    Sort-Object CollectionName, SourceUPN |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $unresolvedPath

  Write-Host "Unresolved exported: $unresolvedPath" -ForegroundColor Yellow
}

if ($resolvedRows.Count -eq 0) {
  throw "No CSV users could be resolved to ODM objects."
}

# -----------------------------
# Optional collection lookup for linking tasks
# -----------------------------
$collectionLookup = @{}

if ($LinkTasksToCollections) {
  Write-Host "Loading collections for optional task linking..." -ForegroundColor Cyan

  $existingCollections = @()

  try {
    $existingCollections = Get-OdmCollection -All
  }
  catch {
    $existingCollections = Get-OdmCollection
  }

  foreach ($c in $existingCollections) {
    if ($c.Name -and -not $collectionLookup.ContainsKey($c.Name)) {
      $collectionLookup[$c.Name] = $c
    }
  }
}

# -----------------------------
# Group by collection and create template tasks
# -----------------------------
$grouped = $resolvedRows | Group-Object CollectionName

$assignmentRows = New-Object System.Collections.Generic.List[object]
$summaryRows    = New-Object System.Collections.Generic.List[object]
$skippedRows    = New-Object System.Collections.Generic.List[object]

foreach ($grp in $grouped) {
  $collectionName = $grp.Name

  $collectionObjects = $grp.Group |
    Where-Object { $_.ObjectId } |
    Group-Object ObjectId |
    ForEach-Object { $_.Group | Select-Object -First 1 }

  if (-not $collectionObjects -or $collectionObjects.Count -eq 0) {
    continue
  }

  if ($collectionObjects.Count -gt $MaxUsersPerTask) {
    $skippedRows.Add([pscustomobject]@{
      CollectionName = $collectionName
      UserCount      = $collectionObjects.Count
      Status         = "SKIPPED"
      Details        = "User count exceeds MaxUsersPerTask value of $MaxUsersPerTask"
    }) | Out-Null

    Write-Warning "Skipping '$collectionName'. User count $($collectionObjects.Count) exceeds MaxUsersPerTask $MaxUsersPerTask."
    continue
  }

  $objectsForTask = @($collectionObjects | ForEach-Object { $_.Object })

  $expectedIdLookup = @{}
  foreach ($item in $collectionObjects) {
    $expectedIdLookup[[string]$item.ObjectId] = $true
  }

  $taskSpecs = @(
    [pscustomobject]@{
      TaskType   = "Mail"
      TaskName   = "$collectionName - Mail"
      Command    = "New-OdmMailMigrationTask"
      TemplateId = $MailTemplateId
    },
    [pscustomobject]@{
      TaskType   = "OneDrive"
      TaskName   = "$collectionName - OneDrive"
      Command    = "New-OdmOneDriveMigrationTask"
      TemplateId = $OneDriveTemplateId
    },
    [pscustomobject]@{
      TaskType   = "Meeting Link Migration"
      TaskName   = "$collectionName - Meeting Link Migration"
      Command    = "New-OdmMeetingLinkMigrationTask"
      TemplateId = $MeetingLinkTemplateId
    },
    [pscustomobject]@{
      TaskType   = "Mailbox Switch"
      TaskName   = "$collectionName - Mailbox Switch"
      Command    = "New-OdmMailSwitchTask"
      TemplateId = $MailboxSwitchTemplateId
    }
  )

  Write-Host "Creating template-based tasks for collection '$collectionName' (Users: $($collectionObjects.Count))..." -ForegroundColor Cyan

  $createdTasks = @()

  foreach ($spec in $taskSpecs) {
    $task = $null
    $taskCreated = $false
    $addSucceeded = $false
    $verifiedObjects = @()
    $details = ""

    try {
      $task = New-OdmTaskFromTemplateSafe `
        -CommandName $spec.Command `
        -TaskName $spec.TaskName `
        -TemplateId $spec.TemplateId

      $taskCreated = $true
      $details = "Task created from template."

      Write-Host "  Created task: $($spec.TaskName)" -ForegroundColor Green
    }
    catch {
      $details = "Failed creating task from template: $($_.Exception.Message)"
      Write-Warning "  FAILED creating $($spec.TaskType) task '$($spec.TaskName)': $($_.Exception.Message)"
    }

    if ($taskCreated -and $task) {
      try {
        $null = $task | Add-OdmObject -Object $objectsForTask
        $addSucceeded = $true
        $details = "Task created and Add-OdmObject completed."
      }
      catch {
        $addSucceeded = $false
        $details = "Task created, but Add-OdmObject failed: $($_.Exception.Message)"
        Write-Warning "  FAILED adding objects to '$($spec.TaskName)': $($_.Exception.Message)"
      }
    }

    if ($taskCreated -and $addSucceeded -and $task) {
      $verifiedObjects = Get-TaskObjectsWithRetry `
        -Task $task `
        -ExpectedIdLookup $expectedIdLookup `
        -Retries $VerificationRetries `
        -DelaySeconds $VerificationDelaySeconds

      $verifiedCount = 0

      foreach ($verifiedObject in $verifiedObjects) {
        if ($verifiedObject.Id -and $expectedIdLookup.ContainsKey([string]$verifiedObject.Id)) {
          $verifiedCount++
        }
      }

      Write-Host "    Verified objects in task: $verifiedCount / $($collectionObjects.Count)"
    }
    else {
      $verifiedCount = 0
    }

    $taskId = $null
    if ($task -and $task.Id) {
      $taskId = $task.Id
    }

    $assignment = New-TaskVerificationRows `
      -CollectionName $collectionName `
      -TaskType $spec.TaskType `
      -TaskName $spec.TaskName `
      -TaskId $taskId `
      -TemplateId $spec.TemplateId `
      -CollectionObjects $collectionObjects `
      -VerifiedTaskObjects $verifiedObjects `
      -TaskCreated $taskCreated `
      -AddCommandSucceeded $addSucceeded `
      -Details $details

    foreach ($row in $assignment) {
      $assignmentRows.Add($row) | Out-Null
    }

    $missingCount = $collectionObjects.Count - $verifiedCount

    $summaryRows.Add([pscustomobject]@{
      CollectionName      = $collectionName
      TaskType            = $spec.TaskType
      TaskName            = $spec.TaskName
      TaskId              = $taskId
      TemplateId          = $spec.TemplateId
      IntendedObjectCount = $collectionObjects.Count
      VerifiedObjectCount = $verifiedCount
      MissingObjectCount  = $missingCount
      TaskCreated         = $taskCreated
      AddCommandSucceeded = $addSucceeded
      Status              = if ($taskCreated -and $addSucceeded -and $missingCount -eq 0) { "VERIFIED" } elseif ($taskCreated -and $addSucceeded) { "PARTIAL_OR_NOT_VERIFIED" } elseif ($taskCreated) { "CREATED_ADD_FAILED" } else { "CREATE_FAILED" }
      Details             = $details
    }) | Out-Null

    if ($taskCreated -and $task) {
      $createdTasks += $task
    }
  }

  if ($LinkTasksToCollections -and $createdTasks.Count -gt 0) {
    if ($collectionLookup.ContainsKey($collectionName)) {
      try {
        Add-OdmTask -Tasks $createdTasks -To $collectionLookup[$collectionName] | Out-Null
        Write-Host "  Linked created tasks to collection: $collectionName" -ForegroundColor DarkGray
      }
      catch {
        Write-Warning "  Could not link tasks to collection '$collectionName': $($_.Exception.Message)"
      }
    }
    else {
      Write-Warning "  Collection '$collectionName' not found, so tasks were not linked to collection."
    }
  }

  Write-Host ""
}

# -----------------------------
# Export reports
# -----------------------------
$assignmentRows |
  Sort-Object CollectionName, TaskType, SourceUPN |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path $assignmentReportPath

$summaryRows |
  Sort-Object CollectionName, TaskType |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path $summaryReportPath

if ($skippedRows.Count -gt 0) {
  $skippedRows |
    Sort-Object CollectionName |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $skippedPath
}

Write-Host "Reports written:" -ForegroundColor Green
Write-Host "  Assignment verification: $assignmentReportPath"
Write-Host "  Task summary:            $summaryReportPath"

if ($unresolvedRows.Count -gt 0) {
  Write-Host "  Unresolved UPNs:          $unresolvedPath"
}

if ($skippedRows.Count -gt 0) {
  Write-Host "  Skipped collections:      $skippedPath"
}

Write-Host "Done. Template-based tasks created and NOT started." -ForegroundColor Green