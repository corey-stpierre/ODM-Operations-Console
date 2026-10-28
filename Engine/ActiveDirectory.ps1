# Organization-scoped ODM AD API. This is separate from the M365 Accounts workload.
function Assert-QOdmAdContext {
    Assert-QOdmOrganizationSelected
    if ((Get-QOdmProperty $script:QOdmState @('ContextMode')) -ne 'ActiveDirectory') { throw 'Open the Active Directory workspace for the selected organization first.' }
    if ($script:QOdmState.ProjectId -or $script:QOdmState.WorkloadId) { throw 'AD context contains a Microsoft 365 selection. Reopen the AD workspace.' }
}

function Open-QOdmActiveDirectory {
    Assert-QOdmOrganizationSelected
    foreach ($name in @('ProjectId','ProjectName','ProjectObject','WorkloadId','WorkloadName','WorkloadType','WorkloadObject')) { $script:QOdmState[$name]=$null }
    $script:QOdmState['ContextMode']='ActiveDirectory'
    $script:QOdmState['ContextEpoch']=[guid]::NewGuid().ToString()
    $script:QOdmAdPreview=$null
    Reset-QOdmCaches
    Enable-QOdmSafeMode -Reason 'Safe Mode reset when opening the Active Directory workspace.' | Out-Null
    [pscustomobject]@{State=Get-QOdmContextState;Catalog=Get-QOdmAdCatalog}
}

function Get-QOdmAdCatalog {
    $catalog=Get-Content -LiteralPath (Join-Path $script:QOdmAppRoot 'Config\ActiveDirectoryCatalog.json') -Raw | ConvertFrom-Json
    foreach ($entry in @($catalog.Inventories)+@($catalog.Operations)) {
        $cmd=Get-QOdmOperationsCommand $entry.Command
        $missing=@()
        if ($cmd) {
            $names=if ($entry.PSObject.Properties['TargetParameter']) {@($entry.TargetParameter)+@($entry.Parameters | ForEach-Object {$_.Name})} else {@($entry.Parameters)}
            $missing=@($names | Where-Object {-not $cmd.Parameters.ContainsKey($_)})
        }
        $entry | Add-Member Available ([bool]$cmd -and $missing.Count -eq 0)
        $entry | Add-Member AvailabilityNote $(if(-not $cmd){'Not exported by the loaded OdmApi module.'}elseif($missing.Count){'Required API parameters are missing: '+($missing -join ', ')}else{'Available in the loaded module; tenant permissions and prerequisites require connected acceptance.'})
    }
    return $catalog
}

function Get-QOdmAdInventorySpec {
    param([string]$Kind)
    $matches=@((Get-QOdmAdCatalog).Inventories | Where-Object {$_.Kind -eq $Kind})
    if ($matches.Count -ne 1 -or -not $matches[0].Available) { throw "AD inventory '$Kind' is unavailable in this module." }
    return $matches[0]
}

# Single invocation boundary, replaced by fixtures in offline tests. Never evaluates input as code.
function Invoke-QOdmAdNative {
    param([string]$CommandName,[Collections.IDictionary]$Parameters)
    Assert-QOdmAdContext
    $catalog=Get-QOdmAdCatalog
    if ($CommandName -notin @(@($catalog.Inventories)+@($catalog.Operations) | ForEach-Object {$_.Command})) { throw 'Command is outside the reviewed AD catalog.' }
    if ($CommandName -notlike 'Get-*') { Assert-QOdmWriteAllowed -Feature 'ActiveDirectory' }
    if ($Parameters.Contains('AsPlainText')) { throw 'Plaintext credential retrieval is not supported.' }
    $cmd=Get-QOdmOperationsCommand $CommandName
    if (-not $cmd) { throw 'The installed module does not export this AD command.' }
    foreach ($key in $Parameters.Keys) { if (-not $cmd.Parameters.ContainsKey($key)) { throw "Unsupported AD parameter: $key" } }
    $invoke=@{};foreach($key in $Parameters.Keys){$invoke[$key]=$Parameters[$key]};$invoke.ErrorAction='Stop'
    & $cmd @invoke
}

