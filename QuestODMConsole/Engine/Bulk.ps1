Set-StrictMode -Version 2.0

function Resolve-QOdmCsvUsers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    Assert-QOdmWorkloadSelected
    if ($script:QOdmState.Objects.Count -eq 0) { $null = Update-QOdmObjectCache }

    $resolved = [System.Collections.Generic.List[object]]::new()
    $unresolved = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $rowNumber = 0

    foreach ($row in (ConvertTo-QOdmObjectArray -InputObject $Rows)) {
        $rowNumber++
        $upn = Get-QOdmUpnFromRow -Row $row
        if ([string]::IsNullOrWhiteSpace($upn)) {
            $unresolved.Add([pscustomobject]@{
                RowNumber = $rowNumber
                SourceUPN = $null
                ObjectId  = $null
                Status    = 'BLANK_IDENTITY'
                Details   = 'The row did not contain a nonblank supported source identity value.'
            }) | Out-Null
            continue
        }

        if ($seen.ContainsKey($upn)) {
            $unresolved.Add([pscustomobject]@{
                RowNumber = $rowNumber
                SourceUPN = $upn
                ObjectId  = $null
                Status    = 'DUPLICATE_INPUT'
                Details   = 'The same normalized identity appeared earlier in the CSV.'
            }) | Out-Null
            continue
        }
        $seen[$upn] = $true

        try {
            $object = Resolve-QOdmObject -SourceUPN $upn
            if ($null -eq $object) {
                $unresolved.Add([pscustomobject]@{
                    RowNumber = $rowNumber
                    SourceUPN = $upn
                    ObjectId  = $null
                    Status    = 'NOT_FOUND'
                    Details   = 'No ODM object matched the supplied identity in the selected workload.'
                }) | Out-Null
                continue
            }

            $resolved.Add([pscustomobject]@{
                RowNumber = $rowNumber
                SourceUPN = $upn
                ObjectId  = Get-QOdmId -InputObject $object
                Object    = $object
                Row       = $row
            }) | Out-Null
        }
        catch {
            $unresolved.Add([pscustomobject]@{
                RowNumber = $rowNumber
                SourceUPN = $upn
                ObjectId  = $null
                Status    = if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_IDENTITY' } else { 'RESOLUTION_FAILED' }
                Details   = $_.Exception.Message
            }) | Out-Null
        }
    }

    [pscustomobject]@{
        Resolved   = $resolved.ToArray()
        Unresolved = $unresolved.ToArray()
    }
}

function Get-QOdmVerificationStatusForObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Verification,
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [Parameter(Mandatory = $true)][bool]$ShouldExist
    )

    $readSucceeded = [bool](Get-QOdmProperty -InputObject $Verification -Names @('ReadSucceeded') -Default $false)
    if (-not $readSucceeded) { return 'VERIFICATION_READ_FAILED' }

    $memberIds = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $Verification -Names @('MemberIds') -Default @())
    $isPresent = $false
    foreach ($memberId in $memberIds) {
        if ([string]::Equals([string]$memberId, $ObjectId, [StringComparison]::OrdinalIgnoreCase)) {
            $isPresent = $true
            break
        }
    }

    if ($ShouldExist -and $isPresent) { return 'VERIFIED_PRESENT' }
    if (-not $ShouldExist -and -not $isPresent) { return 'VERIFIED_ABSENT' }
    return 'NOT_VERIFIED'
}

function Invoke-QOdmCreateCollectionsFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [bool]$Execute = $false,
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmWorkloadSelected
    Set-QOdmOperationPhase -Phase 'Validating collection-creation CSV'
    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasAllHeaders -Headers $headers -RequiredHeaders @('CollectionName')
    Assert-QOdmCsvHasIdentityHeader -Headers $headers

    if ($script:QOdmState.Objects.Count -eq 0) { $null = Update-QOdmObjectCache }
    if ($script:QOdmState.Collections.Count -eq 0) { $null = Update-QOdmCollectionCache }

    $report = [System.Collections.Generic.List[object]]::new()
    $validRows = [System.Collections.Generic.List[object]]::new()
    $rowNumber = 0
    foreach ($row in $rows) {
        $rowNumber++
        $collectionName = Normalize-QOdmName ([string](Get-QOdmProperty -InputObject $row -Names @('CollectionName')))
        if ([string]::IsNullOrWhiteSpace($collectionName)) {
            $report.Add([pscustomobject]@{
                RowNumber=$rowNumber; CollectionName=$null; CollectionId=$null; SourceUPN=(Get-QOdmUpnFromRow -Row $row); ObjectId=$null
                CollectionAction='INVALID_ROW'; UserAction='NOT_RUN'; Status='INVALID_ROW'; Verified=$false; VerificationState='NOT_RUN'
                Details='CollectionName is required.'
            }) | Out-Null
            continue
        }
        $validRows.Add([pscustomobject]@{ RowNumber=$rowNumber; CollectionName=$collectionName; Row=$row }) | Out-Null
    }

    $groups = ConvertTo-QOdmObjectArray -InputObject ($validRows.ToArray() | Group-Object CollectionName)
    foreach ($group in $groups) {
        $collectionName = [string]$group.Name
        $collection = $null
        $collectionAction = 'EXISTING'
        $collectionError = $null

        try {
            $collection = Resolve-QOdmCollection -CollectionName $collectionName
            if ($null -eq $collection) {
                $collectionAction = if ($Execute) { 'CREATE_PENDING' } else { 'WOULD_CREATE' }
                if ($Execute) {
                    Set-QOdmOperationPhase -Phase "Creating collection '$collectionName'"
                    $createdView = New-QOdmCollection -Name $collectionName
                    $createdId = [string](Get-QOdmProperty -InputObject $createdView -Names @('Id'))
                    if (-not [string]::IsNullOrWhiteSpace($createdId)) {
                        $collection = Resolve-QOdmCollection -CollectionId $createdId
                    }
                    if ($null -eq $collection) { $collection = Resolve-QOdmCollection -CollectionName $collectionName }
                    if ($null -eq $collection) { throw "Collection '$collectionName' was created, but it could not be resolved during the post-write refresh." }
                    $collectionAction = 'CREATED'
                }
            }
        }
        catch {
            $collectionAction = if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_COLLECTION' } else { 'CREATE_OR_RESOLVE_FAILED' }
            $collectionError = $_.Exception.Message
        }

        $objectsById = @{}
        $groupRows = [System.Collections.Generic.List[object]]::new()
        foreach ($input in (ConvertTo-QOdmObjectArray -InputObject $group.Group)) {
            $row = Get-QOdmProperty -InputObject $input -Names @('Row')
            $sourceUpn = Get-QOdmUpnFromRow -Row $row
            $reportRow = [pscustomobject]@{
                RowNumber=[int](Get-QOdmProperty -InputObject $input -Names @('RowNumber') -Default 0)
                CollectionName=$collectionName
                CollectionId=if ($null -ne $collection) { Get-QOdmId -InputObject $collection } else { $null }
                SourceUPN=$sourceUpn
                ObjectId=$null
                CollectionAction=$collectionAction
                UserAction='NOT_RUN'
                Status='NOT_RUN'
                Verified=$false
                VerificationState='NOT_RUN'
                Details=$collectionError
            }

            if (-not [string]::IsNullOrWhiteSpace($collectionError)) {
                $reportRow.Status = $collectionAction
                $report.Add($reportRow) | Out-Null
                continue
            }
            if ([string]::IsNullOrWhiteSpace($sourceUpn)) {
                $reportRow.Status = 'BLANK_IDENTITY'
                $reportRow.Details = 'A supported source identity value is required.'
                $report.Add($reportRow) | Out-Null
                continue
            }

            try {
                $object = Resolve-QOdmObject -SourceUPN $sourceUpn
                if ($null -eq $object) {
                    $reportRow.Status = 'UNRESOLVED'
                    $reportRow.UserAction = 'UNRESOLVED'
                    $reportRow.Details = 'No ODM object matched the supplied identity.'
                    $report.Add($reportRow) | Out-Null
                    continue
                }
                $objectId = Get-QOdmId -InputObject $object
                $reportRow.ObjectId = $objectId
                if (-not [string]::IsNullOrWhiteSpace($objectId) -and -not $objectsById.ContainsKey($objectId)) { $objectsById[$objectId] = $object }
                $reportRow.UserAction = if ($Execute) { 'PENDING_ADD' } else { 'WOULD_ADD' }
                $reportRow.Status = if ($Execute) { 'PENDING' } else { 'DRY_RUN' }
                $groupRows.Add($reportRow) | Out-Null
                $report.Add($reportRow) | Out-Null
            }
            catch {
                $reportRow.Status = if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_IDENTITY' } else { 'RESOLUTION_FAILED' }
                $reportRow.UserAction = 'NOT_RUN'
                $reportRow.Details = $_.Exception.Message
                $report.Add($reportRow) | Out-Null
            }
        }

        if ($Execute -and $null -ne $collection -and $objectsById.Count -gt 0) {
            try {
                Set-QOdmOperationPhase -Phase "Adding users to collection '$collectionName'"
                $objects = ConvertTo-QOdmObjectArray -InputObject $objectsById.Values
                $null = Add-QOdmObjectsToEntity -Entity $collection -Objects $objects
                $verification = Test-QOdmEntityObjectMembership -Entity $collection -ObjectIds @($objectsById.Keys) -ShouldExist $true
                foreach ($item in $groupRows) {
                    $verificationStatus = Get-QOdmVerificationStatusForObject -Verification $verification -ObjectId ([string]$item.ObjectId) -ShouldExist $true
                    $item.VerificationState = $verificationStatus
                    $item.Verified = ($verificationStatus -eq 'VERIFIED_PRESENT')
                    $item.UserAction = if ($item.Verified) { 'VERIFIED_ADDED' } elseif ($verificationStatus -eq 'VERIFICATION_READ_FAILED') { 'ADD_SUBMITTED_READ_FAILED' } else { 'ADD_SUBMITTED_NOT_VERIFIED' }
                    $item.Status = if ($item.Verified) { 'COMPLETED' } else { $verificationStatus }
                    if (-not $item.Verified) {
                        $verificationError = [string](Get-QOdmProperty -InputObject $verification -Names @('Error'))
                        if (-not [string]::IsNullOrWhiteSpace($verificationError)) { $item.Details = $verificationError }
                    }
                }
            }
            catch {
                foreach ($item in $groupRows) {
                    $item.UserAction = 'FAILED'
                    $item.Status = 'FAILED'
                    $item.VerificationState = 'NOT_RUN'
                    $item.Details = $_.Exception.Message
                }
            }
        }
    }

    $path = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'CreateCollections_AddUsers_Report'
    Export-QOdmCsv -Rows $report.ToArray() -Path $path | Out-Null
    [pscustomobject]@{
        Execute          = $Execute
        CollectionGroups = $groups.Count
        VerifiedCount    = (ConvertTo-QOdmObjectArray -InputObject ($report.ToArray() | Where-Object { [bool](Get-QOdmProperty -InputObject $_ -Names @('Verified') -Default $false) })).Count
        Rows             = $report.ToArray()
        ReportPath       = $path
    }
}

