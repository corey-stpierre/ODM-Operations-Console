Set-StrictMode -Version 2.0

function Get-QOdmApplicationRoot {
    [CmdletBinding()]
    param()

    if (Get-Variable -Name QOdmAppRoot -Scope Script -ErrorAction SilentlyContinue) {
        return [string]$script:QOdmAppRoot
    }
    return (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
}

function Get-QOdmConsoleVersion {
    [CmdletBinding()]
    param()

    $path = Join-Path -Path (Get-QOdmApplicationRoot) -ChildPath 'VERSION.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '0.0.0' }
    return ([string](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)).Trim()
}

function Get-QOdmBuildInfo {
    [CmdletBinding()]
    param()

    $path = Join-Path -Path (Get-QOdmApplicationRoot) -ChildPath 'Config\BuildInfo.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            ProductName='Quest ODM Operations Console'; Version=(Get-QOdmConsoleVersion); BuildDateUtc=$null
            BuildId=$null; ReleaseChannel='Unknown'; SupportOwner=$null; SupportEmail=$null
            ValidatedOdmApiVersion=$null; SupportedHost='Windows PowerShell 5.1 x64 STA'
            Notice='Unofficial integration utility.'
        }
    }
    return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}

function Get-QOdmCompatibilityPolicy {
    [CmdletBinding()]
    param([bool]$Refresh = $false)

    if (-not $Refresh -and (Get-Variable -Name QOdmCompatibilityPolicy -Scope Script -ErrorAction SilentlyContinue) -and $null -ne $script:QOdmCompatibilityPolicy) {
        return $script:QOdmCompatibilityPolicy
    }

    $path = Join-Path -Path (Get-QOdmApplicationRoot) -ChildPath 'Config\OdmApiCompatibility.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "OdmApi compatibility policy was not found: $path" }
    $policy = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $minimum = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $policy -Names @('MinimumOdmApiVersion'))
    if ($null -eq $minimum) { throw 'The compatibility policy contains an invalid MinimumOdmApiVersion.' }
    $validated = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $policy -Names @('ValidatedOdmApiVersions') -Default @())
    if ($validated.Count -eq 0) { throw 'The compatibility policy must contain at least one validated OdmApi version.' }
    $script:QOdmCompatibilityPolicy = $policy
    return $policy
}

function Get-QOdmRequiredCommandsByFeature {
    [CmdletBinding()]
    param()

    $policy = Get-QOdmCompatibilityPolicy
    $features = Get-QOdmProperty -InputObject $policy -Names @('RequiredCommands')
    $result = [ordered]@{}
    if ($null -eq $features) { return $result }
    foreach ($property in (ConvertTo-QOdmObjectArray -InputObject $features.PSObject.Properties)) {
        $result[[string]$property.Name] = ConvertTo-QOdmObjectArray -InputObject $property.Value
    }
    return $result
}

function Get-QOdmCompatibilityAssessment {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ModuleStatus,
        [bool]$CheckOnline = $false
    )

    if ($null -eq $ModuleStatus) { $ModuleStatus = Get-QOdmApiModuleStatus -CheckOnline $CheckOnline }
    $policy = Get-QOdmCompatibilityPolicy
    $minimum = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $policy -Names @('MinimumOdmApiVersion'))
    $validatedTexts = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $policy -Names @('ValidatedOdmApiVersions') -Default @())
    $validatedVersions = [System.Collections.Generic.List[object]]::new()
    foreach ($text in $validatedTexts) {
        $version = ConvertTo-QOdmVersionValue -Value $text
        if ($null -ne $version) { $validatedVersions.Add($version) | Out-Null }
    }
    $validatedVersion = if ($validatedVersions.Count -gt 0) { $validatedVersions.ToArray() | Sort-Object -Descending | Select-Object -First 1 } else { $minimum }
    $installed = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $ModuleStatus -Names @('InstalledVersionText'))
    $loaded = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $ModuleStatus -Names @('LoadedVersionText'))
    $online = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $ModuleStatus -Names @('LatestOnlineVersionText'))

    $status = 'NOT_INSTALLED'
    $severity = 'FAIL'
    $details = 'OdmApi is not installed.'
    $validatedInstalled = $false
    if ($null -ne $installed) {
        $validatedInstalled = [bool]($validatedVersions.ToArray() | Where-Object { $_ -eq $installed } | Select-Object -First 1)
        if ($installed -lt $minimum) {
            $status = 'BELOW_MINIMUM'
            $severity = 'FAIL'
            $details = "OdmApi $installed is below the minimum supported version $minimum."
        }
        elseif ($validatedInstalled) {
            $status = 'VALIDATED'
            $severity = 'PASS'
            $details = "OdmApi $installed is validated for console $(Get-QOdmConsoleVersion)."
        }
        else {
            $status = 'UNVALIDATED'
            $severity = 'WARNING'
            $details = "OdmApi $installed meets the minimum requirement but is not in the validated-version list. Command-surface checks remain authoritative."
        }
    }

    $featureAssessments = [System.Collections.Generic.List[object]]::new()
    $availableCommandMap = @{}
    foreach ($availableName in (ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $ModuleStatus -Names @('AvailableCommandNames') -Default @()))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$availableName)) { $availableCommandMap[[string]$availableName] = $true }
    }
    $requiredByFeature = Get-QOdmRequiredCommandsByFeature
    foreach ($featureName in $requiredByFeature.Keys) {
        $required = ConvertTo-QOdmObjectArray -InputObject $requiredByFeature[$featureName]
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($commandName in $required) {
            $commandText = [string]$commandName
            $available = $availableCommandMap.ContainsKey($commandText) -or (Test-QOdmCommand -Name $commandText)
            if (-not $available) { $missing.Add($commandText) | Out-Null }
        }
        $featureAssessments.Add([pscustomobject]@{
            Feature=[string]$featureName; RequiredCommands=$required; MissingCommands=$missing.ToArray()
            Available=($missing.Count -eq 0); Status=if ($missing.Count -eq 0) { 'PASS' } else { 'FAIL' }
        }) | Out-Null
    }

    $coreFeature = $featureAssessments.ToArray() | Where-Object { $_.Feature -eq 'Core' } | Select-Object -First 1
    $coreAvailable = ($null -ne $coreFeature -and [bool]$coreFeature.Available)
    $blocking = ($null -eq $installed -or $installed -lt $minimum -or -not $coreAvailable)
    $latestValidatedText = if ($null -ne $validatedVersion) { [string]$validatedVersion } else { $null }

    [pscustomobject]@{
        ConsoleVersion=(Get-QOdmConsoleVersion)
        MinimumVersion=[string]$minimum
        ValidatedVersions=ConvertTo-QOdmObjectArray -InputObject ($validatedVersions.ToArray() | ForEach-Object { [string]$_ })
        PreferredValidatedVersion=$latestValidatedText
        InstalledVersion=if ($null -ne $installed) { [string]$installed } else { $null }
        LoadedVersion=if ($null -ne $loaded) { [string]$loaded } else { $null }
        LatestOnlineVersion=if ($null -ne $online) { [string]$online } else { $null }
        CompatibilityStatus=$status
        Severity=$severity
        Details=$details
        ValidatedInstalled=$validatedInstalled
        CoreCommandsAvailable=$coreAvailable
        Blocking=$blocking
        FeatureAssessments=$featureAssessments.ToArray()
        OnlineChecked=[bool](Get-QOdmProperty -InputObject $ModuleStatus -Names @('OnlineChecked') -Default $false)
        OnlineCheckSucceeded=[bool](Get-QOdmProperty -InputObject $ModuleStatus -Names @('OnlineCheckSucceeded') -Default $false)
    }
}

