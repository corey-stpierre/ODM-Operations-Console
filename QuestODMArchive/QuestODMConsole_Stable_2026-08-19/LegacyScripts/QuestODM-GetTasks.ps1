<#
.SYNOPSIS
  Export Quest ODM (OdmApi) tasks for Mail + OneDrive across an Organization.

.DESCRIPTION
  - Uses OdmApi (Quest ODM PowerShell API)
  - Connects: Connect-OdmService -> Select-OdmOrganization
  - Enumerates all projects -> all tasks per project
  - Filters to Mail + OneDrive tasks
  - Exports to CSV

.NOTES
  - OdmApi works best in Windows PowerShell 5.1. If you run this in PowerShell 7+,
    it will automatically relaunch itself in powershell.exe.

.EXAMPLE
  C:\temp\QuestODM-GetAllTasks.ps1 -Region US -OrganizationId "00759f6f-8b29-0576-c0ee-266b5c0cf06b" -OutCsv "C:\temp\WM_AllTasks.csv"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$Region = "us",

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [Guid]$OrganizationId,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutCsv = "C:\temp\ODM_Mail_OneDrive_Tasks.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- If running in PowerShell 7+, relaunch in Windows PowerShell 5.1 ----
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $env:ODM_RELAUNCHED_IN_WINPS) {
    $env:ODM_RELAUNCHED_IN_WINPS = "1"

    $argsForWinPS = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-Region", $Region,
        "-OrganizationId", $OrganizationId.ToString(),
        "-OutCsv", $OutCsv
    )

    Write-Host "Detected PowerShell $($PSVersionTable.PSVersion). Relaunching in Windows PowerShell (powershell.exe)..." -ForegroundColor Yellow
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argsForWinPS -Wait -PassThru
    exit $p.ExitCode
}

function Require-Cmdlet([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing cmdlet '$Name'. Ensure the OdmApi module is installed/imported."
    }
}

function Get-PropValue {
    param(
        [Parameter(Mandatory=$true)][object]$Obj,
        [Parameter(Mandatory=$true)][string[]]$Names
    )
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($null -ne $p) { return $p.Value }

        try {
            $v = $Obj.$n
            if ($null -ne $v) { return $v }
        } catch {}

        try {
            $flags = [System.Reflection.BindingFlags]::Instance `
                   -bor [System.Reflection.BindingFlags]::Public `
                   -bor [System.Reflection.BindingFlags]::NonPublic
            $pi = $Obj.GetType().GetProperty($n, $flags)
            if ($pi) {
                $v2 = $pi.GetValue($Obj)
                if ($null -ne $v2) { return $v2 }
            }
        } catch {}
    }
    return $null
}

function Get-AllProjects {
    $cmd = Get-Command Get-OdmProject -ErrorAction Stop
    if ($cmd.Parameters.ContainsKey("All")) { return @(Get-OdmProject -All) }
    return @(Get-OdmProject)
}

function Get-AllTasksForProject {
    param([Parameter(Mandatory=$true)][object]$Project)

    $cmd = Get-Command Get-OdmTask -ErrorAction Stop
    $params = @{}

    # Prefer explicit project parameter if available
    if ($cmd.Parameters.ContainsKey("Project")) {
        $params.Project = $Project
    } elseif ($cmd.Parameters.ContainsKey("ProjectId")) {
        $params.ProjectId = (Get-PropValue -Obj $Project -Names @("Id","ID","ProjectId"))
    } else {
        # Last-resort pipeline
        if ($cmd.Parameters.ContainsKey("All")) {
            return @($Project | Get-OdmTask -All)
        }
        return @($Project | Get-OdmTask)
    }

    if ($cmd.Parameters.ContainsKey("All")) { $params.All = $true }

    try {
        return @(& $cmd.Name @params)
    } catch {
        # If this fails for some projects, keep going
        Write-Warning "Failed to read tasks for project '$($Project.Name)': $($_.Exception.Message)"
        return @()
    }
}

# ---- Load module ----
if (-not (Get-Module -ListAvailable -Name "OdmApi")) {
    throw "OdmApi module not found. Install with: Install-Module OdmApi -Scope CurrentUser"
}
Import-Module OdmApi -ErrorAction Stop

# ---- Connect + Select Organization ----
$regionNorm = $Region.ToLowerInvariant()
Connect-OdmService -Region $regionNorm
Select-OdmOrganization -OrganizationId $OrganizationId

# ---- Ensure output folder exists ----
$folder = Split-Path -Parent $OutCsv
if ($folder -and -not (Test-Path $folder)) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}

# ---- Get projects ----
$projects = @(Get-AllProjects)
if ($projects.Count -eq 0) {
    Write-Warning "No projects found for OrganizationId $OrganizationId"
    @() | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsv
    Write-Host "Export complete (0 rows): $OutCsv"
    exit 0
}

# We’ll filter by Context first; fallback to Type/Name heuristics if Context is blank
$rows = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $projects.Count; $i++) {
    $proj = $projects[$i]
    $pct  = [int](($i + 1) * 100 / [Math]::Max(1, $projects.Count))

    Write-Progress -Activity "Exporting ODM tasks (Mail + OneDrive)" `
        -Status "Project $($i+1)/$($projects.Count): $($proj.Name)" `
        -PercentComplete $pct

    $tasks = @(Get-AllTasksForProject -Project $proj)

    foreach ($t in $tasks) {
        $name   = Get-PropValue -Obj $t -Names @("Name","TaskName","DisplayName")
        $status = Get-PropValue -Obj $t -Names @("Status","State")
        $type   = Get-PropValue -Obj $t -Names @("Type","TaskType")
        $ctx    = Get-PropValue -Obj $t -Names @("Context","Workload")

        $ctxLower  = if ($ctx)  { $ctx.ToString().ToLowerInvariant() } else { "" }
        $typeLower = if ($type) { $type.ToString().ToLowerInvariant() } else { "" }
        $nameLower = if ($name) { $name.ToString().ToLowerInvariant() } else { "" }

        $isMail     = ($ctxLower -match "mail|mailbox|mailboxes|exchange") -or ($typeLower -match "mail|mailbox|mailboxes|exchange") -or ($nameLower -match "mail|mailbox|mailboxes|exchange")
        $isOneDrive = ($ctxLower -match "onedrive") -or ($typeLower -match "onedrive") -or ($nameLower -match "onedrive")

        if (-not ($isMail -or $isOneDrive)) { continue }

        $workload =
            if ($isMail -and $isOneDrive) { "Mail+OneDrive" }
            elseif ($isOneDrive) { "OneDrive" }
            else { "Mail" }

        $rows.Add([pscustomobject]@{
            OrganizationId = $OrganizationId
            Region         = $Region

            ProjectName    = $proj.Name
            ProjectId      = (Get-PropValue -Obj $proj -Names @("Id","ID"))

            Workload       = $workload
            Context        = $ctx

            TaskName       = $name
            Status         = $status
            TaskType       = $type
            Progress       = (Get-PropValue -Obj $t -Names @("Progress"))

            Created        = (Get-PropValue -Obj $t -Names @("Created","CreatedAt"))
            Modified       = (Get-PropValue -Obj $t -Names @("Modified","Updated","UpdatedAt","LastUpdated"))

            TaskId         = (Get-PropValue -Obj $t -Names @("Id","ID","TaskId"))
        }) | Out-Null
    }
}

Write-Progress -Activity "Exporting ODM tasks (Mail + OneDrive)" -Completed

$rows |
    Sort-Object ProjectName, Workload, TaskName |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsv

Write-Host "Export complete: $($rows.Count) row(s) written to $OutCsv"