function Invoke-QOdmRemoveUsersFromCollectionsCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [bool]$Execute = $false,
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmWorkloadSelected
    Set-QOdmOperationPhase -Phase 'Validating collection-removal CSV'
    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasAllHeaders -Headers $headers -RequiredHeaders @('CollectionName')
    Assert-QOdmCsvHasIdentityHeader -Headers $headers

    if ($script:QOdmState.Objects.Count -eq 0) { $null = Update-QOdmObjectCache }
    if ($script:QOdmState.Collections.Count -eq 0) { $null = Update-QOdmCollectionCache }

    $report = [System.Collections.Generic.List[object]]::new()
    $indexedRows = [System.Collections.Generic.List[object]]::new()
    $rowNumber = 0
    foreach ($row in $rows) {
        $rowNumber++
        $indexedRows.Add([pscustomobject]@{
            RowNumber=$rowNumber
            CollectionName=(Normalize-QOdmName ([string](Get-QOdmProperty -InputObject $row -Names @('CollectionName'))))
            Row=$row
        }) | Out-Null
    }

    foreach ($group in (ConvertTo-QOdmObjectArray -InputObject ($indexedRows.ToArray() | Group-Object CollectionName))) {
        $collectionName = [string]$group.Name
        if ([string]::IsNullOrWhiteSpace($collectionName)) {
            foreach ($input in (ConvertTo-QOdmObjectArray -InputObject $group.Group)) {
                $row = Get-QOdmProperty -InputObject $input -Names @('Row')
                $report.Add([pscustomobject]@{
                    RowNumber=(Get-QOdmProperty -InputObject $input -Names @('RowNumber')); CollectionName=$null; CollectionId=$null
                    SourceUPN=(Get-QOdmUpnFromRow -Row $row); ObjectId=$null; Action='NOT_RUN'; Status='INVALID_ROW'
                    Verified=$false; VerificationState='NOT_RUN'; Details='CollectionName is required.'
                }) | Out-Null
            }
            continue
        }

        $collection = $null
        $resolveError = $null
        try { $collection = Resolve-QOdmCollection -CollectionName $collectionName }
        catch { $resolveError = $_.Exception.Message }

        $objectsById = @{}
        $groupRows = [System.Collections.Generic.List[object]]::new()
        foreach ($input in (ConvertTo-QOdmObjectArray -InputObject $group.Group)) {
            $row = Get-QOdmProperty -InputObject $input -Names @('Row')
            $sourceUpn = Get-QOdmUpnFromRow -Row $row
            $resultRow = [pscustomobject]@{
                RowNumber=(Get-QOdmProperty -InputObject $input -Names @('RowNumber'))
                CollectionName=$collectionName
                CollectionId=if ($null -ne $collection) { Get-QOdmId -InputObject $collection } else { $null }
                SourceUPN=$sourceUpn
                ObjectId=$null
                Action=if ($Execute) { 'PENDING_REMOVE' } else { 'WOULD_REMOVE' }
                Status=if ($Execute) { 'PENDING' } else { 'DRY_RUN' }
                Verified=$false
                VerificationState='NOT_RUN'
                Details=$resolveError
            }

            if (-not [string]::IsNullOrWhiteSpace($resolveError)) {
                $resultRow.Action = 'NOT_RUN'
                $resultRow.Status = if ($resolveError -match 'ambiguous') { 'AMBIGUOUS_COLLECTION' } else { 'COLLECTION_RESOLUTION_FAILED' }
                $report.Add($resultRow) | Out-Null
                continue
            }
            if ($null -eq $collection) {
                $resultRow.Action = 'NOT_RUN'
                $resultRow.Status = 'COLLECTION_NOT_FOUND'
                $resultRow.Details = 'The collection was not found in the selected workload.'
                $report.Add($resultRow) | Out-Null
                continue
            }
            if ([string]::IsNullOrWhiteSpace($sourceUpn)) {
                $resultRow.Action = 'NOT_RUN'
                $resultRow.Status = 'BLANK_IDENTITY'
                $resultRow.Details = 'A supported source identity value is required.'
                $report.Add($resultRow) | Out-Null
                continue
            }

            try {
                $object = Resolve-QOdmObject -SourceUPN $sourceUpn
                if ($null -eq $object) {
                    $resultRow.Action = 'NOT_RUN'
                    $resultRow.Status = 'UNRESOLVED'
                    $resultRow.Details = 'No ODM object matched the supplied identity.'
                    $report.Add($resultRow) | Out-Null
                    continue
                }
                $objectId = Get-QOdmId -InputObject $object
                $resultRow.ObjectId = $objectId
                if (-not [string]::IsNullOrWhiteSpace($objectId) -and -not $objectsById.ContainsKey($objectId)) { $objectsById[$objectId] = $object }
                $groupRows.Add($resultRow) | Out-Null
                $report.Add($resultRow) | Out-Null
            }
            catch {
                $resultRow.Action = 'NOT_RUN'
                $resultRow.Status = if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_IDENTITY' } else { 'RESOLUTION_FAILED' }
                $resultRow.Details = $_.Exception.Message
                $report.Add($resultRow) | Out-Null
            }
        }

        if ($Execute -and $null -ne $collection -and $objectsById.Count -gt 0) {
            try {
                Set-QOdmOperationPhase -Phase "Removing users from collection '$collectionName'"
                $objects = ConvertTo-QOdmObjectArray -InputObject $objectsById.Values
                $null = Remove-QOdmObjectsFromEntity -Entity $collection -Objects $objects
                $verification = Test-QOdmEntityObjectMembership -Entity $collection -ObjectIds @($objectsById.Keys) -ShouldExist $false
                foreach ($item in $groupRows) {
                    $verificationStatus = Get-QOdmVerificationStatusForObject -Verification $verification -ObjectId ([string]$item.ObjectId) -ShouldExist $false
                    $item.VerificationState = $verificationStatus
                    $item.Verified = ($verificationStatus -eq 'VERIFIED_ABSENT')
                    $item.Action = if ($item.Verified) { 'VERIFIED_REMOVED' } elseif ($verificationStatus -eq 'VERIFICATION_READ_FAILED') { 'REMOVE_SUBMITTED_READ_FAILED' } else { 'REMOVE_SUBMITTED_NOT_VERIFIED' }
                    $item.Status = if ($item.Verified) { 'COMPLETED' } else { $verificationStatus }
                    if (-not $item.Verified) {
                        $verificationError = [string](Get-QOdmProperty -InputObject $verification -Names @('Error'))
                        if (-not [string]::IsNullOrWhiteSpace($verificationError)) { $item.Details = $verificationError }
                    }
                }
            }
            catch {
                foreach ($item in $groupRows) {
                    $item.Action = 'FAILED'
                    $item.Status = 'FAILED'
                    $item.VerificationState = 'NOT_RUN'
                    $item.Details = $_.Exception.Message
                }
            }
        }
    }

    $path = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'RemoveUsersFromCollections_Report'
    Export-QOdmCsv -Rows $report.ToArray() -Path $path | Out-Null
    [pscustomobject]@{ Execute=$Execute; Rows=$report.ToArray(); ReportPath=$path }
}

function Invoke-QOdmRemoveCollectionsFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [bool]$Execute = $false,
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmWorkloadSelected
    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasAnyHeader -Headers $headers -AcceptedHeaders @('CollectionId','CollectionID','Id','ID','CollectionName','Name') -Description 'a collection ID or collection name column'
    if ($script:QOdmState.Collections.Count -eq 0) { $null = Update-QOdmCollectionCache }

    $report = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $rowNumber = 0
    foreach ($row in $rows) {
        $rowNumber++
        $collectionId = [string](Get-QOdmProperty -InputObject $row -Names @('CollectionId','CollectionID','Id','ID'))
        $collectionName = Normalize-QOdmName ([string](Get-QOdmProperty -InputObject $row -Names @('CollectionName','Name')))
        if (-not [string]::IsNullOrWhiteSpace($collectionId)) { $collectionId = $collectionId.Trim() }
        $key = if (-not [string]::IsNullOrWhiteSpace($collectionId)) { 'id:' + $collectionId.ToLowerInvariant() } elseif ($collectionName) { 'name:' + $collectionName.ToLowerInvariant() } else { $null }

        $resultRow = [pscustomobject]@{
            RowNumber=$rowNumber; RequestedCollectionId=$collectionId; RequestedCollectionName=$collectionName
            CollectionId=$null; CollectionName=$null; Action='NOT_RUN'; Status='NOT_RUN'; Deleted=$false; Details=$null
        }
        if ($null -eq $key) {
            $resultRow.Status = 'INVALID_ROW'
            $resultRow.Details = 'A collection ID or name is required.'
            $report.Add($resultRow) | Out-Null
            continue
        }
        if ($seen.ContainsKey($key)) {
            $resultRow.Status = 'DUPLICATE_INPUT'
            $resultRow.Details = 'The same collection reference appeared earlier in the CSV.'
            $report.Add($resultRow) | Out-Null
            continue
        }
        $seen[$key] = $true

        try {
            $collection = Resolve-QOdmCollection -CollectionId $collectionId -CollectionName $collectionName
            if ($null -eq $collection) {
                $resultRow.Status = 'NOT_FOUND'
                $resultRow.Details = 'The collection was not found in the selected workload.'
            }
            else {
                $resultRow.CollectionId = Get-QOdmId -InputObject $collection
                $resultRow.CollectionName = Get-QOdmName -InputObject $collection
                if (-not $Execute) {
                    $resultRow.Action = 'WOULD_DELETE'
                    $resultRow.Status = 'DRY_RUN'
                }
                else {
                    $deleteRows = ConvertTo-QOdmObjectArray -InputObject (Remove-QOdmCollections -CollectionIds @([string]$resultRow.CollectionId))
                    $deleteResult = $deleteRows | Select-Object -First 1
                    if ($null -eq $deleteResult) { throw 'Collection deletion returned no result record.' }
                    $resultRow.Action = [string](Get-QOdmProperty -InputObject $deleteResult -Names @('Status') -Default 'UNKNOWN')
                    $resultRow.Status = $resultRow.Action
                    $resultRow.Deleted = [bool](Get-QOdmProperty -InputObject $deleteResult -Names @('Deleted') -Default $false)
                    $resultRow.Details = [string](Get-QOdmProperty -InputObject $deleteResult -Names @('Details'))
                }
            }
        }
        catch {
            $resultRow.Status = if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_NAME' } else { 'FAILED' }
            $resultRow.Action = 'NOT_RUN'
            $resultRow.Details = $_.Exception.Message
        }
        $report.Add($resultRow) | Out-Null
    }

    $path = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'RemoveCollections_Report'
    Export-QOdmCsv -Rows $report.ToArray() -Path $path | Out-Null
    [pscustomobject]@{ Execute=$Execute; Rows=$report.ToArray(); ReportPath=$path }
}

function Invoke-QOdmFindUserMembershipsFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [Parameter(Mandatory = $true)][ValidateSet('Task','Collection')][string]$EntityType,
        [string[]]$NamePatterns = @(),
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmWorkloadSelected
    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasIdentityHeader -Headers $headers
    $patterns = @(Assert-QOdmRegexPatterns -Patterns $NamePatterns -Description "$EntityType-name pattern")
    $userResolution = Resolve-QOdmCsvUsers -Rows $rows

    if ($EntityType -eq 'Task') {
        if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }
        $entities = ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Tasks.Values
    }
    else {
        if ($script:QOdmState.Collections.Count -eq 0) { $null = Update-QOdmCollectionCache }
        $entities = ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Collections.Values
    }

    if ($patterns.Count -gt 0) {
        $entities = @($entities | Where-Object {
            $entityName = [string](Get-QOdmName -InputObject $_)
            $matched = $false
            foreach ($pattern in $patterns) {
                if ($entityName -match $pattern) { $matched = $true; break }
            }
            $matched
        })
    }

    $resolvedById = @{}
    foreach ($resolved in (ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $userResolution -Names @('Resolved') -Default @()))) {
        $objectId = [string](Get-QOdmProperty -InputObject $resolved -Names @('ObjectId'))
        if (-not [string]::IsNullOrWhiteSpace($objectId)) { $resolvedById[$objectId] = $resolved }
    }

    $membershipRows = [System.Collections.Generic.List[object]]::new()
    $removalPlanRows = [System.Collections.Generic.List[object]]::new()
    $readErrorRows = [System.Collections.Generic.List[object]]::new()

    foreach ($entity in $entities) {
        $entityId = Get-QOdmId -InputObject $entity
        $entityName = Get-QOdmName -InputObject $entity
        try {
            Set-QOdmOperationPhase -Phase "Reading $EntityType membership for '$entityName'"
            $memberOutput = $entity | Get-OdmObject -All -ErrorAction Stop
            $members = ConvertTo-QOdmObjectArray -InputObject $memberOutput
            foreach ($member in $members) {
                $memberId = Get-QOdmId -InputObject $member
                if ([string]::IsNullOrWhiteSpace($memberId) -or -not $resolvedById.ContainsKey($memberId)) { continue }
                $resolved = $resolvedById[$memberId]
                $sourceUpn = [string](Get-QOdmProperty -InputObject $resolved -Names @('SourceUPN'))

                if ($EntityType -eq 'Task') {
                    $view = ConvertTo-QOdmTaskView -Task $entity
                    $membershipRows.Add([pscustomobject]@{
                        SourceUPN=$sourceUpn; ObjectId=$memberId; EntityType='Task'; EntityId=$view.Id; EntityName=$view.Name
                        TaskId=$view.Id; TaskName=$view.Name; CollectionId=$null; CollectionName=$null
                        Type=$view.Type; Status=$view.Status; Context=$view.Context
                    }) | Out-Null
                    $removalPlanRows.Add([pscustomobject]@{
                        TaskId=$view.Id; TaskName=$view.Name; ObjectId=$memberId; SourceUPN=$sourceUpn
                    }) | Out-Null
                }
                else {
                    $view = ConvertTo-QOdmCollectionView -Collection $entity
                    $membershipRows.Add([pscustomobject]@{
                        SourceUPN=$sourceUpn; ObjectId=$memberId; EntityType='Collection'; EntityId=$view.Id; EntityName=$view.Name
                        TaskId=$null; TaskName=$null; CollectionId=$view.Id; CollectionName=$view.Name
                        Type=$null; Status=$null; Context=$view.Description
                    }) | Out-Null
                    $removalPlanRows.Add([pscustomobject]@{
                        CollectionId=$view.Id; CollectionName=$view.Name; ObjectId=$memberId; SourceUPN=$sourceUpn
                    }) | Out-Null
                }
            }
        }
        catch {
            $readErrorRows.Add([pscustomobject]@{
                EntityType=$EntityType; EntityId=$entityId; EntityName=$entityName; Status='MEMBERSHIP_READ_FAILED'; Details=$_.Exception.Message
            }) | Out-Null
        }
    }

    $base = if ($EntityType -eq 'Task') { 'UserTaskMemberships' } else { 'UserCollectionMemberships' }
    $membershipPath = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName ($base + '_Report')
    $planPath = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName ($base + '_RemovalPlan')
    $unresolvedPath = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName ($base + '_Unresolved')
    $readErrorsPath = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName ($base + '_ReadErrors')
    Export-QOdmCsv -Rows $membershipRows.ToArray() -Path $membershipPath | Out-Null
    Export-QOdmCsv -Rows $removalPlanRows.ToArray() -Path $planPath | Out-Null
    Export-QOdmCsv -Rows (ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $userResolution -Names @('Unresolved') -Default @())) -Path $unresolvedPath | Out-Null
    Export-QOdmCsv -Rows $readErrorRows.ToArray() -Path $readErrorsPath | Out-Null

    [pscustomobject]@{
        EntityType       = $EntityType
        MembershipRows   = $membershipRows.ToArray()
        RemovalPlanRows  = $removalPlanRows.ToArray()
        UnresolvedRows   = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $userResolution -Names @('Unresolved') -Default @())
        ReadErrorRows    = $readErrorRows.ToArray()
        MembershipReportPath = $membershipPath
        RemovalPlanPath  = $planPath
        UnresolvedPath   = $unresolvedPath
        ReadErrorsPath   = $readErrorsPath
    }
}

