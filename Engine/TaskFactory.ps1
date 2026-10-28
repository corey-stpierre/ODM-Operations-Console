function New-QOdmTaskFactoryName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CollectionName,
        [AllowNull()][string]$NameText,
        [ValidateSet('Prefix','Suffix')][string]$Placement = 'Suffix'
    )

    $collection = $CollectionName.Trim()
    if ([string]::IsNullOrWhiteSpace($collection)) { throw 'CollectionName cannot be blank when building a task name.' }
    $token = if ($null -eq $NameText) { '' } else { $NameText.Trim() }
    if ([string]::IsNullOrWhiteSpace($token)) { return $collection }
    if ($Placement -eq 'Prefix') { return ('{0} - {1}' -f $token, $collection) }
    return ('{0} - {1}' -f $collection, $token)
}

function Get-QOdmTaskFactorySpecs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Direct','Template')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$CollectionName,
        [string[]]$TaskKinds = @('Mail','OneDrive','MeetingLink','MailboxSwitch'),
        [string]$MailTemplateId,
        [string]$OneDriveTemplateId,
        [string]$MeetingLinkTemplateId,
        [string]$MailboxSwitchTemplateId,
        [string]$MailSuffix = 'Email Sync',
        [string]$OneDriveSuffix = 'OneDrive Sync',
        [string]$MeetingLinkSuffix = 'Meeting Link Migration',
        [string]$MailboxSwitchSuffix = 'Mailbox Switch',
        [ValidateSet('Prefix','Suffix')][string]$MailPlacement = 'Suffix',
        [ValidateSet('Prefix','Suffix')][string]$OneDrivePlacement = 'Suffix',
        [ValidateSet('Prefix','Suffix')][string]$MeetingLinkPlacement = 'Suffix',
        [ValidateSet('Prefix','Suffix')][string]$MailboxSwitchPlacement = 'Suffix'
    )

    $requested = @{}
    foreach ($kind in @($TaskKinds)) { if (-not [string]::IsNullOrWhiteSpace([string]$kind)) { $requested[[string]$kind] = $true } }
    $allSpecs = @(
        [pscustomobject]@{ Kind='Mail'; TaskType='Mail'; TaskName=(New-QOdmTaskFactoryName -CollectionName $CollectionName -NameText $MailSuffix -Placement $MailPlacement); NameText=$MailSuffix; NamePlacement=$MailPlacement; Command='New-OdmMailMigrationTask'; TemplateId=$MailTemplateId }
        [pscustomobject]@{ Kind='OneDrive'; TaskType='OneDrive'; TaskName=(New-QOdmTaskFactoryName -CollectionName $CollectionName -NameText $OneDriveSuffix -Placement $OneDrivePlacement); NameText=$OneDriveSuffix; NamePlacement=$OneDrivePlacement; Command='New-OdmOneDriveMigrationTask'; TemplateId=$OneDriveTemplateId }
        [pscustomobject]@{ Kind='MeetingLink'; TaskType='Meeting Link Migration'; TaskName=(New-QOdmTaskFactoryName -CollectionName $CollectionName -NameText $MeetingLinkSuffix -Placement $MeetingLinkPlacement); NameText=$MeetingLinkSuffix; NamePlacement=$MeetingLinkPlacement; Command='New-OdmMeetingLinkMigrationTask'; TemplateId=$MeetingLinkTemplateId }
        [pscustomobject]@{ Kind='MailboxSwitch'; TaskType='Mailbox Switch'; TaskName=(New-QOdmTaskFactoryName -CollectionName $CollectionName -NameText $MailboxSwitchSuffix -Placement $MailboxSwitchPlacement); NameText=$MailboxSwitchSuffix; NamePlacement=$MailboxSwitchPlacement; Command='New-OdmMailSwitchTask'; TemplateId=$MailboxSwitchTemplateId }
    )
    $specs = ConvertTo-QOdmObjectArray -InputObject ($allSpecs | Where-Object { $requested.ContainsKey([string]$_.Kind) })

    if ($specs.Count -eq 0) { throw 'Select at least one task type.' }
    if ($Mode -eq 'Template') {
        foreach ($spec in $specs) {
            if ([string]::IsNullOrWhiteSpace([string]$spec.TemplateId)) { throw "Template mode requires a template name or ID for $($spec.TaskType)." }
        }
    }
    return (ConvertTo-QOdmObjectArray -InputObject $specs)
}

