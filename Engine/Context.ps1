function ConvertTo-QOdmOrganizationView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Organization,
        [AllowNull()][string]$SourceCommand
    )

    if ($Organization -is [string] -or $Organization -is [Guid]) {
        $id = ([string]$Organization).Trim()
        $name = $id
    }
    else {
        $id = [string](Get-QOdmProperty -InputObject $Organization -Names @(
            'Id','ID','OrganizationId','organizationId','OrganizationID',
            'QuestOrganizationId','questOrganizationId','TenantOrganizationId'
        ))
        $name = [string](Get-QOdmProperty -InputObject $Organization -Names @(
            'OrganizationDisplayName','organizationDisplayName','DisplayName','displayName',
            'OrganizationName','organizationName','Name','FriendlyName','friendlyName'
        ))
        $id = $id.Trim()
        $name = $name.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
    }

    $parsedId = [Guid]::Empty
    $validGuid = $false
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        $validGuid = [Guid]::TryParse($id, [ref]$parsedId)
        if ($validGuid) { $id = $parsedId.ToString() }
    }

    [pscustomobject]@{
        Id            = $id
        Name          = $name
        DisplayText   = if ($id -and $name -and -not [string]::Equals($name, $id, [StringComparison]::OrdinalIgnoreCase)) { "$name [$id]" } else { $id }
        SourceCommand = $SourceCommand
        ValidGuid     = $validGuid
    }
}

function ConvertTo-QOdmProjectView {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Project)

    $id = Get-QOdmId $Project
    $name = Get-QOdmName $Project
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
    $type = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Project -Names @('Type','ProjectType','WorkloadType'))
    $sourceTenant = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Project -Names @(
        'SourceTenantDefaultDomainName','SourceTenantPrimaryDomainName','SourceTenantDomainName',
        'SourceTenant','SourceTenantName','Source'
    ))
    $targetTenant = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Project -Names @(
        'TargetTenantDefaultDomainName','TargetTenantPrimaryDomainName','TargetTenantDomainName',
        'TargetTenant','TargetTenantName','Target'
    ))

    $displayText = $name
    if (-not [string]::IsNullOrWhiteSpace($type)) { $displayText = "$displayText - $type" }
    if (-not [string]::IsNullOrWhiteSpace($sourceTenant) -or -not [string]::IsNullOrWhiteSpace($targetTenant)) {
        $tenantText = ('{0} -> {1}' -f $sourceTenant, $targetTenant).Trim()
        if (-not [string]::IsNullOrWhiteSpace($tenantText) -and $tenantText -ne '->') { $displayText = "$displayText [$tenantText]" }
    }

    [pscustomobject]@{
        Id           = $id
        Name         = $name
        Type         = $type
        SourceTenant = $sourceTenant
        TargetTenant = $targetTenant
        DisplayText  = $displayText
    }
}

function ConvertTo-QOdmWorkloadView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Workload,
        [bool]$IsProjectContext = $false
    )

    $id = Get-QOdmId $Workload
    $name = Get-QOdmName $Workload
    $type = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Workload -Names @('WorkloadType','Type','ProjectType'))
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }

    $displayText = $name
    if ($IsProjectContext) {
        $displayText = if ($type) { "$name - Project context ($type)" } else { "$name - Project context" }
    }
    elseif ($type) {
        $displayText = "$name - $type"
    }

    [pscustomobject]@{
        Id               = $id
        Name             = $name
        Type             = $type
        IsProjectContext = $IsProjectContext
        ContextKind      = if ($IsProjectContext) { 'Project' } else { 'Workload' }
        DisplayText      = $displayText
    }
}

