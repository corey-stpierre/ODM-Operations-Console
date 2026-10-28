Set-StrictMode -Version 2.0

function Initialize-QOdmState {
    [CmdletBinding()]
    param([bool]$PreserveModule = $false)

    $moduleVersion = $null
    $modulePath = $null
    $apiSurface = $null
    $moduleScopeValidated = $false
    $modulePreload = $null
    $moduleRuntimeProbe = $null
    $moduleRuntimeProbeStatus = 'NOT_RUN'

    $preloadVariable = Get-Variable -Name 'QuestODMConsoleOdmApiPreload' -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $preloadVariable) { $modulePreload = $preloadVariable.Value }

    if ($PreserveModule -and (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue)) {
        $moduleVersion = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleVersion')
        $modulePath = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModulePath')
        $apiSurface = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ApiSurface')
        $moduleScopeValidated = [bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleScopeValidated') -Default $false)
        $existingPreload = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModulePreload')
        if ($null -ne $existingPreload) { $modulePreload = $existingPreload }
        $moduleRuntimeProbe = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleRuntimeProbe')
        $moduleRuntimeProbeStatus = [string](Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleRuntimeProbeStatus') -Default 'NOT_RUN')
    }

    $script:QOdmState = [ordered]@{
        Connected                = $false
        ContextMode              = 'Microsoft365'
        ContextEpoch             = [guid]::NewGuid().ToString()
        ContextValid             = $true
        ContextError             = $null
        Region                   = $null
        OrganizationId           = $null
        OrganizationName         = $null
        ProjectId                = $null
        ProjectName              = $null
        ProjectObject            = $null
        WorkloadId               = $null
        WorkloadName             = $null
        WorkloadType             = $null
        WorkloadObject           = $null
        ModuleVersion            = $moduleVersion
        ModulePath               = $modulePath
        ModulePreload            = $modulePreload
        ModuleRuntimeProbe       = $moduleRuntimeProbe
        ModuleRuntimeProbeStatus = $moduleRuntimeProbeStatus
        ModuleScopeValidated     = $moduleScopeValidated
        ApiSurface               = $apiSurface
        ConnectedAt              = $null
        ConsoleVersion           = '1.1.0-rc.2'
        SafeMode                 = $true
        SafeModeReason           = 'Safe Mode enabled at startup.'
        SafeModeChangedAt        = Get-Date
        SafeModeChangedBy        = [Environment]::UserName
        LastReadinessResult      = $null
        ReadinessCompletedAt     = $null
        BlockedFeatures          = @()
        CurrentOperation         = $null
        CurrentOperationStartedAt = $null
        CurrentPhase             = $null
        Warnings                 = [System.Collections.Generic.List[string]]::new()
        Projects                 = @{}
        Workloads                = @{}
        Objects                  = @{}
        ObjectLookup             = @{}
        Tasks                    = @{}
        Collections              = @{}
        Templates                = @{}
        LastRefresh              = $null
    }
}

function Clear-QOdmSessionContext {
    [CmdletBinding()]
    param([bool]$PreserveConnection = $false)

    if (-not (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue)) {
        Initialize-QOdmState
        return
    }

    if (-not $PreserveConnection) {
        $script:QOdmState.Connected = $false
        $script:QOdmState.Region = $null
        $script:QOdmState.ConnectedAt = $null
    }
    $script:QOdmState.ContextMode = 'Microsoft365'
    $script:QOdmState.ContextEpoch = [guid]::NewGuid().ToString()
    $script:QOdmAdPreview=$null
    $script:QOdmState.ContextValid = $true
    $script:QOdmState.ContextError = $null
    $script:QOdmState.OrganizationId = $null
    $script:QOdmState.OrganizationName = $null
    $script:QOdmState.ProjectId = $null
    $script:QOdmState.ProjectName = $null
    $script:QOdmState.ProjectObject = $null
    $script:QOdmState.WorkloadId = $null
    $script:QOdmState.WorkloadName = $null
    $script:QOdmState.WorkloadType = $null
    $script:QOdmState.WorkloadObject = $null
    $script:QOdmState.Projects = @{}
    $script:QOdmState.Workloads = @{}
    $script:QOdmState.LastReadinessResult = $null
    $script:QOdmState.ReadinessCompletedAt = $null
    $script:QOdmState.BlockedFeatures = @()
    Reset-QOdmCaches
    if (Get-Command -Name 'Enable-QOdmSafeMode' -ErrorAction SilentlyContinue) {
        Enable-QOdmSafeMode -Reason 'Safe Mode reset because the Quest context was cleared.' | Out-Null
    }
    else {
        $script:QOdmState.SafeMode = $true
        $script:QOdmState.SafeModeReason = 'Safe Mode reset because the Quest context was cleared.'
        $script:QOdmState.SafeModeChangedAt = Get-Date
        $script:QOdmState.SafeModeChangedBy = [Environment]::UserName
    }
}

function Reset-QOdmCaches {
    $script:QOdmState.Objects      = @{}
    $script:QOdmState.ObjectLookup = @{}
    $script:QOdmState.Tasks        = @{}
    $script:QOdmState.Collections  = @{}
    $script:QOdmState.Templates    = @{}
    $script:QOdmState.LastRefresh  = $null
}

function Start-QOdmOperationScope {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Operation)

    if (-not (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue)) {
        Initialize-QOdmState
    }
    $script:QOdmState.CurrentOperation = $Operation
    $script:QOdmState.CurrentOperationStartedAt = Get-Date
    $script:QOdmState.CurrentPhase = 'Dispatch'
    $script:QOdmState.Warnings = [System.Collections.Generic.List[string]]::new()
}

function Set-QOdmOperationPhase {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Phase)

    if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) {
        $script:QOdmState.CurrentPhase = $Phase
    }
}