function Enable-QOdmSafeMode {
    [CmdletBinding()]
    param([string]$Reason = 'Safe Mode enabled.')

    if (-not (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue)) { Initialize-QOdmState }
    $script:QOdmState.SafeMode = $true
    $script:QOdmState.SafeModeReason = $Reason
    $script:QOdmState.SafeModeChangedAt = Get-Date
    $script:QOdmState.SafeModeChangedBy = [Environment]::UserName
    return (Get-QOdmSafeModeState)
}

function Disable-QOdmSafeMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OrganizationId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$WorkloadId,
        [Parameter(Mandatory = $true)][string]$ConfirmationText
    )

    Assert-QOdmWorkloadSelected
    if (-not [string]::Equals($ConfirmationText.Trim(), 'ENABLE CHANGES', [StringComparison]::Ordinal)) {
        throw "Enter the exact confirmation text 'ENABLE CHANGES'."
    }
    foreach ($pair in @(
        [pscustomobject]@{Name='Organization';Requested=$OrganizationId;Current=[string]$script:QOdmState.OrganizationId},
        [pscustomobject]@{Name='Project';Requested=$ProjectId;Current=[string]$script:QOdmState.ProjectId},
        [pscustomobject]@{Name='Workload';Requested=$WorkloadId;Current=[string]$script:QOdmState.WorkloadId}
    )) {
        if (-not [string]::Equals([string]$pair.Requested, [string]$pair.Current, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$($pair.Name) confirmation does not match the active Quest context."
        }
    }
    if (-not [bool]$script:QOdmState.ContextValid) { throw 'The Quest context is invalid. Reconnect before enabling changes.' }
    $script:QOdmState.SafeMode = $false
    $script:QOdmState.SafeModeReason = 'Changes explicitly enabled for the current context.'
    $script:QOdmState.SafeModeChangedAt = Get-Date
    $script:QOdmState.SafeModeChangedBy = [Environment]::UserName
    return (Get-QOdmSafeModeState)
}

function Get-QOdmSafeModeState {
    [CmdletBinding()]
    param()

    if (-not (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue)) { Initialize-QOdmState }
    [pscustomobject]@{
        Enabled=[bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('SafeMode') -Default $true)
        Reason=[string](Get-QOdmProperty -InputObject $script:QOdmState -Names @('SafeModeReason') -Default 'Safe Mode enabled at startup.')
        ChangedAt=Get-QOdmProperty -InputObject $script:QOdmState -Names @('SafeModeChangedAt')
        ChangedBy=Get-QOdmProperty -InputObject $script:QOdmState -Names @('SafeModeChangedBy')
        OrganizationId=$script:QOdmState.OrganizationId
        OrganizationName=$script:QOdmState.OrganizationName
        ProjectId=$script:QOdmState.ProjectId
        ProjectName=$script:QOdmState.ProjectName
        WorkloadId=$script:QOdmState.WorkloadId
        WorkloadName=$script:QOdmState.WorkloadName
    }
}

function Get-QOdmOperationWriteFeature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [AllowNull()][System.Collections.IDictionary]$Parameters
    )

    $p = if ($null -eq $Parameters) { @{} } else { $Parameters }
    switch ($Operation) {
        'AddObjectToTask' { return 'Membership' }
        'RemoveObjectFromTask' { return 'Membership' }
        'AddObjectToCollection' { return 'Membership' }
        'RemoveObjectFromCollection' { return 'Membership' }
        'NewCollection' { return 'Membership' }
        'DeleteCollections' { return 'Membership' }
        'StartTasks' { return 'TaskLifecycle' }
        'StopTasks' { return 'TaskLifecycle' }
        'DeleteTasks' { return 'TaskLifecycle' }
        'CreateTaskErrorLogExport' { return 'Reporting' }
        'RemoveMmpcFlag' { return 'LocalWrite' }
        'AddUsersToEntityFromCsv' { if ([bool](Get-QOdmProperty -InputObject $p -Names @('Execute') -Default $false)) { return 'Membership' }; return $null }
        'RemoveUsersFromEntityFromCsv' { if ([bool](Get-QOdmProperty -InputObject $p -Names @('Execute') -Default $false)) { return 'Membership' }; return $null }
        'TaskFactory' { if ([bool](Get-QOdmProperty -InputObject $p -Names @('Execute') -Default $false)) { return 'TaskFactory' }; return $null }
        'Bulk' {
            $nested = Get-QOdmProperty -InputObject $p -Names @('Parameters') -Default @{}
            $execute = [bool](Get-QOdmProperty -InputObject $nested -Names @('Execute') -Default $false)
            if (-not $execute) { return $null }
            $bulkName = [string](Get-QOdmProperty -InputObject $p -Names @('Operation'))
            switch ($bulkName) {
                'DiscoverAllAccounts' { return 'AccountDiscovery' }
                'DiscoverAccountsFromCsv' { return 'AccountDiscovery' }
                'MapAccountsFromCsv' { return 'AccountDiscovery' }
                'StartTasksFromCsv' { return 'TaskLifecycle' }
                'StopTasksFromCsv' { return 'TaskLifecycle' }
                'DeleteTasksFromCsv' { return 'TaskLifecycle' }
                'DeleteTasksAcrossProjects' { return 'TaskLifecycle' }
                'DeleteAllTasks' { return 'TaskLifecycle' }
                default { return 'Membership' }
            }
        }
        default { return $null }
    }
}

function Assert-QOdmWriteAllowed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Feature)

    if ([bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('SafeMode') -Default $true)) {
        throw 'Safe Mode is enabled. Use the header control to explicitly enable changes for the active organization, project, and workload.'
    }
    if (-not [bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('ContextValid') -Default $true)) {
        throw 'The Quest context is invalid. Reconnect before performing a write operation.'
    }
    $blocked = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $script:QOdmState -Names @('BlockedFeatures') -Default @())
    if ($blocked -contains 'AllWrites' -or $blocked -contains $Feature) {
        throw "The most recent readiness check blocks feature '$Feature'. Review Diagnostics, correct the failed readiness checks, and run the check again."
    }
}

function Assert-QOdmOperationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [AllowNull()][System.Collections.IDictionary]$Parameters
    )

    $feature = Get-QOdmOperationWriteFeature -Operation $Operation -Parameters $Parameters
    if (-not [string]::IsNullOrWhiteSpace([string]$feature)) { Assert-QOdmWriteAllowed -Feature $feature }
}

