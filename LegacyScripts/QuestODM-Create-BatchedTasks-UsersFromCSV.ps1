<#
QuestODM-Create-Tasks-FromCollectionCsv.ps1

Reads a CSV with:
  CollectionName,SourceUPN

For each unique CollectionName:
  - resolves the listed SourceUPNs to ODM account objects
  - creates 4 tasks:
      <CollectionName> - Email Sync
      <CollectionName> - OneDrive Sync
      <CollectionName> - Meeting Link Migration
      <CollectionName> - Mailbox Switch
  - adds the resolved objects to each task
  - optionally links the tasks back to the matching collection in ODM for UI visibility
  - does NOT start any tasks
  - exports detailed reporting

Requirements:
- Windows PowerShell 5.1
- OdmApi module
- Correct Org / Project / Accounts workload context

CSV format:
CollectionName,SourceUPN
Wave001_04-27-26,user1@source.com
Wave001_04-27-26,user2@source.com
Wave002_04-28-26,user3@source.com
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

  [Parameter()]
  [ValidateSet("US","EU","AU","CA","UK","us","eu","au","ca","uk")]
  [string]$Region = "US",

  [Parameter()]
  [string]$NotifyRecipients = "",

  [Parameter()]
  [string]$OutDir = "C:\Temp\ODM_Reports",

  # If you want the script to try linking created tasks back to the collection with the same name
  [switch]$LinkTasksToCollections
)

# -----------------------------
# Config
# -----------------------------
$mailFrom = Get-Date "2025-11-01"
$OneDriveFilterItems = "AfterLastSuccessfulRun"   # Change to "AllItems" for first-ever OneDrive pass if needed

$MailSuffix        = "Email Sync"
$OneDriveSuffix    = "OneDrive Sync"
$MeetingLinkSuffix = "Meeting Link Migration"
$MailSwitchSuffix  = "Mailbox Switch"

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

if (-not ("OdmMailMigrationTask" -as [type])) {
  throw "OdmMailMigrationTask type is not loaded. Ensure OdmApi is installed and run this in Windows PowerShell 5.1."
}

if (-not ("OdmOneDriveMigrationTask" -as [type])) {
  throw "OdmOneDriveMigrationTask type is not loaded. Ensure OdmApi is installed and run this in Windows PowerShell 5.1."
}

if (-not (Get-Command New-OdmMeetingLinkMigrationTask -ErrorAction SilentlyContinue)) {
  throw "New-OdmMeetingLinkMigrationTask was not found in OdmApi."
}

if (-not (Get-Command New-OdmMailSwitchTask -ErrorAction SilentlyContinue)) {
  throw "New-OdmMailSwitchTask was not found in OdmApi."
}

# -----------------------------
# Helpers
# -----------------------------
function Normalize-Upn {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  return $Value.Trim().ToLower()
}