function Add-QOdmWarning {
    [CmdletBinding()]
    param([AllowNull()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    if (-not (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue)) {
        Initialize-QOdmState
    }
    if ($null -eq $script:QOdmState.Warnings) {
        $script:QOdmState.Warnings = [System.Collections.Generic.List[string]]::new()
    }
    if (-not $script:QOdmState.Warnings.Contains($Message)) {
        $script:QOdmState.Warnings.Add($Message) | Out-Null
    }
    Write-Warning $Message
}

function Get-QOdmOperationWarnings {
    if (-not (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue)) { return @() }
    if ($null -eq $script:QOdmState.Warnings) { return @() }
    return $script:QOdmState.Warnings.ToArray()
}

function ConvertTo-QOdmObjectArray {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    # Avoid PowerShell's array-subexpression binder for wrapped generic
    # List[object] instances. Some Windows PowerShell and PowerShell 7 builds
    # throw "Argument types do not match" when @($list) is evaluated after
    # the list was created through New-Object. Enumerating explicitly into a
    # CLR-created list is stable for scalars, arrays, API collections, and
    # cross-runspace PSObjects.
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

function Get-QOdmProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace([string]$name)) { continue }

        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in @($InputObject.Keys)) {
                if ([string]::Equals([string]$key, [string]$name, [StringComparison]::OrdinalIgnoreCase)) {
                    $value = $InputObject[$key]
                    if ($null -ne $value) { return $value }
                }
            }
        }

        try {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
        }
        catch { }

        try {
            $flags = [System.Reflection.BindingFlags]::Instance `
                -bor [System.Reflection.BindingFlags]::Public `
                -bor [System.Reflection.BindingFlags]::NonPublic `
                -bor [System.Reflection.BindingFlags]::IgnoreCase
            $propertyInfo = $InputObject.GetType().GetProperty($name, $flags)
            if ($null -ne $propertyInfo) {
                $value = $propertyInfo.GetValue($InputObject, $null)
                if ($null -ne $value) { return $value }
            }
        }
        catch { }
    }

    return $Default
}

function Test-QOdmPropertyTrue {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string[]]$Names)
    return [bool](Get-QOdmProperty -InputObject $InputObject -Names $Names -Default $false)
}

function Copy-QOdmValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in @($Value.Keys)) { $copy[$key] = Copy-QOdmValue -Value $Value[$key] }
        return $copy
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in (ConvertTo-QOdmObjectArray -InputObject $Value)) { $items.Add((Copy-QOdmValue -Value $item)) | Out-Null }
        return $items.ToArray()
    }
    return $Value
}

function Copy-QOdmHashtable {
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$InputHashtable)

    if ($null -eq $InputHashtable) { return @{} }
    $copy = @{}
    foreach ($key in @($InputHashtable.Keys)) { $copy[[string]$key] = Copy-QOdmValue -Value $InputHashtable[$key] }
    return $copy
}

function ConvertTo-QOdmDisplayString {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [DateTime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Value -is [System.Collections.IDictionary]) {
        return (($Value.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = [System.Collections.Generic.List[string]]::new()
        foreach ($item in (ConvertTo-QOdmObjectArray -InputObject $Value)) {
            $itemName = Get-QOdmProperty -InputObject $item -Names @('Name', 'DisplayName', 'Id', 'ID')
            if ($null -ne $itemName) { $items.Add([string]$itemName) | Out-Null } else { $items.Add([string]$item) | Out-Null }
        }
        return ($items -join '; ')
    }
    return [string]$Value
}

function Get-QOdmId {
    param([AllowNull()][object]$InputObject)
    $value = Get-QOdmProperty -InputObject $InputObject -Names @('Id', 'ID', 'ObjectId', 'TaskId', 'CollectionId', 'ProjectId', 'ProjectWorkloadId', 'WorkloadId', 'TemplateId', 'OrganizationId', 'organizationId', 'OrganizationID', 'QuestOrganizationId', 'TenantOrganizationId')
    if ($null -eq $value) { return $null }
    return [string]$value
}

function Get-QOdmName {
    param([AllowNull()][object]$InputObject)
    $value = Get-QOdmProperty -InputObject $InputObject -Names @('Name', 'DisplayName', 'TaskName', 'ProjectName', 'ProjectDisplayName', 'WorkloadName', 'OrganizationDisplayName', 'organizationDisplayName', 'OrganizationName', 'organizationName', 'Title')
    if ($null -eq $value) { return $null }
    return [string]$value
}

function Normalize-QOdmUpn {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return $Value.Trim().ToLowerInvariant()
}

function Normalize-QOdmName {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return $Value.Trim()
}

function Get-QOdmSourceUpn {
    param([AllowNull()][object]$InputObject)
    $value = Get-QOdmProperty -InputObject $InputObject -Names @('SourceUserPrincipalName', 'SourceUPN', 'SourceUpn', 'SourceEmail', 'UserPrincipalName', 'UPN')
    return (Normalize-QOdmUpn ([string]$value))
}

function Get-QOdmTargetUpn {
    param([AllowNull()][object]$InputObject)
    $value = Get-QOdmProperty -InputObject $InputObject -Names @('TargetUserPrincipalName', 'TargetUPN', 'TargetUpn', 'TargetEmail')
    return (Normalize-QOdmUpn ([string]$value))
}

function Test-QOdmDirectoryWritable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [bool]$Create = $true)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if (Test-Path -LiteralPath $Path) {
            if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
        }
        elseif ($Create) { New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        else { return $false }

        $testPath = Join-Path $Path ('.write-test-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
        try { [System.IO.File]::WriteAllText($testPath, 'Quest ODM Operations Console write test') }
        finally { if (Test-Path -LiteralPath $testPath) { Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue } }
        return $true
    }
    catch { return $false }
}

function Get-QOdmDefaultDataRoot {
    [CmdletBinding()]
    param()

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$env:QUESTODMCONSOLE_DATA_ROOT)) { $candidates.Add([string]$env:QUESTODMCONSOLE_DATA_ROOT) | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'QuestODMConsole')) | Out-Null }
    try {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if (-not [string]::IsNullOrWhiteSpace($localAppData)) { $candidates.Add((Join-Path $localAppData 'QuestODMConsole')) | Out-Null }
    }
    catch { }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:TEMP)) { $candidates.Add((Join-Path $env:TEMP 'QuestODMConsole')) | Out-Null }
    try {
        $temporaryPath = [System.IO.Path]::GetTempPath()
        if (-not [string]::IsNullOrWhiteSpace($temporaryPath)) { $candidates.Add((Join-Path $temporaryPath 'QuestODMConsole')) | Out-Null }
    }
    catch { }

    foreach ($candidate in (ConvertTo-QOdmObjectArray -InputObject ($candidates.ToArray() | Select-Object -Unique))) {
        if (Test-QOdmDirectoryWritable -Path $candidate -Create $true) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'A writable per-user data directory could not be created. Set QUESTODMCONSOLE_DATA_ROOT to a writable local folder.'
}

function Get-QOdmDefaultReportDirectory { return (Join-Path (Get-QOdmDefaultDataRoot) 'Reports') }
function Get-QOdmDefaultLogDirectory { return (Join-Path (Get-QOdmDefaultDataRoot) 'Logs') }

function Get-QOdmOutputDirectory {
    [CmdletBinding()]
    param([AllowNull()][string]$OutputDirectory)

    $wasExplicit = -not [string]::IsNullOrWhiteSpace($OutputDirectory)
    $target = if ($wasExplicit) { $OutputDirectory } else { Get-QOdmDefaultReportDirectory }
    if (Test-QOdmDirectoryWritable -Path $target -Create $true) { return (Resolve-Path -LiteralPath $target).Path }
    if ($wasExplicit) { throw "The selected output directory is unavailable or not writable: $target" }

    $fallbackRoot = if (-not [string]::IsNullOrWhiteSpace([string]$env:TEMP)) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $fallback = Join-Path $fallbackRoot 'QuestODMConsole\Reports'
    if (Test-QOdmDirectoryWritable -Path $fallback -Create $true) { return (Resolve-Path -LiteralPath $fallback).Path }
    throw 'A writable report directory could not be created.'
}

function Get-QOdmCommandParameterNames {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CommandName)

    $command = Get-Command -Name $CommandName -ErrorAction Stop
    if ($null -ne $command.Parameters -and $command.Parameters.Count -gt 0) {
        return (ConvertTo-QOdmObjectArray -InputObject $command.Parameters.Keys)
    }
    if ($null -ne $command.ScriptBlock -and $null -ne $command.ScriptBlock.Ast -and $null -ne $command.ScriptBlock.Ast.ParamBlock) {
        $names = $command.ScriptBlock.Ast.ParamBlock.Parameters.Name.VariablePath.UserPath |
            Where-Object { $_ } |
            Sort-Object -Unique
        return (ConvertTo-QOdmObjectArray -InputObject $names)
    }
    return @()
}

function Get-QOdmCommandInvocationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [AllowNull()][System.Collections.IDictionary]$Parameters = $null,
        [string[]]$RequiredParameters = @(),
        [string[]]$OptionalParameters = @()
    )

    $inputParameters = if ($null -eq $Parameters) { @{} } else { $Parameters }
    $parameterNames = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCommandParameterNames -CommandName $CommandName)
    $supported = @{}
    $ignoredOptional = [System.Collections.Generic.List[string]]::new()

    foreach ($required in @($RequiredParameters)) {
        if ($parameterNames -notcontains $required) { throw "$CommandName does not expose the required parameter '$required'." }
        if (-not $inputParameters.Contains($required)) { throw "$CommandName requires the caller to supply '$required'." }
    }

    foreach ($keyObject in @($inputParameters.Keys)) {
        $key = [string]$keyObject
        if ($parameterNames -contains $key) {
            $supported[$key] = $inputParameters[$keyObject]
            continue
        }
        if ($OptionalParameters -contains $key) {
            $ignoredOptional.Add($key) | Out-Null
            continue
        }
        throw "$CommandName does not expose parameter '$key'. The operation was stopped instead of silently changing its meaning."
    }

    [pscustomobject]@{
        CommandName       = $CommandName
        Parameters        = $supported
        IgnoredOptional   = $ignoredOptional.ToArray()
        AvailableParameters = $parameterNames
    }
}

function Invoke-QOdmSupportedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [AllowNull()][System.Collections.IDictionary]$Parameters = $null,
        [string[]]$RequiredParameters = @(),
        [string[]]$OptionalParameters = @()
    )

    $plan = Get-QOdmCommandInvocationPlan -CommandName $CommandName -Parameters $Parameters -RequiredParameters $RequiredParameters -OptionalParameters $OptionalParameters
    $ignoredOptional = ConvertTo-QOdmObjectArray -InputObject $plan.IgnoredOptional
    if ($ignoredOptional.Count -gt 0) {
        Add-QOdmWarning -Message ("{0} does not support optional parameter(s): {1}. Those optional settings were not applied." -f $CommandName, ($ignoredOptional -join ', '))
    }
    $invokeParameters = [hashtable]$plan.Parameters
    if ($plan.AvailableParameters -contains 'ErrorAction' -and -not $invokeParameters.ContainsKey('ErrorAction')) {
        $invokeParameters.ErrorAction = 'Stop'
    }
    return (& $CommandName @invokeParameters)
}

function Invoke-QOdmSupportedCommandArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [AllowNull()][System.Collections.IDictionary]$Parameters = $null,
        [string[]]$RequiredParameters = @(),
        [string[]]$OptionalParameters = @()
    )

    # Capture command output before normalization. This is deliberately not an
    # array-subexpression: PowerShell can throw "Argument types do not match"
    # when @($value) receives a generic List[object] created through New-Object.
    $commandOutput = Invoke-QOdmSupportedCommand -CommandName $CommandName -Parameters $Parameters `
        -RequiredParameters $RequiredParameters -OptionalParameters $OptionalParameters
    return (ConvertTo-QOdmObjectArray -InputObject $commandOutput)
}

function Test-QOdmCommand {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-QOdmLoadedApiModule {
    [CmdletBinding()]
    param()

    $modules = @()
    try { $modules = ConvertTo-QOdmObjectArray -InputObject (Get-Module -Name 'OdmApi' -All -ErrorAction SilentlyContinue) }
    catch { $modules = ConvertTo-QOdmObjectArray -InputObject (Get-Module -Name 'OdmApi' -ErrorAction SilentlyContinue) }
    return ($modules | Sort-Object Version -Descending | Select-Object -First 1)
}

function Get-QOdmWorkerModulePreload {
    [CmdletBinding()]
    param()

    $variable = Get-Variable -Name 'QuestODMConsoleOdmApiPreload' -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $variable) { return $null }
    return $variable.Value
}