function New-QOdmReadinessCheckRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS','WARNING','FAIL','NOT APPLICABLE')][string]$Status,
        [AllowNull()][string]$Details,
        [string[]]$BlocksFeatures = @(),
        [AllowNull()][object]$Evidence = $null
    )

    [pscustomobject]@{
        Category=$Category; Name=$Name; Status=$Status; Details=$Details
        BlocksFeatures=ConvertTo-QOdmObjectArray -InputObject $BlocksFeatures
        Evidence=$Evidence; CheckedAt=Get-Date
    }
}

function Add-QOdmReadinessCheckRecord {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory = $true)][object]$Record
    )
    $List.Add($Record) | Out-Null
}

function ConvertTo-QOdmHtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Export-QOdmReadinessResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [AllowNull()][string]$OutputDirectory
    )

    $directory = Get-QOdmOutputDirectory -OutputDirectory $OutputDirectory
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $directory "QuestODMConsole_Readiness_$stamp.json"
    $htmlPath = Join-Path $directory "QuestODMConsole_Readiness_$stamp.html"
    $Result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $rows = [System.Text.StringBuilder]::new()
    foreach ($check in (ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $Result -Names @('Checks') -Default @()))) {
        $null = $rows.Append('<tr>')
        foreach ($value in @($check.Category,$check.Name,$check.Status,$check.Details,((ConvertTo-QOdmObjectArray -InputObject $check.BlocksFeatures) -join ', '))) {
            $null = $rows.Append('<td>')
            $null = $rows.Append((ConvertTo-QOdmHtmlText -Value $value))
            $null = $rows.Append('</td>')
        }
        $null = $rows.Append('</tr>')
    }
    $summary = Get-QOdmProperty -InputObject $Result -Names @('Summary')
    $html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>Quest ODM Console Readiness</title>