function Invoke-QOdmMatchObjectsFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [string]$EmailColumn = 'SourceEmail',
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmWorkloadSelected
    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    if ([string]::IsNullOrWhiteSpace($EmailColumn)) { $EmailColumn = 'SourceEmail' }
    Assert-QOdmCsvHasAnyHeader -Headers $headers -AcceptedHeaders @($EmailColumn) -Description "the requested identity column '$EmailColumn'"
    if ($script:QOdmState.Objects.Count -eq 0) { $null = Update-QOdmObjectCache }

    $matched = [System.Collections.Generic.List[object]]::new()
    $notFound = [System.Collections.Generic.List[object]]::new()
    $rowNumber = 0
    foreach ($row in $rows) {
        $rowNumber++
        $identity = Normalize-QOdmUpn ([string](Get-QOdmProperty -InputObject $row -Names @($EmailColumn)))
        if ([string]::IsNullOrWhiteSpace($identity)) {
            $notFound.Add([pscustomobject]@{ RowNumber=$rowNumber; InputValue=$null; Status='BLANK_IDENTITY'; Details="Column '$EmailColumn' was blank." }) | Out-Null
            continue
        }
        try {
            $object = Resolve-QOdmObject -SourceUPN $identity
            if ($null -eq $object) {
                $notFound.Add([pscustomobject]@{ RowNumber=$rowNumber; InputValue=$identity; Status='NOT_FOUND'; Details='No ODM object matched.' }) | Out-Null
            }
            else {
                $view = ConvertTo-QOdmObjectView -Object $object
                $matched.Add([pscustomobject]@{
                    RowNumber=$rowNumber; InputValue=$identity; ObjectId=$view.Id; DisplayName=$view.DisplayName; Name=$view.Name
                    SourceUPN=$view.SourceUPN; TargetUPN=$view.TargetUPN; SourceEmail=$view.SourceEmail; TargetEmail=$view.TargetEmail
                    ObjectType=$view.ObjectType; MigrationStatus=$view.MigrationStatus; Status='MATCHED'
                }) | Out-Null
            }
        }
        catch {
            $notFound.Add([pscustomobject]@{
                RowNumber=$rowNumber; InputValue=$identity; Status=if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_IDENTITY' } else { 'RESOLUTION_FAILED' }; Details=$_.Exception.Message
            }) | Out-Null
        }
    }

    $matchedPath = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'ObjectInfo_Matched'
    $notFoundPath = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'ObjectInfo_NotFound'
    Export-QOdmCsv -Rows $matched.ToArray() -Path $matchedPath | Out-Null
    Export-QOdmCsv -Rows $notFound.ToArray() -Path $notFoundPath | Out-Null
    [pscustomobject]@{ Matched=$matched.ToArray(); NotFound=$notFound.ToArray(); MatchedPath=$matchedPath; NotFoundPath=$notFoundPath }
}