function Normalize-Name {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
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

  if ([string]::IsNullOrWhiteSpace($Key)) { return }

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

function Add-IfParam {
  param(
    [Parameter(Mandatory)][hashtable]$Hash,
    [Parameter(Mandatory)][string[]]$ParamNames,
    [Parameter(Mandatory)][string]$ParamName,
    $Value
  )

  if ($ParamNames -contains $ParamName) {
    if ($null -ne $Value) {
      $Hash[$ParamName] = $Value
    }
    return $true
  }

  return $false
}

function Get-SafeCount {
  param($Task)

  try {
    return @($Task | Get-OdmObject -All).Count
  }
  catch {
    return -1
  }
}

# -----------------------------
# Output files
# -----------------------------
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$assignmentReportPath = Join-Path $OutDir "UserToTaskAssignments_$stamp.csv"
$summaryReportPath    = Join-Path $OutDir "TaskSummary_$stamp.csv"
$unresolvedPath       = Join-Path $OutDir "UnresolvedUPNs_$stamp.csv"

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

$propNames = $allObjects[0].PSObject.Properties.Name
$upnProps = $propNames | Where-Object {
  $_ -match 'upn' -or $_ -match 'UserPrincipalName' -or $_ -match 'email' -or $_ -match 'mail'
}

Write-Host "UPN-like properties detected: $($upnProps -join ', ')"

$objLookup = @{}
foreach ($obj in $allObjects) {
  foreach ($prop in $upnProps) {
    $value = $obj.$prop
    if ($value) {
      Add-LookupEntry -Lookup $objLookup -Key $value -Obj $obj
    }
  }
}

Write-Host "Lookup entries created: $($objLookup.Count)"
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
# Parameter discovery
# -----------------------------
$meetingLinkParamNames = Get-CommandParamNames -Name New-OdmMeetingLinkMigrationTask
$mailSwitchParamNames  = Get-CommandParamNames -Name New-OdmMailSwitchTask

# -----------------------------
# Optionally load collections for task linking
# -----------------------------
$collectionLookup = @{}
if ($LinkTasksToCollections) {
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
# Group by collection and create tasks
# -----------------------------
$grouped = $resolvedRows | Group-Object CollectionName

$assignmentRows = New-Object System.Collections.Generic.List[object]
$summaryRows    = New-Object System.Collections.Generic.List[object]

foreach ($grp in $grouped) {
  $collectionName = $grp.Name

  # Dedup objects within this collection
  $collectionObjects = $grp.Group |
    Where-Object { $_.ObjectId } |
    Group-Object ObjectId |
    ForEach-Object { $_.Group | Select-Object -First 1 }

  if (-not $collectionObjects -or $collectionObjects.Count -eq 0) {
    continue
  }

  $objectsForTask = @($collectionObjects | ForEach-Object { $_.Object })

  $mailTaskName        = "$collectionName - $MailSuffix"
  $oneDriveTaskName    = "$collectionName - $OneDriveSuffix"
  $meetingLinkTaskName = "$collectionName - $MeetingLinkSuffix"
  $mailSwitchTaskName  = "$collectionName - $MailSwitchSuffix"

  Write-Host "Creating tasks for collection '$collectionName' (Users: $($collectionObjects.Count))..." -ForegroundColor Cyan

  # -------------------------
  # Mail task
  # -------------------------
  $mailTask = $null
  $mailAssignedCount = -1

  try {
    $mailTask = New-OdmMailMigrationTask `
      -Name $mailTaskName `
      -SkipO365LicenseAssignment `
      -MigrateMail `
      -MigrateCalendar `
      -MigrateContacts `
      -MigrateTasks `
      -MigrateRecoverableItems `
      -MigrateRules `
      -MigrateDelegates `
      -EnableAutomapping `
      -MigrateFolderPermissions `
      -MigrateAutoReplyState `
      -MigrateLitigationHoldSettings `
      -AipLabelProcessing "Skip" `
      -MailForwarding "Ignore" `
      -MigrateMailFrom $mailFrom `
      -NotifyOnTaskCompletion `
      -NotifyOnlyOnTaskFailure:$false `
      -NotificationRecipientEmail $NotifyRecipients `
      -ScheduledStartTime $null

    $null = $mailTask | Add-OdmObject -Object $objectsForTask
    $mailAssignedCount = Get-SafeCount -Task $mailTask

    Write-Host "  Created: $mailTaskName (Users added: $mailAssignedCount)" -ForegroundColor Green
  }
  catch {
    Write-Warning "  FAILED creating Mail task '$mailTaskName': $($_.Exception.Message)"
  }

  # -------------------------
  # OneDrive task
  # -------------------------
  $oneDriveTask = $null
  $oneDriveAssignedCount = -1

  try {
    $oneDriveTask = New-OdmOneDriveMigrationTask `
      -Name $oneDriveTaskName `
      -SkipO365LicenseAssignment `
      -MigrationAction "Skip" `
      -FileVersions "Latest" `
      -Author "TargetAccount" `
      -PermissionBehaviour "All" `
      -FilterItems $OneDriveFilterItems `
      -RerunIfMissingItems:$false `
      -ProcessSensitivityLabels:$false `
      -EnableReporting:$true `
      -NotifyOnTaskCompletion:$true `
      -NotifyOnlyOnTaskFailure:$false `
      -NotificationRecipientEmail $NotifyRecipients `
      -ScheduledStartTime $null

    $null = $oneDriveTask | Add-OdmObject -Object $objectsForTask
    $oneDriveAssignedCount = Get-SafeCount -Task $oneDriveTask

    Write-Host "  Created: $oneDriveTaskName (Users added: $oneDriveAssignedCount)" -ForegroundColor Green
  }
  catch {
    Write-Warning "  FAILED creating OneDrive task '$oneDriveTaskName': $($_.Exception.Message)"
    Write-Warning "  NOTE: If this is first-ever OneDrive pass, consider setting `$OneDriveFilterItems = 'AllItems'."
  }

  # -------------------------
  # Meeting Link task
  # -------------------------
  $meetingLinkTask = $null
  $meetingAssignedCount = -1

  try {
    $meetingLinkParams = @{
      Name = $meetingLinkTaskName
    }

    Add-IfParam -Hash $meetingLinkParams -ParamNames $meetingLinkParamNames -ParamName "NotifyOnTaskCompletion" -Value $true | Out-Null
    Add-IfParam -Hash $meetingLinkParams -ParamNames $meetingLinkParamNames -ParamName "NotifyOnlyOnTaskFailure" -Value $false | Out-Null
    Add-IfParam -Hash $meetingLinkParams -ParamNames $meetingLinkParamNames -ParamName "NotificationRecipientEmail" -Value $NotifyRecipients | Out-Null

    $meetingLinkTask = New-OdmMeetingLinkMigrationTask @meetingLinkParams
    $null = $meetingLinkTask | Add-OdmObject -Object $objectsForTask
    $meetingAssignedCount = Get-SafeCount -Task $meetingLinkTask

    Write-Host "  Created: $meetingLinkTaskName (Users added: $meetingAssignedCount)" -ForegroundColor Green
  }
  catch {
    Write-Warning "  FAILED creating Meeting Link task '$meetingLinkTaskName': $($_.Exception.Message)"
  }

  # -------------------------
  # Mail Switch task
  # -------------------------
  $mailSwitchTask = $null
  $mailSwitchAssignedCount = -1

  try {
    $mailSwitchParams = @{
      Name = $mailSwitchTaskName
    }

    Add-IfParam -Hash $mailSwitchParams -ParamNames $mailSwitchParamNames -ParamName "NotifyOnTaskCompletion" -Value $true | Out-Null
    Add-IfParam -Hash $mailSwitchParams -ParamNames $mailSwitchParamNames -ParamName "NotifyOnlyOnTaskFailure" -Value $false | Out-Null
    Add-IfParam -Hash $mailSwitchParams -ParamNames $mailSwitchParamNames -ParamName "NotificationRecipientEmail" -Value $NotifyRecipients | Out-Null
    Add-IfParam -Hash $mailSwitchParams -ParamNames $mailSwitchParamNames -ParamName "MailForwarding" -Value "Enable" | Out-Null
    Add-IfParam -Hash $mailSwitchParams -ParamNames $mailSwitchParamNames -ParamName "SwitchDirection" -Value "SourceToTarget" | Out-Null

    $mailSwitchTask = New-OdmMailSwitchTask @mailSwitchParams
    $null = $mailSwitchTask | Add-OdmObject -Object $objectsForTask
    $mailSwitchAssignedCount = Get-SafeCount -Task $mailSwitchTask

    Write-Host "  Created: $mailSwitchTaskName (Users added: $mailSwitchAssignedCount)" -ForegroundColor Green
  }
  catch {
    Write-Warning "  FAILED creating Mail Switch task '$mailSwitchTaskName': $($_.Exception.Message)"
  }

  # -------------------------
  # Optional: link tasks to matching collection
  # -------------------------
  if ($LinkTasksToCollections -and $collectionLookup.ContainsKey($collectionName)) {
    $tasksToLink = @()
    if ($mailTask)        { $tasksToLink += $mailTask }
    if ($oneDriveTask)    { $tasksToLink += $oneDriveTask }
    if ($meetingLinkTask) { $tasksToLink += $meetingLinkTask }
    if ($mailSwitchTask)  { $tasksToLink += $mailSwitchTask }

    if ($tasksToLink.Count -gt 0) {
      try {
        Add-OdmTask -Tasks $tasksToLink -To $collectionLookup[$collectionName] | Out-Null
        Write-Host "  Linked tasks to collection: $collectionName" -ForegroundColor DarkGray
      }
      catch {
        Write-Warning "  Could not link tasks to collection '$collectionName': $($_.Exception.Message)"
      }
    }
  }

  foreach ($item in $collectionObjects) {
    $assignmentRows.Add([pscustomobject]@{
      CollectionName          = $collectionName
      SourceUPN               = $item.SourceUPN
      ObjectId                = $item.ObjectId
      MailTaskName            = $mailTaskName
      MailUsersAdded          = $mailAssignedCount
      OneDriveTaskName        = $oneDriveTaskName
      OneDriveUsersAdded      = $oneDriveAssignedCount
      MeetingLinkTaskName     = $meetingLinkTaskName
      MeetingLinkUsersAdded   = $meetingAssignedCount
      MailSwitchTaskName      = $mailSwitchTaskName
      MailSwitchUsersAdded    = $mailSwitchAssignedCount
    }) | Out-Null
  }

  $summaryRows.Add([pscustomobject]@{
    CollectionName           = $collectionName
    UserCount                = $collectionObjects.Count
    MailTaskName             = $mailTaskName
    MailUsersAdded           = $mailAssignedCount
    OneDriveTaskName         = $oneDriveTaskName
    OneDriveUsersAdded       = $oneDriveAssignedCount
    MeetingLinkTaskName      = $meetingLinkTaskName
    MeetingLinkUsersAdded    = $meetingAssignedCount
    MailSwitchTaskName       = $mailSwitchTaskName
    MailSwitchUsersAdded     = $mailSwitchAssignedCount
    OneDriveFilterItems      = $OneDriveFilterItems
  }) | Out-Null

  Write-Host ""
}

# -----------------------------
# Export reports
# -----------------------------
$assignmentRows |
  Sort-Object CollectionName, SourceUPN |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path $assignmentReportPath

$summaryRows |
  Sort-Object CollectionName |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path $summaryReportPath

Write-Host "Reports written:" -ForegroundColor Green
Write-Host "  Assignment detail: $assignmentReportPath"
Write-Host "  Task summary:      $summaryReportPath"
Write-Host "Done. Tasks created and NOT started." -ForegroundColor Green