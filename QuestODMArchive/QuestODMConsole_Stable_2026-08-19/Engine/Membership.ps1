function Get-QOdmTaskMembers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TaskId)

    $task = Resolve-QOdmTask -TaskId $TaskId
    if ($null -eq $task) { throw "Task not found: $TaskId" }
    Set-QOdmOperationPhase -Phase "Reading members of task '$((Get-QOdmName $task))'"
    $memberOutput = $task | Get-OdmObject -All -ErrorAction Stop
    $members = ConvertTo-QOdmObjectArray -InputObject $memberOutput
    $viewOutput = $members | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-QOdmObjectView $_ } | Sort-Object SourceUPN, DisplayName
    return (ConvertTo-QOdmObjectArray -InputObject $viewOutput)
}

function Get-QOdmCollectionMembers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CollectionId)

    $collection = Resolve-QOdmCollection -CollectionId $CollectionId
    if ($null -eq $collection) { throw "Collection not found: $CollectionId" }
    Set-QOdmOperationPhase -Phase "Reading members of collection '$((Get-QOdmName $collection))'"
    $memberOutput = $collection | Get-OdmObject -All -ErrorAction Stop
    $members = ConvertTo-QOdmObjectArray -InputObject $memberOutput
    $viewOutput = $members | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-QOdmObjectView $_ } | Sort-Object SourceUPN, DisplayName
    return (ConvertTo-QOdmObjectArray -InputObject $viewOutput)
}

function Find-QOdmObjectAssociations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [string[]]$TaskNamePatterns = @(),
        [string[]]$CollectionNamePatterns = @()
    )

    $object = Resolve-QOdmObject -ObjectId $ObjectId
    if ($null -eq $object) { throw "Object not found: $ObjectId" }
    $taskPatterns = ConvertTo-QOdmObjectArray -InputObject (Assert-QOdmRegexPatterns -Patterns $TaskNamePatterns -Description 'task-name pattern')
    $collectionPatterns = ConvertTo-QOdmObjectArray -InputObject (Assert-QOdmRegexPatterns -Patterns $CollectionNamePatterns -Description 'collection-name pattern')

    if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }
    if ($script:QOdmState.Collections.Count -eq 0) { $null = Update-QOdmCollectionCache }

    $taskRows = [System.Collections.Generic.List[object]]::new()
    $collectionRows = [System.Collections.Generic.List[object]]::new()
    $readErrors = [System.Collections.Generic.List[object]]::new()

    $tasks = ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Tasks.Values
    if ($taskPatterns.Count -gt 0) {
        $tasks = @($tasks | Where-Object {
            $name = [string](Get-QOdmName $_)
            $matched = $false
            foreach ($pattern in $taskPatterns) { if ($name -match $pattern) { $matched = $true; break } }
            $matched
        })
    }

    foreach ($task in $tasks) {
        $taskId = Get-QOdmId $task
        $taskName = Get-QOdmName $task
        try {
            $memberOutput = $task | Get-OdmObject -All -ErrorAction Stop
            $memberIds = ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $memberOutput) | ForEach-Object { Get-QOdmId $_ } | Where-Object { $_ })
            if ($memberIds -contains $ObjectId) {
                $view = ConvertTo-QOdmTaskView $task
                $taskRows.Add([pscustomobject]@{
                    ObjectId = $ObjectId; TaskId = $view.Id; TaskName = $view.Name
                    Type = $view.Type; Status = $view.Status; Context = $view.Context
                }) | Out-Null
            }
        }
        catch {
            $readErrors.Add([pscustomobject]@{ EntityType='Task'; EntityId=$taskId; EntityName=$taskName; Error=$_.Exception.Message }) | Out-Null
        }
    }

    $collections = ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Collections.Values
    if ($collectionPatterns.Count -gt 0) {
        $collections = @($collections | Where-Object {
            $name = [string](Get-QOdmName $_)
            $matched = $false
            foreach ($pattern in $collectionPatterns) { if ($name -match $pattern) { $matched = $true; break } }
            $matched
        })
    }

    foreach ($collection in $collections) {
        $collectionId = Get-QOdmId $collection
        $collectionName = Get-QOdmName $collection
        try {
            $memberOutput = $collection | Get-OdmObject -All -ErrorAction Stop
            $memberIds = ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $memberOutput) | ForEach-Object { Get-QOdmId $_ } | Where-Object { $_ })
            if ($memberIds -contains $ObjectId) {
                $view = ConvertTo-QOdmCollectionView $collection
                $collectionRows.Add([pscustomobject]@{
                    ObjectId=$ObjectId; CollectionId=$view.Id; CollectionName=$view.Name; Description=$view.Description
                }) | Out-Null
            }
        }
        catch {
            $readErrors.Add([pscustomobject]@{ EntityType='Collection'; EntityId=$collectionId; EntityName=$collectionName; Error=$_.Exception.Message }) | Out-Null
        }
    }

    [pscustomobject]@{
        Object      = ConvertTo-QOdmObjectView $object
        Tasks       = ConvertTo-QOdmObjectArray -InputObject ($taskRows.ToArray() | Sort-Object TaskName, TaskId)
        Collections = ConvertTo-QOdmObjectArray -InputObject ($collectionRows.ToArray() | Sort-Object CollectionName, CollectionId)
        ReadErrors  = $readErrors.ToArray()
    }
}