function Invoke-QOdmRemoveUsersFromTasksPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [bool]$Execute = $false,
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmWorkloadSelected
    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasAnyHeader -Headers $headers -AcceptedHeaders @('TaskId','TaskID','TaskName','Name') -Description 'a task ID or task name column'
    if (-not (Test-QOdmHeaderMatch -Headers $headers -Candidate 'ObjectId') -and -not (Test-QOdmCsvIdentityHeaders -Headers $headers)) {
        throw 'CSV must contain ObjectId or a supported source identity column.'
    }
    if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }
    if ($script:QOdmState.Objects.Count -eq 0) { $null = Update-QOdmObjectCache }

    $report = [System.Collections.Generic.List[object]]::new()
    $indexedRows = [System.Collections.Generic.List[object]]::new()
    $rowNumber = 0
    foreach ($row in $rows) {
        $rowNumber++
        $indexedRows.Add([pscustomobject]@{
            RowNumber=$rowNumber
            TaskId=[string](Get-QOdmProperty -InputObject $row -Names @('TaskId','TaskID'))
            TaskName=Normalize-QOdmName ([string](Get-QOdmProperty -InputObject $row -Names @('TaskName','Name')))
            Row=$row
        }) | Out-Null
    }

    foreach ($group in (ConvertTo-QOdmObjectArray -InputObject ($indexedRows.ToArray() | Group-Object { if (-not [string]::IsNullOrWhiteSpace([string]$_.TaskId)) { 'id:' + ([string]$_.TaskId).Trim().ToLowerInvariant() } else { 'name:' + ([string]$_.TaskName).ToLowerInvariant() } }))) {
        $groupItems = ConvertTo-QOdmObjectArray -InputObject $group.Group
        $first = $groupItems[0]
        $taskId = [string](Get-QOdmProperty -InputObject $first -Names @('TaskId'))
        $taskName = [string](Get-QOdmProperty -InputObject $first -Names @('TaskName'))
        if (-not [string]::IsNullOrWhiteSpace($taskId)) { $taskId = $taskId.Trim() }
        $task = $null
        $taskError = $null
        if ([string]::IsNullOrWhiteSpace($taskId) -and [string]::IsNullOrWhiteSpace($taskName)) { $taskError = 'A task ID or name is required.' }
        else {
            try { $task = Resolve-QOdmTask -TaskId $taskId -TaskName $taskName }
            catch { $taskError = $_.Exception.Message }
            if ($null -eq $task -and [string]::IsNullOrWhiteSpace($taskError)) { $taskError = 'Task was not found in the selected workload.' }
        }

        $seenObjectIds = @{}
        $pending = [System.Collections.Generic.List[object]]::new()
        foreach ($input in (ConvertTo-QOdmObjectArray -InputObject $group.Group)) {
            $row = Get-QOdmProperty -InputObject $input -Names @('Row')
            $objectId = [string](Get-QOdmProperty -InputObject $row -Names @('ObjectId','ObjectID'))
            if (-not [string]::IsNullOrWhiteSpace($objectId)) { $objectId = $objectId.Trim() }
            $sourceUpn = Get-QOdmUpnFromRow -Row $row
            $resultRow = [pscustomobject]@{
                RowNumber=(Get-QOdmProperty -InputObject $input -Names @('RowNumber'))
                TaskId=if ($null -ne $task) { Get-QOdmId -InputObject $task } else { $taskId }
                TaskName=if ($null -ne $task) { Get-QOdmName -InputObject $task } else { $taskName }
                ObjectId=$objectId; SourceUPN=$sourceUpn; Action=if ($Execute) { 'PENDING_REMOVE' } else { 'WOULD_REMOVE' }
                Status=if ($Execute) { 'PENDING' } else { 'DRY_RUN' }; CommandSucceeded=$false; Verified=$false; VerificationState='NOT_RUN'; Details=$taskError
            }
            if (-not [string]::IsNullOrWhiteSpace($taskError)) {
                $resultRow.Action = 'NOT_RUN'
                $resultRow.Status = if ($taskError -match 'ambiguous') { 'AMBIGUOUS_TASK' } elseif ($taskError -match 'required') { 'INVALID_ROW' } else { 'TASK_NOT_FOUND' }
                $report.Add($resultRow) | Out-Null
                continue
            }
            if ([string]::IsNullOrWhiteSpace($objectId) -and [string]::IsNullOrWhiteSpace($sourceUpn)) {
                $resultRow.Action='NOT_RUN'; $resultRow.Status='BLANK_IDENTITY'; $resultRow.Details='The row does not contain ObjectId or a supported source identity.'
                $report.Add($resultRow) | Out-Null
                continue
            }

            try {
                $object = if (-not [string]::IsNullOrWhiteSpace($objectId)) { Resolve-QOdmObject -ObjectId $objectId } else { Resolve-QOdmObject -SourceUPN $sourceUpn }
                if ($null -eq $object) {
                    $resultRow.Action = 'NOT_RUN'; $resultRow.Status = 'OBJECT_NOT_FOUND'; $resultRow.Details = 'The ODM object was not found.'
                    $report.Add($resultRow) | Out-Null
                    continue
                }
                $resolvedId = [string](Get-QOdmId -InputObject $object)
                if ([string]::IsNullOrWhiteSpace($resolvedId)) {
                    $resultRow.Action='NOT_RUN'; $resultRow.Status='OBJECT_ID_MISSING'; $resultRow.Details='The resolved ODM object does not expose a usable ID.'
                    $report.Add($resultRow) | Out-Null
                    continue
                }
                $resultRow.ObjectId = $resolvedId
                if ([string]::IsNullOrWhiteSpace($resultRow.SourceUPN)) { $resultRow.SourceUPN = Get-QOdmSourceUpn -InputObject $object }
                if ($seenObjectIds.ContainsKey($resolvedId)) {
                    $resultRow.Action='NOT_RUN'; $resultRow.Status='DUPLICATE_OBJECT'; $resultRow.Details='This row resolves to an ODM object already listed for the same task.'
                    $report.Add($resultRow) | Out-Null
                    continue
                }
                $seenObjectIds[$resolvedId] = $true
                $pending.Add([pscustomobject]@{ Object=$object; ObjectId=$resolvedId; ReportRow=$resultRow }) | Out-Null
                $report.Add($resultRow) | Out-Null
            }
            catch {
                $resultRow.Action = 'NOT_RUN'
                $resultRow.Status = if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_IDENTITY' } else { 'RESOLUTION_FAILED' }
                $resultRow.Details = $_.Exception.Message
                $report.Add($resultRow) | Out-Null
            }
        }

        if ($Execute -and $null -ne $task -and $pending.Count -gt 0) {
            $successful = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $pending) {
                $resultRow = Get-QOdmProperty -InputObject $item -Names @('ReportRow')
                try {
                    $null = Remove-QOdmObjectsFromEntity -Entity $task -Objects @((Get-QOdmProperty -InputObject $item -Names @('Object')))
                    $resultRow.CommandSucceeded=$true
                    $resultRow.Action='REMOVE_SUBMITTED'
                    $resultRow.Status='COMMAND_SUCCEEDED'
                    $successful.Add($item) | Out-Null
                }
                catch {
                    $resultRow.Action='FAILED'; $resultRow.Status='COMMAND_FAILED'; $resultRow.VerificationState='NOT_RUN'; $resultRow.Details=$_.Exception.Message
                }
            }

            if ($successful.Count -gt 0) {
                $successfulIds = ConvertTo-QOdmObjectArray -InputObject ($successful.ToArray() | ForEach-Object { [string](Get-QOdmProperty -InputObject $_ -Names @('ObjectId')) })
                $verification = Test-QOdmEntityObjectMembership -Entity $task -ObjectIds $successfulIds -ShouldExist $false
                foreach ($item in $successful) {
                    $resultRow = Get-QOdmProperty -InputObject $item -Names @('ReportRow')
                    $verificationStatus = Get-QOdmVerificationStatusForObject -Verification $verification -ObjectId ([string](Get-QOdmProperty -InputObject $item -Names @('ObjectId'))) -ShouldExist $false
                    $resultRow.VerificationState = $verificationStatus
                    $resultRow.Verified = ($verificationStatus -eq 'VERIFIED_ABSENT')
                    $resultRow.Action = if ($resultRow.Verified) { 'VERIFIED_REMOVED' } elseif ($verificationStatus -eq 'VERIFICATION_READ_FAILED') { 'REMOVE_SUBMITTED_READ_FAILED' } else { 'REMOVE_SUBMITTED_NOT_VERIFIED' }
                    $resultRow.Status = if ($resultRow.Verified) { 'COMPLETED' } else { $verificationStatus }
                    if (-not $resultRow.Verified) {
                        $verificationError = [string](Get-QOdmProperty -InputObject $verification -Names @('Error'))
                        if (-not [string]::IsNullOrWhiteSpace($verificationError)) { $resultRow.Details = $verificationError }
                        elseif ($verificationStatus -eq 'NOT_VERIFIED') { $resultRow.Details='The removal command completed, but the object was still present after verification retries.' }
                    }
                }
            }
        }
    }

    $path = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'RemoveUsersFromTasks_Report'
    Export-QOdmCsv -Rows $report.ToArray() -Path $path | Out-Null
    [pscustomobject]@{ Execute=$Execute; Rows=$report.ToArray(); ReportPath=$path; VerifiedCount=(ConvertTo-QOdmObjectArray -InputObject ($report.ToArray() | Where-Object { [bool](Get-QOdmProperty -InputObject $_ -Names @('Verified') -Default $false) })).Count }
}

function Get-QOdmAllProjectContexts {
    [CmdletBinding()]
    param()

    Assert-QOdmOrganizationSelected
    $roots = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProjectsAll)
    $contexts = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($root in $roots) {
        $rootId = Get-QOdmId -InputObject $root
        if ([string]::IsNullOrWhiteSpace($rootId)) { continue }
        if (-not $seen.ContainsKey($rootId)) {
            $seen[$rootId] = $true
            $contexts.Add([pscustomobject]@{
                RootProjectId=$rootId; RootProjectName=(Get-QOdmName -InputObject $root); ContextId=$rootId
                ContextName=(Get-QOdmName -InputObject $root); ContextType='Project'; ContextObject=$root; RootProject=$root
            }) | Out-Null
        }
        try {
            foreach ($workload in (ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProjectWorkloads -Project $root))) {
                $workloadId = Get-QOdmId -InputObject $workload
                if ([string]::IsNullOrWhiteSpace($workloadId) -or $seen.ContainsKey($workloadId)) { continue }
                $seen[$workloadId] = $true
                $contexts.Add([pscustomobject]@{
                    RootProjectId=$rootId; RootProjectName=(Get-QOdmName -InputObject $root); ContextId=$workloadId
                    ContextName=(Get-QOdmName -InputObject $workload); ContextType='Workload'; ContextObject=$workload; RootProject=$root
                }) | Out-Null
            }
        }
        catch {
            Add-QOdmWarning -Message ("Workloads could not be enumerated for project '$((Get-QOdmName -InputObject $root))' [$rootId]: $($_.Exception.Message)")
        }
    }
    return $contexts.ToArray()
}

function Select-QOdmRawContextObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$ContextDescriptor)

    $contextType = [string](Get-QOdmProperty -InputObject $ContextDescriptor -Names @('ContextType'))
    $contextObject = Get-QOdmProperty -InputObject $ContextDescriptor -Names @('ContextObject')
    $contextId = [string](Get-QOdmProperty -InputObject $ContextDescriptor -Names @('ContextId'))
    if ($null -eq $contextObject) { throw "Quest context object '$contextId' is unavailable." }

    if ($contextType -eq 'Workload') {
        Select-QOdmProjectWorkloadSafe -Workload $contextObject -ProjectWorkloadId $contextId
    }
    else {
        Select-QOdmProjectSafe -Project $contextObject -ProjectId $contextId
    }
}

