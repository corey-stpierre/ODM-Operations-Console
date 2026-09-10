[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $testsRoot
$mockRoot = Join-Path $testsRoot 'Mocks'
$mockManifest = Join-Path $mockRoot 'OdmApi\2.1.396\OdmApi.psd1'
$enginePath = Join-Path $appRoot 'Engine\QuestODMConsole.Engine.psm1'
$oldModulePath = $env:PSModulePath
$oldDataRoot = $env:QUESTODMCONSOLE_DATA_ROOT
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('QuestODMConsole-V1Governance-' + [Guid]::NewGuid().ToString('N'))
$env:PSModulePath = "$mockRoot$([IO.Path]::PathSeparator)$oldModulePath"
$env:QUESTODMCONSOLE_DATA_ROOT = Join-Path $tempRoot 'Data'

function ConvertTo-TestArray {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    $result = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $InputObject) { return ,$result.ToArray() }
    $value = $InputObject
    try {
        if ($InputObject -is [System.Management.Automation.PSObject] -and $null -ne $InputObject.BaseObject) {
            $value = $InputObject.BaseObject
        }
    }
    catch { $value = $InputObject }
    if ($value -is [string] -or $value -is [System.Collections.IDictionary]) {
        $result.Add($InputObject) | Out-Null
        return ,$result.ToArray()
    }
    if ($value -is [System.Collections.IEnumerable]) {
        foreach ($item in $value) { $result.Add($item) | Out-Null }
        return ,$result.ToArray()
    }
    $result.Add($InputObject) | Out-Null
    return ,$result.ToArray()
}

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-TestOperation {
    param([string]$Operation,[hashtable]$Parameters=@{})
    $result = Invoke-QOdmOperation -Operation $Operation -Parameters $Parameters
    if (-not [bool]$result.Success) {
        throw "Operation '$Operation' failed: $($result.Error)`r`n$($result.Details)"
    }
    return $result
}

function Enable-TestChanges {
    $result = Invoke-TestOperation -Operation SetSafeMode -Parameters @{
        Enabled=$false
        OrganizationId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        ProjectId='project-001'
        WorkloadId='workload-accounts'
        ConfirmationText='ENABLE CHANGES'
    }
    Assert-True (-not [bool]$result.Data.Enabled) 'Safe Mode must be disabled after the exact context confirmation.'
}