function Test-QOdmEntityObjectMembership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Entity,
        [Parameter(Mandatory = $true)][string[]]$ObjectIds,
        [Parameter(Mandatory = $true)][bool]$ShouldExist,
        [int]$Retries = 5,
        [int]$DelaySeconds = 2
    )

    $expectedIds = @($ObjectIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
    if ($Retries -lt 1) { $Retries = 1 }
    if ($DelaySeconds -lt 0) { $DelaySeconds = 0 }
    if ($expectedIds.Count -eq 0) {
        return [pscustomobject]@{
            VerificationState='NO_OBJECTS'; Verified=$true; ShouldExist=$ShouldExist; Attempts=0
            ExpectedCount=0; PresentExpectedCount=0; MemberIds=@(); ReadSucceeded=$true; Error=$null
        }
    }

    $lastMembers = @()
    $lastError = $null
    $verified = $false
    $attemptUsed = 0
    $presentExpectedCount = 0
    $lastReadSucceeded = $false

    for ($attempt = 1; $attempt -le $Retries -and -not $verified; $attempt++) {
        $attemptUsed = $attempt
        try {
            $memberOutput = $Entity | Get-OdmObject -All -ErrorAction Stop
            $lastMembers = ConvertTo-QOdmObjectArray -InputObject $memberOutput
            $lastError = $null
            $lastReadSucceeded = $true
        }
        catch {
            $lastMembers = @()
            $lastError = $_.Exception.Message
            $lastReadSucceeded = $false
        }

        if ($lastReadSucceeded) {
            $memberLookup = @{}
            foreach ($member in $lastMembers) {
                $memberId = Get-QOdmId $member
                if ($memberId) { $memberLookup[[string]$memberId] = $true }
            }
            $presentExpectedCount = 0
            foreach ($expectedId in $expectedIds) { if ($memberLookup.ContainsKey($expectedId)) { $presentExpectedCount++ } }
            if ($ShouldExist) { $verified = ($presentExpectedCount -eq $expectedIds.Count) }
            else { $verified = ($presentExpectedCount -eq 0) }
        }

        if (-not $verified -and $attempt -lt $Retries -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
    }

    $state = if (-not $lastReadSucceeded) { 'READ_FAILED' } elseif ($verified) { 'VERIFIED' } else { 'NOT_VERIFIED' }
    [pscustomobject]@{
        VerificationState    = $state
        Verified             = $verified
        ShouldExist          = $ShouldExist
        Attempts             = $attemptUsed
        ExpectedCount        = $expectedIds.Count
        PresentExpectedCount = $presentExpectedCount
        MemberIds            = ConvertTo-QOdmObjectArray -InputObject ($lastMembers | ForEach-Object { Get-QOdmId $_ } | Where-Object { $_ } | Select-Object -Unique)
        ReadSucceeded        = $lastReadSucceeded
        Error                = $lastError
    }
}

function New-QOdmMembershipChangeResult {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][object]$Entity,
        [Parameter(Mandatory = $true)][ValidateSet('Task','Collection')][string]$EntityType,
        [Parameter(Mandatory = $true)][object]$Verification
    )

    $result = [ordered]@{
        Object            = ConvertTo-QOdmObjectView $Object
        Verified          = [bool](Get-QOdmProperty -InputObject $Verification -Names @('Verified') -Default $false)
        VerificationState = [string](Get-QOdmProperty -InputObject $Verification -Names @('VerificationState') -Default 'NOT_VERIFIED')
        Verification      = $Verification
    }
    if ($EntityType -eq 'Task') { $result.Task = ConvertTo-QOdmTaskView $Entity }
    else { $result.Collection = ConvertTo-QOdmCollectionView $Entity }
    [pscustomobject]$result
}