function Resolve-QOdmContextDescriptor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Contexts, [Parameter(Mandatory = $true)][string]$ContextId)

    $matches = @($Contexts | Where-Object { [string]::Equals([string](Get-QOdmProperty -InputObject $_ -Names @('ContextId')), $ContextId, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -gt 1) { throw "Project/workload ID '$ContextId' matched more than one context." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Invoke-QOdmDeleteTasksAcrossProjectsFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [bool]$Execute = $false,
        [bool]$StopRunning = $true,
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmOrganizationSelected
    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasAnyHeader -Headers $headers -AcceptedHeaders @('ProjectId','ProjectID','WorkloadId','ProjectWorkloadId') -Description 'a project or workload ID column'
    Assert-QOdmCsvHasAnyHeader -Headers $headers -AcceptedHeaders @('TaskId','TaskID','Id','ID','TaskName','Name') -Description 'a task ID or task name column'

    Set-QOdmOperationPhase -Phase 'Enumerating Quest project and workload contexts'
    $contexts = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmAllProjectContexts)
    $savedContext = Get-QOdmContextSnapshot
    $report = [System.Collections.Generic.List[object]]::new()
    $contextSelectionAttempted = $false

    try {
        $rowNumber = 0
        foreach ($row in $rows) {
            $rowNumber++
            $contextId = [string](Get-QOdmProperty -InputObject $row -Names @('ProjectId','ProjectID','WorkloadId','ProjectWorkloadId'))
            $taskId = [string](Get-QOdmProperty -InputObject $row -Names @('TaskId','TaskID','Id','ID'))
            $taskName = Normalize-QOdmName ([string](Get-QOdmProperty -InputObject $row -Names @('TaskName','Name')))
            if (-not [string]::IsNullOrWhiteSpace($contextId)) { $contextId = $contextId.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($taskId)) { $taskId = $taskId.Trim() }

            $resultRow = [pscustomobject]@{
                RowNumber=$rowNumber; ProjectId=$contextId; ProjectName=$null; WorkloadId=$null; WorkloadName=$null
                TaskId=$taskId; TaskName=$taskName; PreviousStatus=$null; Action='NOT_RUN'; Status='NOT_RUN'; Deleted=$false; Details=$null
            }
            if ([string]::IsNullOrWhiteSpace($contextId) -or ([string]::IsNullOrWhiteSpace($taskId) -and [string]::IsNullOrWhiteSpace($taskName))) {
                $resultRow.Status = 'INVALID_ROW'
                $resultRow.Details = 'A project/workload ID and task ID or task name are required.'
                $report.Add($resultRow) | Out-Null
                continue
            }

            try {
                $descriptor = Resolve-QOdmContextDescriptor -Contexts $contexts -ContextId $contextId
                if ($null -eq $descriptor) {
                    $resultRow.Status = 'PROJECT_NOT_FOUND'
                    $resultRow.Details = 'The project or workload context was not found in the selected organization.'
                    $report.Add($resultRow) | Out-Null
                    continue
                }
                $resultRow.ProjectId = [string](Get-QOdmProperty -InputObject $descriptor -Names @('RootProjectId'))
                $resultRow.ProjectName = [string](Get-QOdmProperty -InputObject $descriptor -Names @('RootProjectName'))
                if ([string](Get-QOdmProperty -InputObject $descriptor -Names @('ContextType')) -eq 'Workload') {
                    $resultRow.WorkloadId = [string](Get-QOdmProperty -InputObject $descriptor -Names @('ContextId'))
                    $resultRow.WorkloadName = [string](Get-QOdmProperty -InputObject $descriptor -Names @('ContextName'))
                }

                Set-QOdmOperationPhase -Phase "Selecting context '$contextId' for task lookup"
                $contextSelectionAttempted = $true
                Select-QOdmRawContextObject -ContextDescriptor $descriptor
                Set-QOdmOperationPhase -Phase "Reading tasks in context '$contextId'"
                $tasks = Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmTask' -Parameters @{ All=$true } -RequiredParameters @('All')
                $task = Resolve-QOdmExactEntity -Entities $tasks -Id $taskId -Name $taskName -EntityType 'Task'
                if ($null -eq $task) {
                    $resultRow.Status = 'TASK_NOT_FOUND'
                    $resultRow.Details = 'The task was not found in the specified project/workload context.'
                    $report.Add($resultRow) | Out-Null
                    continue
                }

                $resultRow.TaskId = Get-QOdmId -InputObject $task
                $resultRow.TaskName = Get-QOdmName -InputObject $task
                $resultRow.PreviousStatus = Get-QOdmTaskStatus -Task $task
                if (-not $Execute) {
                    $resultRow.Action = 'WOULD_DELETE'
                    $resultRow.Status = 'DRY_RUN'
                }
                else {
                    Set-QOdmOperationPhase -Phase "Deleting task in context '$contextId'"
                    $deleteResult = Remove-QOdmTaskSafely -Task $task -StopRunning $StopRunning
                    $resultRow.Action = [string](Get-QOdmProperty -InputObject $deleteResult -Names @('Status') -Default 'UNKNOWN')
                    $resultRow.Status = $resultRow.Action
                    $resultRow.Deleted = [bool](Get-QOdmProperty -InputObject $deleteResult -Names @('Deleted') -Default $false)
                    $resultRow.Details = [string](Get-QOdmProperty -InputObject $deleteResult -Names @('Details'))
                }
            }
            catch {
                $resultRow.Status = if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_TASK' } else { 'FAILED' }
                $resultRow.Action = 'NOT_RUN'
                $resultRow.Details = $_.Exception.Message
            }
            $report.Add($resultRow) | Out-Null
        }
    }
    finally {
        if ($contextSelectionAttempted) {
            try { $null = Restore-QOdmContextSnapshot -Snapshot $savedContext }
            catch {
                $report.Add([pscustomobject]@{
                    RowNumber=0; ProjectId=(Get-QOdmProperty -InputObject $savedContext -Names @('ProjectId')); ProjectName=(Get-QOdmProperty -InputObject $savedContext -Names @('ProjectName'))
                    WorkloadId=(Get-QOdmProperty -InputObject $savedContext -Names @('WorkloadId')); WorkloadName=(Get-QOdmProperty -InputObject $savedContext -Names @('WorkloadName'))
                    TaskId=$null; TaskName=$null; PreviousStatus=$null; Action='NOT_RUN'; Status='CONTEXT_RESTORE_FAILED'; Deleted=$false; Details=$_.Exception.Message
                }) | Out-Null
            }
        }
    }

    $path = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'DeleteTasksAcrossProjects_Report'
    Export-QOdmCsv -Rows $report.ToArray() -Path $path | Out-Null
    [pscustomobject]@{ Execute=$Execute; Rows=$report.ToArray(); ReportPath=$path; ContextValid=$script:QOdmState.ContextValid }
}

function Invoke-QOdmSetTaskRunStateFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [Parameter(Mandatory = $true)][ValidateSet('Start','Stop')][string]$Action,
        [bool]$Execute = $false,
        [AllowNull()][string]$OutputDirectory = $null,
        [int]$DelaySeconds = 2
    )

    Assert-QOdmWorkloadSelected
    if ($DelaySeconds -lt 0) { $DelaySeconds = 0 }
    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasAnyHeader -Headers $headers -AcceptedHeaders @('TaskId','TaskID','Id','ID','TaskName','Name') -Description 'a task ID or task name column'
    if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }

    $report = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $rowNumber = 0
    foreach ($row in $rows) {
        $rowNumber++
        $taskId = [string](Get-QOdmProperty -InputObject $row -Names @('TaskId','TaskID','Id','ID'))
        $taskName = Normalize-QOdmName ([string](Get-QOdmProperty -InputObject $row -Names @('TaskName','Name')))
        if (-not [string]::IsNullOrWhiteSpace($taskId)) { $taskId = $taskId.Trim() }
        $key = if (-not [string]::IsNullOrWhiteSpace($taskId)) { 'id:' + $taskId.ToLowerInvariant() } elseif ($taskName) { 'name:' + $taskName.ToLowerInvariant() } else { $null }
        $resultRow = [pscustomobject]@{
            RowNumber=$rowNumber; RequestedTaskId=$taskId; RequestedTaskName=$taskName; TaskId=$null; TaskName=$null
            PreviousStatus=$null; RequestedAction=$Action; ActionAttempted=$false; ActionSucceeded=$false; Status='NOT_RUN'; Details=$null
        }
        if ($null -eq $key) {
            $resultRow.Status='INVALID_ROW'; $resultRow.Details='A task ID or task name is required.'; $report.Add($resultRow) | Out-Null; continue
        }
        if ($seen.ContainsKey($key)) {
            $resultRow.Status='DUPLICATE_INPUT'; $resultRow.Details='The same task reference appeared earlier in the CSV.'; $report.Add($resultRow) | Out-Null; continue
        }
        $seen[$key] = $true
        try {
            $task = Resolve-QOdmTask -TaskId $taskId -TaskName $taskName
            if ($null -eq $task) {
                $resultRow.Status='NOT_FOUND'; $resultRow.Details='The task was not found in the selected workload.'
            }
            else {
                $resultRow.TaskId = Get-QOdmId -InputObject $task
                $resultRow.TaskName = Get-QOdmName -InputObject $task
                $resultRow.PreviousStatus = Get-QOdmTaskStatus -Task $task
                if (-not $Execute) {
                    $resultRow.Status = 'DRY_RUN'
                    $resultRow.Details = "The task would be submitted to $Action-OdmTask."
                }
                else {
                    $actionResult = if ($Action -eq 'Start') { Start-QOdmTaskSafely -Task $task -DelaySeconds $DelaySeconds } else { Stop-QOdmTaskSafely -Task $task -DelaySeconds $DelaySeconds }
                    if ($Action -eq 'Start') {
                        $resultRow.ActionAttempted = [bool](Get-QOdmProperty -InputObject $actionResult -Names @('StartAttempted') -Default $false)
                        $resultRow.ActionSucceeded = [bool](Get-QOdmProperty -InputObject $actionResult -Names @('StartSucceeded') -Default $false)
                    }
                    else {
                        $resultRow.ActionAttempted = [bool](Get-QOdmProperty -InputObject $actionResult -Names @('StopAttempted') -Default $false)
                        $resultRow.ActionSucceeded = [bool](Get-QOdmProperty -InputObject $actionResult -Names @('StopSucceeded') -Default $false)
                    }
                    $resultRow.Status = [string](Get-QOdmProperty -InputObject $actionResult -Names @('Status') -Default 'UNKNOWN')
                    $resultRow.Details = [string](Get-QOdmProperty -InputObject $actionResult -Names @('Details'))
                }
            }
        }
        catch {
            $resultRow.Status = if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_NAME' } else { 'FAILED' }
            $resultRow.Details = $_.Exception.Message
        }
        $report.Add($resultRow) | Out-Null
    }

    if ($Execute) { $null = Update-QOdmTaskCache }
    $path = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName ("{0}Tasks_Report" -f $Action)
    Export-QOdmCsv -Rows $report.ToArray() -Path $path | Out-Null
    [pscustomobject]@{ Execute=$Execute; Action=$Action; Rows=$report.ToArray(); ReportPath=$path }
}