<style>body{font-family:Segoe UI,Arial;margin:24px;color:#273142}h1{color:#2E4778}table{border-collapse:collapse;width:100%}th,td{border:1px solid #d0d8e5;padding:8px;text-align:left;vertical-align:top}th{background:#edf2f8}.meta{margin-bottom:16px;padding:12px;background:#f6fbfe;border:1px solid #d0d8e5}</style></head>
<body><h1>Quest ODM Operations Console readiness</h1>
<div class="meta">Overall: $(ConvertTo-QOdmHtmlText $summary.OverallStatus) &nbsp;|&nbsp; PASS: $($summary.Pass) &nbsp; WARNING: $($summary.Warning) &nbsp; FAIL: $($summary.Fail) &nbsp; N/A: $($summary.NotApplicable)<br>Generated: $(ConvertTo-QOdmHtmlText $Result.CompletedAt)<br>Context: $(ConvertTo-QOdmHtmlText $Result.ContextDisplay)</div>
<table><thead><tr><th>Category</th><th>Check</th><th>Status</th><th>Details</th><th>Blocks</th></tr></thead><tbody>$($rows.ToString())</tbody></table></body></html>
"@
    [System.IO.File]::WriteAllText($htmlPath, $html, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
    return [pscustomobject]@{ JsonPath=$jsonPath; HtmlPath=$htmlPath; Reports=@($jsonPath,$htmlPath) }
}

function Invoke-QOdmReadinessCheck {
    [CmdletBinding()]
    param(
        [bool]$CheckOnlineModuleVersion = $false,
        [AllowNull()][string]$OutputDirectory = $null
    )

    Set-QOdmOperationPhase -Phase 'Running V1 readiness checks'
    $checks = [System.Collections.Generic.List[object]]::new()

    $isWindows = ($env:OS -eq 'Windows_NT')
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Host' -Name 'Windows operating system' -Status $(if ($isWindows) {'PASS'} else {'FAIL'}) -Details $(if ($isWindows) {'Windows detected.'} else {'The console requires Windows.'}) -BlocksFeatures $(if ($isWindows) {@()} else {@('AllWrites')}))
    $is64 = [Environment]::Is64BitProcess
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Host' -Name '64-bit process' -Status $(if ($is64) {'PASS'} else {'FAIL'}) -Details "64-bit process: $is64" -BlocksFeatures $(if ($is64) {@()} else {@('AllWrites')}))
    $psVersion = [version]$PSVersionTable.PSVersion
    $psOk = ($psVersion -ge [version]'5.1')
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Host' -Name 'PowerShell version' -Status $(if ($psOk) {'PASS'} else {'FAIL'}) -Details "PowerShell $psVersion ($($PSVersionTable.PSEdition))" -BlocksFeatures $(if ($psOk) {@()} else {@('AllWrites')}))
    $sta = ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA)
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Host' -Name 'STA apartment state' -Status $(if ($sta) {'PASS'} else {'FAIL'}) -Details "Apartment state: $([Threading.Thread]::CurrentThread.ApartmentState)" -BlocksFeatures $(if ($sta) {@()} else {@('AllWrites')}))

    $moduleStatus = Get-QOdmApiModuleStatus -CheckOnline $CheckOnlineModuleVersion
    $compatibility = Get-QOdmCompatibilityAssessment -ModuleStatus $moduleStatus -CheckOnline $CheckOnlineModuleVersion
    $compatStatus = [string]$compatibility.Severity
    if ($compatStatus -eq 'WARNING') { $readinessCompatStatus = 'WARNING' } elseif ($compatStatus -eq 'PASS') { $readinessCompatStatus = 'PASS' } else { $readinessCompatStatus = 'FAIL' }
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'OdmApi' -Name 'Validated version policy' -Status $readinessCompatStatus -Details $compatibility.Details -BlocksFeatures $(if ([bool]$compatibility.Blocking) {@('AllWrites')} else {@()}) -Evidence $compatibility)

    foreach ($feature in (ConvertTo-QOdmObjectArray -InputObject $compatibility.FeatureAssessments)) {
        $missing = ConvertTo-QOdmObjectArray -InputObject $feature.MissingCommands
        $status = if ($missing.Count -eq 0) { 'PASS' } elseif ($feature.Feature -in @('Reporting','TaskMonitoring','Readiness')) { 'WARNING' } else { 'FAIL' }
        $details = if ($missing.Count -eq 0) { 'All required commands are available.' } else { 'Missing: ' + ($missing -join ', ') }
        $blocks = if ($status -eq 'FAIL') { @([string]$feature.Feature) } else { @() }
        if ([string]$feature.Feature -eq 'Core' -and $status -eq 'FAIL') { $blocks = @('AllWrites') }
        Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'OdmApi command surface' -Name ([string]$feature.Feature) -Status $status -Details $details -BlocksFeatures $blocks -Evidence $feature)
    }

    $dataRoot = Get-QOdmDefaultDataRoot
    $logDirectory = Get-QOdmDefaultLogDirectory
    $reportDirectory = Get-QOdmOutputDirectory -OutputDirectory $OutputDirectory
    $dataWritable = Test-QOdmDirectoryWritable -Path $dataRoot -Create $true
    $logWritable = Test-QOdmDirectoryWritable -Path $logDirectory -Create $true
    $reportWritable = Test-QOdmDirectoryWritable -Path $reportDirectory -Create $true
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Storage' -Name 'Application data directory' -Status $(if ($dataWritable) {'PASS'} else {'FAIL'}) -Details $dataRoot -BlocksFeatures $(if ($dataWritable) {@()} else {@('AllWrites')}))
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Storage' -Name 'Log directory' -Status $(if ($logWritable) {'PASS'} else {'FAIL'}) -Details $logDirectory -BlocksFeatures $(if ($logWritable) {@()} else {@('AllWrites')}))
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Storage' -Name 'Report directory' -Status $(if ($reportWritable) {'PASS'} else {'FAIL'}) -Details $reportDirectory -BlocksFeatures $(if ($reportWritable) {@()} else {@('Reporting')}))

    $connected = [bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('Connected') -Default $false)
    $contextValid = [bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('ContextValid') -Default $true)
    $organizationSelected = -not [string]::IsNullOrWhiteSpace([string]$script:QOdmState.OrganizationId)
    $projectSelected = -not [string]::IsNullOrWhiteSpace([string]$script:QOdmState.ProjectId)
    $workloadSelected = -not [string]::IsNullOrWhiteSpace([string]$script:QOdmState.WorkloadId)
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest context' -Name 'Authentication' -Status $(if ($connected) {'PASS'} else {'NOT APPLICABLE'}) -Details $(if ($connected) {'Connected to Quest On Demand.'} else {'Connect to Quest to run tenant checks.'}))
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest context' -Name 'Context validity' -Status $(if (-not $connected) {'NOT APPLICABLE'} elseif ($contextValid) {'PASS'} else {'FAIL'}) -Details $(if ($contextValid) {'Context is valid.'} else {[string]$script:QOdmState.ContextError}) -BlocksFeatures $(if ($connected -and -not $contextValid) {@('AllWrites')} else {@()}))
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest context' -Name 'Organization selected' -Status $(if (-not $connected) {'NOT APPLICABLE'} elseif ($organizationSelected) {'PASS'} else {'WARNING'}) -Details ([string]$script:QOdmState.OrganizationName))
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest context' -Name 'Project selected' -Status $(if (-not $connected) {'NOT APPLICABLE'} elseif ($projectSelected) {'PASS'} else {'WARNING'}) -Details ([string]$script:QOdmState.ProjectName))
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest context' -Name 'Workload selected' -Status $(if (-not $connected) {'NOT APPLICABLE'} elseif ($workloadSelected) {'PASS'} else {'WARNING'}) -Details ([string]$script:QOdmState.WorkloadName))

    if ($connected -and $organizationSelected) {
        if (Test-QOdmCommand -Name 'Get-OdmRoleAssignments') {
            try {
                $roleAssignments = ConvertTo-QOdmObjectArray -InputObject (Get-OdmRoleAssignments -ErrorAction Stop)
                Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Role assignments' -Status $(if ($roleAssignments.Count -gt 0) {'PASS'} else {'WARNING'}) -Details ("Role assignment records returned: {0}" -f $roleAssignments.Count) -Evidence $roleAssignments)
            }
            catch { Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Role assignments' -Status 'WARNING' -Details $_.Exception.Message) }
        }
        else { Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Role assignments' -Status 'NOT APPLICABLE' -Details 'Get-OdmRoleAssignments is unavailable.') }

        if (Test-QOdmCommand -Name 'Get-OdmRoles') {
            try {
                $roleDefinitions = ConvertTo-QOdmObjectArray -InputObject (Get-OdmRoles -ErrorAction Stop)
                Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Role definitions' -Status $(if ($roleDefinitions.Count -gt 0) {'PASS'} else {'WARNING'}) -Details ("Role definition records returned: {0}" -f $roleDefinitions.Count) -Evidence $roleDefinitions)
            }
            catch { Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Role definitions' -Status 'WARNING' -Details $_.Exception.Message) }
        }
        else { Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Role definitions' -Status 'NOT APPLICABLE' -Details 'Get-OdmRoles is unavailable.') }

        $effectiveSubscription = $null
        if (Test-QOdmCommand -Name 'Get-EffectiveMigrationSubscription') {
            try {
                $effectiveSubscription = Get-EffectiveMigrationSubscription -ErrorAction Stop
                $subscriptionCount = (ConvertTo-QOdmObjectArray -InputObject $effectiveSubscription).Count
                Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Effective migration subscription' -Status $(if ($subscriptionCount -gt 0) {'PASS'} else {'WARNING'}) -Details ("Effective subscription records returned: {0}" -f $subscriptionCount) -Evidence $effectiveSubscription)
            }
            catch { Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Effective migration subscription' -Status 'WARNING' -Details $_.Exception.Message) }
        }
        else { Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Effective migration subscription' -Status 'NOT APPLICABLE' -Details 'Get-EffectiveMigrationSubscription is unavailable.') }

        if (Test-QOdmCommand -Name 'Test-ActiveMigrationSubscription') {
            try {
                $activeSubscription = [bool](Test-ActiveMigrationSubscription -ErrorAction Stop)
                Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Active migration subscription' -Status $(if ($activeSubscription) {'PASS'} else {'FAIL'}) -Details $(if ($activeSubscription) {'An active migration subscription was found.'} else {'No active migration subscription was reported.'}) -BlocksFeatures $(if ($activeSubscription) {@()} else {@('TaskFactory','AccountDiscovery','TaskLifecycle')}) -Evidence $effectiveSubscription)
            }
            catch { Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Active migration subscription' -Status 'WARNING' -Details $_.Exception.Message) }
        }
        else { Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name 'Active migration subscription' -Status 'NOT APPLICABLE' -Details 'Test-ActiveMigrationSubscription is unavailable.') }
    }
    else {
        foreach ($name in @('Role assignments','Role definitions','Effective migration subscription','Active migration subscription')) {
            Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest access' -Name $name -Status 'NOT APPLICABLE' -Details 'Connect and select an organization to run this check.')
        }
    }

    if ($connected -and $workloadSelected) {
        foreach ($readTest in @(
            [pscustomobject]@{Name='Task inventory';Feature='TaskLifecycle';Script={ ConvertTo-QOdmObjectArray -InputObject (Get-QOdmTasksView -Refresh $true) }},
            [pscustomobject]@{Name='Collection inventory';Feature='Membership';Script={ ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCollectionsView -Refresh $true) }},
            [pscustomobject]@{Name='Object inventory';Feature='Membership';Script={ $objectView = Get-QOdmObjectsView -Refresh $true -MaxResults 1; ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $objectView -Names @('Items') -Default @()) }},
            [pscustomobject]@{Name='Template inventory';Feature='TaskFactory';Script={ ConvertTo-QOdmObjectArray -InputObject (Get-QOdmTemplatesView -Refresh $true) }}
        )) {
            try {
                $items = & $readTest.Script
                Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest read tests' -Name $readTest.Name -Status 'PASS' -Details ("Read completed. Records returned: {0}" -f (Get-QOdmSafeCount -Value $items)))
            }
            catch {
                $status = if ($readTest.Name -eq 'Template inventory') { 'WARNING' } else { 'FAIL' }
                $blocks = if ($status -eq 'FAIL') { @([string]$readTest.Feature) } else { @() }
                Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest read tests' -Name $readTest.Name -Status $status -Details $_.Exception.Message -BlocksFeatures $blocks)
            }
        }
    }
    else {
        foreach ($name in @('Task inventory','Collection inventory','Object inventory','Template inventory')) {
            Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Quest read tests' -Name $name -Status 'NOT APPLICABLE' -Details 'Open a workload to run this read test.')
        }
    }

    $safeMode = Get-QOdmSafeModeState
    Add-QOdmReadinessCheckRecord -List $checks -Record (New-QOdmReadinessCheckRecord -Category 'Safety' -Name 'Safe Mode' -Status $(if ([bool]$safeMode.Enabled) {'PASS'} else {'WARNING'}) -Details $(if ([bool]$safeMode.Enabled) {'Read-only Safe Mode is enabled.'} else {'Changes are enabled for the active context.'}))

    $checkArray = $checks.ToArray()
    $passCount = (ConvertTo-QOdmObjectArray -InputObject ($checkArray | Where-Object { $_.Status -eq 'PASS' })).Count
    $warningCount = (ConvertTo-QOdmObjectArray -InputObject ($checkArray | Where-Object { $_.Status -eq 'WARNING' })).Count
    $failCount = (ConvertTo-QOdmObjectArray -InputObject ($checkArray | Where-Object { $_.Status -eq 'FAIL' })).Count
    $naCount = (ConvertTo-QOdmObjectArray -InputObject ($checkArray | Where-Object { $_.Status -eq 'NOT APPLICABLE' })).Count
    $blocked = [System.Collections.Generic.List[string]]::new()
    foreach ($failedCheck in (ConvertTo-QOdmObjectArray -InputObject ($checkArray | Where-Object { $_.Status -eq 'FAIL' }))) {
        foreach ($feature in (ConvertTo-QOdmObjectArray -InputObject $failedCheck.BlocksFeatures)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$feature) -and -not $blocked.Contains([string]$feature)) { $blocked.Add([string]$feature) | Out-Null }
        }
    }
    $overall = if ($failCount -gt 0) { 'FAIL' } elseif ($warningCount -gt 0) { 'WARNING' } else { 'PASS' }
    $contextDisplay = '{0} / {1} / {2}' -f $script:QOdmState.OrganizationName,$script:QOdmState.ProjectName,$script:QOdmState.WorkloadName
    $result = [pscustomobject]@{
        ConsoleVersion=(Get-QOdmConsoleVersion); StartedAt=$script:QOdmState.CurrentOperationStartedAt; CompletedAt=Get-Date
        ContextDisplay=$contextDisplay; Context=(Get-QOdmContextState); Compatibility=$compatibility; Checks=$checkArray
        Summary=[pscustomobject]@{OverallStatus=$overall;Pass=$passCount;Warning=$warningCount;Fail=$failCount;NotApplicable=$naCount;BlockedFeatures=$blocked.ToArray()}
        Reports=@()
    }
    $exports = Export-QOdmReadinessResult -Result $result -OutputDirectory $OutputDirectory
    $result.Reports = ConvertTo-QOdmObjectArray -InputObject $exports.Reports
    Add-Member -InputObject $result -NotePropertyName JsonPath -NotePropertyValue $exports.JsonPath -Force
    Add-Member -InputObject $result -NotePropertyName HtmlPath -NotePropertyValue $exports.HtmlPath -Force
    $script:QOdmState.LastReadinessResult = $result
    $script:QOdmState.ReadinessCompletedAt = $result.CompletedAt
    $script:QOdmState.BlockedFeatures = $blocked.ToArray()
    return $result
}

function Get-QOdmOperationHistoryPath {
    [CmdletBinding()]
    param()

    $directory = Get-QOdmDefaultLogDirectory
    if (-not (Test-QOdmDirectoryWritable -Path $directory -Create $true)) { throw "The operation-history directory is not writable: $directory" }
    return (Join-Path $directory 'OperationHistory.jsonl')
}

function Get-QOdmFileSha256 {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        if (Get-Command -Name 'Get-FileHash' -ErrorAction SilentlyContinue) {
            return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
            finally { $sha.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }
}

function ConvertTo-QOdmSanitizedValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [int]$Depth = 0
    )

    if ($Depth -gt 6) { return '<depth-limit>' }
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($keyObject in (ConvertTo-QOdmObjectArray -InputObject $Value.Keys)) {
            $key = [string]$keyObject
            if ($key -match '(?i)(token|secret|password|credential|cookie|authorization|accesskey|apikey)') { $copy[$key] = '<redacted>' }
            else { $copy[$key] = ConvertTo-QOdmSanitizedValue -Value $Value[$keyObject] -Depth ($Depth + 1) }
        }
        return [pscustomobject]$copy
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in (ConvertTo-QOdmObjectArray -InputObject $Value)) { $items.Add((ConvertTo-QOdmSanitizedValue -Value $item -Depth ($Depth + 1))) | Out-Null }
        return $items.ToArray()
    }
    $objectCopy = [ordered]@{}
    foreach ($property in (ConvertTo-QOdmObjectArray -InputObject $Value.PSObject.Properties)) {
        $name = [string]$property.Name
        if ($name -match '(?i)(token|secret|password|credential|cookie|authorization|accesskey|apikey)') { $objectCopy[$name] = '<redacted>' }
        elseif ($name -notmatch '^(Methods|Method|ScriptStackTrace|ExceptionText)$') { $objectCopy[$name] = ConvertTo-QOdmSanitizedValue -Value $property.Value -Depth ($Depth + 1) }
    }
    return [pscustomobject]$objectCopy
}