function Test-QOdmApiRuntimeInitialization {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Management.Automation.PSModuleInfo]$Module)

    $resultBase = [ordered]@{
        Status                 = 'FAILED'
        Attempted              = $false
        Passed                 = $false
        Blocking               = $true
        PrivateFunctionPresent = $false
        ModuleName             = if ($null -ne $Module) { [string]$Module.Name } else { $null }
        ModuleVersion          = if ($null -ne $Module) { [string]$Module.Version } else { $null }
        ModulePath             = if ($null -ne $Module) { [string]$Module.Path } else { $null }
        Details                = $null
        Error                  = $null
        ExceptionType          = $null
        FullyQualifiedErrorId  = $null
        ScriptStackTrace       = $null
        TestedAt               = Get-Date
    }

    if ($null -eq $Module) {
        $resultBase.Error = 'No OdmApi module object was supplied to the runtime-initialization probe.'
        $resultBase.Details = $resultBase.Error
        return [pscustomobject]$resultBase
    }

    try {
        $expectedName = [string]$Module.Name
        $expectedVersion = [string]$Module.Version
        $rawProbeOutput = & $Module {
            param([string]$ExpectedName, [string]$ExpectedVersion)

            $privateCommand = Get-Command -Name 'Set-ModuleVersion' -CommandType Function -ErrorAction SilentlyContinue
            if ($null -eq $privateCommand -or -not [string]::Equals([string]$privateCommand.ModuleName, $ExpectedName, [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{
                    Status='SKIPPED_PRIVATE_FUNCTION_NOT_PRESENT'; Attempted=$false; Passed=$true; Blocking=$false
                    PrivateFunctionPresent=$false; ModuleName=$ExpectedName; ModuleVersion=$ExpectedVersion
                    Details='The installed OdmApi module does not contain the private Set-ModuleVersion function. The compatibility probe was skipped; Connect-OdmService remains the authoritative runtime test.'
                    Error=$null; ExceptionType=$null; FullyQualifiedErrorId=$null; ScriptStackTrace=$null
                }
            }

            try {
                & $privateCommand
                $resolvedModuleName = [string](Get-Variable -Name 'ModuleName' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
                $resolvedModuleVersion = [string](Get-Variable -Name 'ModuleVersion' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
                if ([string]::IsNullOrWhiteSpace($resolvedModuleName)) {
                    throw 'Set-ModuleVersion completed without setting the module-scoped ModuleName value.'
                }
                if ([string]::IsNullOrWhiteSpace($resolvedModuleVersion)) {
                    throw 'Set-ModuleVersion completed without setting the module-scoped ModuleVersion value.'
                }
                if (-not [string]::Equals($resolvedModuleName, $ExpectedName, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Set-ModuleVersion resolved module '$resolvedModuleName' instead of '$ExpectedName'."
                }
                return [pscustomobject]@{
                    Status='PASS'; Attempted=$true; Passed=$true; Blocking=$false; PrivateFunctionPresent=$true
                    ModuleName=$resolvedModuleName; ModuleVersion=$resolvedModuleVersion
                    Details='OdmApi private module-version initialization completed successfully in the module session state.'
                    Error=$null; ExceptionType=$null; FullyQualifiedErrorId=$null; ScriptStackTrace=$null
                }
            }
            catch {
                return [pscustomobject]@{
                    Status='FAILED'; Attempted=$true; Passed=$false; Blocking=$true; PrivateFunctionPresent=$true
                    ModuleName=$ExpectedName; ModuleVersion=$ExpectedVersion
                    Details=('The private OdmApi Set-ModuleVersion function failed: {0}' -f $_.Exception.Message)
                    Error=$_.Exception.Message; ExceptionType=$_.Exception.GetType().FullName
                    FullyQualifiedErrorId=$_.FullyQualifiedErrorId; ScriptStackTrace=$_.ScriptStackTrace
                }
            }
        } $expectedName $expectedVersion
        $probeOutput = ConvertTo-QOdmObjectArray -InputObject $rawProbeOutput

        if ($probeOutput.Count -eq 0 -or $null -eq $probeOutput[$probeOutput.Count - 1]) {
            $resultBase.Error = 'The OdmApi runtime-initialization probe returned no result.'
            $resultBase.Details = $resultBase.Error
            return [pscustomobject]$resultBase
        }

        $probe = $probeOutput[$probeOutput.Count - 1]
        foreach ($name in @('Status','Attempted','Passed','Blocking','PrivateFunctionPresent','ModuleName','ModuleVersion','Details','Error','ExceptionType','FullyQualifiedErrorId','ScriptStackTrace')) {
            $value = Get-QOdmProperty -InputObject $probe -Names @($name)
            if ($null -ne $value) { $resultBase[$name] = $value }
        }
        return [pscustomobject]$resultBase
    }
    catch {
        $resultBase.Attempted = $true
        $resultBase.Error = $_.Exception.Message
        $resultBase.ExceptionType = $_.Exception.GetType().FullName
        $resultBase.FullyQualifiedErrorId = $_.FullyQualifiedErrorId
        $resultBase.ScriptStackTrace = $_.ScriptStackTrace
        $resultBase.Details = 'The console could not execute the OdmApi runtime-initialization probe: {0}' -f $_.Exception.Message
        return [pscustomobject]$resultBase
    }
}


function Import-QOdmApiModule {
    [CmdletBinding()]
    param()

    $preload = Get-QOdmWorkerModulePreload
    $loaded = Get-QOdmLoadedApiModule

    if ($null -eq $loaded) {
        $available = ConvertTo-QOdmObjectArray -InputObject (Get-Module -ListAvailable -Name 'OdmApi' | Sort-Object Version -Descending)
        if ($available.Count -eq 0) {
            throw 'The OdmApi module is not installed. Install it with: Install-Module OdmApi -Scope CurrentUser -Force'
        }

        $candidate = $available[0]
        $manifestPath = Join-Path -Path $candidate.ModuleBase -ChildPath 'OdmApi.psd1'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { $manifestPath = [string]$candidate.Path }
        if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "The OdmApi module was discovered, but its manifest or module path could not be resolved. Module base: $($candidate.ModuleBase)"
        }

        $imported = ConvertTo-QOdmObjectArray -InputObject (Import-Module -Name $manifestPath -Global -PassThru -ErrorAction Stop)
        $loaded = $imported | Where-Object { $_.Name -eq 'OdmApi' } | Sort-Object Version -Descending | Select-Object -First 1
        if ($null -eq $loaded) { $loaded = Get-QOdmLoadedApiModule }
        if ($null -eq $loaded) { throw 'OdmApi import completed without returning or loading a module object.' }
    }

    $connectCommand = Get-Command -Name 'Connect-OdmService' -ErrorAction Stop
    if ($null -eq $connectCommand.Module -or -not [string]::Equals([string]$connectCommand.Module.Name, 'OdmApi', [StringComparison]::OrdinalIgnoreCase)) {
        $resolvedName = if ($null -ne $connectCommand.Module) { [string]$connectCommand.Module.Name } else { '<none>' }
        throw "Connect-OdmService resolved to module '$resolvedName' instead of 'OdmApi'."
    }
    # Use the module object that owns the command PowerShell will actually invoke. This
    # avoids probing a different loaded version when multiple OdmApi versions exist.
    $loaded = $connectCommand.Module

    $runtimeProbe = Test-QOdmApiRuntimeInitialization -Module $loaded
    $probeStatus = [string](Get-QOdmProperty -InputObject $runtimeProbe -Names @('Status') -Default 'FAILED')
    $probePassed = [bool](Get-QOdmProperty -InputObject $runtimeProbe -Names @('Passed') -Default $false)

    if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) {
        $script:QOdmState.ModuleVersion = [string]$loaded.Version
        $script:QOdmState.ModulePath = [string]$loaded.Path
        $script:QOdmState.ModulePreload = $preload
        $script:QOdmState.ModuleRuntimeProbe = $runtimeProbe
        $script:QOdmState.ModuleRuntimeProbeStatus = $probeStatus
        $script:QOdmState.ModuleScopeValidated = $probePassed
    }

    if (-not $probePassed) {
        $probeDetails = [string](Get-QOdmProperty -InputObject $runtimeProbe -Names @('Details','Error') -Default 'No probe details were returned.')
        throw "OdmApi runtime initialization failed before authentication. $probeDetails"
    }
    if ($probeStatus -eq 'SKIPPED_PRIVATE_FUNCTION_NOT_PRESENT') {
        Add-QOdmWarning -Message ([string](Get-QOdmProperty -InputObject $runtimeProbe -Names @('Details')))
    }

    return $loaded
}

function Get-QOdmApiSurfaceReport {
    [CmdletBinding()]
    param([bool]$ImportModule = $false)

    $requiredCommands = @(
        'Connect-OdmService','Select-OdmOrganization','Get-OdmProject','Select-OdmProject',
        'Get-OdmProjectWorkload','Select-OdmProjectWorkload','Get-OdmObject','Get-OdmTask',
        'Get-OdmCollection','Add-OdmObject','Remove-OdmObject','New-OdmCollection',
        'Remove-OdmCollection','Remove-OdmTask'
    )
    $optionalCommands = @(
        'Disconnect-OdmService','Get-OdmOrganizations','Get-OdmActiveOrganizations','Get-OdmTaskTemplates','Start-OdmTask','Stop-OdmTask','Add-OdmTask',
        'New-OdmMailMigrationTask','New-OdmOneDriveMigrationTask',
        'New-OdmMeetingLinkMigrationTask','New-OdmMailSwitchTask','New-OdmDiscoveryTask','New-OdmMappingFileTask'
    )

    $available = ConvertTo-QOdmObjectArray -InputObject (Get-Module -ListAvailable -Name 'OdmApi' | Sort-Object Version -Descending)
    $latest = $available | Select-Object -First 1
    $loaded = Get-QOdmLoadedApiModule
    if ($null -eq $loaded -and $ImportModule -and $null -ne $latest) { $loaded = Import-QOdmApiModule }

    $assessed = ($null -ne $loaded)
    $missingRequired = [System.Collections.Generic.List[string]]::new()
    $availableOptional = [System.Collections.Generic.List[string]]::new()
    $missingOptional = [System.Collections.Generic.List[string]]::new()
    $contractIssues = [System.Collections.Generic.List[string]]::new()
    $runtimeProbe = $null
    $moduleScopeValidated = $false

    if ($assessed) {
        $stateProbe = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleRuntimeProbe') } else { $null }
        $stateVersion = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { [string](Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleVersion')) } else { $null }
        if ($null -ne $stateProbe -and [string]::Equals($stateVersion, [string]$loaded.Version, [StringComparison]::OrdinalIgnoreCase)) {
            $runtimeProbe = $stateProbe
        }
        else {
            $runtimeProbe = Test-QOdmApiRuntimeInitialization -Module $loaded
        }
        $moduleScopeValidated = [bool](Get-QOdmProperty -InputObject $runtimeProbe -Names @('Passed') -Default $false)
        if (-not $moduleScopeValidated) {
            $contractIssues.Add(('OdmApi runtime initialization failed: {0}' -f (Get-QOdmProperty -InputObject $runtimeProbe -Names @('Details','Error') -Default 'No details returned.'))) | Out-Null
        }

        foreach ($commandName in $requiredCommands) {
            if (-not (Test-QOdmCommand -Name $commandName)) { $missingRequired.Add($commandName) | Out-Null }
        }
        foreach ($commandName in $optionalCommands) {
            if (Test-QOdmCommand -Name $commandName) { $availableOptional.Add($commandName) | Out-Null }
            else { $missingOptional.Add($commandName) | Out-Null }
        }

        $contracts = @(
            [pscustomobject]@{ Command = 'Connect-OdmService'; Alternatives = @('Region') },
            [pscustomobject]@{ Command = 'Select-OdmOrganization'; Alternatives = @('OrganizationId') },
            [pscustomobject]@{ Command = 'Get-OdmProject'; Alternatives = @('All','ProjectId') },
            [pscustomobject]@{ Command = 'Select-OdmProject'; Alternatives = @('Project','ProjectId') },
            [pscustomobject]@{ Command = 'Get-OdmProjectWorkload'; Alternatives = @('Project+All','ProjectWorkloadId') },
            [pscustomobject]@{ Command = 'Select-OdmProjectWorkload'; Alternatives = @('ProjectWorkloadId','Project') },
            [pscustomobject]@{ Command = 'Get-OdmObject'; Alternatives = @('FilterObject+All') },
            [pscustomobject]@{ Command = 'Get-OdmTask'; Alternatives = @('Project+All+TaskId+CollectionId') },
            [pscustomobject]@{ Command = 'Get-OdmCollection'; Alternatives = @('ResultSize') },
            [pscustomobject]@{ Command = 'Add-OdmObject'; Alternatives = @('To+Objects') },
            [pscustomobject]@{ Command = 'Remove-OdmObject'; Alternatives = @('From+Objects') },
            [pscustomobject]@{ Command = 'New-OdmCollection'; Alternatives = @('Name') },
            [pscustomobject]@{ Command = 'Remove-OdmCollection'; Alternatives = @('Collections') },
            [pscustomobject]@{ Command = 'Remove-OdmTask'; Alternatives = @('Tasks') }
        )

        foreach ($contract in $contracts) {
            if (-not (Test-QOdmCommand -Name $contract.Command)) { continue }
            $parameters = @(Get-QOdmCommandParameterNames -CommandName $contract.Command)
            $satisfied = $false
            foreach ($alternative in @($contract.Alternatives)) {
                $requiredNames = @([string]$alternative -split '\+')
                $setSatisfied = $true
                foreach ($parameterName in $requiredNames) {
                    if ($parameters -notcontains $parameterName) { $setSatisfied = $false; break }
                }
                if ($setSatisfied) { $satisfied = $true; break }
            }
            if (-not $satisfied) { $contractIssues.Add("$($contract.Command) does not expose a supported parameter contract.") | Out-Null }
        }
    }

    $compatible = $null
    if ($assessed) { $compatible = ($missingRequired.Count -eq 0 -and $contractIssues.Count -eq 0) }
    $hostRecommendation = if ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5) {
        'Recommended host detected: 64-bit Windows PowerShell 5.1.'
    }
    else {
        'PowerShell 7 detected. If the Quest module returns Windows-only or proxy-object errors, use the Windows PowerShell 5.1 launcher.'
    }

    [pscustomobject]@{
        Installed                = ($available.Count -gt 0 -or $null -ne $loaded)
        Loaded                   = $assessed
        Assessed                 = $assessed
        Compatible               = $compatible
        ModuleScopeValidated     = $moduleScopeValidated
        ModuleRuntimeProbe       = $runtimeProbe
        ModuleRuntimeProbeStatus = [string](Get-QOdmProperty -InputObject $runtimeProbe -Names @('Status') -Default 'NOT_RUN')
        ModulePreload             = Get-QOdmWorkerModulePreload
        ModuleVersion            = if ($null -ne $loaded) { [string]$loaded.Version } elseif ($null -ne $latest) { [string]$latest.Version } else { $null }
        ModulePath               = if ($null -ne $loaded) { [string]$loaded.Path } elseif ($null -ne $latest) { [string]$latest.Path } else { $null }
        RequiredCommands         = $requiredCommands
        MissingRequired          = $missingRequired.ToArray()
        AvailableOptional        = $availableOptional.ToArray()
        MissingOptional          = $missingOptional.ToArray()
        ParameterContractIssues  = $contractIssues.ToArray()
        HostRecommendation       = $hostRecommendation
    }
}

function Assert-QOdmApiSurface {
    [CmdletBinding()]
    param([AllowNull()][object]$Report)

    if ($null -eq $Report -or -not [bool](Get-QOdmProperty -InputObject $Report -Names @('Installed') -Default $false)) {
        throw 'The OdmApi module is not installed. Install it with: Install-Module OdmApi -Scope CurrentUser -Force'
    }
    if (-not [bool](Get-QOdmProperty -InputObject $Report -Names @('Assessed') -Default $false)) {
        throw 'The OdmApi command surface could not be assessed after module import.'
    }
    if (-not [bool](Get-QOdmProperty -InputObject $Report -Names @('Compatible') -Default $false)) {
        $parts = [System.Collections.Generic.List[string]]::new()
        $missing = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $Report -Names @('MissingRequired') -Default @())
        $issues = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $Report -Names @('ParameterContractIssues') -Default @())
        if ($missing.Count -gt 0) { $parts.Add(('Missing commands: {0}' -f ($missing -join ', '))) | Out-Null }
        if ($issues.Count -gt 0) { $parts.Add(('Parameter contract issues: {0}' -f ($issues -join '; '))) | Out-Null }
        throw ('The installed OdmApi module does not expose the required API surface. {0}' -f ($parts.ToArray() -join ' '))
    }
}

function Add-QOdmObjectLookupEntry {
    param([Parameter(Mandatory = $true)][hashtable]$Lookup, [AllowNull()][string]$Value, [Parameter(Mandatory = $true)][object]$Object)

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $normalized = Normalize-QOdmUpn $Value
    if (-not $normalized -or $normalized -notmatch '@') { return }

    $existing = @()
    if ($Lookup.ContainsKey($normalized)) { $existing = ConvertTo-QOdmObjectArray -InputObject $Lookup[$normalized] }
    $objectId = Get-QOdmId $Object
    foreach ($item in $existing) {
        $existingId = Get-QOdmId $item
        if ($objectId -and $existingId -and [string]::Equals($objectId, $existingId, [StringComparison]::OrdinalIgnoreCase)) { return }
        if (-not $objectId -and [object]::ReferenceEquals($item, $Object)) { return }
    }
    $newValues = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $existing) { $newValues.Add($item) | Out-Null }
    $newValues.Add($Object) | Out-Null
    $Lookup[$normalized] = $newValues.ToArray()
}