function Invoke-QOdmStartTasksFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [bool]$Execute = $false,
        [AllowNull()][string]$OutputDirectory = $null,
        [int]$DelaySeconds = 2
    )
    Invoke-QOdmSetTaskRunStateFromCsv -CsvPath $CsvPath -Action Start -Execute $Execute -OutputDirectory $OutputDirectory -DelaySeconds $DelaySeconds
}

function Invoke-QOdmStopTasksFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [bool]$Execute = $false,
        [AllowNull()][string]$OutputDirectory = $null,
        [int]$DelaySeconds = 2
    )
    Invoke-QOdmSetTaskRunStateFromCsv -CsvPath $CsvPath -Action Stop -Execute $Execute -OutputDirectory $OutputDirectory -DelaySeconds $DelaySeconds
}

function Invoke-QOdmDeleteTasksFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [bool]$Execute = $false,
        [bool]$StopRunning = $true,
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmWorkloadSelected
    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasAnyHeader -Headers $headers -AcceptedHeaders @('TaskId','TaskID','Id','ID','TaskName','Name') -Description 'a task ID or task name column'
    if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }

    $report = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $rowNumber = 0
    foreach ($row in $rows) {
        $rowNumber++
        $taskId = [string](Get-QOdmProperty -InputObject $row -Names @('TaskId','TaskID','Id','ID'))
        $taskName = Normalize-QOdmName ([string](Get-QOdmProperty -InputObject $row -Names @('TaskName','Name')))
        if (-not [string]::IsNullOrWhiteSpace($taskId)) { $taskId = $taskId.Trim() }
        $key = if (-not [string]::IsNullOrWhiteSpace($taskId)) { 'id:' + $taskId.ToLowerInvariant() } elseif ($taskName) { 'name:' + $taskName.ToLowerInvariant() } else { $null }
        $resultRow = [pscustomobject]@{
            RowNumber=$rowNumber; RequestedTaskId=$taskId; RequestedTaskName=$taskName; TaskId=$null; TaskName=$null
            PreviousStatus=$null; Action='NOT_RUN'; Status='NOT_RUN'; Deleted=$false; Details=$null
        }
        if ($null -eq $key) {
            $resultRow.Status='INVALID_ROW'; $resultRow.Details='A task ID or name is required.'; $report.Add($resultRow) | Out-Null; continue
        }
        if ($seen.ContainsKey($key)) {
            $resultRow.Status='DUPLICATE_INPUT'; $resultRow.Details='The same task reference appeared earlier in the CSV.'; $report.Add($resultRow) | Out-Null; continue
        }
        $seen[$key]=$true
        try {
            $task = Resolve-QOdmTask -TaskId $taskId -TaskName $taskName
            if ($null -eq $task) {
                $resultRow.Status='NOT_FOUND'; $resultRow.Details='The task was not found in the selected workload.'
            }
            else {
                $resultRow.TaskId=Get-QOdmId -InputObject $task
                $resultRow.TaskName=Get-QOdmName -InputObject $task
                $resultRow.PreviousStatus=Get-QOdmTaskStatus -Task $task
                if (-not $Execute) { $resultRow.Action='WOULD_DELETE'; $resultRow.Status='DRY_RUN' }
                else {
                    $deleteResult=Remove-QOdmTaskSafely -Task $task -StopRunning $StopRunning
                    $resultRow.Action=[string](Get-QOdmProperty -InputObject $deleteResult -Names @('Status') -Default 'UNKNOWN')
                    $resultRow.Status=$resultRow.Action
                    $resultRow.Deleted=[bool](Get-QOdmProperty -InputObject $deleteResult -Names @('Deleted') -Default $false)
                    $resultRow.Details=[string](Get-QOdmProperty -InputObject $deleteResult -Names @('Details'))
                    if ($resultRow.Deleted -and $script:QOdmState.Tasks.ContainsKey([string]$resultRow.TaskId)) { $script:QOdmState.Tasks.Remove([string]$resultRow.TaskId) }
                }
            }
        }
        catch {
            $resultRow.Status=if ($_.Exception.Message -match 'ambiguous') { 'AMBIGUOUS_NAME' } else { 'FAILED' }
            $resultRow.Details=$_.Exception.Message
        }
        $report.Add($resultRow) | Out-Null
    }

    $path=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'DeleteTasks_Report'
    Export-QOdmCsv -Rows $report.ToArray() -Path $path | Out-Null
    [pscustomobject]@{ Execute=$Execute; Rows=$report.ToArray(); ReportPath=$path }
}

function Invoke-QOdmDeleteAllTasks {
    [CmdletBinding()]
    param(
        [bool]$Execute = $false,
        [AllowNull()][string]$ConfirmationText = $null,
        [bool]$StopRunning = $true,
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmWorkloadSelected
    $requiredText = 'DELETE ALL ODM TASKS'
    if ($Execute -and -not [string]::Equals([string]$ConfirmationText, $requiredText, [StringComparison]::Ordinal)) {
        throw "Execution requires the exact confirmation text: $requiredText"
    }
    $tasks = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmTasksView -Refresh $true | ForEach-Object { Resolve-QOdmTask -TaskId ([string]$_.Id) } | Where-Object { $null -ne $_ })
    $report = [System.Collections.Generic.List[object]]::new()
    foreach ($task in $tasks) {
        $row = [pscustomobject]@{
            TaskId=(Get-QOdmId -InputObject $task); TaskName=(Get-QOdmName -InputObject $task); PreviousStatus=(Get-QOdmTaskStatus -Task $task)
            Action=if ($Execute) { 'PENDING_DELETE' } else { 'WOULD_DELETE' }; Status=if ($Execute) { 'PENDING' } else { 'DRY_RUN' }; Deleted=$false; Details=$null
        }
        if ($Execute) {
            $deleteResult = Remove-QOdmTaskSafely -Task $task -StopRunning $StopRunning
            $row.Action = [string](Get-QOdmProperty -InputObject $deleteResult -Names @('Status') -Default 'UNKNOWN')
            $row.Status = $row.Action
            $row.Deleted = [bool](Get-QOdmProperty -InputObject $deleteResult -Names @('Deleted') -Default $false)
            $row.Details = [string](Get-QOdmProperty -InputObject $deleteResult -Names @('Details'))
            if ($row.Deleted -and $script:QOdmState.Tasks.ContainsKey([string]$row.TaskId)) { $script:QOdmState.Tasks.Remove([string]$row.TaskId) }
        }
        $report.Add($row) | Out-Null
    }
    $path=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'DeleteAllTasks_Report'
    Export-QOdmCsv -Rows $report.ToArray() -Path $path | Out-Null
    [pscustomobject]@{ Execute=$Execute; TaskCount=$tasks.Count; Rows=$report.ToArray(); ReportPath=$path; RequiredConfirmation=$requiredText }
}