function Get-QOdmContextState {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Connected                = [bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('Connected') -Default $false)
        ContextMode              = [string](Get-QOdmProperty $script:QOdmState @('ContextMode') 'Microsoft365')
        ContextEpoch             = [string](Get-QOdmProperty $script:QOdmState @('ContextEpoch'))
        ContextValid             = [bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('ContextValid') -Default $true)
        ContextError             = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ContextError')
        Region                   = Get-QOdmProperty -InputObject $script:QOdmState -Names @('Region')
        OrganizationId           = Get-QOdmProperty -InputObject $script:QOdmState -Names @('OrganizationId')
        OrganizationName         = Get-QOdmProperty -InputObject $script:QOdmState -Names @('OrganizationName')
        ProjectId                = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ProjectId')
        ProjectName              = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ProjectName')
        WorkloadId               = Get-QOdmProperty -InputObject $script:QOdmState -Names @('WorkloadId')
        WorkloadName             = Get-QOdmProperty -InputObject $script:QOdmState -Names @('WorkloadName')
        WorkloadType             = Get-QOdmProperty -InputObject $script:QOdmState -Names @('WorkloadType')
        ModuleVersion            = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleVersion')
        ModulePath               = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModulePath')
        ModulePreload            = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModulePreload')
        ModulePreloadStatus      = [string](Get-QOdmProperty -InputObject (Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModulePreload')) -Names @('Status') -Default 'NOT_RUN')
        ModuleRuntimeProbe       = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleRuntimeProbe')
        ModuleRuntimeProbeStatus = [string](Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleRuntimeProbeStatus') -Default 'NOT_RUN')
        ModuleScopeValidated     = [bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleScopeValidated') -Default $false)
        ApiSurface               = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ApiSurface')
        ConnectedAt              = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ConnectedAt')
        LastRefresh              = Get-QOdmProperty -InputObject $script:QOdmState -Names @('LastRefresh')
        ConsoleVersion           = [string](Get-QOdmProperty -InputObject $script:QOdmState -Names @('ConsoleVersion') -Default '1.1.0-rc.2')
        SafeMode                 = [bool](Get-QOdmProperty -InputObject $script:QOdmState -Names @('SafeMode') -Default $true)
        SafeModeReason           = [string](Get-QOdmProperty -InputObject $script:QOdmState -Names @('SafeModeReason') -Default 'Safe Mode enabled.')
        SafeModeChangedAt        = Get-QOdmProperty -InputObject $script:QOdmState -Names @('SafeModeChangedAt')
        SafeModeChangedBy        = Get-QOdmProperty -InputObject $script:QOdmState -Names @('SafeModeChangedBy')
        ReadinessCompletedAt     = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ReadinessCompletedAt')
        BlockedFeatures          = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $script:QOdmState -Names @('BlockedFeatures') -Default @())
    }
}

function Expand-QOdmDiscoveryItems {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputItems,
        [int]$Depth = 0
    )

    $itemBuffer = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (ConvertTo-QOdmObjectArray -InputObject $InputItems)) {
        if ($null -ne $item) { $itemBuffer.Add($item) | Out-Null }
    }
    $items = $itemBuffer.ToArray()
    if ($Depth -ge 4 -or $items.Count -ne 1) { return $items }

    $candidate = $items[0]
    if ($candidate -is [string] -or $candidate -is [Guid]) { return $items }

    # Some API wrappers return a collection as a single pipeline object. Expand it
    # explicitly before evaluating named envelope properties.
    if (($candidate -is [System.Collections.IEnumerable]) -and
        -not ($candidate -is [string]) -and
        -not ($candidate -is [System.Collections.IDictionary])) {
        $enumerated = ConvertTo-QOdmObjectArray -InputObject $candidate
        if ($enumerated.Count -gt 0 -and -not ($enumerated.Count -eq 1 -and [object]::ReferenceEquals($enumerated[0], $candidate))) {
            return $enumerated
        }
    }

    foreach ($propertyName in @('Organizations','organizations','Items','items','Value','value','Results','results','Data','data')) {
        $nested = Get-QOdmProperty -InputObject $candidate -Names @($propertyName)
        if ($null -eq $nested -or [object]::ReferenceEquals($nested, $candidate)) { continue }
        $expanded = ConvertTo-QOdmObjectArray -InputObject (Expand-QOdmDiscoveryItems -InputItems $nested -Depth ($Depth + 1))
        # The presence of a recognized envelope property is authoritative even
        # when that property contains an empty collection. Falling through would
        # incorrectly treat the envelope itself as an organization record.
        return $expanded
    }

    return $items
}

function Add-QOdmOrganizationViewToMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][object]$View
    )

    $id = [string](Get-QOdmProperty -InputObject $View -Names @('Id'))
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    $key = $id.ToLowerInvariant()

    if (-not $Map.ContainsKey($key)) {
        $Map[$key] = $View
        return
    }

    $existing = $Map[$key]
    $existingName = [string](Get-QOdmProperty -InputObject $existing -Names @('Name'))
    $newName = [string](Get-QOdmProperty -InputObject $View -Names @('Name'))
    $existingHasFriendlyName = -not [string]::IsNullOrWhiteSpace($existingName) -and -not [string]::Equals($existingName, $id, [StringComparison]::OrdinalIgnoreCase)
    $newHasFriendlyName = -not [string]::IsNullOrWhiteSpace($newName) -and -not [string]::Equals($newName, $id, [StringComparison]::OrdinalIgnoreCase)

    if (-not $existingHasFriendlyName -and $newHasFriendlyName) { $Map[$key] = $View }
}

function Get-QOdmOrganizationsForConsole {
    [CmdletBinding()]
    param()

    $commands = @('Get-OdmOrganizations','Get-OdmActiveOrganizations')
    $attempts = [System.Collections.Generic.List[object]]::new()
    $organizationMap = @{}
    $supported = $false

    foreach ($commandName in $commands) {
        $available = Test-QOdmCommand -Name $commandName
        if (-not $available) {
            $attempts.Add([pscustomobject]@{
                Command=$commandName; Available=$false; Succeeded=$false; RawCount=0; ExpandedCount=0
                ConvertedCount=0; InvalidIdCount=0; Error='Command not available.'
            }) | Out-Null
            continue
        }

        $supported = $true
        try {
            $raw = ConvertTo-QOdmObjectArray -InputObject (Invoke-QOdmSupportedCommandArray -CommandName $commandName)
            $expanded = ConvertTo-QOdmObjectArray -InputObject (Expand-QOdmDiscoveryItems -InputItems $raw)
            $convertedCount = 0
            $invalidIdCount = 0

            foreach ($organization in $expanded) {
                if ($null -eq $organization) { continue }
                $view = ConvertTo-QOdmOrganizationView -Organization $organization -SourceCommand $commandName
                if (-not [bool](Get-QOdmProperty -InputObject $view -Names @('ValidGuid') -Default $false)) {
                    $invalidIdCount++
                    continue
                }
                Add-QOdmOrganizationViewToMap -Map $organizationMap -View $view
                $convertedCount++
            }

            $attempts.Add([pscustomobject]@{
                Command=$commandName; Available=$true; Succeeded=$true; RawCount=$raw.Count; ExpandedCount=$expanded.Count
                ConvertedCount=$convertedCount; InvalidIdCount=$invalidIdCount; Error=$null
            }) | Out-Null
        }
        catch {
            $attempts.Add([pscustomobject]@{
                Command=$commandName; Available=$true; Succeeded=$false; RawCount=0; ExpandedCount=0
                ConvertedCount=0; InvalidIdCount=0; Error=$_.Exception.Message
            }) | Out-Null
        }
    }

    $items = ConvertTo-QOdmObjectArray -InputObject ($organizationMap.Values | Sort-Object Name, Id)
    $sourceCommands = ConvertTo-QOdmObjectArray -InputObject ($attempts.ToArray() | Where-Object { $_.Succeeded -and $_.ConvertedCount -gt 0 } | Select-Object -ExpandProperty Command -Unique)
    $attemptErrors = ConvertTo-QOdmObjectArray -InputObject ($attempts.ToArray() | Where-Object { $_.Available -and -not $_.Succeeded } | ForEach-Object { '{0}: {1}' -f $_.Command, $_.Error })
    $warning = $null
    if ($items.Count -eq 0) {
        if (-not $supported) {
            $warning = 'This OdmApi version does not expose an organization-list command. Enter the organization GUID manually.'
        }
        elseif ($attemptErrors.Count -gt 0) {
            $warning = 'Connected, but organization discovery returned no usable organizations. Enter the organization GUID manually. Discovery errors: {0}' -f ($attemptErrors -join ' | ')
        }
        else {
            $warning = 'Connected, but the Quest API returned no usable organizations. Enter the organization GUID manually.'
        }
    }

    [pscustomobject]@{
        Items          = $items
        SourceCommand  = ($sourceCommands -join ', ')
        SourceCommands = $sourceCommands
        Supported      = $supported
        Attempts       = $attempts.ToArray()
        Warning        = $warning
    }
}