try {
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    Remove-Module QuestODMConsole.Engine -Force -ErrorAction SilentlyContinue
    Remove-Module OdmApi -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name QuestODMConsoleOdmApiPreload -Scope Global -ErrorAction SilentlyContinue

    $module = Import-Module -Name $mockManifest -Global -PassThru -ErrorAction Stop | Where-Object { $_.Name -eq 'OdmApi' } | Select-Object -First 1
    if ($null -eq $module) { throw 'The mock OdmApi module was not imported.' }
    $global:QuestODMConsoleOdmApiPreload = [pscustomobject]@{
        Status='LOADED'; Installed=$true; Loaded=$true; Version=[string]$module.Version; Path=[string]$module.Path
        ManifestPath=$mockManifest; CommandOwner='OdmApi'; Details='V1 governance test preload.'; Error=$null; PreloadedAt=Get-Date
    }
    Import-Module -Name $enginePath -Force -ErrorAction Stop

    # Compatibility policy and module surface.
    $compatibility = Invoke-TestOperation -Operation GetCompatibilityAssessment -Parameters @{CheckOnline=$false}
    Assert-True ([string]$compatibility.Data.CompatibilityStatus -eq 'VALIDATED') 'Mock OdmApi 2.1.396 must be recognized as validated.'
    Assert-True (-not [bool]$compatibility.Data.Blocking) 'Validated mock module must not be globally blocking.'
    Assert-True ([string]$compatibility.Data.MinimumVersion -eq '2.1.396') 'V1 minimum OdmApi version must be 2.1.396.'
    $features = ConvertTo-TestArray -InputObject $compatibility.Data.FeatureAssessments
    Assert-True ((ConvertTo-TestArray -InputObject ($features | Where-Object { -not $_.Available })).Count -eq 0) 'The mock must expose all V1 feature command groups.'

    # Connect and establish the Accounts context.
    $connect = Invoke-TestOperation -Operation Connect -Parameters @{Region='US'}
    Assert-True ((ConvertTo-TestArray -InputObject $connect.Data.Organizations).Count -eq 2) 'Connect must return the two mock organizations.'
    $null = Invoke-TestOperation -Operation SelectOrganization -Parameters @{OrganizationId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';OrganizationName='Mock Primary Organization'}
    $null = Invoke-TestOperation -Operation SelectProject -Parameters @{ProjectId='project-001'}
    $null = Invoke-TestOperation -Operation SelectWorkload -Parameters @{WorkloadId='workload-accounts'}

    # Safe Mode is mandatory on startup/context changes and blocks writes.
    $safe = Invoke-TestOperation -Operation GetSafeModeState
    Assert-True ([bool]$safe.Data.Enabled) 'Safe Mode must be enabled after opening a workload.'
    $blockedWrite = Invoke-QOdmOperation -Operation NewCollection -Parameters @{Name='Blocked by Safe Mode'}
    Assert-True (-not [bool]$blockedWrite.Success -and [string]$blockedWrite.Error -match 'Safe Mode') 'Safe Mode must block collection creation.'
    $badConfirmation = Invoke-QOdmOperation -Operation SetSafeMode -Parameters @{
        Enabled=$false;OrganizationId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';ProjectId='project-001';WorkloadId='workload-accounts';ConfirmationText='enable changes'
    }
    Assert-True (-not [bool]$badConfirmation.Success) 'Safe Mode confirmation must be case-sensitive and exact.'
    $wrongContext = Invoke-QOdmOperation -Operation SetSafeMode -Parameters @{
        Enabled=$false;OrganizationId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';ProjectId='project-001';WorkloadId='wrong';ConfirmationText='ENABLE CHANGES'
    }
    Assert-True (-not [bool]$wrongContext.Success) 'Safe Mode must reject a mismatched workload confirmation.'

    # Readiness check while Safe Mode is enabled.
    $readiness = Invoke-TestOperation -Operation RunReadinessCheck -Parameters @{CheckOnlineModuleVersion=$false;OutputDirectory=(Join-Path $tempRoot 'Reports')}
    Assert-True ([string]$readiness.Data.Summary.OverallStatus -eq 'PASS') 'Mock V1 readiness must pass on the supported Windows acceptance host.'
    Assert-True ((ConvertTo-TestArray -InputObject $readiness.Data.Summary.BlockedFeatures).Count -eq 0) 'Passing readiness must not block any features.'
    Assert-True (Test-Path -LiteralPath $readiness.Data.JsonPath -PathType Leaf) 'Readiness JSON report must be created.'
    Assert-True (Test-Path -LiteralPath $readiness.Data.HtmlPath -PathType Leaf) 'Readiness HTML report must be created.'
    $checks = ConvertTo-TestArray -InputObject $readiness.Data.Checks
    foreach ($requiredCheck in @('Role assignments','Role definitions','Effective migration subscription','Active migration subscription','Task inventory','Collection inventory','Object inventory','Template inventory')) {
        Assert-True ((ConvertTo-TestArray -InputObject ($checks | Where-Object { $_.Name -eq $requiredCheck })).Count -eq 1) "Readiness must include '$requiredCheck'."
    }

    Enable-TestChanges
    $created = Invoke-TestOperation -Operation NewCollection -Parameters @{Name='V1 Governance Collection'}
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$created.Data.Id)) 'A write must succeed after changes are explicitly enabled.'

    # Task monitoring, export, and error-log export.
    $tasks = Invoke-TestOperation -Operation GetTasks -Parameters @{Refresh=$true}
    $task = ConvertTo-TestArray -InputObject ($tasks.Data | Where-Object { $_.Name -eq 'Accounts Task' } | Select-Object -First 1)
    Assert-True ($task.Count -eq 1) 'The Accounts Task must be available for monitoring tests.'
    $taskDetails = Invoke-TestOperation -Operation GetTaskDetails -Parameters @{TaskId=[string]$task[0].Id;IncludeEvents=$true;IncludeReporting=$true}
    Assert-True ((ConvertTo-TestArray -InputObject $taskDetails.Data.Events).Count -ge 2) 'Task details must include mock event records.'
    Assert-True ((ConvertTo-TestArray -InputObject $taskDetails.Data.Reporting).Count -ge 2) 'Task details must include reporting records.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$taskDetails.Data.Task.LastEvent)) 'Task details must calculate a last-event summary.'
    $taskExport = Invoke-TestOperation -Operation ExportTaskDetails -Parameters @{TaskId=[string]$task[0].Id;OutputDirectory=(Join-Path $tempRoot 'Reports')}
    Assert-True (Test-Path -LiteralPath $taskExport.Data.JsonPath -PathType Leaf) 'Task detail JSON export must be created.'
    Assert-True (Test-Path -LiteralPath $taskExport.Data.EventCsvPath -PathType Leaf) 'Task event CSV export must be created.'
    $errorExport = Invoke-TestOperation -Operation CreateTaskErrorLogExport -Parameters @{TaskId=[string]$task[0].Id;Name='V1 Mock Error Export'}
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$errorExport.Data.CreatedTask.Id)) 'Task error-log export must create and resolve a Quest task.'

    # Changing context resets Safe Mode.
    $null = Invoke-TestOperation -Operation SelectWorkload -Parameters @{WorkloadId='workload-sharepoint'}
    $safeAfterChange = Invoke-TestOperation -Operation GetSafeModeState
    Assert-True ([bool]$safeAfterChange.Data.Enabled) 'Changing workloads must reset Safe Mode.'
    $null = Invoke-TestOperation -Operation SelectWorkload -Parameters @{WorkloadId='workload-accounts'}

    # Structured history must exist, hash input files, and redact sensitive parameter values.
    $csvPath = Join-Path $tempRoot 'history-input.csv'
    @([pscustomobject]@{CollectionName='History';SourceUPN='ada@source.example'}) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $null = Invoke-TestOperation -Operation TaskFactory -Parameters @{
        CsvPath=$csvPath;Mode='Direct';Execute=$false;OutputDirectory=(Join-Path $tempRoot 'Reports');TaskKinds=@('Mail')
    }
    $secret = 'V1-Plaintext-Secret-Should-Not-Appear'
    $failed = Invoke-QOdmOperation -Operation DefinitelyUnknown -Parameters @{Password=$secret;AccessToken='abc123'}
    Assert-True (-not [bool]$failed.Success) 'The intentional unknown operation must fail.'
    $history = Invoke-TestOperation -Operation GetOperationHistory -Parameters @{Last=500}
    $historyRows = ConvertTo-TestArray -InputObject $history.Data
    Assert-True ($historyRows.Count -gt 5) 'Operation history must contain the executed V1 test operations.'
    $factoryRecord = $historyRows | Where-Object { $_.Operation -eq 'TaskFactory' } | Select-Object -Last 1
    Assert-True ($null -ne $factoryRecord) 'Task Factory preview must be present in operation history.'
    Assert-True ((ConvertTo-TestArray -InputObject $factoryRecord.InputFiles).Count -eq 1) 'Operation history must capture input-file metadata.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$factoryRecord.InputFiles[0].Sha256)) 'Operation history must hash the input CSV.'
    $historyPath = Join-Path (Join-Path $env:QUESTODMCONSOLE_DATA_ROOT 'Logs') 'OperationHistory.jsonl'
    $historyText = Get-Content -LiteralPath $historyPath -Raw -ErrorAction Stop
    Assert-True ($historyText -notmatch [regex]::Escape($secret)) 'Operation history must not contain plaintext sensitive parameters.'
    Assert-True ($historyText -match '<redacted>') 'Operation history must mark redacted values.'

    # Sanitized support bundle.
    $logsPath = Join-Path $env:QUESTODMCONSOLE_DATA_ROOT 'Logs'
    New-Item -Path $logsPath -ItemType Directory -Force | Out-Null
    $fakeJwt = 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJzZWNyZXQtdGVzdC11c2VyIn0.abcdefghijklmnopqrstuv'
    $logSecret = 'SupportBundlePlaintextSecret'
    @"