function Invoke-QOdmSingleMembershipChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Add','Remove')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('Task','Collection')][string]$EntityType,
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [Parameter(Mandatory = $true)][string]$EntityId
    )

    $object = Resolve-QOdmObject -ObjectId $ObjectId
    $entity = if ($EntityType -eq 'Task') { Resolve-QOdmTask -TaskId $EntityId } else { Resolve-QOdmCollection -CollectionId $EntityId }
    if ($null -eq $object) { throw "Object not found: $ObjectId" }
    if ($null -eq $entity) { throw "$EntityType not found: $EntityId" }

    if ($Action -eq 'Add') { $null = Add-QOdmObjectsToEntity -Entity $entity -Objects @($object); $shouldExist = $true }
    else { $null = Remove-QOdmObjectsFromEntity -Entity $entity -Objects @($object); $shouldExist = $false }

    $verification = Test-QOdmEntityObjectMembership -Entity $entity -ObjectIds @((Get-QOdmId $object)) -ShouldExist $shouldExist
    New-QOdmMembershipChangeResult -Object $object -Entity $entity -EntityType $EntityType -Verification $verification
}

function Add-QOdmObjectToTask {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ObjectId, [Parameter(Mandatory = $true)][string]$TaskId)
    Invoke-QOdmSingleMembershipChange -Action Add -EntityType Task -ObjectId $ObjectId -EntityId $TaskId
}

function Remove-QOdmObjectFromTask {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ObjectId, [Parameter(Mandatory = $true)][string]$TaskId)
    Invoke-QOdmSingleMembershipChange -Action Remove -EntityType Task -ObjectId $ObjectId -EntityId $TaskId
}

function Add-QOdmObjectToCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ObjectId, [Parameter(Mandatory = $true)][string]$CollectionId)
    Invoke-QOdmSingleMembershipChange -Action Add -EntityType Collection -ObjectId $ObjectId -EntityId $CollectionId
}

function Remove-QOdmObjectFromCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ObjectId, [Parameter(Mandatory = $true)][string]$CollectionId)
    Invoke-QOdmSingleMembershipChange -Action Remove -EntityType Collection -ObjectId $ObjectId -EntityId $CollectionId
}