function Get-QOdmDirectTaskParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [AllowNull()][string]$NotifyRecipients,
        [Parameter(Mandatory = $true)][DateTime]$MailFrom,
        [Parameter(Mandatory = $true)][string]$OneDriveFilterItems
    )

    switch ($Kind) {
        'Mail' {
            $parameters = @{
                Name=$TaskName; SkipO365LicenseAssignment=$true; MigrateMail=$true; MigrateCalendar=$true
                MigrateContacts=$true; MigrateTasks=$true; MigrateRecoverableItems=$true; MigrateRules=$true
                MigrateDelegates=$true; EnableAutomapping=$true; MigrateFolderPermissions=$true
                MigrateAutoReplyState=$true; MigrateLitigationHoldSettings=$true; AipLabelProcessing='Skip'
                MailForwarding='Ignore'; MigrateMailFrom=$MailFrom; ScheduledStartTime=$null
            }
        }
        'OneDrive' {
            $parameters = @{
                Name=$TaskName; SkipO365LicenseAssignment=$true; MigrationAction='Skip'; FileVersions='Latest'
                Author='TargetAccount'; PermissionBehaviour='All'; FilterItems=$OneDriveFilterItems
                RerunIfMissingItems=$false; ProcessSensitivityLabels=$false; EnableReporting=$true; ScheduledStartTime=$null
            }
        }
        'MeetingLink' { $parameters = @{ Name=$TaskName } }
        'MailboxSwitch' { $parameters = @{ Name=$TaskName; MailForwarding='Enable'; SwitchDirection='SourceToTarget' } }
        default { throw "Unsupported task kind: $Kind" }
    }

    if (-not [string]::IsNullOrWhiteSpace($NotifyRecipients)) {
        $parameters.NotifyOnTaskCompletion=$true
        $parameters.NotifyOnlyOnTaskFailure=$false
        $parameters.NotificationRecipientEmail=$NotifyRecipients
    }
    $parameters
}

function New-QOdmTaskFromFactorySpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][ValidateSet('Direct','Template')][string]$Mode,
        [AllowNull()][string]$NotifyRecipients,
        [Parameter(Mandatory = $true)][DateTime]$MailFrom,
        [Parameter(Mandatory = $true)][string]$OneDriveFilterItems
    )

    $commandName = [string](Get-QOdmProperty -InputObject $Spec -Names @('Command'))
    $taskName = [string](Get-QOdmProperty -InputObject $Spec -Names @('TaskName'))
    if (-not (Test-QOdmCommand -Name $commandName)) { throw "$commandName is not available in the installed OdmApi module." }
    if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }
    $existingIds=@{}; foreach($id in @($script:QOdmState.Tasks.Keys)){ $existingIds[[string]$id]=$true }

    if ($Mode -eq 'Template') {
        $parameters = @{ Name=$taskName; TemplateId=[string](Get-QOdmProperty -InputObject $Spec -Names @('TemplateId')) }
        $required = @('Name','TemplateId')
        $optional = @('PassThru')
    }
    else {
        $parameters = Get-QOdmDirectTaskParameters -Kind ([string]$Spec.Kind) -TaskName $taskName -NotifyRecipients $NotifyRecipients -MailFrom $MailFrom -OneDriveFilterItems $OneDriveFilterItems
        # Name is required for a safe create. Quest has changed optional task-setting
        # parameters across OdmApi releases, so apply those only when supported and
        # report omissions instead of blocking every direct task creation.
        $required = @('Name')
        $optional = @($parameters.Keys | Where-Object { [string]$_ -ne 'Name' }) + @('PassThru')
    }

    $available = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCommandParameterNames -CommandName $commandName)
    if ($available -contains 'PassThru') { $parameters.PassThru = $true }
    $returned = Invoke-QOdmSupportedCommandArray -CommandName $commandName -Parameters $parameters -RequiredParameters $required -OptionalParameters $optional
    Resolve-QOdmCreatedEntityAfterWrite -EntityType Task -Name $taskName -ExistingIds $existingIds -ReturnedObjects $returned
}