function Get-QOdmParameterFileMetadata {
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$Parameters)

    $files = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Parameters) { return $files.ToArray() }
    foreach ($keyObject in (ConvertTo-QOdmObjectArray -InputObject $Parameters.Keys)) {
        $key = [string]$keyObject
        $value = $Parameters[$keyObject]
        if ($key -match '(?i)(csvpath|filepath|inputfile)$' -and $value -is [string] -and (Test-Path -LiteralPath $value -PathType Leaf)) {
            $item = Get-Item -LiteralPath $value -ErrorAction SilentlyContinue
            $files.Add([pscustomobject]@{Parameter=$key;FileName=[IO.Path]::GetFileName($value);Length=if($null -ne $item){$item.Length}else{$null};Sha256=Get-QOdmFileSha256 -Path $value}) | Out-Null
        }
        elseif ($value -is [System.Collections.IDictionary]) {
            foreach ($nested in (Get-QOdmParameterFileMetadata -Parameters $value)) { $files.Add($nested) | Out-Null }
        }
    }
    return $files.ToArray()
}

function Get-QOdmOperationCounts {
    [CmdletBinding()]
    param([AllowNull()][object]$Data, [AllowNull()][System.Collections.IDictionary]$Parameters)

    $rows = ConvertTo-QOdmObjectArray -InputObject $Data
    $requested = 0
    foreach ($candidate in @('TaskIds','CollectionIds','ObjectIds','Rows','Users')) {
        $value = Get-QOdmProperty -InputObject $Parameters -Names @($candidate)
        $count = Get-QOdmSafeCount -Value $value
        if ($count -gt $requested) { $requested = $count }
    }
    if ($requested -eq 0 -and $rows.Count -gt 0) { $requested = $rows.Count }
    $succeeded = 0
    $failed = 0
    foreach ($row in $rows) {
        $successValue = Get-QOdmProperty -InputObject $row -Names @('Success','Succeeded','Deleted','StartSucceeded','StopSucceeded','Verified','ExecuteSucceeded','Changed')
        $status = [string](Get-QOdmProperty -InputObject $row -Names @('Status','VerificationState','Result'))
        if ($successValue -eq $true -or $status -match '^(SUCCESS|SUCCEEDED|DELETED|VERIFIED|VERIFIED_ADDED|VERIFIED_REMOVED|START_SUBMITTED|STOP_SUBMITTED|CREATED|INSTALLED_OR_UPDATED)$') { $succeeded++ }
        elseif ($successValue -eq $false -or $status -match '(FAIL|ERROR|NOT_FOUND|AMBIGUOUS|INVALID)') { $failed++ }
    }
    if ($rows.Count -gt 0 -and $succeeded -eq 0 -and $failed -eq 0) { $succeeded = $rows.Count }
    return [pscustomobject]@{Requested=$requested;Succeeded=$succeeded;Failed=$failed}
}

