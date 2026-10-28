# Fixed, reviewed catalog; parameters are data, never evaluated as PowerShell.
function ConvertTo-QOdmOperationSnapshot {
    param([AllowNull()][object]$Value,[int]$Depth=0)
    if($Depth -gt 20){throw 'The task settings exceed the supported preview depth.'}
    if($null -eq $Value){return $null}
    if($Value -is [string] -or $Value -is [ValueType]){return $Value}
    if($Value -is [Collections.IDictionary]){
        $copy=[ordered]@{};foreach($key in ($Value.Keys|Sort-Object)){$copy[[string]$key]=ConvertTo-QOdmOperationSnapshot $Value[$key] ($Depth+1)};return [pscustomobject]$copy
    }
    if($Value -is [Collections.IEnumerable]){return ,@($Value|ForEach-Object {ConvertTo-QOdmOperationSnapshot $_ ($Depth+1)})}
    # Flatten class properties before ConvertTo-Json. Some Quest subclasses hide
    # inherited members and PowerShell 5.1's raw class serializer reports duplicate keys.
    $copy=[ordered]@{}
    foreach($property in ($Value.PSObject.Properties|Sort-Object Name)){$copy[$property.Name]=ConvertTo-QOdmOperationSnapshot $property.Value ($Depth+1)}
    return [pscustomobject]$copy
}
function Get-QOdmOperationsCommand {
    param([string]$Name)
    $module=Get-QOdmLoadedApiModule
    if($null -eq $module){return $null}
    return $module.ExportedCommands[$Name]
}
function Get-QOdmOperationsWorkload {
    Assert-QOdmWorkloadSelected
    switch -Regex ([string]$script:QOdmState.WorkloadType) {
        '^(Accounts|activedirectory|account|acm)$' { 'Accounts'; break }
        '^(Teams|mst)$' { 'Teams'; break }
        '^(SharePoint|spm)$' { 'SharePoint'; break }
        '^(PowerBi|pbi|powerbi)$' { 'PowerBi'; break }
        '^(PowerPlatform|powerplatform|papp)$' { 'PowerPlatform'; break }
        '^(PublicFolders|pfm)$' { 'PublicFolders'; break }
        '^(HybridExchange|he|odmhe)$' { 'HybridExchange'; break }
        default { throw 'Select a supported Microsoft 365 migration workload first.' }
    }
}

