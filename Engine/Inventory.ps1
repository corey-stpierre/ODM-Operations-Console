function ConvertTo-QOdmObjectView {
    param([Parameter(Mandatory = $true)][object]$Object)

    $id = Get-QOdmId $Object
    $displayName = [string](Get-QOdmProperty -InputObject $Object -Names @('DisplayName','Name','SourceDisplayName','TargetDisplayName'))
    $sourceUpn = Get-QOdmSourceUpn $Object
    $targetUpn = Get-QOdmTargetUpn $Object
    $sourceEmail = [string](Get-QOdmProperty -InputObject $Object -Names @('SourceEmail','SourceMail','Mail'))
    $targetEmail = [string](Get-QOdmProperty -InputObject $Object -Names @('TargetEmail','TargetMail'))
    $status = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Object -Names @('ObjectStatus','Status','State','MigrationStatus'))
    $type = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Object -Names @('ObjectType','Type','AccountType'))
    $matched = Get-QOdmProperty -InputObject $Object -Names @('Matched','IsMatched','MatchState')

    return [pscustomobject]@{
        Id              = $id
        DisplayName     = $displayName
        Name            = $displayName
        SourceUPN       = $sourceUpn
        TargetUPN       = $targetUpn
        SourceEmail     = $sourceEmail
        TargetEmail     = $targetEmail
        Status          = $status
        MigrationStatus = $status
        Type            = $type
        ObjectType      = $type
        Matched         = $matched
    }
}

function ConvertTo-QOdmTaskView {
    param([Parameter(Mandatory = $true)][object]$Task)

    return [pscustomobject]@{
        Id          = Get-QOdmId $Task
        Name        = Get-QOdmName $Task
        Status      = Get-QOdmTaskStatus -Task $Task
        Type        = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Task -Names @('Type','TaskType'))
        Context     = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Task -Names @('Context','Workload','Category'))
        Progress    = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Task -Names @('Progress','MigrationProgress','PercentComplete'))
        ObjectCount = Get-QOdmProperty -InputObject $Task -Names @('ObjectCount','ObjectsCount','TotalObjects','Total')
        Collections = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Task -Names @('Collections','Collection','CollectionNames'))
        Created     = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Task -Names @('Created','CreatedAt','CreationDate'))
        Modified    = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Task -Names @('Modified','ModifiedAt','Updated','UpdatedAt','LastUpdated'))
    }
}

function ConvertTo-QOdmCollectionView {
    param([Parameter(Mandatory = $true)][object]$Collection)

    return [pscustomobject]@{
        Id                    = Get-QOdmId $Collection
        Name                  = Get-QOdmName $Collection
        Description           = [string](Get-QOdmProperty -InputObject $Collection -Names @('Description','Notes'))
        ObjectCount           = Get-QOdmProperty -InputObject $Collection -Names @('ObjectCount','ObjectsCount','TotalObjects')
        TaskCount             = Get-QOdmProperty -InputObject $Collection -Names @('TaskCount','TasksCount','TotalTasks')
        ObjectCountReadStatus = $null
        TaskCountReadStatus   = $null
        Created               = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Collection -Names @('Created','CreatedAt'))
        Modified              = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Collection -Names @('Modified','ModifiedAt','UpdatedAt'))
    }
}

function ConvertTo-QOdmTemplateView {
    param([Parameter(Mandatory = $true)][object]$Template)

    $id = [string](Get-QOdmProperty -InputObject $Template -Names @('Id','ID','TemplateId'))
    $name = [string](Get-QOdmProperty -InputObject $Template -Names @('Name','DisplayName','Title'))
    $type = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Template -Names @('Type','TaskType','Context'))
    return [pscustomobject]@{
        Id          = $id
        Name        = $name
        Type        = $type
        ProjectId   = [string](Get-QOdmProperty -InputObject $Template -Names @('ProjectId','ProjectID'))
        Created     = ConvertTo-QOdmDisplayString (Get-QOdmProperty -InputObject $Template -Names @('Created','CreatedAt'))
        DisplayText = if ($type) { "$name - $type" } else { $name }
    }
}