function ConvertTo-QOdmAdId {
    param([string]$Text,[object]$Spec)
    $value=$Text.Trim()
    if (-not $value -or $value -match '[\r\n,]') { throw 'Use one exact ID for each target or reference.' }
    if ($Spec.OpaqueId) { return $value }
    $id=0
    if (-not [int]::TryParse($value,[ref]$id) -or $id -le 0) { throw "$($Spec.Name) needs a positive integer AD ID, not a Microsoft 365 GUID." }
    return $id
}

function Resolve-QOdmAdEntity {
    param([string]$Kind,[string]$Id)
    $spec=Get-QOdmAdInventorySpec $Kind
    if (-not $spec.IdentityProperty) { throw 'This inventory does not expose target IDs.' }
    $key=ConvertTo-QOdmAdId $Id $spec
    $p=@{};$p[$spec.IdentityParameter]=$key
    $items=ConvertTo-QOdmObjectArray (Invoke-QOdmAdNative $spec.Command $p)
    if ($items.Count -ne 1 -or -not [string]::Equals([string](Get-QOdmProperty $items[0] @($spec.IdentityProperty)),[string]$key,[StringComparison]::Ordinal)) { throw "Exact $Kind ID '$Id' did not resolve uniquely in this organization." }
    return $items[0]
}

# Flat snapshots avoid cyclic SDK navigation properties and exclude credentials, keys and global-variable values.
function ConvertTo-QOdmAdSnapshot {
    param([AllowNull()][object]$Value,[switch]$Binding)
    if ($null -eq $Value) { return $null }
    $row=[ordered]@{}
    $names=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
    foreach ($name in ($names | Sort-Object)) {
        if ($name -match '(?i)password|secret|token|authkey|agentkey|servicekey|^value$') { $row[$name]='<redacted>';continue }
        if ($Binding -and $name -match '(?i)timestamp|^last|^AgentVersion$|^NextExecutionDate$|^Started$|^Completed$') { continue }
        $v=Get-QOdmProperty $Value @($name)
        if ($null -eq $v) { $row[$name]=$null }
        elseif($v -is [string]){$row[$name]=Protect-QOdmSupportText $v}
        elseif($v -is [ValueType]){$row[$name]=[string]$v}
        elseif($v.GetType().Name -eq 'GraphqlGlobalId'){$row[$name]=[string]$v}
        elseif($v -is [string[]]){$row[$name]=@($v|ForEach-Object {Protect-QOdmSupportText $_})}
        # Other SDK navigation objects are intentionally not serialized.
    }
    [pscustomobject]$row
}

function Get-QOdmAdInventoryView {
    param([string]$Kind='Devices',[string]$Id,[string]$ParentId,[string]$Filter,[ValidateRange(1,100000)][int]$Limit=1000)
    Assert-QOdmAdContext
    $spec=Get-QOdmAdInventorySpec $Kind
    $p=@{}
    if ($Id) {
        if ($ParentId -or $Filter) { throw 'Use an exact ID alone, or a parent/filter query.' }
        $items=@(Resolve-QOdmAdEntity $Kind $Id)
    } else {
        if ($spec.ParentKind) {
            if (-not $ParentId) { throw "$Kind requires a $($spec.ParentKind) ID in Parent ID." }
            $p[$spec.ParentParameter]=Resolve-QOdmAdEntity $spec.ParentKind $ParentId
        } elseif($ParentId) { throw 'Parent ID is not used by this inventory.' }
        if ($Filter) {
            if ('Filter' -in $spec.Parameters) {$p.Filter=$Filter}
            elseif('SearchQuery' -in $spec.Parameters){$p.SearchQuery=$Filter}
            else {throw 'This inventory does not support a filter.'}
        }
        if ('Limit' -in $spec.Parameters) {$p.Limit=$Limit}
        $items=ConvertTo-QOdmObjectArray (Invoke-QOdmAdNative $spec.Command $p)
    }
    $rows=@(foreach ($item in $items) {
        $snapshot=ConvertTo-QOdmAdSnapshot $item
        [pscustomobject]@{OrganizationId=$script:QOdmState.OrganizationId;Kind=$Kind;TargetId=$(if($spec.IdentityProperty){[string](Get-QOdmProperty $item @($spec.IdentityProperty))}else{''});Name=[string](Get-QOdmProperty $item @('DeviceName','SAMAccountName','WorkflowName','ActionDisplayName','ActionName','TaskName','TenantName','Name','ProfileName','CredentialName','DisplayName','Path','PrincipalName'));EnvironmentId=[string](Get-QOdmProperty $item @('EnvironmentId'));Status=[string](Get-QOdmProperty $item @('Status','CutoverStatus','SelfServiceMigrationStatus'));Details=($snapshot|ConvertTo-Json -Depth 5 -Compress)}
    })
    [pscustomobject]@{Rows=$rows;Note="Returned $($rows.Count) records. Limit $Limit; this is a bounded query, not proof of a complete inventory. Use exact IDs or narrower vendor filters. Details omit secrets and nested SDK objects."}
}