function Add-QOdmObjectsToEntity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Entity, [Parameter(Mandatory = $true)][object]$Objects)

    $items = ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $Objects) | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return @() }
    $command = Get-Command -Name 'Add-OdmObject' -ErrorAction Stop
    if (-not ($command.Parameters.ContainsKey('To') -and $command.Parameters.ContainsKey('Objects'))) {
        throw 'The installed Add-OdmObject command does not expose the required To/Objects parameter contract.'
    }
    $parameters = @{ To = $Entity; Objects = $items; ErrorAction = 'Stop' }
    if ($command.Parameters.ContainsKey('PassThru')) { $parameters.PassThru = $true }
    $output = Add-OdmObject @parameters
    return (ConvertTo-QOdmObjectArray -InputObject $output)
}

function Remove-QOdmObjectsFromEntity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Entity, [Parameter(Mandatory = $true)][object]$Objects)

    $items = ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $Objects) | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return @() }
    $command = Get-Command -Name 'Remove-OdmObject' -ErrorAction Stop
    if (-not ($command.Parameters.ContainsKey('From') -and $command.Parameters.ContainsKey('Objects'))) {
        throw 'The installed Remove-OdmObject command does not expose the required From/Objects parameter contract.'
    }
    $parameters = @{ From = $Entity; Objects = $items; ErrorAction = 'Stop' }
    if ($command.Parameters.ContainsKey('PassThru')) { $parameters.PassThru = $true }
    if ($command.Parameters.ContainsKey('Confirm')) { $parameters.Confirm = $false }
    $output = Remove-OdmObject @parameters
    return (ConvertTo-QOdmObjectArray -InputObject $output)
}