function Update-QOdmObjectCache {
    [CmdletBinding()]
    param([bool]$IncludeAllProperties = $false)

    Assert-QOdmWorkloadSelected
    Set-QOdmOperationPhase -Phase 'Loading ODM objects'
    $parameters = @{ All = $true }
    $optional = @()
    if ($IncludeAllProperties) {
        $parameters.IncludeAllProperties = $true
        $optional += 'IncludeAllProperties'
    }
    $objects = Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmObject' -Parameters $parameters -RequiredParameters @('All') -OptionalParameters $optional

    $script:QOdmState.Objects = @{}
    $script:QOdmState.ObjectLookup = @{}
    foreach ($object in $objects) {
        if ($null -eq $object) { continue }
        $id = Get-QOdmId $object
        if (-not [string]::IsNullOrWhiteSpace($id)) { $script:QOdmState.Objects[$id] = $object }

        $properties = @()
        try { $properties = ConvertTo-QOdmObjectArray -InputObject $object.PSObject.Properties } catch { $properties = @() }
        foreach ($property in $properties) {
            if ($property.Name -match '(?i)(upn|userprincipalname|email|mail)' -and $property.Value -is [string]) {
                Add-QOdmObjectLookupEntry -Lookup $script:QOdmState.ObjectLookup -Value ([string]$property.Value) -Object $object
            }
        }
        Add-QOdmObjectLookupEntry -Lookup $script:QOdmState.ObjectLookup -Value (Get-QOdmSourceUpn $object) -Object $object
        Add-QOdmObjectLookupEntry -Lookup $script:QOdmState.ObjectLookup -Value (Get-QOdmTargetUpn $object) -Object $object
    }
    $script:QOdmState.LastRefresh = Get-Date
    return (ConvertTo-QOdmObjectArray -InputObject $objects)
}

function Update-QOdmTaskCache {
    [CmdletBinding()]
    param()

    Assert-QOdmWorkloadSelected
    Set-QOdmOperationPhase -Phase 'Loading ODM tasks'
    $tasks = Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmTask' -Parameters @{ All = $true } -RequiredParameters @('All')
    $script:QOdmState.Tasks = @{}
    foreach ($task in $tasks) {
        if ($null -eq $task) { continue }
        $id = Get-QOdmId $task
        if (-not [string]::IsNullOrWhiteSpace($id)) { $script:QOdmState.Tasks[$id] = $task }
    }
    $script:QOdmState.LastRefresh = Get-Date
    return (ConvertTo-QOdmObjectArray -InputObject $tasks)
}

function Update-QOdmCollectionCache {
    [CmdletBinding()]
    param()

    Assert-QOdmWorkloadSelected
    Set-QOdmOperationPhase -Phase 'Loading ODM collections'
    $collections = Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmCollection' -Parameters @{ ResultSize = 100000 } -RequiredParameters @('ResultSize')

    $script:QOdmState.Collections = @{}
    foreach ($collection in $collections) {
        if ($null -eq $collection) { continue }
        $id = Get-QOdmId $collection
        if (-not [string]::IsNullOrWhiteSpace($id)) { $script:QOdmState.Collections[$id] = $collection }
    }
    $script:QOdmState.LastRefresh = Get-Date
    return (ConvertTo-QOdmObjectArray -InputObject $collections)
}