function Get-QOdmAdDefinition {
    param([string]$CommandName)
    Assert-QOdmAdContext
    $entries=@((Get-QOdmAdCatalog).Operations | Where-Object {$_.Command -eq $CommandName})
    if($entries.Count -ne 1 -or -not $entries[0].Available){throw 'This AD operation is unavailable in the loaded module.'}
    $entry=$entries[0];$cmd=Get-QOdmOperationsCommand $CommandName
    $fields=@(foreach($p in $entry.Parameters){
        $type=$cmd.Parameters[$p.Name].ParameterType;$underlying=[Nullable]::GetUnderlyingType($type);if($underlying){$type=$underlying}
        $kind='Text';$choices=@()
        if($type -eq [bool] -or $type -eq [Management.Automation.SwitchParameter]){$kind='Choice';$choices=@('true','false')}
        elseif($type.IsEnum){$kind='Choice';$choices=[Enum]::GetNames($type)}
        elseif($type -eq [string[]]){$kind='Lines'}
        [pscustomobject]@{Name=$p.Name;Required=$p.Required;Kind=$kind;Choices=$choices;Description=$p.Description;ReferenceKind=$p.ReferenceKind}
    })
    [pscustomobject]@{Command=$entry.Command;Name=$entry.Name;TargetKind=$entry.TargetKind;Risk=$entry.Risk;Fields=$fields;UnsupportedParameters=$entry.UnsupportedParameters}
}

function ConvertTo-QOdmAdValues {
    param([object]$Spec,[Collections.IDictionary]$Values)
    $cmd=Get-QOdmOperationsCommand $Spec.Command
    $parameters=@{};$display=[ordered]@{};$references=[ordered]@{}
    foreach($name in $Values.Keys){if($name -notin @($Spec.Parameters|ForEach-Object {$_.Name})){throw "Unsupported field '$name'."}}
    foreach($field in $Spec.Parameters){
        $name=$field.Name;$raw=Get-QOdmProperty $Values @($name)
        if($null -eq $raw -or [string]::IsNullOrWhiteSpace([string]$raw)) {if($field.Required){throw "Required field: $name"};continue}
        $type=$cmd.Parameters[$name].ParameterType;$underlying=[Nullable]::GetUnderlyingType($type);if($underlying){$type=$underlying}
        if($field.ReferenceKind){$entity=Resolve-QOdmAdEntity $field.ReferenceKind ([string]$raw);$parameters[$name]=$entity;$display[$name]=[string]$raw;$references[$name]=ConvertTo-QOdmAdSnapshot $entity -Binding;continue}
        if($type -eq [bool] -or $type -eq [Management.Automation.SwitchParameter]){
            if([string]$raw -notmatch '^(?i:true|false)$'){throw "$name must be true or false."};$value=([string]$raw -ieq 'true')
        }elseif($type.IsEnum){
            if([string]$raw -notin [Enum]::GetNames($type)){throw "Invalid choice for $name."};$value=[Enum]::Parse($type,[string]$raw,$true)
        }elseif($type -eq [int]){
            $value=0;if(-not [int]::TryParse([string]$raw,[ref]$value) -or $value -lt 0){throw "$name must be a nonnegative integer."}
        }elseif($type -eq [guid]){
            $value=[guid]::Empty;if(-not [guid]::TryParse([string]$raw,[ref]$value) -or $value -eq [guid]::Empty){throw "$name must be a nonempty GUID copied from Quest."}
        }elseif($type -eq [datetime] -or $type -eq [datetimeoffset]){
            $date=[datetimeoffset]::MinValue
            if([string]$raw -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,7})?)?(Z|[+-]\d{2}:\d{2})$' -or -not [datetimeoffset]::TryParse([string]$raw,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date) -or $date -le [datetimeoffset]::UtcNow.AddMinutes(1)){throw "$name must be an ISO timestamp with timezone at least one minute in the future."}
            $value=if($type -eq [datetime]){$date.UtcDateTime}else{$date}
        }elseif($type -eq [string[]]){$value=[string[]]@(([string]$raw -split '\r?\n')|Where-Object {$_ -ne ''})}
        elseif($type -eq [string]){$value=[string]$raw}
        else{throw "Field $name has an unreviewed parameter type."}
        $parameters[$name]=$value;$display[$name]=$value
    }
    if($Spec.Mode -eq 'Set' -and $parameters.Count -eq 0){throw 'Choose at least one setting to change. Blank optional fields preserve existing values.'}
    # No unexpected mandatory vendor parameter may be satisfied by a prompt/default.
    $known=@($Spec.TargetParameter)+@($parameters.Keys)
    $viable=@($cmd.ParameterSets|Where-Object { @($_.Parameters|Where-Object {$_.IsMandatory -and $_.Name -notin $known}).Count -eq 0 })
    if(-not $viable.Count){throw 'The loaded API requires parameters outside this reviewed action. Use Quest web console.'}
    [pscustomobject]@{Parameters=$parameters;Display=[pscustomobject]$display;References=[pscustomobject]$references}
}