function Get-QOdmProjectsForConsole {
    [CmdletBinding()]
    param()

    $raw = @()
    $views = [System.Collections.Generic.List[object]]::new()
    $rawById = @{}
    $invalidIdCount = 0
    $errorText = $null
    $succeeded = $false

    try {
        $raw = ConvertTo-QOdmObjectArray -InputObject (Expand-QOdmDiscoveryItems -InputItems (Get-QOdmProjectsAll))
        $succeeded = $true
        foreach ($project in $raw) {
            if ($null -eq $project) { continue }
            $id = [string](Get-QOdmId $project)
            if ([string]::IsNullOrWhiteSpace($id)) { $invalidIdCount++; continue }
            $key = $id.ToLowerInvariant()
            if ($rawById.ContainsKey($key)) { continue }
            $rawById[$key] = $project
            $views.Add((ConvertTo-QOdmProjectView -Project $project)) | Out-Null
        }
    }
    catch { $errorText = $_.Exception.Message }

    $items = ConvertTo-QOdmObjectArray -InputObject ($views.ToArray() | Sort-Object Name, Id)
    $warning = $null
    if (-not $succeeded) {
        $warning = 'The organization was selected, but the project list could not be loaded: {0}' -f $errorText
    }
    elseif ($items.Count -eq 0) {
        $warning = 'The organization was selected, but no supported Quest ODM projects were returned.'
    }

    [pscustomobject]@{
        Items          = $items
        RawById        = $rawById
        Succeeded      = $succeeded
        RawCount       = $raw.Count
        ConvertedCount = $items.Count
        InvalidIdCount = $invalidIdCount
        Error          = $errorText
        Warning        = $warning
    }
}