function Add-QOdmTasksToCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Tasks, [Parameter(Mandatory = $true)][object]$Collection)

    $items = ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $Tasks) | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return @() }
    if (-not (Test-QOdmCommand -Name 'Add-OdmTask')) { throw 'Add-OdmTask is not available in the installed OdmApi module.' }
    $command = Get-Command -Name 'Add-OdmTask' -ErrorAction Stop
    if (-not ($command.Parameters.ContainsKey('Tasks') -and $command.Parameters.ContainsKey('To'))) {
        throw 'The installed Add-OdmTask command does not expose the required Tasks/To parameter contract.'
    }
    $parameters = @{ Tasks = $items; To = $Collection; ErrorAction = 'Stop' }
    if ($command.Parameters.ContainsKey('PassThru')) { $parameters.PassThru = $true }
    $output = Add-OdmTask @parameters
    return (ConvertTo-QOdmObjectArray -InputObject $output)
}

function Get-QOdmProjectsAll {
    [CmdletBinding()]
    param()

    $command = Get-Command -Name 'Get-OdmProject' -ErrorAction Stop
    if ($command.Parameters.ContainsKey('All')) {
        $output = Get-OdmProject -All -ErrorAction Stop
    }
    else {
        $output = Get-OdmProject -ErrorAction Stop
    }
    return (ConvertTo-QOdmObjectArray -InputObject $output)
}

function Get-QOdmProjectTasks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Project)

    $command = Get-Command -Name 'Get-OdmTask' -ErrorAction Stop
    if (-not $command.Parameters.ContainsKey('Project')) { throw 'Get-OdmTask does not expose the required Project pipeline parameter.' }
    if ($command.Parameters.ContainsKey('All')) {
        $output = $Project | Get-OdmTask -All -ErrorAction Stop
    }
    else {
        $output = $Project | Get-OdmTask -ErrorAction Stop
    }
    return (ConvertTo-QOdmObjectArray -InputObject $output)
}

function Get-QOdmProjectWorkloads {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Project)

    $command = Get-Command -Name 'Get-OdmProjectWorkload' -ErrorAction Stop
    if (-not $command.Parameters.ContainsKey('Project')) { throw 'Get-OdmProjectWorkload does not expose the required Project pipeline parameter.' }

    $projectParameter = $command.Parameters['Project']
    $parameterType = if ($null -ne $projectParameter) { $projectParameter.ParameterType } else { $null }
    $projectBase = $Project
    try { $projectBase = [System.Management.Automation.PSObject]::Base($Project) } catch { }
    $projectCompatible = ($null -eq $parameterType -or $parameterType -eq [object] -or
        $parameterType.IsInstanceOfType($Project) -or $parameterType.IsInstanceOfType($projectBase))
    if (-not $projectCompatible) {
        Add-QOdmWarning -Message ("Project '{0}' is type '{1}', which is not accepted by Get-OdmProjectWorkload's Project parameter type '{2}'. The root project context remains available, but child workloads cannot be enumerated for this project type." -f (Get-QOdmName $Project), $Project.GetType().FullName, $parameterType.FullName)
        return @()
    }

    if ($command.Parameters.ContainsKey('All')) {
        $output = $Project | Get-OdmProjectWorkload -All -ErrorAction Stop
    }
    else {
        $output = $Project | Get-OdmProjectWorkload -ErrorAction Stop
    }
    return (ConvertTo-QOdmObjectArray -InputObject $output)
}

function Select-QOdmProjectSafe {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Project,
        [AllowNull()][string]$ProjectId
    )

    $command = Get-Command -Name 'Select-OdmProject' -ErrorAction Stop
    if ($null -ne $Project -and $command.Parameters.ContainsKey('Project')) {
        $null = Invoke-QOdmSupportedCommand -CommandName 'Select-OdmProject' -Parameters @{ Project=$Project } -RequiredParameters @('Project')
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectId) -and $command.Parameters.ContainsKey('ProjectId')) {
        $null = Invoke-QOdmSupportedCommand -CommandName 'Select-OdmProject' -Parameters @{ ProjectId=$ProjectId } -RequiredParameters @('ProjectId')
        return
    }

    if ($null -eq $Project -and -not [string]::IsNullOrWhiteSpace($ProjectId) -and $command.Parameters.ContainsKey('Project')) {
        $resolved = Resolve-QOdmProjectById -ProjectId $ProjectId
        if ($null -ne $resolved) {
            $null = Invoke-QOdmSupportedCommand -CommandName 'Select-OdmProject' -Parameters @{ Project=$resolved } -RequiredParameters @('Project')
            return
        }
    }

    throw 'Select-OdmProject does not expose a usable Project or ProjectId parameter contract for the requested project.'
}

function Select-QOdmProjectWorkloadSafe {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Workload,
        [AllowNull()][string]$ProjectWorkloadId
    )

    $command = Get-Command -Name 'Select-OdmProjectWorkload' -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($ProjectWorkloadId) -and $command.Parameters.ContainsKey('ProjectWorkloadId')) {
        $null = Invoke-QOdmSupportedCommand -CommandName 'Select-OdmProjectWorkload' -Parameters @{ ProjectWorkloadId=$ProjectWorkloadId } -RequiredParameters @('ProjectWorkloadId')
        return
    }

    # Older/future command surfaces may support only the Project pipeline parameter.
    # Bind only when the object is assignable to that parameter type; never coerce an
    # OdmProjectWorkload into an OdmProject parameter.
    if ($null -ne $Workload -and $command.Parameters.ContainsKey('Project')) {
        $projectParameter = $command.Parameters['Project']
        $parameterType = if ($null -ne $projectParameter) { $projectParameter.ParameterType } else { $null }
        $workloadBase = $Workload
        try { $workloadBase = [System.Management.Automation.PSObject]::Base($Workload) } catch { }
        $isCompatible = ($null -eq $parameterType -or $parameterType -eq [object] -or
            $parameterType.IsInstanceOfType($Workload) -or $parameterType.IsInstanceOfType($workloadBase))
        if ($isCompatible) {
            $null = Invoke-QOdmSupportedCommand -CommandName 'Select-OdmProjectWorkload' -Parameters @{ Project=$Workload } -RequiredParameters @('Project')
            return
        }
    }

    throw 'Select-OdmProjectWorkload does not expose a usable ProjectWorkloadId parameter contract for the requested workload.'
}


function Get-QOdmCollectionTasks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Collection)

    $collectionId = Get-QOdmId $Collection
    if ([string]::IsNullOrWhiteSpace($collectionId)) { throw 'The collection does not expose an ID, so its linked tasks cannot be read safely.' }
    $command = Get-Command -Name 'Get-OdmTask' -ErrorAction Stop
    if (-not $command.Parameters.ContainsKey('CollectionId')) {
        throw 'Get-OdmTask does not expose the required CollectionId parameter. Collection-to-task reads are unavailable with this OdmApi version.'
    }
    $parameters = @{ CollectionId = $collectionId }
    if ($command.Parameters.ContainsKey('All')) { $parameters.All = $true }
    $parameters.ErrorAction = 'Stop'
    $output = Get-OdmTask @parameters
    return (ConvertTo-QOdmObjectArray -InputObject $output)
}

function Resolve-QOdmProjectById {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProjectId)

    if ([string]::IsNullOrWhiteSpace($ProjectId)) { return $null }
    if ($script:QOdmState.Projects.ContainsKey($ProjectId)) { return $script:QOdmState.Projects[$ProjectId] }
    $command = Get-Command -Name 'Get-OdmProject' -ErrorAction Stop
    if ($command.Parameters.ContainsKey('ProjectId')) {
        $matches = ConvertTo-QOdmObjectArray -InputObject (Get-OdmProject -ProjectId $ProjectId -ErrorAction Stop)
    }
    else {
        $matches = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProjectsAll | Where-Object { [string]::Equals([string](Get-QOdmId $_), $ProjectId, [StringComparison]::OrdinalIgnoreCase) })
    }
    if ($matches.Count -gt 1) { throw "Project ID '$ProjectId' returned more than one object." }
    if ($matches.Count -eq 1) {
        $resolvedId = Get-QOdmId $matches[0]
        if ($resolvedId) { $script:QOdmState.Projects[$resolvedId] = $matches[0] }
        return $matches[0]
    }
    return $null
}