function New-QOdmCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    Assert-QOdmWorkloadSelected
    $normalized = Normalize-QOdmName $Name
    if (-not $normalized) { throw 'Collection name cannot be empty.' }
    if ($script:QOdmState.Collections.Count -eq 0) { $null = Update-QOdmCollectionCache }

    $existing = Resolve-QOdmCollection -CollectionName $normalized
    if ($null -ne $existing) { throw "A collection named '$normalized' already exists. Existing ID: $((Get-QOdmId $existing))" }

    $existingIds = @{}
    foreach ($id in @($script:QOdmState.Collections.Keys)) { $existingIds[[string]$id] = $true }
    $command = Get-Command -Name 'New-OdmCollection' -ErrorAction Stop
    if (-not $command.Parameters.ContainsKey('Name')) { throw 'New-OdmCollection does not expose the required Name parameter.' }
    $parameters = @{ Name=$normalized }
    if ($command.Parameters.ContainsKey('PassThru')) { $parameters.PassThru = $true }
    # Current OdmApi releases do not return the new collection. The resolver below
    # deliberately supports both no-output and PassThru-capable implementations.
    $returned = Invoke-QOdmSupportedCommandArray -CommandName 'New-OdmCollection' -Parameters $parameters -RequiredParameters @('Name') -OptionalParameters @('PassThru')
    $collection = Resolve-QOdmCreatedEntityAfterWrite -EntityType Collection -Name $normalized -ExistingIds $existingIds -ReturnedObjects $returned
    $id = Get-QOdmId $collection
    if ($id) { $script:QOdmState.Collections[$id] = $collection }
    ConvertTo-QOdmCollectionView $collection
}

function Remove-QOdmCollections {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$CollectionIds)

    Assert-QOdmWorkloadSelected
    $requestedIds = @($CollectionIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
    if ($requestedIds.Count -eq 0) { throw 'No collections were selected.' }
    $command = Get-Command -Name 'Remove-OdmCollection' -ErrorAction Stop
    if (-not $command.Parameters.ContainsKey('Collections')) { throw 'Remove-OdmCollection does not expose the required Collections parameter.' }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $requestedIds) {
        $collection = Resolve-QOdmCollection -CollectionId $id
        if ($null -eq $collection) {
            $results.Add([pscustomobject]@{ CollectionId=$id; CollectionName=$null; Deleted=$false; Status='NOT_FOUND'; Details='Collection was not found in the selected workload.' }) | Out-Null
            continue
        }
        $collectionId = Get-QOdmId $collection
        $collectionName = Get-QOdmName $collection
        try {
            $parameters = @{ Collections=@($collection); ErrorAction='Stop' }
            if ($command.Parameters.ContainsKey('Confirm')) { $parameters.Confirm=$false }
            Remove-OdmCollection @parameters | Out-Null
            if ($collectionId -and $script:QOdmState.Collections.ContainsKey($collectionId)) { $script:QOdmState.Collections.Remove($collectionId) }
            $results.Add([pscustomobject]@{ CollectionId=$collectionId; CollectionName=$collectionName; Deleted=$true; Status='DELETED'; Details='Delete command completed.' }) | Out-Null
        }
        catch {
            $results.Add([pscustomobject]@{ CollectionId=$collectionId; CollectionName=$collectionName; Deleted=$false; Status='FAILED'; Details=$_.Exception.Message }) | Out-Null
        }
    }
    $results.ToArray()
}

function Start-QOdmTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$TaskIds,
        [int]$DelaySeconds = 2
    )

    Assert-QOdmWorkloadSelected
    Set-QOdmOperationPhase -Phase 'Starting selected tasks'
    if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($taskId in (ConvertTo-QOdmObjectArray -InputObject ($TaskIds | Where-Object { $_ } | Select-Object -Unique))) {
        $task = $null
        try { $task = Resolve-QOdmTask -TaskId ([string]$taskId) } catch { }
        if ($null -eq $task) {
            $results.Add([pscustomobject]@{
                TaskId=[string]$taskId; TaskName=$null; PreviousStatus=$null
                StartAttempted=$false; StartSucceeded=$false; Status='TASK_NOT_FOUND'
                Details='The task was not found in the selected workload.'
            }) | Out-Null
            continue
        }
        $results.Add((Start-QOdmTaskSafely -Task $task -DelaySeconds $DelaySeconds)) | Out-Null
    }
    $null = Update-QOdmTaskCache
    return $results.ToArray()
}