function Write-QOdmOperationHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [AllowNull()][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][DateTime]$StartedAt,
        [Parameter(Mandatory = $true)][DateTime]$EndedAt
    )

    try {
        $counts = Get-QOdmOperationCounts -Data (Get-QOdmProperty -InputObject $Result -Names @('Data')) -Parameters $Parameters
        $reports = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $Result -Names @('Reports') -Default @())
        $preview = $null
        $execute = Get-QOdmProperty -InputObject $Parameters -Names @('Execute')
        if ($null -eq $execute) {
            $nested = Get-QOdmProperty -InputObject $Parameters -Names @('Parameters')
            $execute = Get-QOdmProperty -InputObject $nested -Names @('Execute')
        }
        if ($null -ne $execute) { $preview = -not [bool]$execute }
        $record = [ordered]@{
            Timestamp=$EndedAt.ToString('o')
            StartedAt=$StartedAt.ToString('o')
            DurationSeconds=[Math]::Round(($EndedAt - $StartedAt).TotalSeconds,3)
            WindowsUser=[Environment]::UserName
            ComputerName=$env:COMPUTERNAME
            ConsoleVersion=Get-QOdmConsoleVersion
            OdmApiVersion=[string]$script:QOdmState.ModuleVersion
            OrganizationId=$script:QOdmState.OrganizationId
            OrganizationName=$script:QOdmState.OrganizationName
            ProjectId=$script:QOdmState.ProjectId
            ProjectName=$script:QOdmState.ProjectName
            WorkloadId=$script:QOdmState.WorkloadId
            WorkloadName=$script:QOdmState.WorkloadName
            Operation=$Operation
            Preview=$preview
            SafeMode=[bool]$script:QOdmState.SafeMode
            InputFiles=Get-QOdmParameterFileMetadata -Parameters $Parameters
            RequestedCount=$counts.Requested
            SucceededCount=$counts.Succeeded
            FailedCount=$counts.Failed
            VerificationStatus=Get-QOdmProperty -InputObject (Get-QOdmProperty -InputObject $Result -Names @('Data')) -Names @('VerificationState','VerificationStatus')
            Reports=$reports
            Success=[bool](Get-QOdmProperty -InputObject $Result -Names @('Success') -Default $false)
            ResultMessage=[string](Get-QOdmProperty -InputObject $Result -Names @('Message'))
            Error=[string](Get-QOdmProperty -InputObject $Result -Names @('Error'))
            DiagnosticId=[string](Get-QOdmProperty -InputObject $Result -Names @('DiagnosticId'))
            Parameters=ConvertTo-QOdmSanitizedValue -Value $Parameters
        }
        $json = ([pscustomobject]$record | ConvertTo-Json -Depth 10 -Compress)
        Add-Content -LiteralPath (Get-QOdmOperationHistoryPath) -Value $json -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Add-QOdmWarning -Message ("Operation history could not be written: {0}" -f $_.Exception.Message)
    }
}

function Get-QOdmOperationHistory {
    [CmdletBinding()]
    param([int]$Last = 250)

    if ($Last -lt 1) { $Last = 1 }
    if ($Last -gt 5000) { $Last = 5000 }
    $path = Get-QOdmOperationHistoryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $lines = ConvertTo-QOdmObjectArray -InputObject (Get-Content -LiteralPath $path -Tail $Last -ErrorAction Stop)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        try { $records.Add(([string]$line | ConvertFrom-Json -ErrorAction Stop)) | Out-Null }
        catch { $records.Add([pscustomobject]@{Timestamp=$null;Operation='PARSE_ERROR';Success=$false;Error=$_.Exception.Message;RawLine=[string]$line}) | Out-Null }
    }
    return $records.ToArray()
}

function ConvertTo-QOdmTaskEventView {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Event)

    [pscustomobject]@{
        Timestamp=Get-QOdmProperty -InputObject $Event -Names @('Timestamp','Date','Created','CreatedAt','Time')
        Severity=ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Event -Names @('Severity','Level'))
        Category=ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Event -Names @('Category','EventCategory','Type'))
        Message=[string](Get-QOdmProperty -InputObject $Event -Names @('Message','Description','Details','Text'))
        ObjectId=[string](Get-QOdmProperty -InputObject $Event -Names @('ObjectId','EntityId'))
        Acknowledged=Get-QOdmProperty -InputObject $Event -Names @('Acknowledged','IsAcknowledged')
    }
}