function Resolve-QOdmExactEntity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object]$Entities,
        [AllowNull()][string]$Id,
        [AllowNull()][string]$Name,
        [Parameter(Mandatory = $true)][string]$EntityType
    )

    $items = ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $Entities) | Where-Object { $null -ne $_ })
    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        $matches = @($items | Where-Object { [string]::Equals([string](Get-QOdmId $_), $Id.Trim(), [StringComparison]::OrdinalIgnoreCase) })
        if ($matches.Count -gt 1) { throw "$EntityType ID '$Id' matched more than one object." }
        if ($matches.Count -eq 1) { return $matches[0] }
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $matches = @($items | Where-Object { [string]::Equals([string](Get-QOdmName $_), $Name.Trim(), [StringComparison]::OrdinalIgnoreCase) })
        if ($matches.Count -gt 1) {
            $candidateText = @($matches | ForEach-Object { '{0} [{1}]' -f (Get-QOdmName $_), (Get-QOdmId $_) }) -join '; '
            throw "$EntityType name '$Name' is ambiguous. Use an exact ID. Matches: $candidateText"
        }
        if ($matches.Count -eq 1) { return $matches[0] }
    }
    return $null
}

function Assert-QOdmRegexPatterns {
    [CmdletBinding()]
    param([AllowNull()][string[]]$Patterns, [string]$Description = 'name pattern')

    $validated = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) { continue }
        try { [void][regex]::new([string]$pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
        catch { throw "Invalid $Description '$pattern': $($_.Exception.Message)" }
        $validated.Add([string]$pattern) | Out-Null
    }
    return $validated.ToArray()
}

function Get-QOdmContextSnapshot {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        ContextValid     = [bool]$script:QOdmState.ContextValid
        ContextError     = $script:QOdmState.ContextError
        OrganizationId   = $script:QOdmState.OrganizationId
        OrganizationName = $script:QOdmState.OrganizationName
        ProjectId        = $script:QOdmState.ProjectId
        ProjectName      = $script:QOdmState.ProjectName
        ProjectObject    = $script:QOdmState.ProjectObject
        WorkloadId       = $script:QOdmState.WorkloadId
        WorkloadName     = $script:QOdmState.WorkloadName
        WorkloadType     = $script:QOdmState.WorkloadType
        WorkloadObject   = $script:QOdmState.WorkloadObject
    }
}

function Restore-QOdmContextSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    Assert-QOdmConnected
    $projectId = [string](Get-QOdmProperty -InputObject $Snapshot -Names @('ProjectId'))
    $workloadId = [string](Get-QOdmProperty -InputObject $Snapshot -Names @('WorkloadId'))
    $projectObject = Get-QOdmProperty -InputObject $Snapshot -Names @('ProjectObject')
    $workloadObject = Get-QOdmProperty -InputObject $Snapshot -Names @('WorkloadObject')

    try {
        if (-not [string]::IsNullOrWhiteSpace($workloadId)) {
            if (-not [string]::IsNullOrWhiteSpace($projectId) -and [string]::Equals($projectId, $workloadId, [StringComparison]::OrdinalIgnoreCase)) {
                Select-QOdmProjectSafe -Project $projectObject -ProjectId $projectId
            }
            else {
                Select-QOdmProjectWorkloadSafe -Workload $workloadObject -ProjectWorkloadId $workloadId
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($projectId)) {
            Select-QOdmProjectSafe -Project $projectObject -ProjectId $projectId
        }

        $script:QOdmState.ContextValid = [bool](Get-QOdmProperty -InputObject $Snapshot -Names @('ContextValid') -Default $true)
        $script:QOdmState.ContextError = Get-QOdmProperty -InputObject $Snapshot -Names @('ContextError')
        $script:QOdmState.OrganizationId = Get-QOdmProperty -InputObject $Snapshot -Names @('OrganizationId')
        $script:QOdmState.OrganizationName = Get-QOdmProperty -InputObject $Snapshot -Names @('OrganizationName')
        $script:QOdmState.ProjectId = $projectId
        $script:QOdmState.ProjectName = Get-QOdmProperty -InputObject $Snapshot -Names @('ProjectName')
        $script:QOdmState.ProjectObject = $projectObject
        $script:QOdmState.WorkloadId = $workloadId
        $script:QOdmState.WorkloadName = Get-QOdmProperty -InputObject $Snapshot -Names @('WorkloadName')
        $script:QOdmState.WorkloadType = Get-QOdmProperty -InputObject $Snapshot -Names @('WorkloadType')
        $script:QOdmState.WorkloadObject = $workloadObject
        Reset-QOdmCaches
        return $true
    }
    catch {
        Invalidate-QOdmContext -Reason ('Quest context restoration failed: {0}. Reconnect before performing another write operation.' -f $_.Exception.Message)
        throw
    }
}

function Get-QOdmTaskStatus {
    [CmdletBinding()]
    param([AllowNull()][object]$Task)
    $status = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Task -Names @('Status', 'State', 'TaskStatus'))
    if ([string]::IsNullOrWhiteSpace([string]$status)) { return $null }
    return ([string]$status).Trim()
}

function Test-QOdmTaskIsStoppable {
    param([AllowNull()][object]$Task)
    return ((Get-QOdmTaskStatus -Task $Task) -in @('In Progress', 'Starting'))
}

function Test-QOdmTaskIsActive {
    param([AllowNull()][object]$Task)
    $status = Get-QOdmTaskStatus -Task $Task
    if ([string]::IsNullOrWhiteSpace($status)) { return $false }
    $normalized = ($status -replace '[^A-Za-z]', '').ToLowerInvariant()
    return ($normalized -in @('inprogress','running','starting','queued','stopping'))
}

function Test-QOdmTaskIsStartable {
    [CmdletBinding()]
    param([AllowNull()][object]$Task)

    # Quest remains authoritative for which completed, failed, stopped, or new
    # states can be rerun. The console only blocks states that are already active
    # to avoid duplicate start submissions.
    return (-not (Test-QOdmTaskIsActive -Task $Task))
}

function Invoke-QOdmTaskLifecycleCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Start-OdmTask','Stop-OdmTask')][string]$CommandName,
        [Parameter(Mandatory = $true)][object]$Task
    )

    $command = Get-Command -Name $CommandName -ErrorAction Stop
    $parameters = @{}
    if ($command.Parameters.ContainsKey('Confirm')) { $parameters.Confirm = $false }
    if ($command.Parameters.ContainsKey('ErrorAction')) { $parameters.ErrorAction = 'Stop' }

    $taskParameterName = $null
    foreach ($candidate in @('Tasks','Task','InputObject')) {
        foreach ($availableName in (ConvertTo-QOdmObjectArray -InputObject $command.Parameters.Keys)) {
            if ([string]::Equals([string]$availableName, $candidate, [StringComparison]::OrdinalIgnoreCase)) {
                $taskParameterName = [string]$availableName
                break
            }
        }
        if ($taskParameterName) { break }
    }

    if ($taskParameterName) {
        $parameters[$taskParameterName] = if ([string]::Equals($taskParameterName, 'Tasks', [StringComparison]::OrdinalIgnoreCase)) { @($Task) } else { $Task }
        & $CommandName @parameters | Out-Null
        return
    }

    $acceptsPipeline = $false
    foreach ($parameterMetadata in (ConvertTo-QOdmObjectArray -InputObject $command.Parameters.Values)) {
        foreach ($attribute in (ConvertTo-QOdmObjectArray -InputObject $parameterMetadata.Attributes)) {
            if ($attribute -is [System.Management.Automation.ParameterAttribute] -and ($attribute.ValueFromPipeline -or $attribute.ValueFromPipelineByPropertyName)) {
                $acceptsPipeline = $true
                break
            }
        }
        if ($acceptsPipeline) { break }
    }
    if (-not $acceptsPipeline) {
        throw "$CommandName does not expose a supported Task/Tasks parameter or pipeline input contract."
    }

    $Task | & $CommandName @parameters | Out-Null
}

function Start-QOdmTaskSafely {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Task, [int]$DelaySeconds = 2)

    $taskId = Get-QOdmId $Task
    $taskName = Get-QOdmName $Task
    $status = Get-QOdmTaskStatus -Task $Task
    if (-not (Test-QOdmTaskIsStartable -Task $Task)) {
        return [pscustomobject]@{
            TaskId=$taskId; TaskName=$taskName; PreviousStatus=$status
            StartAttempted=$false; StartSucceeded=$false; Status='SKIPPED_ALREADY_ACTIVE'
            Details='The task is already active, queued, starting, running, or stopping.'
        }
    }
    if (-not (Test-QOdmCommand -Name 'Start-OdmTask')) {
        return [pscustomobject]@{
            TaskId=$taskId; TaskName=$taskName; PreviousStatus=$status
            StartAttempted=$false; StartSucceeded=$false; Status='START_UNSUPPORTED'
            Details='Start-OdmTask is not available in the installed OdmApi module.'
        }
    }

    try {
        Invoke-QOdmTaskLifecycleCommand -CommandName 'Start-OdmTask' -Task $Task
        if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
        return [pscustomobject]@{
            TaskId=$taskId; TaskName=$taskName; PreviousStatus=$status
            StartAttempted=$true; StartSucceeded=$true; Status='START_SUBMITTED'
            Details='Start-OdmTask accepted the task.'
        }
    }
    catch {
        return [pscustomobject]@{
            TaskId=$taskId; TaskName=$taskName; PreviousStatus=$status
            StartAttempted=$true; StartSucceeded=$false; Status='START_FAILED'
            Details=$_.Exception.Message
        }
    }
}