Authorization: Bearer $logSecret
access_token=$logSecret
password=$logSecret
$fakeJwt
"@ | Set-Content -LiteralPath (Join-Path $logsPath 'V1-sensitive-test.log') -Encoding UTF8
    $bundle = Invoke-TestOperation -Operation CreateSupportBundle -Parameters @{OutputDirectory=(Join-Path $tempRoot 'Reports')}
    Assert-True (Test-Path -LiteralPath $bundle.Data.BundlePath -PathType Leaf) 'Support bundle ZIP must be created.'
    $extractPath = Join-Path $tempRoot 'SupportExtract'
    Expand-Archive -LiteralPath $bundle.Data.BundlePath -DestinationPath $extractPath -Force
    $bundleText = ((Get-ChildItem -LiteralPath $extractPath -Recurse -File -ErrorAction Stop | ForEach-Object {
        try { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop } catch { '' }
    }) -join "`n")
    Assert-True ($bundleText -notmatch [regex]::Escape($logSecret)) 'Support bundle must remove plaintext secrets from logs.'
    Assert-True ($bundleText -notmatch [regex]::Escape($fakeJwt)) 'Support bundle must remove JWT-like values.'
    Assert-True ($bundleText -match '<redacted') 'Support bundle must retain redaction markers.'
    foreach ($requiredBundleFile in @('BuildInfo.json','Compatibility.json','Environment.json','Context.json','ApiSurface.json','SafeMode.json','README.txt')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $extractPath $requiredBundleFile) -PathType Leaf) "Support bundle must contain $requiredBundleFile."
    }

    Write-Output 'V1 GOVERNANCE TESTS: PASS'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $env:PSModulePath = $oldModulePath
    $env:QUESTODMCONSOLE_DATA_ROOT = $oldDataRoot
    Remove-Module QuestODMConsole.Engine -Force -ErrorAction SilentlyContinue
    Remove-Module OdmApi -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name QuestODMConsoleOdmApiPreload -Scope Global -ErrorAction SilentlyContinue
}