function Get-QOdmTaskDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [bool]$IncludeEvents = $true,
        [bool]$IncludeReporting = $true
    )

    Assert-QOdmWorkloadSelected
    Set-QOdmOperationPhase -Phase 'Loading task details'
    $task = Resolve-QOdmTask -TaskId $TaskId
    if ($null -eq $task) { throw "Task not found: $TaskId" }
    $events = @()
    $eventError = $null
    if ($IncludeEvents -and (Test-QOdmCommand -Name 'Get-OdmEvent')) {
        try { $events = ConvertTo-QOdmObjectArray -InputObject ($task | Get-OdmEvent -CurrentOnly -ErrorAction Stop) }
        catch { $eventError = $_.Exception.Message; Add-QOdmWarning -Message ("Task events could not be loaded: {0}" -f $eventError) }
    }
    $eventViews = ConvertTo-QOdmObjectArray -InputObject ($events | ForEach-Object { ConvertTo-QOdmTaskEventView -Event $_ } | Sort-Object Timestamp -Descending)

    $reporting = @()
    $reportingError = $null
    if ($IncludeReporting -and (Test-QOdmCommand -Name 'Get-OdmReporting')) {
        try {
            $parameters = @{}
            if (-not [string]::IsNullOrWhiteSpace([string]$script:QOdmState.ProjectId)) { $parameters.ProjectId = [string]$script:QOdmState.ProjectId }
            $parameters.All = $true
            $allReporting = Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmReporting' -Parameters $parameters -OptionalParameters @('ProjectId','All')
            $taskName = Get-QOdmName $task
            $reporting = ConvertTo-QOdmObjectArray -InputObject ($allReporting | Where-Object {
                $reportedTaskId = [string](Get-QOdmProperty -InputObject $_ -Names @('TaskId','TaskID','MigrationTaskId'))
                $reportedTaskName = [string](Get-QOdmProperty -InputObject $_ -Names @('TaskName','MigrationTaskName'))
                ([string]::Equals($reportedTaskId,$TaskId,[StringComparison]::OrdinalIgnoreCase)) -or
                (-not [string]::IsNullOrWhiteSpace($reportedTaskName) -and [string]::Equals($reportedTaskName,$taskName,[StringComparison]::OrdinalIgnoreCase))
            })
        }
        catch { $reportingError = $_.Exception.Message; Add-QOdmWarning -Message ("Task reporting could not be loaded: {0}" -f $reportingError) }
    }

    $status = Get-QOdmTaskStatus -Task $task
    $created = Get-QOdmProperty -InputObject $task -Names @('Created','CreatedAt','CreationDate')
    $started = Get-QOdmProperty -InputObject $task -Names @('Started','StartedAt','StartTime','StartDate')
    $completed = Get-QOdmProperty -InputObject $task -Names @('Completed','CompletedAt','CompletionTime','FinishTime','FinishedAt')
    $duration = Get-QOdmProperty -InputObject $task -Names @('Duration','Elapsed','ElapsedTime')
    if ($null -eq $duration -and $null -ne $started) {
        try {
            $startDate = [DateTime]$started
            $endDate = if ($null -ne $completed) { [DateTime]$completed } else { Get-Date }
            $duration = $endDate - $startDate
        }
        catch { }
    }
    $total = Get-QOdmProperty -InputObject $task -Names @('ObjectCount','ObjectsCount','TotalObjects','Total') -Default $reporting.Count
    $processed = 0; $succeeded = 0; $failed = 0
    foreach ($row in $reporting) {
        $state = [string](Get-QOdmProperty -InputObject $row -Names @('ObjectState','State','Status','MigrationStatus'))
        if ($state -match '(?i)(success|complete|migrated|processed)') { $succeeded++; $processed++ }
        elseif ($state -match '(?i)(fail|error)') { $failed++; $processed++ }
        elseif ($state -notmatch '(?i)(queued|pending|new|not started)') { $processed++ }
    }
    if ($succeeded -eq 0) { $succeeded = [int](Get-QOdmProperty -InputObject $task -Names @('SucceededCount','SuccessCount','CompletedCount') -Default 0) }
    if ($failed -eq 0) { $failed = [int](Get-QOdmProperty -InputObject $task -Names @('FailedCount','ErrorCount') -Default 0) }
    if ($processed -eq 0) { $processed = [int](Get-QOdmProperty -InputObject $task -Names @('ProcessedCount','CompletedCount') -Default ($succeeded + $failed)) }
    $lastEvent = $eventViews | Select-Object -First 1
    $lastError = $eventViews | Where-Object { ([string]$_.Severity -match '(?i)(error|critical|fatal)') -or ([string]$_.Message -match '(?i)(error|fail)') } | Select-Object -First 1

    [pscustomobject]@{
        Task=[pscustomobject]@{
            Name=Get-QOdmName $task; Id=Get-QOdmId $task; Type=ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $task -Names @('Type','TaskType'))
            Status=$status; Created=$created; Started=$started; Completed=$completed; Duration=ConvertTo-QOdmDisplayString $duration
            Collection=ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $task -Names @('Collections','Collection','CollectionNames'))
            MemberCount=$total; ProcessedCount=$processed; SucceededCount=$succeeded; FailedCount=$failed
            LastEvent=if($null -ne $lastEvent){$lastEvent.Message}else{$null}; LastError=if($null -ne $lastError){$lastError.Message}else{$null}
        }
        Events=$eventViews; Reporting=$reporting; RawTask=$task; EventError=$eventError; ReportingError=$reportingError
        LoadedAt=Get-Date; AutoRefreshSupported=$true
    }
}

function Export-QOdmTaskDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [AllowNull()][string]$OutputDirectory
    )

    $details = Get-QOdmTaskDetails -TaskId $TaskId -IncludeEvents $true -IncludeReporting $true
    $directory = Get-QOdmOutputDirectory -OutputDirectory $OutputDirectory
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = ([string]$details.Task.Name -replace '[^A-Za-z0-9_.-]','_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'Task' }
    $jsonPath = Join-Path $directory ("TaskDetails_{0}_{1}.json" -f $safeName,$stamp)
    $eventPath = Join-Path $directory ("TaskEvents_{0}_{1}.csv" -f $safeName,$stamp)
    $details | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Export-QOdmCsv -Rows $details.Events -Path $eventPath | Out-Null
    return [pscustomobject]@{ Details=$details; JsonPath=$jsonPath; EventCsvPath=$eventPath; Reports=@($jsonPath,$eventPath) }
}

function New-QOdmTaskErrorLogExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [AllowNull()][string]$Name
    )

    Assert-QOdmWorkloadSelected
    if (-not (Test-QOdmCommand -Name 'New-OdmReportingErrorLogsExportTask')) { throw 'New-OdmReportingErrorLogsExportTask is not available in the installed OdmApi module.' }
    $task = Resolve-QOdmTask -TaskId $TaskId
    if ($null -eq $task) { throw "Task not found: $TaskId" }
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'Error logs - {0} - {1}' -f (Get-QOdmName $task),(Get-Date -Format 'yyyyMMdd-HHmmss') }
    $available = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCommandParameterNames -CommandName 'New-OdmReportingErrorLogsExportTask')
    $parameters = @{Name=$Name}
    $required = @()
    $optional = @('Name','TaskId','TaskIds','FilterObject','Task','ProjectId','PassThru')
    if ($available -contains 'Name') { $required += 'Name' }
    if ($available -contains 'TaskId') { $parameters.TaskId = $TaskId; $required += 'TaskId' }
    elseif ($available -contains 'TaskIds') { $parameters.TaskIds = @($TaskId); $required += 'TaskIds' }
    elseif ($available -contains 'FilterObject') { $parameters.FilterObject = $task; $required += 'FilterObject' }
    elseif ($available -contains 'Task') { $parameters.Task = $task; $required += 'Task' }
    else { throw 'The installed error-log export constructor does not expose a task-specific selector. The operation was stopped to avoid exporting an unintended scope.' }
    if ($available -contains 'ProjectId' -and -not [string]::IsNullOrWhiteSpace([string]$script:QOdmState.ProjectId)) { $parameters.ProjectId = [string]$script:QOdmState.ProjectId }
    if ($available -contains 'PassThru') { $parameters.PassThru = $true }
    $existingIds = @{}; foreach ($id in (ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Tasks.Keys)) { $existingIds[[string]$id] = $true }
    $returned = Invoke-QOdmSupportedCommandArray -CommandName 'New-OdmReportingErrorLogsExportTask' -Parameters $parameters -RequiredParameters $required -OptionalParameters $optional
    $created = $null
    try { $created = Resolve-QOdmCreatedEntityAfterWrite -EntityType Task -Name $Name -ExistingIds $existingIds -ReturnedObjects $returned }
    catch {
        if ($returned.Count -eq 1) { $created = $returned[0] } else { throw }
    }
    return [pscustomobject]@{CreatedTask=if($null -ne $created){ConvertTo-QOdmTaskView $created}else{$null};RawTask=$created;SourceTaskId=$TaskId;Name=$Name}
}