function Stop-QOdmTaskSafely {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Task, [int]$DelaySeconds = 2)

    $taskId = Get-QOdmId $Task
    $taskName = Get-QOdmName $Task
    $status = Get-QOdmTaskStatus -Task $Task
    if (-not (Test-QOdmTaskIsStoppable -Task $Task)) {
        return [pscustomobject]@{ TaskId=$taskId; TaskName=$taskName; PreviousStatus=$status; StopAttempted=$false; StopSucceeded=$false; Status='SKIPPED_NOT_STOPPABLE'; Details="Stop-OdmTask accepts only tasks whose current status is 'In Progress' or 'Starting'." }
    }
    if (-not (Test-QOdmCommand -Name 'Stop-OdmTask')) {
        return [pscustomobject]@{ TaskId=$taskId; TaskName=$taskName; PreviousStatus=$status; StopAttempted=$false; StopSucceeded=$false; Status='STOP_UNSUPPORTED'; Details='Stop-OdmTask is not available in the installed OdmApi module.' }
    }
    try {
        Invoke-QOdmTaskLifecycleCommand -CommandName 'Stop-OdmTask' -Task $Task
        if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
        return [pscustomobject]@{ TaskId=$taskId; TaskName=$taskName; PreviousStatus=$status; StopAttempted=$true; StopSucceeded=$true; Status='STOP_SUBMITTED'; Details='Stop command submitted.' }
    }
    catch {
        return [pscustomobject]@{ TaskId=$taskId; TaskName=$taskName; PreviousStatus=$status; StopAttempted=$true; StopSucceeded=$false; Status='STOP_FAILED'; Details=$_.Exception.Message }
    }
}

function Remove-QOdmTaskSafely {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Task, [bool]$StopRunning = $true, [int]$DeleteRetries = 3, [int]$DelaySeconds = 2)

    if ($DeleteRetries -lt 1) { $DeleteRetries = 1 }
    if ($DelaySeconds -lt 0) { $DelaySeconds = 0 }
    $taskId = Get-QOdmId $Task
    $taskName = Get-QOdmName $Task
    $previousStatus = Get-QOdmTaskStatus -Task $Task
    $details = [System.Collections.Generic.List[string]]::new()
    $stopAttempted = $false
    $stopSucceeded = $false

    if ($StopRunning -and (Test-QOdmTaskIsStoppable -Task $Task)) {
        $stopResult = Stop-QOdmTaskSafely -Task $Task -DelaySeconds $DelaySeconds
        $stopAttempted = [bool](Get-QOdmProperty -InputObject $stopResult -Names @('StopAttempted') -Default $false)
        $stopSucceeded = [bool](Get-QOdmProperty -InputObject $stopResult -Names @('StopSucceeded') -Default $false)
        $stopDetails = [string](Get-QOdmProperty -InputObject $stopResult -Names @('Details'))
        if (-not [string]::IsNullOrWhiteSpace($stopDetails)) { $details.Add($stopDetails) | Out-Null }
    }

    $deleted = $false
    $lastError = $null
    for ($attempt = 1; $attempt -le $DeleteRetries -and -not $deleted; $attempt++) {
        try {
            $command = Get-Command Remove-OdmTask -ErrorAction Stop
            if (-not $command.Parameters.ContainsKey('Tasks')) { throw 'The installed Remove-OdmTask command does not expose the supported Tasks parameter contract.' }
            $parameters = @{ Tasks = @($Task); ErrorAction = 'Stop' }
            if ($command.Parameters.ContainsKey('Confirm')) { $parameters.Confirm = $false }
            Remove-OdmTask @parameters | Out-Null
            $deleted = $true
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $DeleteRetries -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
        }
    }
    if ($deleted) { $details.Add('Delete command completed.') | Out-Null }
    elseif (-not [string]::IsNullOrWhiteSpace($lastError)) { $details.Add($lastError) | Out-Null }

    [pscustomobject]@{
        TaskId=$taskId; TaskName=$taskName; PreviousStatus=$previousStatus
        StopAttempted=$stopAttempted; StopSucceeded=$stopSucceeded; Deleted=$deleted
        Status=if ($deleted) { 'DELETED' } else { 'FAILED' }
        Details=($details.ToArray() -join ' ')
    }
}

function Assert-QOdmConnected {
    if (-not [bool]$script:QOdmState.Connected) { throw 'Not connected to Quest On Demand. Use Connect first.' }
    if (-not [bool]$script:QOdmState.ContextValid) { throw 'The Quest context is invalid because a previous context restoration failed. Reconnect before continuing.' }
}

function Assert-QOdmOrganizationSelected {
    Assert-QOdmConnected
    if ([string]::IsNullOrWhiteSpace([string]$script:QOdmState.OrganizationId)) { throw 'No Quest ODM organization is selected.' }
}

function Assert-QOdmWorkloadSelected {
    Assert-QOdmOrganizationSelected
    if ((Get-QOdmProperty $script:QOdmState @('ContextMode')) -eq 'ActiveDirectory') { throw 'Select a Microsoft 365 project/workload to leave the AD workspace first.' }
    if ([string]::IsNullOrWhiteSpace([string]$script:QOdmState.WorkloadId)) { throw 'No Quest ODM workload is selected.' }
}

function Invalidate-QOdmContext {
    [CmdletBinding()]
    param([AllowNull()][string]$Reason)

    $script:QOdmState.ContextValid = $false
    $script:QOdmState.ContextError = $Reason
    $script:QOdmState.WorkloadId = $null
    $script:QOdmState.WorkloadName = $null
    $script:QOdmState.ProjectObject = $null
    $script:QOdmState.WorkloadType = $null
    $script:QOdmState.WorkloadObject = $null
    Reset-QOdmCaches
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { Add-QOdmWarning -Message $Reason }
}

function New-QOdmReportPath {
    param([AllowNull()][string]$OutputDirectory, [Parameter(Mandatory = $true)][string]$BaseName, [string]$Extension = '.csv')
    $directory = Get-QOdmOutputDirectory -OutputDirectory $OutputDirectory
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    return (Join-Path $directory ("{0}_{1}_{2}{3}" -f $BaseName, $stamp, [Guid]::NewGuid().ToString('N').Substring(0,8), $Extension))
}

function Import-QOdmCsv {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A CSV path is required.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CSV file not found: $Path" }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $parser=New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path,[Text.UTF8Encoding]::new($false,$true),$true)
    $rows=[Collections.Generic.List[object]]::new()
    try {
        $parser.TextFieldType='Delimited';$parser.SetDelimiters(',');$parser.HasFieldsEnclosedInQuotes=$true;$parser.TrimWhiteSpace=$false
        if($parser.EndOfData){throw 'CSV is empty.'}
        $headers=$parser.ReadFields();$seen=@{}
        foreach($header in $headers){
            if([string]::IsNullOrWhiteSpace($header) -or $header -ne $header.Trim()){throw 'CSV headers must be nonblank with no surrounding spaces. Use comma separators.'}
            if($seen.ContainsKey($header)){throw "Duplicate CSV header: $header"};$seen[$header]=$true
        }
        while(-not $parser.EndOfData){
            $line=$parser.LineNumber;$fields=$parser.ReadFields()
            if($fields.Count -ne $headers.Count){throw "CSV row at line $line has $($fields.Count) fields; expected $($headers.Count). Quote values containing commas."}
            $row=[ordered]@{};for($i=0;$i -lt $headers.Count;$i++){$row[$headers[$i]]=$fields[$i]}
            $rows.Add([pscustomobject]$row)|Out-Null
        }
        if(-not $rows.Count){throw 'CSV contains headers but no data rows.'}
        return $rows.ToArray()
    } finally {$parser.Close();$parser.Dispose()}
}

function Get-QOdmCsvHeaders {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Rows)
    $items = ConvertTo-QOdmObjectArray -InputObject $Rows
    if ($items.Count -eq 0 -or $null -eq $items[0]) { return @() }
    return (ConvertTo-QOdmObjectArray -InputObject $items[0].PSObject.Properties.Name)
}