function Get-QOdmWorkloadsForConsole {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Project)

    $projectId = [string](Get-QOdmId $Project)
    if ([string]::IsNullOrWhiteSpace($projectId)) {
        throw 'The selected project does not expose an ID, so workload discovery cannot continue safely.'
    }
    $raw = @()
    $views = [System.Collections.Generic.List[object]]::new()
    $rawById = @{}
    $invalidIdCount = 0
    $errorText = $null
    $succeeded = $false

    try {
        $raw = ConvertTo-QOdmObjectArray -InputObject (Expand-QOdmDiscoveryItems -InputItems (Get-QOdmProjectWorkloads -Project $Project))
        $succeeded = $true
        foreach ($workload in $raw) {
            if ($null -eq $workload) { continue }
            $id = [string](Get-QOdmId $workload)
            if ([string]::IsNullOrWhiteSpace($id)) { $invalidIdCount++; continue }
            if ([string]::Equals($id, $projectId, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $key = $id.ToLowerInvariant()
            if ($rawById.ContainsKey($key)) { continue }
            $rawById[$key] = $workload
            $views.Add((ConvertTo-QOdmWorkloadView -Workload $workload)) | Out-Null
        }
    }
    catch { $errorText = $_.Exception.Message }

    # Every selected project is itself a valid context. Keep it available even when the
    # project type does not expose child workloads or the child-workload read fails.
    $rawById[$projectId.ToLowerInvariant()] = $Project
    $views.Add((ConvertTo-QOdmWorkloadView -Workload $Project -IsProjectContext $true)) | Out-Null

    $items = ConvertTo-QOdmObjectArray -InputObject ($views.ToArray() | Sort-Object IsProjectContext, Type, Name, Id)
    $warning = $null
    if (-not $succeeded) {
        $warning = 'The project was selected, but child workload discovery failed. The root project context remains available. Details: {0}' -f $errorText
    }

    [pscustomobject]@{
        Items          = $items
        RawById        = $rawById
        Succeeded      = $succeeded
        RawCount       = $raw.Count
        ChildCount     = [Math]::Max(0, $items.Count - 1)
        ConvertedCount = $items.Count
        InvalidIdCount = $invalidIdCount
        Error          = $errorText
        Warning        = $warning
    }
}

function Connect-QOdmConsole {
    [CmdletBinding()]
    param(
        [ValidateSet('US','EU','AU','CA','UK','us','eu','au','ca','uk')]
        [string]$Region = 'US'
    )

    Set-QOdmOperationPhase -Phase 'Loading preloaded OdmApi module'
    try {
        $module = Import-QOdmApiModule
        Initialize-QOdmState -PreserveModule $true
        $script:QOdmState.ModuleVersion = [string]$module.Version
        $script:QOdmState.ModulePath = [string]$module.Path

        Set-QOdmOperationPhase -Phase 'Validating OdmApi command surface'
        $apiSurface = Get-QOdmApiSurfaceReport
        Assert-QOdmApiSurface -Report $apiSurface
        $script:QOdmState.ApiSurface = $apiSurface
        $script:QOdmState.ModuleRuntimeProbe = Get-QOdmProperty -InputObject $apiSurface -Names @('ModuleRuntimeProbe')
        $script:QOdmState.ModuleRuntimeProbeStatus = [string](Get-QOdmProperty -InputObject $apiSurface -Names @('ModuleRuntimeProbeStatus') -Default 'NOT_RUN')
        $script:QOdmState.ModuleScopeValidated = [bool](Get-QOdmProperty -InputObject $apiSurface -Names @('ModuleScopeValidated') -Default $false)

        Set-QOdmOperationPhase -Phase 'Authenticating to Quest On Demand'
        $null = Invoke-QOdmSupportedCommand -CommandName 'Connect-OdmService' -Parameters @{ Region = $Region.ToLowerInvariant() } -RequiredParameters @('Region')

        $script:QOdmState.Connected = $true
        $script:QOdmState.ContextMode = 'Microsoft365'
    $script:QOdmState.ContextEpoch = [guid]::NewGuid().ToString()
    $script:QOdmAdPreview=$null
    $script:QOdmState.ContextValid = $true
        $script:QOdmState.ContextError = $null
        $script:QOdmState.Region = $Region.ToUpperInvariant()
        $script:QOdmState.ConnectedAt = Get-Date

        Set-QOdmOperationPhase -Phase 'Loading Quest organizations'
        $organizationResult = Get-QOdmOrganizationsForConsole
        $organizations = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $organizationResult -Names @('Items') -Default @())
        $organizationWarning = [string](Get-QOdmProperty -InputObject $organizationResult -Names @('Warning'))
        if (-not [string]::IsNullOrWhiteSpace($organizationWarning)) { Add-QOdmWarning -Message $organizationWarning }

        Set-QOdmOperationPhase -Phase 'Connected'
        [pscustomobject]@{
            State                       = Get-QOdmContextState
            Organizations               = $organizations
            SupportsOrganizationBrowser = [bool](Get-QOdmProperty -InputObject $organizationResult -Names @('Supported') -Default $false)
            OrganizationBrowserCommand  = [string](Get-QOdmProperty -InputObject $organizationResult -Names @('SourceCommand'))
            OrganizationBrowserWarning  = $organizationWarning
            OrganizationDiscovery       = $organizationResult
            SupportsTemplates           = [bool](Test-QOdmCommand -Name 'Get-OdmTaskTemplates')
            ApiSurface                  = $apiSurface
        }
    }
    catch {
        Initialize-QOdmState -PreserveModule $true
        throw
    }
}

function Disconnect-QOdmConsole {
    [CmdletBinding()]
    param()

    Set-QOdmOperationPhase -Phase 'Disconnecting'
    if (Test-QOdmCommand -Name 'Disconnect-OdmService') {
        try { $null = Invoke-QOdmSupportedCommand -CommandName 'Disconnect-OdmService' }
        catch { Add-QOdmWarning -Message ('Quest disconnect warning: {0}' -f $_.Exception.Message) }
    }

    Initialize-QOdmState -PreserveModule $true
    Get-QOdmContextState
}