function Stop-QOdmTasks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$TaskIds)

    Assert-QOdmWorkloadSelected
    $ids = @($TaskIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
    if ($ids.Count -eq 0) { throw 'No tasks were selected.' }
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $task = Resolve-QOdmTask -TaskId $id
        if ($null -eq $task) {
            $results.Add([pscustomobject]@{ TaskId=$id; TaskName=$null; PreviousStatus=$null; StopAttempted=$false; StopSucceeded=$false; Status='NOT_FOUND'; Details='Task was not found.' }) | Out-Null
        }
        else { $results.Add((Stop-QOdmTaskSafely -Task $task)) | Out-Null }
    }
    try { $null = Update-QOdmTaskCache } catch { Add-QOdmWarning -Message "Task inventory refresh after stop processing failed: $($_.Exception.Message)" }
    $results.ToArray()
}

function Remove-QOdmTasks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$TaskIds, [bool]$StopRunning = $true)

    Assert-QOdmWorkloadSelected
    $ids = @($TaskIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
    if ($ids.Count -eq 0) { throw 'No tasks were selected.' }
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $task = Resolve-QOdmTask -TaskId $id
        if ($null -eq $task) {
            $results.Add([pscustomobject]@{ TaskId=$id; TaskName=$null; PreviousStatus=$null; StopAttempted=$false; StopSucceeded=$false; Deleted=$false; Status='NOT_FOUND'; Details='Task was not found.' }) | Out-Null
            continue
        }
        $result = Remove-QOdmTaskSafely -Task $task -StopRunning $StopRunning
        $results.Add($result) | Out-Null
        $deleted = [bool](Get-QOdmProperty -InputObject $result -Names @('Deleted') -Default $false)
        $resultId = [string](Get-QOdmProperty -InputObject $result -Names @('TaskId'))
        if ($deleted -and $resultId -and $script:QOdmState.Tasks.ContainsKey($resultId)) { $script:QOdmState.Tasks.Remove($resultId) }
    }
    $results.ToArray()
}

function Invoke-QOdmCsvEntityMembershipChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Add','Remove')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('Task','Collection')][string]$EntityType,
        [Parameter(Mandatory = $true)][string]$EntityId,
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [bool]$Execute = $false,
        [AllowNull()][string]$OutputDirectory = $null
    )

    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasIdentityHeader -Headers $headers
    if ($script:QOdmState.Objects.Count -eq 0) { $null = Update-QOdmObjectCache }
    $entity = if ($EntityType -eq 'Task') { Resolve-QOdmTask -TaskId $EntityId } else { Resolve-QOdmCollection -CollectionId $EntityId }
    if ($null -eq $entity) { throw "$EntityType not found: $EntityId" }

    $pending = [System.Collections.Generic.List[object]]::new()
    $report = [System.Collections.Generic.List[object]]::new()
    $seenIdentities = @{}
    $seenObjectIds = @{}
    $rowNumber = 1
    foreach ($row in $rows) {
        $rowNumber++
        $upn = Get-QOdmUpnFromRow $row
        if (-not $upn) {
            $report.Add([pscustomobject]@{ SourceUPN=$null; ObjectId=$null; EntityType=$EntityType; EntityId=$EntityId; Action=$Action; Status='BLANK_IDENTITY'; CommandSucceeded=$false; Verified=$false; VerificationState='NOT_RUN'; Details="CSV row $rowNumber does not contain a usable identity value." }) | Out-Null
            continue
        }
        if ($seenIdentities.ContainsKey($upn)) {
            $report.Add([pscustomobject]@{ SourceUPN=$upn; ObjectId=$null; EntityType=$EntityType; EntityId=$EntityId; Action=$Action; Status='DUPLICATE_INPUT'; CommandSucceeded=$false; Verified=$false; VerificationState='NOT_RUN'; Details="Duplicate identity at CSV row $rowNumber." }) | Out-Null
            continue
        }
        $seenIdentities[$upn]=$true

        try { $object = Resolve-QOdmObject -SourceUPN $upn }
        catch {
            $report.Add([pscustomobject]@{ SourceUPN=$upn; ObjectId=$null; EntityType=$EntityType; EntityId=$EntityId; Action=$Action; Status='AMBIGUOUS_IDENTITY'; CommandSucceeded=$false; Verified=$false; VerificationState='NOT_RUN'; Details=$_.Exception.Message }) | Out-Null
            continue
        }
        if ($null -eq $object) {
            $report.Add([pscustomobject]@{ SourceUPN=$upn; ObjectId=$null; EntityType=$EntityType; EntityId=$EntityId; Action=$Action; Status='UNRESOLVED'; CommandSucceeded=$false; Verified=$false; VerificationState='NOT_RUN'; Details='No ODM object matched.' }) | Out-Null
            continue
        }

        $objectId = [string](Get-QOdmId $object)
        if ([string]::IsNullOrWhiteSpace($objectId)) {
            $report.Add([pscustomobject]@{ SourceUPN=$upn; ObjectId=$null; EntityType=$EntityType; EntityId=$EntityId; Action=$Action; Status='OBJECT_ID_MISSING'; CommandSucceeded=$false; Verified=$false; VerificationState='NOT_RUN'; Details='The resolved ODM object does not expose a usable ID.' }) | Out-Null
            continue
        }
        if ($seenObjectIds.ContainsKey($objectId)) {
            $report.Add([pscustomobject]@{ SourceUPN=$upn; ObjectId=$objectId; EntityType=$EntityType; EntityId=$EntityId; Action=$Action; Status='DUPLICATE_OBJECT'; CommandSucceeded=$false; Verified=$false; VerificationState='NOT_RUN'; Details='This CSV identity resolves to an ODM object already processed by an earlier row.' }) | Out-Null
            continue
        }
        $seenObjectIds[$objectId]=$true

        $reportRow = [pscustomobject]@{
            SourceUPN=$upn; ObjectId=$objectId; EntityType=$EntityType; EntityId=$EntityId; Action=$Action
            Status=if($Execute){'PENDING'}else{'DRY_RUN'}; CommandSucceeded=$false; Verified=$false
            VerificationState='NOT_RUN'; Details=$null
        }
        $report.Add($reportRow) | Out-Null
        $pending.Add([pscustomobject]@{ Object=$object; ObjectId=$objectId; ReportRow=$reportRow }) | Out-Null
    }

    if ($Execute -and $pending.Count -gt 0) {
        $successful = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $pending) {
            $reportRow = Get-QOdmProperty -InputObject $item -Names @('ReportRow')
            $object = Get-QOdmProperty -InputObject $item -Names @('Object')
            try {
                if ($Action -eq 'Add') { $null = Add-QOdmObjectsToEntity -Entity $entity -Objects @($object) }
                else { $null = Remove-QOdmObjectsFromEntity -Entity $entity -Objects @($object) }
                $reportRow.CommandSucceeded = $true
                $reportRow.Status = 'COMMAND_SUCCEEDED'
                $successful.Add($item) | Out-Null
            }
            catch {
                $reportRow.Status = 'COMMAND_FAILED'
                $reportRow.VerificationState = 'NOT_RUN'
                $reportRow.Details = $_.Exception.Message
            }
        }

        if ($successful.Count -gt 0) {
            $shouldExist = ($Action -eq 'Add')
            $successfulIds = ConvertTo-QOdmObjectArray -InputObject ($successful.ToArray() | ForEach-Object { [string](Get-QOdmProperty -InputObject $_ -Names @('ObjectId')) })
            $verification = Test-QOdmEntityObjectMembership -Entity $entity -ObjectIds $successfulIds -ShouldExist $shouldExist
            $readSucceeded = [bool](Get-QOdmProperty -InputObject $verification -Names @('ReadSucceeded') -Default $false)
            $memberIds = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $verification -Names @('MemberIds') -Default @())
            $memberLookup = @{}
            foreach ($memberId in $memberIds) {
                if (-not [string]::IsNullOrWhiteSpace([string]$memberId)) { $memberLookup[[string]$memberId] = $true }
            }
            $verificationError = [string](Get-QOdmProperty -InputObject $verification -Names @('Error'))

            foreach ($item in $successful) {
                $reportRow = Get-QOdmProperty -InputObject $item -Names @('ReportRow')
                $objectId = [string](Get-QOdmProperty -InputObject $item -Names @('ObjectId'))
                if (-not $readSucceeded) {
                    $reportRow.Status = 'VERIFY_READ_FAILED'
                    $reportRow.VerificationState = 'VERIFICATION_READ_FAILED'
                    $reportRow.Details = $verificationError
                    continue
                }
                $present = $memberLookup.ContainsKey($objectId)
                $matches = if ($shouldExist) { $present } else { -not $present }
                $reportRow.Verified = [bool]$matches
                if ($matches) {
                    $reportRow.VerificationState = if ($shouldExist) { 'VERIFIED_PRESENT' } else { 'VERIFIED_ABSENT' }
                    $reportRow.Status = if ($shouldExist) { 'VERIFIED_ADDED' } else { 'VERIFIED_REMOVED' }
                }
                else {
                    $reportRow.VerificationState = 'NOT_VERIFIED'
                    $reportRow.Status = 'NOT_VERIFIED'
                    $reportRow.Details = 'The Quest write command completed, but the expected membership state was not observed after verification retries.'
                }
            }
        }
    }

    $baseName = if ($Action -eq 'Add') { "AddUsersTo$EntityType" } else { "RemoveUsersFrom$EntityType" }
    $reportPath = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName $baseName
    Export-QOdmCsv -Rows $report.ToArray() -Path $reportPath | Out-Null
    [pscustomobject]@{
        Entity = if($EntityType -eq 'Task'){ConvertTo-QOdmTaskView $entity}else{ConvertTo-QOdmCollectionView $entity}
        Execute=$Execute; ResolvedCount=$pending.Count; CommandSucceededCount=(ConvertTo-QOdmObjectArray -InputObject ($report.ToArray() | Where-Object { [bool](Get-QOdmProperty -InputObject $_ -Names @('CommandSucceeded') -Default $false) })).Count
        VerifiedCount=(ConvertTo-QOdmObjectArray -InputObject ($report.ToArray() | Where-Object { [bool](Get-QOdmProperty -InputObject $_ -Names @('Verified') -Default $false) })).Count
        Report=$report.ToArray(); ReportPath=$reportPath; Reports=@($reportPath)
    }
}

function Add-QOdmUsersToEntityFromCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Task','Collection')][string]$EntityType, [Parameter(Mandatory = $true)][string]$EntityId, [Parameter(Mandatory = $true)][string]$CsvPath, [bool]$Execute=$false, [AllowNull()][string]$OutputDirectory=$null)
    Invoke-QOdmCsvEntityMembershipChange -Action Add -EntityType $EntityType -EntityId $EntityId -CsvPath $CsvPath -Execute $Execute -OutputDirectory $OutputDirectory
}

function Remove-QOdmUsersFromEntityFromCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Task','Collection')][string]$EntityType, [Parameter(Mandatory = $true)][string]$EntityId, [Parameter(Mandatory = $true)][string]$CsvPath, [bool]$Execute=$false, [AllowNull()][string]$OutputDirectory=$null)
    Invoke-QOdmCsvEntityMembershipChange -Action Remove -EntityType $EntityType -EntityId $EntityId -CsvPath $CsvPath -Execute $Execute -OutputDirectory $OutputDirectory
}