function Test-QOdmHeaderMatch {
    param([Parameter(Mandatory = $true)][string[]]$Headers, [Parameter(Mandatory = $true)][string]$Candidate)
    foreach ($header in @($Headers)) { if ([string]::Equals($header, $Candidate, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

function Assert-QOdmCsvHasAnyHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Headers, [Parameter(Mandatory = $true)][string[]]$AcceptedHeaders, [Parameter(Mandatory = $true)][string]$Description)
    foreach ($accepted in @($AcceptedHeaders)) { if (Test-QOdmHeaderMatch -Headers $Headers -Candidate $accepted) { return } }
    throw "CSV must contain $Description. Accepted headers: $($AcceptedHeaders -join ', ')."
}

function Assert-QOdmCsvHasAllHeaders {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Headers, [Parameter(Mandatory = $true)][string[]]$RequiredHeaders)
    $missing = @($RequiredHeaders | Where-Object { -not (Test-QOdmHeaderMatch -Headers $Headers -Candidate $_) })
    if ($missing.Count -gt 0) { throw "CSV is missing required column(s): $($missing -join ', ')." }
}

function Get-QOdmIdentityColumnNames { return @('SourceUPN','SourceUserPrincipalName','SourceUpn','UPN','UserPrincipalName','SourceEmail','Email') }

function Test-QOdmCsvIdentityHeaders {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Headers)
    foreach ($accepted in @(Get-QOdmIdentityColumnNames)) { if (Test-QOdmHeaderMatch -Headers $Headers -Candidate $accepted) { return $true } }
    return $false
}

function Assert-QOdmCsvHasIdentityHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Headers)
    Assert-QOdmCsvHasAnyHeader -Headers $Headers -AcceptedHeaders @(Get-QOdmIdentityColumnNames) -Description 'a supported source identity column'
}

function Get-QOdmUpnFromRow {
    param([Parameter(Mandatory = $true)][object]$Row)
    foreach ($column in @(Get-QOdmIdentityColumnNames)) {
        $value = Get-QOdmProperty -InputObject $Row -Names @($column)
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return (Normalize-QOdmUpn ([string]$value)) }
    }
    return $null
}

function Export-QOdmCsv {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Rows, [Parameter(Mandatory = $true)][string]$Path)
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-QOdmDirectoryWritable -Path $directory -Create $true)) { throw "The report directory is unavailable or not writable: $directory" }
    $items = ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $Rows) | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
        [System.IO.File]::WriteAllText($Path, '', $encoding)
    }
    else { $items | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 }
    return $Path
}

function Get-QOdmSafeCount {
    param([AllowNull()][object]$Value)
    return (ConvertTo-QOdmObjectArray -InputObject $Value).Count
}

function New-QOdmErrorDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$Operation,
        [AllowNull()][string]$Phase
    )

    $invocation = $ErrorRecord.InvocationInfo
    $innerMessages = [System.Collections.Generic.List[string]]::new()
    $inner = $ErrorRecord.Exception.InnerException
    while ($null -ne $inner) {
        $innerMessages.Add(('{0}: {1}' -f $inner.GetType().FullName, $inner.Message)) | Out-Null
        $inner = $inner.InnerException
    }
    $commandName = $null
    if ($null -ne $invocation -and $null -ne $invocation.MyCommand) { $commandName = [string]$invocation.MyCommand.Name }
    $moduleName = $null
    $moduleVersion = $null
    try {
        if ($null -ne $invocation -and $null -ne $invocation.MyCommand -and $null -ne $invocation.MyCommand.Module) {
            $moduleName = [string]$invocation.MyCommand.Module.Name
            $moduleVersion = [string]$invocation.MyCommand.Module.Version
        }
    }
    catch { }

    [pscustomobject]@{
        DiagnosticId          = [Guid]::NewGuid().ToString()
        Timestamp             = Get-Date
        Operation             = $Operation
        Phase                 = $Phase
        Message               = $ErrorRecord.Exception.Message
        ExceptionType         = $ErrorRecord.Exception.GetType().FullName
        FullyQualifiedErrorId = $ErrorRecord.FullyQualifiedErrorId
        CategoryInfo          = [string]$ErrorRecord.CategoryInfo
        CommandName           = $commandName
        CommandModule         = $moduleName
        CommandModuleVersion  = $moduleVersion
        ScriptName            = if ($null -ne $invocation) { [string]$invocation.ScriptName } else { $null }
        ScriptLineNumber      = if ($null -ne $invocation) { [int]$invocation.ScriptLineNumber } else { 0 }
        OffsetInLine          = if ($null -ne $invocation) { [int]$invocation.OffsetInLine } else { 0 }
        PositionMessage       = if ($null -ne $invocation) { [string]$invocation.PositionMessage } else { $null }
        ScriptStackTrace      = $ErrorRecord.ScriptStackTrace
        InnerExceptions       = $innerMessages.ToArray()
        ExceptionText         = $ErrorRecord.Exception.ToString()
        PowerShellVersion     = [string]$PSVersionTable.PSVersion
        PowerShellEdition     = [string]$PSVersionTable.PSEdition
        Is64BitProcess        = [Environment]::Is64BitProcess
        OrganizationId        = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { $script:QOdmState.OrganizationId } else { $null }
        ProjectId             = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { $script:QOdmState.ProjectId } else { $null }
        WorkloadId            = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { $script:QOdmState.WorkloadId } else { $null }
        OdmApiVersion         = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { $script:QOdmState.ModuleVersion } else { $null }
        OdmApiPath            = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { $script:QOdmState.ModulePath } else { $null }
        OdmApiPreloadStatus   = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { [string](Get-QOdmProperty -InputObject $script:QOdmState.ModulePreload -Names @('Status') -Default 'NOT_RUN') } else { 'NOT_RUN' }
        OdmApiRuntimeProbeStatus = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { [string]$script:QOdmState.ModuleRuntimeProbeStatus } else { 'NOT_RUN' }
        OdmApiRuntimeProbeDetails = if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { [string](Get-QOdmProperty -InputObject $script:QOdmState.ModuleRuntimeProbe -Names @('Details','Error')) } else { $null }
    }
}

function Format-QOdmDiagnosticText {
    [CmdletBinding()]
    param([AllowNull()][object]$Diagnostic)
    if ($null -eq $Diagnostic) { return $null }
    $lines = @(
        ('Diagnostic ID: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('DiagnosticId'))),
        ('Operation: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('Operation'))),
        ('Phase: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('Phase'))),
        ('Message: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('Message'))),
        ('Exception: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('ExceptionType'))),
        ('FullyQualifiedErrorId: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('FullyQualifiedErrorId'))),
        ('Category: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('CategoryInfo'))),
        ('Command: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('CommandName'))),
        ('Command module: {0} {1}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('CommandModule')), (Get-QOdmProperty -InputObject $Diagnostic -Names @('CommandModuleVersion'))),
        ('Source: {0}, line {1}, column {2}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('ScriptName')), (Get-QOdmProperty -InputObject $Diagnostic -Names @('ScriptLineNumber')), (Get-QOdmProperty -InputObject $Diagnostic -Names @('OffsetInLine'))),
        ('Position: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('PositionMessage'))),
        ('Script stack: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('ScriptStackTrace'))),
        ('Inner exceptions: {0}' -f ((ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $Diagnostic -Names @('InnerExceptions') -Default @())) -join ' | ')),
        ('Quest context: Organization={0}; Project={1}; Workload={2}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('OrganizationId')), (Get-QOdmProperty -InputObject $Diagnostic -Names @('ProjectId')), (Get-QOdmProperty -InputObject $Diagnostic -Names @('WorkloadId'))),
        ('OdmApi: {0}; {1}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('OdmApiVersion')), (Get-QOdmProperty -InputObject $Diagnostic -Names @('OdmApiPath'))),
        ('OdmApi preload/probe: {0} / {1}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('OdmApiPreloadStatus')), (Get-QOdmProperty -InputObject $Diagnostic -Names @('OdmApiRuntimeProbeStatus'))),
        ('OdmApi probe details: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('OdmApiRuntimeProbeDetails'))),
        ('PowerShell: {0} ({1}); 64-bit={2}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('PowerShellVersion')), (Get-QOdmProperty -InputObject $Diagnostic -Names @('PowerShellEdition')), (Get-QOdmProperty -InputObject $Diagnostic -Names @('Is64BitProcess'))),
        ('Exception text: {0}' -f (Get-QOdmProperty -InputObject $Diagnostic -Names @('ExceptionText')))
    )
    return ($lines -join "`r`n")
}

function New-QOdmOperationResult {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][bool]$Success,
        [AllowNull()][object]$Data,
        [AllowNull()][string]$Message,
        [AllowNull()][string]$Error,
        [AllowNull()][string]$Details,
        [AllowNull()][object]$Reports,
        [AllowNull()][object]$Warnings,
        [AllowNull()][object]$Diagnostic
    )

    [pscustomobject]@{
        Operation    = $Operation
        Success      = $Success
        Message      = $Message
        Error        = $Error
        Details      = $Details
        Data         = $Data
        Reports      = (ConvertTo-QOdmObjectArray -InputObject $Reports)
        Warnings     = (ConvertTo-QOdmObjectArray -InputObject $Warnings)
        DiagnosticId = Get-QOdmProperty -InputObject $Diagnostic -Names @('DiagnosticId')
        Phase        = Get-QOdmProperty -InputObject $Diagnostic -Names @('Phase') -Default $(if (Get-Variable -Name QOdmState -Scope Script -ErrorAction SilentlyContinue) { $script:QOdmState.CurrentPhase } else { $null })
        Diagnostic   = $Diagnostic
        Timestamp    = Get-Date
    }
}