function Export-QOdmTasksReport {
    [CmdletBinding()]
    param([AllowNull()][string]$OutputDirectory = $null, [bool]$IncludeAllProjects = $false)

    Assert-QOdmOrganizationSelected
    $rows = [System.Collections.Generic.List[object]]::new()
    $contextValid = [bool]$script:QOdmState.ContextValid
    if ($IncludeAllProjects) {
        Set-QOdmOperationPhase -Phase 'Enumerating all Quest project/workload contexts for task export'
        $contexts = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmAllProjectContexts)
        $savedContext = Get-QOdmContextSnapshot
        $seenTaskContext = @{}
        $contextSelectionAttempted = $false
        try {
            foreach ($descriptor in $contexts) {
                $contextId = [string](Get-QOdmProperty -InputObject $descriptor -Names @('ContextId'))
                $contextName = [string](Get-QOdmProperty -InputObject $descriptor -Names @('ContextName'))
                $contextType = [string](Get-QOdmProperty -InputObject $descriptor -Names @('ContextType'))
                try {
                    Set-QOdmOperationPhase -Phase "Selecting context '$contextId' for task export"
                    Select-QOdmRawContextObject -ContextDescriptor $descriptor
                    $contextSelectionAttempted = $true
                    Set-QOdmOperationPhase -Phase "Reading tasks from context '$contextId'"
                    $tasks = Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmTask' -Parameters @{ All=$true } -RequiredParameters @('All')
                    foreach ($task in $tasks) {
                        $taskId = Get-QOdmId -InputObject $task
                        $dedupeKey = $contextId + '|' + $taskId
                        if ($seenTaskContext.ContainsKey($dedupeKey)) { continue }
                        $seenTaskContext[$dedupeKey] = $true
                        $view = ConvertTo-QOdmTaskView -Task $task
                        $rows.Add([pscustomobject]@{
                            OrganizationId=$script:QOdmState.OrganizationId; Region=$script:QOdmState.Region
                            ProjectName=(Get-QOdmProperty -InputObject $descriptor -Names @('RootProjectName')); ProjectId=(Get-QOdmProperty -InputObject $descriptor -Names @('RootProjectId'))
                            WorkloadName=if ($contextType -eq 'Workload') { $contextName } else { $null }; WorkloadId=if ($contextType -eq 'Workload') { $contextId } else { $null }
                            TaskName=$view.Name; Status=$view.Status; TaskType=$view.Type; Context=$view.Context; Progress=$view.Progress; Created=$view.Created; Modified=$view.Modified; TaskId=$view.Id
                        }) | Out-Null
                    }
                }
                catch {
                    $rows.Add([pscustomobject]@{
                        OrganizationId=$script:QOdmState.OrganizationId; Region=$script:QOdmState.Region
                        ProjectName=(Get-QOdmProperty -InputObject $descriptor -Names @('RootProjectName')); ProjectId=(Get-QOdmProperty -InputObject $descriptor -Names @('RootProjectId'))
                        WorkloadName=if ($contextType -eq 'Workload') { $contextName } else { $null }; WorkloadId=if ($contextType -eq 'Workload') { $contextId } else { $null }
                        TaskName=$null; Status='CONTEXT_TASK_READ_FAILED'; TaskType=$null; Context=$_.Exception.Message; Progress=$null; Created=$null; Modified=$null; TaskId=$null
                    }) | Out-Null
                }
            }
        }
        finally {
            if ($contextSelectionAttempted) {
                try { $null = Restore-QOdmContextSnapshot -Snapshot $savedContext }
                catch {
                    $rows.Add([pscustomobject]@{
                        OrganizationId=$script:QOdmState.OrganizationId; Region=$script:QOdmState.Region
                        ProjectName=(Get-QOdmProperty -InputObject $savedContext -Names @('ProjectName')); ProjectId=(Get-QOdmProperty -InputObject $savedContext -Names @('ProjectId'))
                        WorkloadName=(Get-QOdmProperty -InputObject $savedContext -Names @('WorkloadName')); WorkloadId=(Get-QOdmProperty -InputObject $savedContext -Names @('WorkloadId'))
                        TaskName=$null; Status='CONTEXT_RESTORE_FAILED'; TaskType=$null; Context=$_.Exception.Message; Progress=$null; Created=$null; Modified=$null; TaskId=$null
                    }) | Out-Null
                }
            }
            $contextValid = [bool]$script:QOdmState.ContextValid
        }
    }
    else {
        Assert-QOdmWorkloadSelected
        if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }
        foreach ($task in (ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Tasks.Values)) {
            $view = ConvertTo-QOdmTaskView -Task $task
            $rows.Add([pscustomobject]@{
                OrganizationId=$script:QOdmState.OrganizationId; Region=$script:QOdmState.Region; ProjectName=$script:QOdmState.ProjectName; ProjectId=$script:QOdmState.ProjectId
                WorkloadName=$script:QOdmState.WorkloadName; WorkloadId=$script:QOdmState.WorkloadId; TaskName=$view.Name; Status=$view.Status; TaskType=$view.Type
                Context=$view.Context; Progress=$view.Progress; Created=$view.Created; Modified=$view.Modified; TaskId=$view.Id
            }) | Out-Null
        }
    }
    $path=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'ODM_Tasks'
    Export-QOdmCsv -Rows $rows.ToArray() -Path $path | Out-Null
    [pscustomobject]@{ RowCount=$rows.Count; Rows=$rows.ToArray(); ReportPath=$path; ContextValid=$contextValid }
}

function Export-QOdmCollectionsReport {
    [CmdletBinding()]
    param([AllowNull()][string]$OutputDirectory = $null, [bool]$IncludeCounts = $true)

    Assert-QOdmWorkloadSelected
    $collections = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCollectionsView -Refresh $true -IncludeCounts $IncludeCounts)
    $rows = ConvertTo-QOdmObjectArray -InputObject ($collections | ForEach-Object {
        [pscustomobject]@{
            CollectionName=(Get-QOdmProperty -InputObject $_ -Names @('Name')); CollectionId=(Get-QOdmProperty -InputObject $_ -Names @('Id'))
            ObjectCount=(Get-QOdmProperty -InputObject $_ -Names @('ObjectCount')); ObjectCountReadStatus=(Get-QOdmProperty -InputObject $_ -Names @('ObjectCountReadStatus'))
            TaskCount=(Get-QOdmProperty -InputObject $_ -Names @('TaskCount')); TaskCountReadStatus=(Get-QOdmProperty -InputObject $_ -Names @('TaskCountReadStatus'))
            Description=(Get-QOdmProperty -InputObject $_ -Names @('Description')); Created=(Get-QOdmProperty -InputObject $_ -Names @('Created')); Modified=(Get-QOdmProperty -InputObject $_ -Names @('Modified'))
        }
    })
    $path=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'AllCollections'
    Export-QOdmCsv -Rows $rows -Path $path | Out-Null
    [pscustomobject]@{ RowCount=$rows.Count; Rows=$rows; ReportPath=$path }
}

function Invoke-QOdmBulkOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [AllowNull()][System.Collections.IDictionary]$Parameters = $null
    )

    $safeParameters = Copy-QOdmHashtable -InputHashtable $Parameters
    switch ($Operation) {
        'CreateCollectionsAndAddUsers' { return (Invoke-QOdmCreateCollectionsFromCsv @safeParameters) }
        'RemoveUsersFromCollections'   { return (Invoke-QOdmRemoveUsersFromCollectionsCsv @safeParameters) }
        'RemoveCollections'            { return (Invoke-QOdmRemoveCollectionsFromCsv @safeParameters) }
        'FindUserCollections'          { $safeParameters['EntityType'] = 'Collection'; return (Invoke-QOdmFindUserMembershipsFromCsv @safeParameters) }
        'FindUserTasks'                { $safeParameters['EntityType'] = 'Task'; return (Invoke-QOdmFindUserMembershipsFromCsv @safeParameters) }
        'MatchObjectInfo'              { return (Invoke-QOdmMatchObjectsFromCsv @safeParameters) }
        'RemoveUsersFromTasksPlan'     { return (Invoke-QOdmRemoveUsersFromTasksPlan @safeParameters) }
        'StartTasksFromCsv'            { return (Invoke-QOdmStartTasksFromCsv @safeParameters) }
        'StopTasksFromCsv'             { return (Invoke-QOdmStopTasksFromCsv @safeParameters) }
        'DeleteTasksFromCsv'           { return (Invoke-QOdmDeleteTasksFromCsv @safeParameters) }
        'DeleteTasksAcrossProjects'    { return (Invoke-QOdmDeleteTasksAcrossProjectsFromCsv @safeParameters) }
        'DeleteAllTasks'               { return (Invoke-QOdmDeleteAllTasks @safeParameters) }
        'ExportTasks'                  { return (Export-QOdmTasksReport @safeParameters) }
        'ExportCollections'            { return (Export-QOdmCollectionsReport @safeParameters) }
        'DiscoverAllAccounts'          { $safeParameters['Operation'] = 'DiscoverAll'; return (Invoke-QOdmAccountTaskOperation @safeParameters) }
        'DiscoverAccountsFromCsv'      { $safeParameters['Operation'] = 'DiscoverFromCsv'; return (Invoke-QOdmAccountTaskOperation @safeParameters) }
        'MapAccountsFromCsv'           { $safeParameters['Operation'] = 'MapFromCsv'; return (Invoke-QOdmAccountTaskOperation @safeParameters) }
        default                        { throw "Unknown bulk operation: $Operation" }
    }
}