function Update-QOdmTemplateCache {
    [CmdletBinding()]
    param()

    Assert-QOdmWorkloadSelected
    Set-QOdmOperationPhase -Phase 'Loading ODM task templates'
    $script:QOdmState.Templates = @{}
    if (-not (Test-QOdmCommand -Name 'Get-OdmTaskTemplates')) { return @() }

    $command = Get-Command -Name 'Get-OdmTaskTemplates' -ErrorAction Stop
    if (-not $command.Parameters.ContainsKey('All')) {
        Add-QOdmWarning -Message 'Get-OdmTaskTemplates does not expose All; templates were not loaded to avoid presenting a partial list.'
        return @()
    }

    $templateList = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $errors = [System.Collections.Generic.List[string]]::new()
    $candidateProjectIds = @($script:QOdmState.WorkloadId, $script:QOdmState.ProjectId) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique

    if ($command.Parameters.ContainsKey('ProjectId')) {
        foreach ($projectId in $candidateProjectIds) {
            try {
                $templateOutput = Get-OdmTaskTemplates -ProjectId $projectId -All -ErrorAction Stop
                foreach ($template in (ConvertTo-QOdmObjectArray -InputObject $templateOutput)) {
                    if ($null -eq $template) { continue }
                    $id = Get-QOdmId $template
                    if ($id -and -not $seen.ContainsKey($id)) {
                        $seen[$id] = $true
                        $templateList.Add($template) | Out-Null
                    }
                }
            }
            catch { $errors.Add(("Project '$projectId': {0}" -f $_.Exception.Message)) | Out-Null }
        }
    }

    if ($templateList.Count -eq 0) {
        try {
            $templateOutput = Get-OdmTaskTemplates -All -ErrorAction Stop
            foreach ($template in (ConvertTo-QOdmObjectArray -InputObject $templateOutput)) {
                if ($null -eq $template) { continue }
                $id = Get-QOdmId $template
                if ($id -and -not $seen.ContainsKey($id)) {
                    $seen[$id] = $true
                    $templateList.Add($template) | Out-Null
                }
            }
        }
        catch { $errors.Add($_.Exception.Message) | Out-Null }
    }

    foreach ($errorText in (ConvertTo-QOdmObjectArray -InputObject ($errors.ToArray() | Select-Object -Unique))) {
        Add-QOdmWarning -Message "Task template enumeration warning: $errorText"
    }

    foreach ($template in $templateList) {
        $id = Get-QOdmId $template
        if ($id) { $script:QOdmState.Templates[$id] = $template }
    }
    return $templateList.ToArray()
}

function Get-QOdmEntityIdSet {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Entities)

    $set = @{}
    foreach ($entity in (ConvertTo-QOdmObjectArray -InputObject $Entities)) {
        if ($null -eq $entity) { continue }
        $id = Get-QOdmId $entity
        if ($id) { $set[$id] = $true }
    }
    return $set
}

function Resolve-QOdmCreatedEntityAfterWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Task','Collection')][string]$EntityType,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$ExistingIds,
        [AllowNull()][object]$ReturnedObjects,
        [int]$Retries = 6,
        [int]$DelaySeconds = 2
    )

    if ($Retries -lt 1) { $Retries = 1 }
    if ($DelaySeconds -lt 0) { $DelaySeconds = 0 }

    $returnedCandidates = ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $ReturnedObjects) | Where-Object {
        $id = Get-QOdmId $_
        $id -and -not $ExistingIds.ContainsKey($id) -and [string]::Equals([string](Get-QOdmName $_), $Name, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($returnedCandidates.Count -gt 1) {
        $ids = @($returnedCandidates | ForEach-Object { Get-QOdmId $_ }) -join ', '
        throw "$EntityType creation returned multiple new objects named '$Name': $ids"
    }
    if ($returnedCandidates.Count -eq 1) { return $returnedCandidates[0] }

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        if ($EntityType -eq 'Task') {
            $null = Update-QOdmTaskCache
            $inventory = ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Tasks.Values
        }
        else {
            $null = Update-QOdmCollectionCache
            $inventory = ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Collections.Values
        }

        $matches = ConvertTo-QOdmObjectArray -InputObject ($inventory | Where-Object {
            $id = Get-QOdmId $_
            $id -and -not $ExistingIds.ContainsKey($id) -and [string]::Equals([string](Get-QOdmName $_), $Name, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -eq 1) { return $matches[0] }
        if ($matches.Count -gt 1) {
            $ids = @($matches | ForEach-Object { Get-QOdmId $_ }) -join ', '
            throw "$EntityType creation is ambiguous. Multiple new objects named '$Name' were found: $ids"
        }
        if ($attempt -lt $Retries -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
    }

    throw "$EntityType creation command completed, but the new object named '$Name' could not be resolved after $Retries inventory refresh attempt(s)."
}

function Get-QOdmObjectsView {
    [CmdletBinding()]
    param([string]$Search, [int]$MaxResults = 1000, [bool]$Refresh = $false)

    Assert-QOdmWorkloadSelected
    if ($Refresh -or $script:QOdmState.Objects.Count -eq 0) { $null = Update-QOdmObjectCache }
    $views = ConvertTo-QOdmObjectArray -InputObject ($script:QOdmState.Objects.Values | ForEach-Object { ConvertTo-QOdmObjectView $_ })
    $totalLoaded = $views.Count

    if (-not [string]::IsNullOrWhiteSpace($Search)) {
        $needle = $Search.Trim()
        $views = ConvertTo-QOdmObjectArray -InputObject ($views | Where-Object {
            $candidateValues = @($_.DisplayName, $_.SourceUPN, $_.TargetUPN, $_.SourceEmail, $_.TargetEmail, $_.Id)
            foreach ($candidate in $candidateValues) {
                if ($null -ne $candidate -and ([string]$candidate).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
            }
            return $false
        })
    }

    $matched = $views.Count
    if ($MaxResults -gt 0) { $views = ConvertTo-QOdmObjectArray -InputObject ($views | Sort-Object SourceUPN, DisplayName, Id | Select-Object -First $MaxResults) }
    return [pscustomobject]@{ Items = (ConvertTo-QOdmObjectArray -InputObject $views); TotalLoaded = $totalLoaded; Matched = $matched; Returned = $views.Count }
}


function Get-QOdmTasksView {
    [CmdletBinding()]
    param([string]$Search, [string]$Status, [bool]$Refresh = $false)

    Assert-QOdmWorkloadSelected
    if ($Refresh -or $script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }
    $views = ConvertTo-QOdmObjectArray -InputObject ($script:QOdmState.Tasks.Values | ForEach-Object { ConvertTo-QOdmTaskView $_ })
    if (-not [string]::IsNullOrWhiteSpace($Search)) {
        $needle = $Search.Trim()
        $views = ConvertTo-QOdmObjectArray -InputObject ($views | Where-Object { @($_.Name,$_.Type,$_.Context,$_.Id) | Where-Object { $null -ne $_ -and ([string]$_).IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1 })
    }
    if (-not [string]::IsNullOrWhiteSpace($Status) -and $Status -ne 'All') { $views = ConvertTo-QOdmObjectArray -InputObject ($views | Where-Object { $_.Status -eq $Status }) }
    return (ConvertTo-QOdmObjectArray -InputObject ($views | Sort-Object Name, Id))
}

function Get-QOdmCollectionsView {
    [CmdletBinding()]
    param([string]$Search, [bool]$Refresh = $false, [bool]$IncludeCounts = $false)

    Assert-QOdmWorkloadSelected
    if ($Refresh -or $script:QOdmState.Collections.Count -eq 0) { $null = Update-QOdmCollectionCache }
    $views = [System.Collections.Generic.List[object]]::new()
    foreach ($collection in (ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Collections.Values)) {
        $view = ConvertTo-QOdmCollectionView $collection
        if ($IncludeCounts -and $null -eq $view.ObjectCount) {
            try {
                $memberOutput = $collection | Get-OdmObject -All -ErrorAction Stop
                $view.ObjectCount = (ConvertTo-QOdmObjectArray -InputObject $memberOutput).Count
                $view.ObjectCountReadStatus = 'READ_SUCCEEDED'
            }
            catch {
                $view.ObjectCountReadStatus = 'READ_FAILED'
                Add-QOdmWarning -Message "Object count could not be read for collection '$($view.Name)' [$($view.Id)]: $($_.Exception.Message)"
            }
        }
        if ($IncludeCounts -and $null -eq $view.TaskCount) {
            try {
                $view.TaskCount = (ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCollectionTasks -Collection $collection)).Count
                $view.TaskCountReadStatus = 'READ_SUCCEEDED'
            }
            catch {
                $view.TaskCountReadStatus = 'READ_FAILED'
                Add-QOdmWarning -Message "Task count could not be read for collection '$($view.Name)' [$($view.Id)]: $($_.Exception.Message)"
            }
        }
        $views.Add($view) | Out-Null
    }

    $result = $views.ToArray()
    if (-not [string]::IsNullOrWhiteSpace($Search)) {
        $needle = $Search.Trim()
        $result = ConvertTo-QOdmObjectArray -InputObject ($result | Where-Object { @($_.Name,$_.Description,$_.Id) | Where-Object { $null -ne $_ -and ([string]$_).IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1 })
    }
    return (ConvertTo-QOdmObjectArray -InputObject ($result | Sort-Object Name, Id))
}

function Get-QOdmTemplatesView {
    [CmdletBinding()]
    param([bool]$Refresh = $false)

    Assert-QOdmWorkloadSelected
    if ($Refresh -or $script:QOdmState.Templates.Count -eq 0) { $null = Update-QOdmTemplateCache }
    return (ConvertTo-QOdmObjectArray -InputObject ($script:QOdmState.Templates.Values | ForEach-Object { ConvertTo-QOdmTemplateView $_ } | Sort-Object Type, Name, Id))
}

function Get-QOdmDashboard {
    [CmdletBinding()]
    param([bool]$Refresh = $true)

    Assert-QOdmWorkloadSelected
    if ($Refresh -or $script:QOdmState.Objects.Count -eq 0) { $null = Update-QOdmObjectCache }
    if ($Refresh -or $script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }
    if ($Refresh -or $script:QOdmState.Collections.Count -eq 0) { $null = Update-QOdmCollectionCache }

    $taskObjects = ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Tasks.Values
    $taskViews = ConvertTo-QOdmObjectArray -InputObject ($taskObjects | ForEach-Object { ConvertTo-QOdmTaskView $_ })
    $running = (ConvertTo-QOdmObjectArray -InputObject ($taskObjects | Where-Object { Test-QOdmTaskIsActive -Task $_ })).Count
    $failed = (ConvertTo-QOdmObjectArray -InputObject ($taskViews | Where-Object { (([string]$_.Status -replace '[^A-Za-z]', '').ToLowerInvariant()) -match 'fail|error' })).Count

    return [pscustomobject]@{
        State           = Get-QOdmContextState
        ObjectCount     = $script:QOdmState.Objects.Count
        TaskCount       = $script:QOdmState.Tasks.Count
        CollectionCount = $script:QOdmState.Collections.Count
        RunningTasks    = $running
        FailedTasks     = $failed
        RefreshedAt     = Get-Date
        Warnings        = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmOperationWarnings)
    }
}

function Resolve-QOdmObject {
    [CmdletBinding()]
    param([string]$ObjectId, [string]$SourceUPN)

    Assert-QOdmWorkloadSelected
    if ($script:QOdmState.Objects.Count -eq 0) { $null = Update-QOdmObjectCache }

    if (-not [string]::IsNullOrWhiteSpace($ObjectId)) {
        if ($script:QOdmState.Objects.ContainsKey($ObjectId)) { return $script:QOdmState.Objects[$ObjectId] }
        $idMatches = ConvertTo-QOdmObjectArray -InputObject ($script:QOdmState.Objects.Values | Where-Object { [string]::Equals([string](Get-QOdmId $_), $ObjectId, [StringComparison]::OrdinalIgnoreCase) })
        if ($idMatches.Count -gt 1) { throw "ODM object ID '$ObjectId' matched more than one object." }
        if ($idMatches.Count -eq 1) { return $idMatches[0] }
        return $null
    }

    $normalized = Normalize-QOdmUpn $SourceUPN
    if (-not $normalized) { return $null }
    $matches = @()
    if ($script:QOdmState.ObjectLookup.ContainsKey($normalized)) { $matches = ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.ObjectLookup[$normalized] }
    $unique = @{}
    foreach ($match in $matches) {
        if ($null -eq $match) { continue }
        $id = Get-QOdmId $match
        $key = if ($id) { $id.ToLowerInvariant() } else { [string]$match.GetHashCode() }
        if (-not $unique.ContainsKey($key)) { $unique[$key] = $match }
    }
    $resolved = ConvertTo-QOdmObjectArray -InputObject $unique.Values
    if ($resolved.Count -gt 1) {
        $candidates = @($resolved | ForEach-Object { '{0} [{1}]' -f (Get-QOdmSourceUpn $_), (Get-QOdmId $_) }) -join '; '
        throw "Identity '$SourceUPN' is ambiguous in the selected ODM workload. Use an exact object ID. Matches: $candidates"
    }
    if ($resolved.Count -eq 1) { return $resolved[0] }
    return $null
}

function Resolve-QOdmTask {
    [CmdletBinding()]
    param([string]$TaskId, [string]$TaskName)

    Assert-QOdmWorkloadSelected
    if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }
    return (Resolve-QOdmExactEntity -Entities (ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Tasks.Values) -Id $TaskId -Name $TaskName -EntityType 'Task')
}

function Resolve-QOdmCollection {
    [CmdletBinding()]
    param([string]$CollectionId, [string]$CollectionName)

    Assert-QOdmWorkloadSelected
    if ($script:QOdmState.Collections.Count -eq 0) { $null = Update-QOdmCollectionCache }
    return (Resolve-QOdmExactEntity -Entities (ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Collections.Values) -Id $CollectionId -Name $CollectionName -EntityType 'Collection')
}

function Resolve-QOdmTemplateReference {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    Assert-QOdmWorkloadSelected
    $value = $Reference.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'A template name or ID is required.' }
    if ($script:QOdmState.Templates.Count -eq 0) { $null = Update-QOdmTemplateCache }

    $idMatches = ConvertTo-QOdmObjectArray -InputObject ($script:QOdmState.Templates.Values | Where-Object { [string]::Equals([string](Get-QOdmId $_), $value, [StringComparison]::OrdinalIgnoreCase) })
    if ($idMatches.Count -gt 1) { throw "Template ID '$value' matched more than one template." }
    if ($idMatches.Count -eq 1) {
        return [pscustomobject]@{ Id = Get-QOdmId $idMatches[0]; Name = Get-QOdmName $idMatches[0]; Reference = $value; Source = 'LoadedId'; Template = $idMatches[0] }
    }

    $nameMatches = ConvertTo-QOdmObjectArray -InputObject ($script:QOdmState.Templates.Values | Where-Object {
        $view = ConvertTo-QOdmTemplateView $_
        [string]::Equals([string]$view.Name, $value, [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals([string]$view.DisplayText, $value, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($nameMatches.Count -eq 1) {
        return [pscustomobject]@{ Id = Get-QOdmId $nameMatches[0]; Name = Get-QOdmName $nameMatches[0]; Reference = $value; Source = 'LoadedName'; Template = $nameMatches[0] }
    }
    if ($nameMatches.Count -gt 1) {
        $candidateText = @($nameMatches | ForEach-Object { $view = ConvertTo-QOdmTemplateView $_; '{0} [{1}]' -f $view.Name, $view.Id }) -join '; '
        throw "Template reference '$value' is ambiguous. Select or enter an exact template ID. Matches: $candidateText"
    }

    $parsedGuid = [Guid]::Empty
    if ([Guid]::TryParse($value, [ref]$parsedGuid)) {
        return [pscustomobject]@{ Id = $parsedGuid.ToString(); Name = $null; Reference = $value; Source = 'RawGuid'; Template = $null }
    }
    throw "Template '$value' was not found in the selected context. Refresh the workspace or enter the exact template GUID."
}