function Invoke-QOdmAdAction {
    [CmdletBinding()]
    param([string]$CommandName,[string]$TargetIds,[string]$CsvPath,[Collections.IDictionary]$Values=@{},[bool]$Execute=$false,[bool]$Acknowledged=$false,[string]$ConfirmationText,[string]$PreviewToken,[string]$OutputDirectory)
    $ErrorActionPreference='Stop'
    Assert-QOdmAdContext
    if($Execute){Assert-QOdmWriteAllowed -Feature 'ActiveDirectory'}
    $definition=Get-QOdmAdDefinition $CommandName
    $spec=@((Get-QOdmAdCatalog).Operations|Where-Object {$_.Command -eq $CommandName})[0]
    $targetSpec=Get-QOdmAdInventorySpec $spec.TargetKind
    $converted=ConvertTo-QOdmAdValues $spec $Values
    if($CsvPath -and $TargetIds){throw 'Use target IDs or a CSV, not both.'}
    $hash='';$requests=@()
    if($CsvPath){
        $hash=Get-QOdmFileSha256 $CsvPath
        $requests=@(Import-QOdmCsv $CsvPath)
        $headers=@(Get-QOdmCsvHeaders $requests)
        foreach($header in $headers){if($header -notin @('OrganizationId','TargetId','EnvironmentId','Kind','Name','Status','Details')){throw "Unsupported AD CSV column '$header'. Use the documented schema or an exported AD inventory."}}
        foreach($required in @('OrganizationId','TargetId')){if($required -notin $headers){throw "CSV requires $required and TargetId columns."}}
        foreach($row in $requests){
            if([string]$row.OrganizationId -ne [string]$script:QOdmState.OrganizationId){throw 'A CSV organization does not match the selected Quest organization.'}
            $rowKind=[string](Get-QOdmProperty $row @('Kind'));if($rowKind -and $rowKind -ne $spec.TargetKind){throw 'CSV inventory kind does not match the action target kind.'}
        }
        if((Get-QOdmFileSha256 $CsvPath) -ne $hash){throw 'CSV changed while reading. Preview again.'}
    }else{
        $requests=@(($TargetIds -split '[,\r\n]')|Where-Object {$_ -and $_.Trim()}|ForEach-Object {[pscustomobject]@{TargetId=$_.Trim()}})
    }
    if(-not $requests.Count -or $requests.Count -gt 1000){throw 'Select 1 to 1,000 explicit target IDs. There is no all-devices action.'}
    if($spec.TargetKind -in @('InteractiveProfiles','ReACLProfiles') -and $requests.Count -ne 1){throw 'Edit one shared profile at a time.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$targets=@();$bound=@();$records=@()
    foreach($row in $requests){
        $id=[string](ConvertTo-QOdmAdId ([string]$row.TargetId) $targetSpec)
        if(-not $seen.Add($id)){throw "Duplicate target ID: $id"}
        $entity=Resolve-QOdmAdEntity $spec.TargetKind $id
        $guard=[string](Get-QOdmProperty $row @('EnvironmentId'))
        if($guard -and $guard -ne [string](Get-QOdmProperty $entity @('EnvironmentId'))){throw "Environment mismatch for target $id."}
        $targets+=@($entity);$bound+=@(ConvertTo-QOdmAdSnapshot $entity -Binding)
        $records+=@([pscustomobject]@{TargetId=$id;Status='NOT_SUBMITTED';Before=ConvertTo-QOdmAdSnapshot $entity;Response=@();Error=''})
    }
    $module=Get-QOdmLoadedApiModule
    $fingerprint=@($CommandName,$script:QOdmState.OrganizationId,$script:QOdmState.Region,$script:QOdmState.ContextEpoch,[string]$module.Version,[string]$module.Path,$hash,$bound,$converted.Display,$converted.References)|ConvertTo-Json -Depth 12 -Compress
    $plan=[ordered]@{Command=$CommandName;OrganizationId=$script:QOdmState.OrganizationId;Region=$script:QOdmState.Region;Context='ActiveDirectory';TargetKind=$spec.TargetKind;Risk=$spec.Risk;Execution='May take effect immediately. DoNotStartBefore is an earliest start, not a hold. Shared profile changes affect every device using that profile.';Settings=$converted.Display;References=$converted.References;InputFileHash=$hash;Status='PREVIEW';Targets=$records;Reports=@()}
    $report=New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName 'ActiveDirectory' -Extension '.json';$plan.Reports=@($report)
    if(-not $Execute){
        $token=[guid]::NewGuid().ToString('N');$script:QOdmAdPreview=@{Token=$token;Fingerprint=$fingerprint;At=[datetime]::UtcNow}
        $plan|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $report -Encoding UTF8
        return [pscustomobject]@{PreviewToken=$token;Plan=[pscustomobject]$plan;Reports=$plan.Reports}
    }
    if(-not $Acknowledged -or $ConfirmationText -cne 'APPLY AD ACTION'){throw "Acknowledge the impact and enter exactly APPLY AD ACTION."}
    $prior=Get-Variable QOdmAdPreview -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if(-not $prior -or -not $PreviewToken -or $prior.Token -cne $PreviewToken -or $prior.Fingerprint -cne $fingerprint -or ([datetime]::UtcNow-$prior.At).TotalMinutes -gt 15){throw 'Preview again: the preview expired, was consumed, or the context, file, inputs or target configuration changed.'}
    $script:QOdmAdPreview=$null
    $plan.Status='SUBMITTING'
    $plan|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $report -Encoding UTF8
    for($i=0;$i -lt $targets.Count;$i++){
        $record=$records[$i];$record.Status='SUBMITTING'
        # Persist before each submission. A journal failure must prevent the next write.
        $plan|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $report -Encoding UTF8
        try{
            $p=@{};foreach($key in $converted.Parameters.Keys){$p[$key]=$converted.Parameters[$key]}
            $p[$spec.TargetParameter]=if($targetSpec.OpaqueId){[object[]]@($record.TargetId)}else{$targets[$i]}
            $response=ConvertTo-QOdmObjectArray (Invoke-QOdmAdNative $CommandName $p)
            $record.Response=@($response|ForEach-Object {ConvertTo-QOdmAdSnapshot $_})
            if($targetSpec.OpaqueId){
                if($response.Count -ne 1){throw 'Self-service returned no unambiguous action result.'}
                $errors=ConvertTo-QOdmObjectArray (Get-QOdmProperty $response[0] @('Errors') @())
                if($errors.Count -gt 0 -or [int](Get-QOdmProperty $response[0] @('TotalUpdatedCount') -1) -ne 1){throw 'Self-service reported errors or an unexpected updated count. Review Quest before retrying.'}
            }
            $record.Status='SUBMITTED_REVIEW_REQUIRED'
        }catch{
            $record.Status='REVIEW_REQUIRED';$record.Error='Submission or response validation failed. Its outcome may be uncertain. Review Quest jobs/workflow runs before any retry; no automatic retry was attempted.'
            $plan.Status='REVIEW_REQUIRED';break
        }finally{$plan|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $report -Encoding UTF8}
    }
    if($plan.Status -eq 'SUBMITTING'){$plan.Status='SUBMITTED_REVIEW_REQUIRED'}
    $plan|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $report -Encoding UTF8
    [pscustomobject]@{PreviewToken='';Plan=[pscustomobject]$plan;Reports=$plan.Reports}
}