function Protect-QOdmSupportText {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    $sanitized = [string]$Text
    $patterns = @(
        [pscustomobject]@{ Pattern='(?im)(Authorization\s*[:=]\s*Bearer\s+)[^\s\"'']+'; Replacement='$1<redacted>' },
        [pscustomobject]@{ Pattern='(?im)((?:access_token|refresh_token|id_token|client_secret|password|passwd|secret|cookie|set-cookie|api[_-]?key)\s*[=:]\s*)[^\r\n,;]+'; Replacement='$1<redacted>' },
        [pscustomobject]@{ Pattern='(?i)eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}'; Replacement='<redacted-jwt>' }
    )
    foreach ($entry in $patterns) {
        try { $sanitized = [regex]::Replace($sanitized,[string]$entry.Pattern,[string]$entry.Replacement) }
        catch { }
    }
    return $sanitized
}

function New-QOdmSupportBundle {
    [CmdletBinding()]
    param([AllowNull()][string]$OutputDirectory)

    Set-QOdmOperationPhase -Phase 'Creating sanitized support bundle'
    $directory = Get-QOdmOutputDirectory -OutputDirectory $OutputDirectory
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bundlePath = Join-Path $directory "QuestODMConsole_SupportBundle_$stamp.zip"
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("QuestODMConsole-Support-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -Path $tempRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
    try {
        $buildInfo = Get-QOdmBuildInfo
        $compatibility = Get-QOdmCompatibilityAssessment -ModuleStatus (Get-QOdmApiModuleStatus -CheckOnline $false)
        $environment = Get-QOdmEnvironmentInfo
        $state = Get-QOdmContextState
        $surface = Get-QOdmApiSurfaceReport
        $payloads = [ordered]@{
            'BuildInfo.json'=$buildInfo
            'Compatibility.json'=$compatibility
            'Environment.json'=(ConvertTo-QOdmSanitizedValue -Value $environment)
            'Context.json'=(ConvertTo-QOdmSanitizedValue -Value $state)
            'ApiSurface.json'=(ConvertTo-QOdmSanitizedValue -Value $surface)
            'SafeMode.json'=(Get-QOdmSafeModeState)
            'LastReadiness.json'=(ConvertTo-QOdmSanitizedValue -Value $script:QOdmState.LastReadinessResult)
        }
        foreach ($fileName in $payloads.Keys) {
            $payloads[$fileName] | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $tempRoot $fileName) -Encoding UTF8
        }

        $settingsPath = Join-Path (Join-Path (Get-QOdmDefaultDataRoot) 'Config') 'QuestODMConsole.settings.json'
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            try {
                $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
                ConvertTo-QOdmSanitizedValue -Value $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $tempRoot 'Settings.redacted.json') -Encoding UTF8
            }
            catch { "Settings could not be parsed: $($_.Exception.Message)" | Set-Content -LiteralPath (Join-Path $tempRoot 'Settings.error.txt') -Encoding UTF8 }
        }

        $logsOut = Join-Path $tempRoot 'Logs'; New-Item -Path $logsOut -ItemType Directory -Force | Out-Null
        $logDirectory = Get-QOdmDefaultLogDirectory
        if (Test-Path -LiteralPath $logDirectory -PathType Container) {
            foreach ($logFile in (ConvertTo-QOdmObjectArray -InputObject (Get-ChildItem -LiteralPath $logDirectory -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 12))) {
                if ([string]$logFile.Name -match '(?i)(token|credential|cookie)') { continue }
                try {
                    $rawLog = Get-Content -LiteralPath $logFile.FullName -Raw -ErrorAction Stop
                    Protect-QOdmSupportText -Text $rawLog | Set-Content -LiteralPath (Join-Path $logsOut $logFile.Name) -Encoding UTF8 -ErrorAction Stop
                }
                catch {
                    ("Log could not be sanitized: {0}" -f $_.Exception.Message) | Set-Content -LiteralPath (Join-Path $logsOut ($logFile.BaseName + '.error.txt')) -Encoding UTF8
                }
            }
        }

        $validationOut = Join-Path $tempRoot 'Validation'; New-Item -Path $validationOut -ItemType Directory -Force | Out-Null
        foreach ($validationName in @('BUILD_VALIDATION.txt','V1_RELEASE_VALIDATION.json','Tests\NATIVE_PARSER_BUILD_VALIDATION.txt')) {
            $source = Join-Path (Get-QOdmApplicationRoot) $validationName
            if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination $validationOut -Force }
        }
        $reportDirectory = Get-QOdmDefaultReportDirectory
        $reportList = @()
        if (Test-Path -LiteralPath $reportDirectory -PathType Container) {
            $reportList = Get-ChildItem -LiteralPath $reportDirectory -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 100 Name,Length,LastWriteTime
        }
        $reportList | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $tempRoot 'RecentReports.json') -Encoding UTF8
        @"
Quest ODM Operations Console support bundle
Created: $(Get-Date -Format o)
Console version: $(Get-QOdmConsoleVersion)
This bundle is sanitized and intentionally excludes access tokens, credentials, cookies, authorization headers, and raw authentication artifacts.
"@ | Set-Content -LiteralPath (Join-Path $tempRoot 'README.txt') -Encoding UTF8

        if (Test-Path -LiteralPath $bundlePath) { Remove-Item -LiteralPath $bundlePath -Force }
        if (Get-Command -Name 'Compress-Archive' -ErrorAction SilentlyContinue) {
            Compress-Archive -Path (Join-Path $tempRoot '*') -DestinationPath $bundlePath -CompressionLevel Optimal -Force -ErrorAction Stop
        }
        else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::CreateFromDirectory($tempRoot,$bundlePath,[System.IO.Compression.CompressionLevel]::Optimal,$false)
        }
        if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) { throw 'The support-bundle archive was not created.' }
        return [pscustomobject]@{BundlePath=$bundlePath;Sha256=Get-QOdmFileSha256 -Path $bundlePath;Reports=@($bundlePath);Sanitized=$true}
    }
    finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } }
}