function Select-QOdmOrganizationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OrganizationId,
        [string]$OrganizationName
    )

    Assert-QOdmConnected
    Set-QOdmOperationPhase -Phase 'Selecting Quest organization'
    $organizationIdText = $OrganizationId.Trim()
    $parsedGuid = [Guid]::Empty
    if (-not [Guid]::TryParse($organizationIdText, [ref]$parsedGuid)) {
        throw "OrganizationId must be a GUID. Value supplied: $OrganizationId"
    }

    $selectParameters = @{ OrganizationId = $parsedGuid }
    $optionalParameters = @()
    $selectCommand = Get-Command -Name 'Select-OdmOrganization' -ErrorAction Stop
    if ($selectCommand.Parameters.ContainsKey('SkipProjectCheck')) {
        $selectParameters.SkipProjectCheck = $true
        $optionalParameters += 'SkipProjectCheck'
    }
    $null = Invoke-QOdmSupportedCommand -CommandName 'Select-OdmOrganization' -Parameters $selectParameters -RequiredParameters @('OrganizationId') -OptionalParameters $optionalParameters

    $resolvedOrganizationName = $OrganizationName
    if ([string]::IsNullOrWhiteSpace($resolvedOrganizationName)) { $resolvedOrganizationName = $parsedGuid.ToString() }

    $script:QOdmState.ContextMode = 'Microsoft365'
    $script:QOdmState.ContextEpoch = [guid]::NewGuid().ToString()
    $script:QOdmAdPreview=$null
    $script:QOdmState.ContextValid = $true
    $script:QOdmState.ContextError = $null
    $script:QOdmState.OrganizationId = $parsedGuid.ToString()
    $script:QOdmState.OrganizationName = $resolvedOrganizationName
    $script:QOdmState.ProjectId = $null
    $script:QOdmState.ProjectName = $null
    $script:QOdmState.ProjectObject = $null
    $script:QOdmState.WorkloadId = $null
    $script:QOdmState.WorkloadName = $null
    $script:QOdmState.WorkloadType = $null
    $script:QOdmState.WorkloadObject = $null
    $script:QOdmState.Projects = @{}
    $script:QOdmState.Workloads = @{}
    Reset-QOdmCaches
    Enable-QOdmSafeMode -Reason 'Safe Mode reset because the organization changed.' | Out-Null

    Set-QOdmOperationPhase -Phase 'Loading Quest projects'
    $discovery = Get-QOdmProjectsForConsole
    $rawById = Get-QOdmProperty -InputObject $discovery -Names @('RawById') -Default @{}
    foreach ($key in (ConvertTo-QOdmObjectArray -InputObject $rawById.Keys)) {
        $rawProject = $rawById[$key]
        $id = Get-QOdmId $rawProject
        if (-not [string]::IsNullOrWhiteSpace($id)) { $script:QOdmState.Projects[$id] = $rawProject }
    }

    $projectWarning = [string](Get-QOdmProperty -InputObject $discovery -Names @('Warning'))
    if (-not [string]::IsNullOrWhiteSpace($projectWarning)) { Add-QOdmWarning -Message $projectWarning }

    [pscustomobject]@{
        State            = Get-QOdmContextState
        Projects         = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $discovery -Names @('Items') -Default @())
        ProjectWarning   = $projectWarning
        ProjectDiscovery = $discovery
    }
}