function Test-QOdmTaskCollectionLink {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$Collection, [Parameter(Mandatory=$true)][object]$Tasks)

    $expected=ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $Tasks) | ForEach-Object { Get-QOdmId $_ } | Where-Object { $_ } | Select-Object -Unique)
    try {
        $linked=ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCollectionTasks -Collection $Collection)
        $lookup=@{}; foreach($task in $linked){ $id=Get-QOdmId $task; if($id){$lookup[[string]$id]=$true} }
        $verified=ConvertTo-QOdmObjectArray -InputObject ($expected | Where-Object { $lookup.ContainsKey([string]$_) })
        [pscustomobject]@{ VerificationState=if($verified.Count -eq $expected.Count){'VERIFIED'}else{'NOT_VERIFIED'}; Verified=($verified.Count -eq $expected.Count); ExpectedCount=$expected.Count; VerifiedCount=$verified.Count; Error=$null }
    }
    catch {
        [pscustomobject]@{ VerificationState='READ_FAILED'; Verified=$false; ExpectedCount=$expected.Count; VerifiedCount=0; Error=$_.Exception.Message }
    }
}

function Invoke-QOdmTaskFactory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [ValidateSet('Direct','Template')][string]$Mode = 'Direct',
        [bool]$Execute = $false,
        [AllowNull()][string]$OutputDirectory = $null,
        [string]$NotifyRecipients,
        [bool]$LinkTasksToCollections = $false,
        [DateTime]$MailFrom = ([DateTime]'2025-11-01'),
        [string]$OneDriveFilterItems = 'AfterLastSuccessfulRun',
        [int]$MaxUsersPerTask = 1000,
        [int]$VerificationRetries = 6,
        [int]$VerificationDelaySeconds = 5,
        [ValidateSet('Skip','Fail','Allow')][string]$ExistingTaskBehavior = 'Skip',
        [string[]]$TaskKinds = @('Mail','OneDrive','MeetingLink','MailboxSwitch'),
        [string]$MailTemplateId,
        [string]$OneDriveTemplateId,
        [string]$MeetingLinkTemplateId,
        [string]$MailboxSwitchTemplateId,
        [string]$MailSuffix = 'Email Sync',
        [string]$OneDriveSuffix = 'OneDrive Sync',
        [string]$MeetingLinkSuffix = 'Meeting Link Migration',
        [string]$MailboxSwitchSuffix = 'Mailbox Switch',
        [ValidateSet('Prefix','Suffix')][string]$MailPlacement = 'Suffix',
        [ValidateSet('Prefix','Suffix')][string]$OneDrivePlacement = 'Suffix',
        [ValidateSet('Prefix','Suffix')][string]$MeetingLinkPlacement = 'Suffix',
        [ValidateSet('Prefix','Suffix')][string]$MailboxSwitchPlacement = 'Suffix'
    )

    Assert-QOdmWorkloadSelected
    Assert-QOdmAccountsWorkload
    if ($MaxUsersPerTask -lt 1) { throw 'MaxUsersPerTask must be at least 1.' }
    if ($VerificationRetries -lt 1) { $VerificationRetries=1 }
    if ($VerificationDelaySeconds -lt 0) { $VerificationDelaySeconds=0 }

    if ($Mode -eq 'Template') {
        if ($TaskKinds -contains 'Mail') { if([string]::IsNullOrWhiteSpace($MailTemplateId)){throw 'Template mode requires a template name or ID for Mail.'}; $MailTemplateId=(Resolve-QOdmTemplateReference -Reference $MailTemplateId).Id }
        if ($TaskKinds -contains 'OneDrive') { if([string]::IsNullOrWhiteSpace($OneDriveTemplateId)){throw 'Template mode requires a template name or ID for OneDrive.'}; $OneDriveTemplateId=(Resolve-QOdmTemplateReference -Reference $OneDriveTemplateId).Id }
        if ($TaskKinds -contains 'MeetingLink') { if([string]::IsNullOrWhiteSpace($MeetingLinkTemplateId)){throw 'Template mode requires a template name or ID for Meeting Link Migration.'}; $MeetingLinkTemplateId=(Resolve-QOdmTemplateReference -Reference $MeetingLinkTemplateId).Id }
        if ($TaskKinds -contains 'MailboxSwitch') { if([string]::IsNullOrWhiteSpace($MailboxSwitchTemplateId)){throw 'Template mode requires a template name or ID for Mailbox Switch.'}; $MailboxSwitchTemplateId=(Resolve-QOdmTemplateReference -Reference $MailboxSwitchTemplateId).Id }
    }

    $rows=ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $CsvPath)
    $headers=ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    Assert-QOdmCsvHasAllHeaders -Headers $headers -RequiredHeaders @('CollectionName')
    Assert-QOdmCsvHasIdentityHeader -Headers $headers
    if($script:QOdmState.Objects.Count -eq 0){$null=Update-QOdmObjectCache -IncludeAllProperties $true}
    if($script:QOdmState.Tasks.Count -eq 0){$null=Update-QOdmTaskCache}
    if($LinkTasksToCollections -and $script:QOdmState.Collections.Count -eq 0){$null=Update-QOdmCollectionCache}

    $resolvedRows=[System.Collections.Generic.List[object]]::new()
    $unresolvedRows=[System.Collections.Generic.List[object]]::new()
    $skippedRows=[System.Collections.Generic.List[object]]::new()
    $rowNumber=1
    foreach($row in $rows){
        $rowNumber++
        $collectionName=Normalize-QOdmName ([string](Get-QOdmProperty -InputObject $row -Names @('CollectionName')))
        $upn=Get-QOdmUpnFromRow $row
        if(-not $collectionName -or -not $upn){
            $skippedRows.Add([pscustomobject]@{CollectionName=$collectionName;UserCount=$null;Status='SKIPPED_INVALID_INPUT';Details="CSV row $rowNumber requires both CollectionName and a supported identity value."})|Out-Null
            continue
        }
        try{$object=Resolve-QOdmObject -SourceUPN $upn}
        catch{$unresolvedRows.Add([pscustomobject]@{CollectionName=$collectionName;SourceUPN=$upn;Status='AMBIGUOUS_IDENTITY';Details=$_.Exception.Message})|Out-Null;continue}
        if($null -eq $object){$unresolvedRows.Add([pscustomobject]@{CollectionName=$collectionName;SourceUPN=$upn;Status='UNRESOLVED';Details='No ODM object matched.'})|Out-Null;continue}
        $resolvedRows.Add([pscustomobject]@{CollectionName=$collectionName;SourceUPN=$upn;ObjectId=Get-QOdmId $object;Object=$object})|Out-Null
    }
    if($resolvedRows.Count -eq 0){throw 'No CSV users could be resolved to ODM objects.'}

    $assignmentRows=[System.Collections.Generic.List[object]]::new()
    $summaryRows=[System.Collections.Generic.List[object]]::new()
    $createdTaskViews=[System.Collections.Generic.List[object]]::new()
    $groups=ConvertTo-QOdmObjectArray -InputObject ($resolvedRows.ToArray() | Group-Object CollectionName)
    foreach($group in $groups){
        $collectionName=[string]$group.Name
        $unique=ConvertTo-QOdmObjectArray -InputObject ($group.Group | Where-Object{$_.ObjectId} | Group-Object ObjectId | ForEach-Object{$_.Group|Select-Object -First 1})
        if($unique.Count -eq 0){continue}
        if($unique.Count -gt $MaxUsersPerTask){$skippedRows.Add([pscustomobject]@{CollectionName=$collectionName;UserCount=$unique.Count;Status='SKIPPED_MAX_USERS';Details="User count exceeds MaxUsersPerTask ($MaxUsersPerTask)."})|Out-Null;continue}

        $specs=ConvertTo-QOdmObjectArray -InputObject (Get-QOdmTaskFactorySpecs -Mode $Mode -CollectionName $collectionName -TaskKinds $TaskKinds -MailTemplateId $MailTemplateId -OneDriveTemplateId $OneDriveTemplateId -MeetingLinkTemplateId $MeetingLinkTemplateId -MailboxSwitchTemplateId $MailboxSwitchTemplateId -MailSuffix $MailSuffix -OneDriveSuffix $OneDriveSuffix -MeetingLinkSuffix $MeetingLinkSuffix -MailboxSwitchSuffix $MailboxSwitchSuffix -MailPlacement $MailPlacement -OneDrivePlacement $OneDrivePlacement -MeetingLinkPlacement $MeetingLinkPlacement -MailboxSwitchPlacement $MailboxSwitchPlacement)
        $objects=ConvertTo-QOdmObjectArray -InputObject ($unique|ForEach-Object{$_.Object})
        $expectedIds=ConvertTo-QOdmObjectArray -InputObject ($unique|ForEach-Object{[string]$_.ObjectId})
        $createdForCollection=[System.Collections.Generic.List[object]]::new()

        foreach($spec in $specs){
            $existingMatches=ConvertTo-QOdmObjectArray -InputObject ($script:QOdmState.Tasks.Values | Where-Object{[string]::Equals([string](Get-QOdmName $_),[string]$spec.TaskName,[StringComparison]::OrdinalIgnoreCase)})
            $task=$null;$taskCreated=$false;$addSucceeded=$false;$verification=$null;$details=$null;$status=if($Execute){'PENDING'}else{'DRY_RUN'}
            if($existingMatches.Count -gt 0 -and $ExistingTaskBehavior -ne 'Allow'){
                if($existingMatches.Count -gt 1){$status='AMBIGUOUS_EXISTING_TASK';$details="Multiple tasks are named '$($spec.TaskName)'. Use IDs to remediate duplicates before running Task Factory."}
                elseif($ExistingTaskBehavior -eq 'Fail'){$status='FAILED_EXISTS';$details="A task named '$($spec.TaskName)' already exists. ID: $((Get-QOdmId $existingMatches[0]))"}
                else{$status='SKIPPED_EXISTS';$details="A task named '$($spec.TaskName)' already exists. ID: $((Get-QOdmId $existingMatches[0]))"}
            }
            elseif(-not $Execute){$status='WOULD_CREATE';$details="$Mode task would be created and populated."}
            else{
                try{
                    $task=New-QOdmTaskFromFactorySpec -Spec $spec -Mode $Mode -NotifyRecipients $NotifyRecipients -MailFrom $MailFrom -OneDriveFilterItems $OneDriveFilterItems
                    $taskCreated=$true;$taskId=Get-QOdmId $task;if($taskId){$script:QOdmState.Tasks[$taskId]=$task}
                    $createdForCollection.Add($task)|Out-Null;$createdTaskViews.Add((ConvertTo-QOdmTaskView $task))|Out-Null;$details='Task created.'
                }catch{$status='CREATE_FAILED';$details=$_.Exception.Message}
                if($taskCreated){try{$null=Add-QOdmObjectsToEntity -Entity $task -Objects $objects;$addSucceeded=$true;$details='Task created and objects submitted.'}catch{$status='ADD_FAILED';$details=$_.Exception.Message}}
                if($taskCreated -and $addSucceeded){
                    $verification=Test-QOdmEntityObjectMembership -Entity $task -ObjectIds $expectedIds -ShouldExist $true -Retries $VerificationRetries -DelaySeconds $VerificationDelaySeconds
                    $status=[string](Get-QOdmProperty -InputObject $verification -Names @('VerificationState') -Default 'NOT_VERIFIED')
                    $verificationError=[string](Get-QOdmProperty -InputObject $verification -Names @('Error'))
                    $presentExpected=[int](Get-QOdmProperty -InputObject $verification -Names @('PresentExpectedCount') -Default 0)
                    $expectedCount=[int](Get-QOdmProperty -InputObject $verification -Names @('ExpectedCount') -Default $expectedIds.Count)
                    if($status -eq 'READ_FAILED'){$details="Objects were submitted, but verification could not read task membership: $verificationError"}
                    elseif($status -eq 'NOT_VERIFIED'){$details="Objects were submitted, but only $presentExpected of $expectedCount expected members were found."}
                    else{$details='Task created, populated, and verified.'}
                }
            }

            $taskIdForReport=if($task){Get-QOdmId $task}elseif($existingMatches.Count -eq 1){Get-QOdmId $existingMatches[0]}else{$null}
            $memberLookup=@{};if($null -ne $verification){foreach($id in (ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $verification -Names @('MemberIds') -Default @()))){$memberLookup[[string]$id]=$true}}
            foreach($item in $unique){
                $verified=$false;if($memberLookup.ContainsKey([string]$item.ObjectId)){$verified=$true}
                $assignmentStatus=$status
                if($verified){$assignmentStatus='VERIFIED_ADDED'}elseif($status -eq 'VERIFIED'){$assignmentStatus='NOT_VERIFIED'}
                $assignmentRows.Add([pscustomobject]@{
                    CollectionName=$collectionName;SourceUPN=$item.SourceUPN;ObjectId=$item.ObjectId;TaskType=$spec.TaskType;TaskName=$spec.TaskName;TaskId=$taskIdForReport
                    Mode=$Mode;TemplateId=$spec.TemplateId;NamePlacement=$spec.NamePlacement;NameText=$spec.NameText;TaskCreated=$taskCreated;AddCommandSucceeded=$addSucceeded;VerifiedInTask=$verified
                    VerificationState=if($null -ne $verification){[string](Get-QOdmProperty -InputObject $verification -Names @('VerificationState') -Default 'NOT_VERIFIED')}else{'NOT_RUN'};Status=$assignmentStatus;Details=$details
                })|Out-Null
            }
            $verifiedCount=if($null -ne $verification){[int](Get-QOdmProperty -InputObject $verification -Names @('PresentExpectedCount') -Default 0)}else{0}
            $summaryRows.Add([pscustomobject]@{
                CollectionName=$collectionName;TaskType=$spec.TaskType;TaskName=$spec.TaskName;TaskId=$taskIdForReport;Mode=$Mode;TemplateId=$spec.TemplateId;NamePlacement=$spec.NamePlacement;NameText=$spec.NameText
                IntendedObjectCount=$unique.Count;VerifiedObjectCount=$verifiedCount;MissingObjectCount=if($Execute -and $taskCreated -and $addSucceeded){$unique.Count-$verifiedCount}else{$null}
                Status=$status;Details=$details
            })|Out-Null
        }

        if($Execute -and $LinkTasksToCollections -and $createdForCollection.Count -gt 0){
            $collection = $null
            $linkResolveError = $null
            try { $collection = Resolve-QOdmCollection -CollectionName $collectionName }
            catch { $linkResolveError = $_.Exception.Message }
            if($null -eq $collection){$summaryRows.Add([pscustomobject]@{CollectionName=$collectionName;TaskType='Collection Link';TaskName=$null;TaskId=$null;Mode=$Mode;TemplateId=$null;IntendedObjectCount=$unique.Count;VerifiedObjectCount=$null;MissingObjectCount=$null;Status='COLLECTION_NOT_FOUND_OR_AMBIGUOUS';Details=if($linkResolveError){$linkResolveError}else{'Matching collection was not found.'}})|Out-Null}
            else{
                try{
                    $null=Add-QOdmTasksToCollection -Tasks $createdForCollection.ToArray() -Collection $collection
                    $linkVerification=Test-QOdmTaskCollectionLink -Collection $collection -Tasks $createdForCollection.ToArray()
                    $summaryRows.Add([pscustomobject]@{CollectionName=$collectionName;TaskType='Collection Link';TaskName=$null;TaskId=$null;Mode=$Mode;TemplateId=$null;IntendedObjectCount=$createdForCollection.Count;VerifiedObjectCount=[int](Get-QOdmProperty -InputObject $linkVerification -Names @('VerifiedCount') -Default 0);MissingObjectCount=([int](Get-QOdmProperty -InputObject $linkVerification -Names @('ExpectedCount') -Default $createdForCollection.Count)-[int](Get-QOdmProperty -InputObject $linkVerification -Names @('VerifiedCount') -Default 0));Status=[string](Get-QOdmProperty -InputObject $linkVerification -Names @('VerificationState') -Default 'NOT_VERIFIED');Details=if([bool](Get-QOdmProperty -InputObject $linkVerification -Names @('Verified') -Default $false)){'Created tasks were linked to the collection and verified.'}else{[string](Get-QOdmProperty -InputObject $linkVerification -Names @('Error'))}})|Out-Null
                }catch{$summaryRows.Add([pscustomobject]@{CollectionName=$collectionName;TaskType='Collection Link';TaskName=$null;TaskId=$null;Mode=$Mode;TemplateId=$null;IntendedObjectCount=$createdForCollection.Count;VerifiedObjectCount=0;MissingObjectCount=$createdForCollection.Count;Status='LINK_FAILED';Details=$_.Exception.Message})|Out-Null}
            }
        }
    }

    $reports=[System.Collections.Generic.List[string]]::new()
    $assignmentPath=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'TaskFactory_UserAssignmentVerification'
    $summaryPath=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'TaskFactory_TaskSummary'
    Export-QOdmCsv -Rows $assignmentRows.ToArray() -Path $assignmentPath|Out-Null;Export-QOdmCsv -Rows $summaryRows.ToArray() -Path $summaryPath|Out-Null
    $reports.Add($assignmentPath)|Out-Null;$reports.Add($summaryPath)|Out-Null
    $unresolvedPath=$null;if($unresolvedRows.Count -gt 0){$unresolvedPath=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'TaskFactory_UnresolvedUPNs';Export-QOdmCsv -Rows $unresolvedRows.ToArray() -Path $unresolvedPath|Out-Null;$reports.Add($unresolvedPath)|Out-Null}
    $skippedPath=$null;if($skippedRows.Count -gt 0){$skippedPath=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'TaskFactory_SkippedCollections';Export-QOdmCsv -Rows $skippedRows.ToArray() -Path $skippedPath|Out-Null;$reports.Add($skippedPath)|Out-Null}

    [pscustomobject]@{
        Execute=$Execute;Mode=$Mode;ResolvedRows=$resolvedRows.Count;UnresolvedRows=$unresolvedRows.Count;CollectionGroups=$groups.Count
        CreatedTasks=$createdTaskViews.ToArray();AssignmentRows=$assignmentRows.ToArray();SummaryRows=$summaryRows.ToArray();SkippedRows=$skippedRows.ToArray()
        AssignmentPath=$assignmentPath;SummaryPath=$summaryPath;UnresolvedPath=$unresolvedPath;SkippedPath=$skippedPath;Reports=$reports.ToArray()
    }
}
