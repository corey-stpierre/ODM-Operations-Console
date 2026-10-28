function Get-QOdmManagementItems {
    param([ValidateSet('Templates','Reports','Events','Tasks','Collections')][string]$Kind)
    Assert-QOdmWorkloadSelected
    switch($Kind){
        'Templates' {ConvertTo-QOdmObjectArray (Update-QOdmTemplateCache)}
        'Reports' {Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmReportInfo' -Parameters @{ProjectId=$script:QOdmState.ProjectId} -RequiredParameters @('ProjectId')}
        'Events' {Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmEvent' -Parameters @{All=$true;CurrentOnly=$true} -RequiredParameters @('All','CurrentOnly')}
        'Tasks' {ConvertTo-QOdmObjectArray (Update-QOdmTaskCache)}
        'Collections' {ConvertTo-QOdmObjectArray (Update-QOdmCollectionCache)}
    }
}

function Get-QOdmManagementView {
    param([ValidateSet('Templates','Reports','Events','Tasks','Collections')][string]$Kind='Templates')
    $rows=foreach($item in (Get-QOdmManagementItems -Kind $Kind)){
        if($item -is [string]){continue}
        [pscustomobject]@{Id=Get-QOdmId $item;Name=Get-QOdmName $item;Type=[string](Get-QOdmProperty $item @('Type','TemplateType','AssetName'));Status=[string](Get-QOdmProperty $item @('Status','Severity'));Message=[string](Get-QOdmProperty $item @('Message','Description'));ExportId=[string](Get-QOdmProperty $item @('ExportId'));WorkloadId=$script:QOdmState.WorkloadId}
    }
    [pscustomobject]@{Rows=ConvertTo-QOdmObjectArray $rows;Note=if($Kind -eq 'Reports'){'Quest report-link API returns up to 1,000 entries for the parent project; use the web console for downloads and larger inventories.'}else{'Inventory refreshed.'}}
}

function Invoke-QOdmManagement {
    [CmdletBinding()]
    param([ValidateSet('RenameCollection','SaveTaskTemplate','ImportTemplates','ExportTemplate','AcknowledgeEvent')][string]$Action,[string]$Id,[string]$Name,[string]$FilePath,[bool]$Execute=$false,[string]$PreviewToken,[string]$OutputDirectory)
    $ErrorActionPreference='Stop'
    Assert-QOdmWorkloadSelected
    $command='';$p=@{};$details=$null;$inputHash='';$target=$null
    $allTemplates=@()
    if($Action -in @('SaveTaskTemplate','ImportTemplates','ExportTemplate')){$allTemplates=ConvertTo-QOdmObjectArray (Get-QOdmManagementItems Templates)}
    if($Action -eq 'RenameCollection'){
        $items=ConvertTo-QOdmObjectArray (Get-QOdmManagementItems Collections)
        $target=Resolve-QOdmExactEntity -Entities $items -Id $Id -EntityType Collection
        if(-not $target){throw 'Collection ID not found in the current workload.'}
        if([string]::IsNullOrWhiteSpace($Name)){throw 'Enter the new collection name.'}
        if(@($items|Where-Object {(Get-QOdmName $_) -eq $Name.Trim() -and (Get-QOdmId $_) -ne $Id}).Count){throw 'Another collection already uses this name.'}
        $command='Set-OdmCollection';$p=@{Collection=$target;Name=$Name.Trim();PassThru=$true};$details=[pscustomobject]@{CurrentName=Get-QOdmName $target;NewName=$Name.Trim()}
    }elseif($Action -eq 'SaveTaskTemplate'){
        $null=Update-QOdmTaskCache;$target=Resolve-QOdmTask -TaskId $Id
        if(-not $target){throw 'Task ID not found in the current workload.'}
        if([string]::IsNullOrWhiteSpace($Name)){throw 'Enter a template name.'}
        if(@($allTemplates|Where-Object {(Get-QOdmName $_) -eq $Name.Trim()}).Count){throw 'A template with this name already exists.'}
        $command='New-OdmTaskTemplate';$p=@{Task=$target;Name=$Name.Trim();PassThru=$true};$details=ConvertTo-QOdmSanitizedValue $target
    }elseif($Action -eq 'ExportTemplate'){
        $target=Resolve-QOdmExactEntity -Entities $allTemplates -Id $Id -EntityType Template
        if(-not $target){throw 'Template ID not found in the current context.'}
        $owner=[string](Get-QOdmProperty $target @('ProjectId'));if($owner -notin @($script:QOdmState.ProjectId,$script:QOdmState.WorkloadId)){throw 'Template ownership does not match this context.'}
        $command='Export-OdmTaskTemplate';$p=@{Template=$target};$details=[pscustomobject]@{Name=Get-QOdmName $target;TemplateType=Get-QOdmProperty $target @('TemplateType');Destination='A new file in the Reports folder'}
    }elseif($Action -eq 'AcknowledgeEvent'){
        $events=ConvertTo-QOdmObjectArray (Get-QOdmManagementItems Events)
        $target=Resolve-QOdmExactEntity -Entities $events -Id $Id -EntityType Event
        if(-not $target){throw 'Current event ID not found in this workload.'}
        $command='Set-OdmEventAcknowledged';$p=@{Events=@($Id)};$details=ConvertTo-QOdmSanitizedValue $target
    }else{
        if([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($FilePath)){throw 'Template import paths must not contain wildcard characters, including square brackets.'}
        if(-not (Test-Path -LiteralPath $FilePath -PathType Leaf)){throw 'Choose an exported Quest template JSON file.'}
        $data=ConvertTo-QOdmObjectArray (Get-Content -LiteralPath $FilePath -Raw|ConvertFrom-Json -ErrorAction Stop)
        if(-not $data.Count){throw 'Template file is empty.'}
        $types=@(Get-QOdmOperationsCatalog|ForEach-Object {$_.Spec.TaskType}|Where-Object {$_}|Select-Object -Unique)
        $seen=@{};$previewItems=@()
        foreach($item in $data){
            $itemName=[string](Get-QOdmProperty $item @('Name'));$type=[string](Get-QOdmProperty $item @('TemplateType'));$values=[string](Get-QOdmProperty $item @('Values'))
            if(-not $itemName -or -not $type -or -not $values){throw 'Every template needs Name, TemplateType and Values.'}
            if($type -notin $types){throw "Template type '$type' is not a verified type for this workload."}
            if([int](Get-QOdmProperty $item @('ExportVersion') 1) -gt 1){throw 'Unsupported template export version.'}
            $settings=$values|ConvertFrom-Json -ErrorAction Stop
            if([string](Get-QOdmProperty $settings @('type')) -ne $type){throw 'TemplateType does not match Values.type.'}
            if($seen.ContainsKey($itemName) -or @($allTemplates|Where-Object {(Get-QOdmName $_) -eq $itemName}).Count){throw "Duplicate template name '$itemName'."};$seen[$itemName]=$true
            $previewItems+=[pscustomobject]@{Name=$itemName;Type=$type;Settings=ConvertTo-QOdmSanitizedValue $settings}
        }
        $details=$previewItems;$inputHash=Get-QOdmFileSha256 $FilePath;$command='Import-OdmTaskTemplate';$p=@{Path=$FilePath;PassThru=$true}
    }
    $cmd=Get-QOdmOperationsCommand $command
    if($target -and $Action -ne 'ExportTemplate'){
        $owner=[string](Get-QOdmProperty $target @('ProjectId'))
        if($owner -and $owner -ne $script:QOdmState.WorkloadId){throw 'The selected item belongs to another workload.'}
    }
    if(-not $cmd){throw 'The installed module does not expose this management action.'}
    foreach($key in $p.Keys){if(-not $cmd.Parameters.ContainsKey($key)){throw "The installed module does not support the required $key parameter."}}
    $fingerprint=@($Action,$Id,$Name,$FilePath,$inputHash,$script:QOdmState.OrganizationId,$script:QOdmState.ProjectId,$script:QOdmState.WorkloadId,[string]$cmd.Module.Version,($details|ConvertTo-Json -Depth 20 -Compress))|ConvertTo-Json -Compress
    $plan=[ordered]@{Action=$Action;WorkloadId=$script:QOdmState.WorkloadId;Id=$Id;Name=$Name;InputFileHash=$inputHash;Details=$details;Status='PREVIEW';Error='';Reports=@()}
    $report=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'Management' -Extension '.json';$plan.Reports=@($report)
    if(-not $Execute){
        $token=[Guid]::NewGuid().ToString('N');$script:QOdmManagementPreview=@{Token=$token;Fingerprint=$fingerprint;At=[DateTime]::UtcNow}
        $plan|ConvertTo-Json -Depth 25|Set-Content -LiteralPath $report -Encoding UTF8
        return [pscustomobject]@{PreviewToken=$token;Plan=[pscustomobject]$plan;Reports=$plan.Reports}
    }
    if($Action -ne 'ExportTemplate'){Assert-QOdmWriteAllowed -Feature 'OperationsCenter'}
    $prior=Get-Variable QOdmManagementPreview -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if(-not $prior -or $prior.Token -ne $PreviewToken -or $prior.Fingerprint -ne $fingerprint -or ([DateTime]::UtcNow-$prior.At).TotalMinutes -gt 15){throw 'Preview this management action again; the context, input or source state changed.'}
    $script:QOdmManagementPreview=$null
    $plan.Status='SUBMITTING';$plan|ConvertTo-Json -Depth 25|Set-Content -LiteralPath $report -Encoding UTF8
    try{
        if($Action -eq 'ExportTemplate'){$p.Path=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'QuestTemplate' -Extension '.json';$plan.Reports+=@($p.Path)}
        $result=ConvertTo-QOdmObjectArray (& $cmd @p)
        $plan.Status='SUBMITTED_REVIEW_REQUIRED';$plan.Details=ConvertTo-QOdmSanitizedValue $result
        if($Action -eq 'ExportTemplate'){
            if(-not (Test-Path -LiteralPath $p.Path -PathType Leaf)){throw 'The template export file was not created.'};$plan.Status='EXPORTED'
        }elseif($Action -eq 'RenameCollection'){
            $null=Update-QOdmCollectionCache;$updated=Resolve-QOdmCollection -CollectionId $Id
            if((Get-QOdmName $updated) -ne $Name.Trim()){throw 'Collection rename readback did not match.'};$plan.Status='VERIFIED'
        }
    }catch{$plan.Status='REVIEW_REQUIRED';$plan.Error=Protect-QOdmSupportText $_.Exception.Message}
    finally{$plan|ConvertTo-Json -Depth 25|Set-Content -LiteralPath $report -Encoding UTF8}
    [pscustomobject]@{PreviewToken='';Plan=[pscustomobject]$plan;Reports=$plan.Reports}
}