function Select-QOdmProjectContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProjectId)

    Assert-QOdmOrganizationSelected
    Set-QOdmOperationPhase -Phase 'Selecting Quest project'
    $project = Resolve-QOdmProjectById -ProjectId $ProjectId
    if ($null -eq $project) { throw "Project not found: $ProjectId" }

    Select-QOdmProjectSafe -Project $project -ProjectId $ProjectId

    $script:QOdmState.ContextMode = 'Microsoft365'
    $script:QOdmState.ContextEpoch = [guid]::NewGuid().ToString()
    $script:QOdmAdPreview=$null
    $script:QOdmState.ContextValid = $true
    $script:QOdmState.ContextError = $null
    $script:QOdmState.ProjectId = $ProjectId
    $script:QOdmState.ProjectName = Get-QOdmName $project
    $script:QOdmState.ProjectObject = $project
    $script:QOdmState.WorkloadId = $null
    $script:QOdmState.WorkloadName = $null
    $script:QOdmState.WorkloadType = $null
    $script:QOdmState.WorkloadObject = $null
    $script:QOdmState.Workloads = @{}
    Reset-QOdmCaches
    Enable-QOdmSafeMode -Reason 'Safe Mode reset because the project changed.' | Out-Null

    Set-QOdmOperationPhase -Phase 'Loading project workloads'
    $discovery = Get-QOdmWorkloadsForConsole -Project $project
    $rawById = Get-QOdmProperty -InputObject $discovery -Names @('RawById') -Default @{}
    foreach ($key in (ConvertTo-QOdmObjectArray -InputObject $rawById.Keys)) {
        $rawWorkload = $rawById[$key]
        $id = Get-QOdmId $rawWorkload
        if (-not [string]::IsNullOrWhiteSpace($id)) { $script:QOdmState.Workloads[$id] = $rawWorkload }
    }

    $workloadWarning = [string](Get-QOdmProperty -InputObject $discovery -Names @('Warning'))
    if (-not [string]::IsNullOrWhiteSpace($workloadWarning)) { Add-QOdmWarning -Message $workloadWarning }

    [pscustomobject]@{
        State             = Get-QOdmContextState
        Workloads         = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $discovery -Names @('Items') -Default @())
        WorkloadWarning   = $workloadWarning
        WorkloadDiscovery = $discovery
    }
}

function Select-QOdmWorkloadContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WorkloadId)

    Assert-QOdmOrganizationSelected
    Set-QOdmOperationPhase -Phase 'Selecting Quest workload'

    $workload = $null
    if ($script:QOdmState.Workloads.ContainsKey($WorkloadId)) { $workload = $script:QOdmState.Workloads[$WorkloadId] }
    $isRootProject = [string]::Equals($WorkloadId, [string]$script:QOdmState.ProjectId, [StringComparison]::OrdinalIgnoreCase)

    if ($isRootProject) {
        if ($null -eq $workload) { $workload = Resolve-QOdmProjectById -ProjectId $WorkloadId }
        if ($null -eq $workload) { throw "Project context not found: $WorkloadId" }
        Select-QOdmProjectSafe -Project $workload -ProjectId $WorkloadId
    }
    else {
        if ($null -eq $workload) {
            $matches = Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmProjectWorkload' -Parameters @{ ProjectWorkloadId=$WorkloadId } -RequiredParameters @('ProjectWorkloadId')
            if ($matches.Count -gt 1) { throw "Workload ID '$WorkloadId' returned more than one result." }
            if ($matches.Count -eq 1) { $workload = $matches[0] }
        }
        if ($null -eq $workload) { throw "Workload not found: $WorkloadId" }
        Select-QOdmProjectWorkloadSafe -Workload $workload -ProjectWorkloadId $WorkloadId
    }

    $script:QOdmState.ContextMode = 'Microsoft365'
    $script:QOdmState.ContextEpoch = [guid]::NewGuid().ToString()
    $script:QOdmAdPreview=$null
    $script:QOdmState.ContextValid = $true
    $script:QOdmState.ContextError = $null
    $script:QOdmState.WorkloadId = $WorkloadId
    $script:QOdmState.WorkloadName = Get-QOdmName $workload
    if ([string]::IsNullOrWhiteSpace([string]$script:QOdmState.WorkloadName)) { $script:QOdmState.WorkloadName = $WorkloadId }
    $script:QOdmState.WorkloadType = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $workload -Names @('WorkloadType','Type','ProjectType'))
    $script:QOdmState.WorkloadObject = $workload
    Reset-QOdmCaches
    Enable-QOdmSafeMode -Reason 'Safe Mode reset because the workload changed.' | Out-Null

    Get-QOdmContextState
}