function Get-QOdmOperationsCatalog {
    $workload=Get-QOdmOperationsWorkload
    $catalog=Get-Content -LiteralPath (Join-Path $script:QOdmAppRoot 'Config\OperationsCatalog.json') -Raw | ConvertFrom-Json
    foreach($spec in $catalog) {
        if($spec.Workload -notin @('Any',$workload)){continue}
        $command=Get-QOdmOperationsCommand $spec.Command
        $missing=@(); if($command){$missing=@($spec.Parameters | Where-Object {-not $command.Parameters.ContainsKey($_.Name)})}
        if($command){
            # Refuse newly mandatory settings absent from the reviewed form. Otherwise
            # PowerShell can prompt inside the worker instead of failing predictably.
            $missing+=@($command.Parameters.Values|Where-Object {
                $_.Name -notin @($spec.Parameters.Name) -and
                @($_.Attributes|Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0
            })
        }
        $immediate=($spec.Command -eq 'New-OdmAddressRewritingTask')
        $missingSchedule=($command -and $spec.Mode -eq 'Create' -and -not $command.Parameters.ContainsKey('ScheduledStartTime'))
        [pscustomobject]@{Command=$spec.Command;Name=$spec.Name;Workload=$spec.Workload;Risk=$spec.Risk;Available=($null -ne $command -and $missing.Count -eq 0 -and -not $immediate -and -not $missingSchedule);Details=if($immediate){'Use Quest web console: address rewriting can run immediately and replace a fixed-ID task; it has no held-task contract.'}elseif($missingSchedule){'Use Quest web console: this vendor constructor does not expose ScheduledStartTime, so the console cannot explicitly guarantee held creation.'}elseif(-not $command){'Not available in the loaded Quest module.'}elseif($missing.Count){'Module contract differs; use Quest web console.'}elseif($spec.Mode -eq 'Update'){'Review changes and any existing schedule before applying.'}else{'Create held task; review before starting.'};Spec=$spec}
    }
}

function Get-QOdmOperationsDefinition {
    param([Parameter(Mandatory=$true)][string]$CommandName)
    $entry=@(Get-QOdmOperationsCatalog | Where-Object {$_.Command -eq $CommandName})
    if($entry.Count -ne 1 -or -not $entry[0].Available){throw 'This operation is unavailable for the selected workload/module. Reload operations.'}
    $command=Get-QOdmOperationsCommand $CommandName
    $isUpdate=([string](Get-QOdmProperty $entry[0].Spec @('Mode')) -eq 'Update')
    $help=Get-Help -Name ('OdmApi\'+$CommandName) -ErrorAction SilentlyContinue
    $fields=foreach($p in $entry[0].Spec.Parameters){
        if($p.Name -eq 'PassThru' -or ($p.Name -eq 'ScheduledStartTime' -and -not $isUpdate)){continue}
        $m=$command.Parameters[$p.Name]; $type=$m.ParameterType
        $underlying=[Nullable]::GetUnderlyingType($type); if($underlying){$type=$underlying}
        $kind='Text';$choices=@()
        if($type -eq [bool] -or $type -eq [Management.Automation.SwitchParameter]){$kind='Choice';$choices=@('true','false')}
        elseif($type.IsEnum){$kind='Choice';$choices=[Enum]::GetNames($type)}
        else{$choices=@($m.Attributes | Where-Object {$_ -is [Management.Automation.ValidateSetAttribute]} | ForEach-Object {$_.ValidValues});if($choices.Count){$kind='Choice'}}
        if($p.Name -match '(?i)password|secret|token|credential'){$kind='Secret'}
        if($p.Name -in $entry[0].Spec.ObjectParameters){$kind='ObjectIds'}
        if($p.Name -eq 'Task'){$kind='TaskId'}
        $description=''
        if($help){$hp=Get-QOdmProperty (Get-QOdmProperty $help @('parameters')) @('parameter') @();$h=@($hp | Where-Object {$_.name -eq $p.Name});if($h.Count){$description=([string](((Get-QOdmProperty $h[0] @('description') @()) | ForEach-Object {Get-QOdmProperty $_ @('Text') ''}) -join ' ')).Trim()}}
        if($kind -eq 'ObjectIds'){$description='Enter exact Quest object IDs, separated by commas. IDs are resolved afresh within the selected workload. '+$description}
        if($kind -eq 'TaskId'){$description='Exact Quest task ID from Tasks. The type must match this update command. Active tasks cannot be edited. '+$description}
        if($p.Name -eq 'ScheduledStartTime'){$description='A future ISO timestamp with timezone schedules automatic execution. Enter hold to remove the schedule; leave blank to preserve it. '+$description}
        if($p.Name -match 'FilePath'){$description='Choose a local file with the exact Quest format for this operation. The preview records its hash and validates CSV structure; service-specific column rules still apply. '+$description}
        [pscustomobject]@{Name=$p.Name;Required=($p.Required -or ($p.Name -eq 'Name' -and -not $isUpdate));Kind=$kind;Choices=@($choices);Default=$p.Default;Description=$description}
    }
    [pscustomobject]@{Command=$CommandName;Name=$entry[0].Name;Mode=if($isUpdate){'Update'}else{'Create'};Risk=$entry[0].Risk;SupportsMembers=$entry[0].Spec.SupportsMembers;Fields=@($fields);WorkloadId=$script:QOdmState.WorkloadId;TaskType=$entry[0].Spec.TaskType}
}

function Get-QOdmOperationsInventory {
    param([string]$Kind='Default',[AllowNull()][object]$Entity)
    $workload=Get-QOdmOperationsWorkload
    $command='Get-OdmObject';$p=@{All=$true}
    switch($workload){
        'Teams' {if($Kind -eq 'Default'){$Kind='Teams'};if($Kind -notin @('Teams','Groups','Chats')){throw 'Choose Teams, Groups, or Chats.'};$p.TypeOfTeam=$Kind}
        'PowerBi' {if($Kind -eq 'Default'){$Kind='Workspaces'};switch($Kind){'Workspaces'{$p.TypeOfPowerBi='Workspace'} 'Gateways'{$p.TypeOfPowerBi='Gateway'} 'Connections'{$p.TypeOfPowerBi='Connection'} 'Profiles'{$command='Get-OdmPbiUserProfile'} default{throw 'Choose Workspaces, Gateways, Connections, or Profiles.'}}}
        'PowerPlatform' {$map=@{Default='Get-OdmPPEnvironment';Environments='Get-OdmPPEnvironment';Apps='Get-OdmPPApp';Solutions='Get-OdmPPSolution';Flows='Get-OdmPPFlow';Connections='Get-OdmPPConnection';Dataflows='Get-OdmPPDataflow'};if(-not $map.ContainsKey($Kind)){throw 'Choose a Power Platform inventory kind.'};$command=$map[$Kind]}
        'PublicFolders' {$command='Get-OdmPfPublicFolder'}
    }
    if($null -ne $Entity){if($command -notin @('Get-OdmObject','Get-OdmPfPublicFolder')){throw 'Membership verification is unavailable for this inventory kind.'};$p.FilterObject=$Entity}
    Invoke-QOdmSupportedCommandArray -CommandName $command -Parameters $p -RequiredParameters @($p.Keys)
}

function Get-QOdmOperationsInventoryView {
    param([string]$Kind='Default')
    $rows=foreach($o in (Get-QOdmOperationsInventory -Kind $Kind)){
        [pscustomobject]@{ObjectId=Get-QOdmId $o;Name=Get-QOdmName $o;Kind=$Kind;WorkloadId=$script:QOdmState.WorkloadId;Type=[string](Get-QOdmProperty $o @('Type','SpmType'));Status=[string](Get-QOdmProperty $o @('Status','State'));Source=[string](Get-QOdmProperty $o @('SourceUPN','SourceUserPrincipalName','SpmSourceUrl','WorkspaceName','EnvironmentName'));Target=[string](Get-QOdmProperty $o @('TargetUPN','SpmTargetUrl','TargetName'))}
    }
    [pscustomobject]@{Rows=ConvertTo-QOdmObjectArray $rows}
}

function Resolve-QOdmOperationsIds {
    param([string]$Text,[string]$Kind='Default')
    $ids=@($Text -split '[,;\r\n]+' | ForEach-Object {$_.Trim()} | Where-Object {$_} | Select-Object -Unique)
    if(-not $ids.Count){throw 'Supply at least one exact Quest object ID.'}
    $inventory=ConvertTo-QOdmObjectArray (Get-QOdmOperationsInventory -Kind $Kind)
    foreach($id in $ids){
        $matches=@($inventory | Where-Object {(Get-QOdmId $_) -eq $id})
        if($matches.Count -ne 1){throw "Object ID '$id' does not uniquely resolve in this workload and inventory kind."}
        $owner=[string](Get-QOdmProperty $matches[0] @('ProjectId'))
        if($owner -and $owner -ne $script:QOdmState.WorkloadId){throw "Object '$id' belongs to a different workload."}
        $matches[0]
    }
}

function ConvertTo-QOdmOperationsValue {
    param([object]$Metadata,[AllowNull()][object]$Value)
    $type=$Metadata.ParameterType;$base=[Nullable]::GetUnderlyingType($type);if($base){$type=$base}
    if($type -eq [bool] -or $type -eq [Management.Automation.SwitchParameter]){
        if([string]$Value -notmatch '^(?i:true|false)$'){throw "Use true or false for $($Metadata.Name)."}
        $converted=([string]$Value -ieq 'true')
    }elseif($type -eq [DateTime]){
        $parsed=[DateTimeOffset]::MinValue
        if([string]$Value -notmatch '(Z|[+-]\d\d:\d\d)$' -or -not [DateTimeOffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){throw "Use an ISO date/time with timezone for $($Metadata.Name), such as 2026-11-01T00:00:00Z."}
        $converted=$parsed.UtcDateTime
    }elseif($type.IsEnum){
        if([string]$Value -notin [Enum]::GetNames($type)){throw "Choose a listed value for $($Metadata.Name)."}
        $converted=[Enum]::Parse($type,[string]$Value,$true)
    }elseif($type -in @([string],[int],[long],[guid])){$converted=[Management.Automation.LanguagePrimitives]::ConvertTo($Value,$type,[Globalization.CultureInfo]::InvariantCulture)}
    else{throw "Unsupported parameter type for $($Metadata.Name); use the Quest web console."}
    foreach($a in $Metadata.Attributes){
        if($a -is [Management.Automation.ValidateSetAttribute] -and [string]$converted -notin $a.ValidValues){throw "Invalid choice for $($Metadata.Name)."}
        if($a -is [Management.Automation.ValidateRangeAttribute] -and ($converted -lt $a.MinRange -or $converted -gt $a.MaxRange)){throw "Value outside the allowed range for $($Metadata.Name)."}
        if($a -is [Management.Automation.ValidateNotNullOrEmptyAttribute] -and [string]::IsNullOrEmpty([string]$converted)){throw "$($Metadata.Name) cannot be empty."}
    }
    return $converted
}

function Invoke-QOdmOperationsTask {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$CommandName,[hashtable]$Values=@{},[string]$MemberIds='', [string]$MemberKind='Default', [bool]$ScopeAcknowledged=$false,[bool]$Execute=$false,[string]$PreviewToken='', [string]$OutputDirectory)
    # Common parameters must not be splatted into vendor setters: several setters
    # iterate PSBoundParameters as task properties. Stop errors by scope instead.
    $ErrorActionPreference='Stop'
    $definition=Get-QOdmOperationsDefinition -CommandName $CommandName
    $spec=(Get-QOdmOperationsCatalog | Where-Object {$_.Command -eq $CommandName}).Spec
    $command=Get-QOdmOperationsCommand $CommandName
    $isUpdate=($definition.Mode -eq 'Update')
    $currentTask=$null
    $p=@{};$files=@();$safeValues=[ordered]@{};$defaults=[ordered]@{}
    foreach($key in $Values.Keys){
        $field=@($definition.Fields | Where-Object {$_.Name -eq $key})
        if($field.Count -ne 1){throw "Unknown or reserved setting '$key'."}
        if($field[0].Kind -eq 'TaskId'){
            $null=Update-QOdmTaskCache
            $currentTask=Resolve-QOdmTask -TaskId ([string]$Values[$key])
            if(-not $currentTask){throw 'The task does not exist in this workload.'}
            if([string](Get-QOdmProperty $currentTask @('ProjectId')) -ne $script:QOdmState.WorkloadId){throw 'The task belongs to a different workload.'}
            if($currentTask.GetType().Name -ne [string]$spec.ExpectedType){throw "Task type mismatch. This command requires $($spec.ExpectedType)."}
            if(Test-QOdmTaskIsActive -Task $currentTask){throw 'Stop the active task and refresh before editing.'}
            $p[$key]=$currentTask
        }elseif($key -eq 'ScheduledStartTime' -and [string]$Values[$key] -ieq 'hold'){$p[$key]=$null}
        elseif($field[0].Kind -eq 'ObjectIds'){
            $kind=if($key -eq 'Object'){'Default'}else{$key}
            $objects=ConvertTo-QOdmObjectArray (Resolve-QOdmOperationsIds -Text ([string]$Values[$key]) -Kind $kind)
            if($command.Parameters[$key].ParameterType.IsArray){$p[$key]=$objects}else{if($objects.Count -ne 1){throw "$key needs exactly one ID."};$p[$key]=$objects[0]}
        }else{$p[$key]=ConvertTo-QOdmOperationsValue -Metadata $command.Parameters[$key] -Value $Values[$key]}
        $safeValues[$key]=if($field[0].Kind -eq 'Secret'){'<redacted>'}else{$Values[$key]}
        if($key -match 'FilePath' -and $p[$key]){
            $path=[string]$p[$key]
            if([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($path)){throw 'Quest file paths must not contain wildcard characters, including square brackets. Copy the file to a simple path first.'}
            if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Input file does not exist: $path"}
            if([IO.Path]::GetExtension($path) -ieq '.csv'){$null=Import-QOdmCsv -Path $path}
            $files+= [pscustomobject]@{Path=$path;SHA256=Get-QOdmFileSha256 $path}
        }
    }
    foreach($field in $definition.Fields){
        if($field.Required -and -not $p.ContainsKey($field.Name)){throw "A value is required for $($field.Name)."}
        if(-not $p.ContainsKey($field.Name)){$defaults[$field.Name]=$field.Default}
    }
    if($p.ContainsKey('FilePath') -and $p.FilePath -and ($CommandName -in @('New-OdmMappingFileTask','New-OdmTeamsMapFromFileTask','New-OdmPbiMapWorkspacesFromFileTask','New-OdmPbiImportGatewaysMappingTask'))){
        $headers=Get-QOdmCsvHeaders -Rows (Import-QOdmCsv -Path ([string]$p.FilePath))
        switch($CommandName){
            'New-OdmMappingFileTask' {$validation=Get-QOdmAccountCsvValidation -Mode Mapping -CsvPath $p.FilePath;if(-not $validation.Valid){throw 'Account mapping CSV contains invalid or duplicate rows.'}}
            'New-OdmTeamsMapFromFileTask' {Assert-QOdmCsvHasAllHeaders -Headers $headers -RequiredHeaders @('SourceMailNickname','TargetMailNickname')}
            'New-OdmPbiMapWorkspacesFromFileTask' {Assert-QOdmCsvHasAllHeaders -Headers $headers -RequiredHeaders @('Source Workspace Name','Target Workspace Name')}
            'New-OdmPbiImportGatewaysMappingTask' {Assert-QOdmCsvHasAllHeaders -Headers $headers -RequiredHeaders @('Name','Target Gateway')}
        }
    }
    if($CommandName -eq 'New-OdmDiscoveryTask' -and $p.ContainsKey('DiscoverUsingCSV') -and $p.DiscoverUsingCSV){
        if(-not $p.ContainsKey('FilePath') -or -not $p.FilePath){throw 'CSV discovery requires FilePath.'}
        $validation=Get-QOdmAccountCsvValidation -Mode Discovery -CsvPath $p.FilePath;if(-not $validation.Valid){throw 'Account discovery CSV contains invalid or duplicate rows.'}
    }
    if($CommandName -eq 'New-OdmTeamsDiscoverTask' -and $p.ContainsKey('DiscoveryOption') -and [string]$p.DiscoveryOption -like 'specified*' -and (-not $p.ContainsKey('FilePath') -or -not $p.FilePath)){throw 'Specified Teams discovery requires a CSV FilePath.'}
    $templateSettings=$null
    if($p.ContainsKey('TemplateId')){
        if(-not $spec.TaskType){throw 'This template route has no verified task-type contract. Use explicit settings or Quest web console.'}
        $templateSettings=Test-QOdmContentTemplate -TemplateId ([string]$p.TemplateId) -Spec ([pscustomobject]@{TemplateType=$spec.TaskType;Name=$spec.Name})
    }
    if(-not $ScopeAcknowledged){throw 'Review the object scope and defaults, then check the scope acknowledgement. Omitted selectors can affect the whole workload when a task runs.'}
    $members=@()
    if($MemberIds){
        if(-not $definition.SupportsMembers){throw 'This operation does not support post-creation membership. Use its object/CSV fields.'}
        $members=ConvertTo-QOdmObjectArray (Resolve-QOdmOperationsIds -Text $MemberIds -Kind $MemberKind)
    }
    if($isUpdate){
        if($Values.Count -lt 2){throw 'Provide the task ID and at least one setting to change.'}
        if($p.ContainsKey('ScheduledStartTime') -and $null -ne $p.ScheduledStartTime -and $p.ScheduledStartTime.ToUniversalTime() -le [DateTime]::UtcNow){throw 'Scheduled start must be in the future.'}
        if($command.Parameters.ContainsKey('PassThru')){$p.PassThru=$true}
    }else{
        # Creation is held. Scheduling an existing task is a separate reviewed update.
        if(-not $command.Parameters.ContainsKey('ScheduledStartTime')){throw 'The installed command lacks the required held-task scheduling contract.'}
        $p.ScheduledStartTime=$null
    }
    $fingerprintData=[ordered]@{Command=$CommandName;Organization=$script:QOdmState.OrganizationId;Project=$script:QOdmState.ProjectId;Workload=$script:QOdmState.WorkloadId;Module=[string]$command.Module.Version;Values=[ordered]@{};Members=$MemberIds;Kind=$MemberKind;Files=$files;Template=$templateSettings;CurrentTask=ConvertTo-QOdmOperationSnapshot $currentTask}
    foreach($key in ($Values.Keys | Sort-Object)){$fingerprintData.Values[$key]=$Values[$key]}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($fingerprintData | ConvertTo-Json -Depth 30 -Compress))))}finally{$sha.Dispose()}
    $plan=[ordered]@{Command=$CommandName;Operation=$spec.Name;Risk=$spec.Risk;WorkloadId=$script:QOdmState.WorkloadId;Parameters=$safeValues;OmittedSettings=$defaults;Template=ConvertTo-QOdmSanitizedValue $templateSettings;Members=@($members | ForEach-Object {Get-QOdmId $_});Files=$files;Schedule=if($isUpdate){if($p.ContainsKey('ScheduledStartTime')){if($p.ScheduledStartTime){'AUTOMATIC START: '+$p.ScheduledStartTime.ToString('o')}else{'Hold; remove schedule'}}else{'Preserve existing schedule'}}else{'Held - no automatic start'};Status='PREVIEW';TaskId=if($currentTask){Get-QOdmId $currentTask}else{''};CurrentTask=ConvertTo-QOdmSanitizedValue $currentTask;Error='';Reports=@()}
    $report=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'OperationsCenter' -Extension '.json'
    $plan.Reports=@($report)
    if(-not $Execute){
        $token=[Guid]::NewGuid().ToString('N')
        $script:QOdmOperationsPreview=@{Token=$token;Digest=$digest;At=[DateTime]::UtcNow}
        $plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $report -Encoding UTF8
        return [pscustomobject]@{PreviewToken=$token;Plan=[pscustomobject]$plan;Reports=@($report)}
    }
    Assert-QOdmWriteAllowed -Feature 'OperationsCenter'
    $prior=Get-Variable -Name QOdmOperationsPreview -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if(-not $prior -or $prior.Token -ne $PreviewToken -or $prior.Digest -ne $digest -or ([DateTime]::UtcNow-$prior.At).TotalMinutes -gt 15){throw 'Preview again: the settings, context, input file, template, or module changed, or the preview expired.'}
    $script:QOdmOperationsPreview=$null
    # Never retry a create call automatically: a timeout may occur after server success.
    $plan.Status='SUBMITTING';$plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $report -Encoding UTF8
    try{
        if($isUpdate){
            $null=& $command @p
            $null=Update-QOdmTaskCache
            $updated=Resolve-QOdmTask -TaskId $plan.TaskId
            if(-not $updated){throw 'The updated task was not returned by readback.'}
            $plan.CurrentTask=ConvertTo-QOdmSanitizedValue $updated
            # Vendor parameter-to-property mappings differ by task; show readback for operator verification.
            $plan.Status='UPDATED_REVIEW_REQUIRED'
            return [pscustomobject]@{PreviewToken='';Plan=[pscustomobject]$plan;Reports=@($report)}
        }
        $existing=ConvertTo-QOdmObjectArray (Update-QOdmTaskCache)
        if($p.ContainsKey('Name') -and @($existing | Where-Object {(Get-QOdmName $_) -eq [string]$p.Name}).Count){throw 'A task with this name already exists. Review it before retrying.'}
        if($command.Parameters.ContainsKey('PassThru')){$p.PassThru=$true}
        $created=ConvertTo-QOdmObjectArray (& $command @p)
        if($created.Count -ne 1 -or -not (Get-QOdmId $created[0])){throw 'Quest did not return exactly one identifiable task. Review Tasks before retrying.'}
        $task=$created[0];$plan.TaskId=Get-QOdmId $task
        $plan.Status='CREATED_REVIEW_REQUIRED';$plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $report -Encoding UTF8
        $owner=[string](Get-QOdmProperty $task @('ProjectId'))
        if($owner -and $owner -ne $script:QOdmState.WorkloadId){throw 'Returned task context differs from the selected workload.'}
        $run=[string](Get-QOdmProperty $task @('Run'))
        if($run -ne 'later'){throw 'Quest did not confirm that the task is held; inspect its schedule immediately.'}
        if($members.Count){
            $null=Add-QOdmObjectsToEntity -Entity $task -Objects $members
            $actual=ConvertTo-QOdmObjectArray (Get-QOdmOperationsInventory -Kind $MemberKind -Entity $task)
            $ids=@($actual | ForEach-Object {Get-QOdmId $_})
            if(@($members | Where-Object {(Get-QOdmId $_) -notin $ids}).Count){throw 'Task membership readback is incomplete. Inspect the created task before starting it.'}
        }
        $plan.Status='CREATED_HELD';$script:QOdmState.Tasks[$plan.TaskId]=$task
    }catch{
        $plan.Status='REVIEW_REQUIRED';$message=$_.Exception.Message
        foreach($f in ($definition.Fields | Where-Object {$_.Kind -eq 'Secret'})){if($Values.ContainsKey($f.Name) -and [string]$Values[$f.Name]){$message=$message.Replace([string]$Values[$f.Name],'<redacted>')}}
        $plan.Error=Protect-QOdmSupportText $message
    }finally{$plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $report -Encoding UTF8}
    [pscustomobject]@{PreviewToken='';Plan=[pscustomobject]$plan;Reports=@($report)}
}
