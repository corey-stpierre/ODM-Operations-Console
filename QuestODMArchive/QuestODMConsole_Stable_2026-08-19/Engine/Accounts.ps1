Set-StrictMode -Version 2.0

function Assert-QOdmAccountsWorkload {
    [CmdletBinding()]
    param()

    Assert-QOdmWorkloadSelected
    $workloadName = [string](Get-QOdmProperty -InputObject $script:QOdmState -Names @('WorkloadName'))
    $workloadType = [string](Get-QOdmProperty -InputObject $script:QOdmState -Names @('WorkloadType'))
    $descriptor = ('{0} {1}' -f $workloadName, $workloadType).Trim()
    if ($descriptor -notmatch '(?i)account') {
        throw "Account discovery and account mapping require the Accounts workload. Current context: '$workloadName' ($workloadType)."
    }
}

function Test-QOdmAsciiFileName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $name = [IO.Path]::GetFileName($Path)
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    foreach ($character in $name.ToCharArray()) {
        if ([int][char]$character -gt 127) { return $false }
    }
    return $true
}

function Test-QOdmUpnFormat {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value.Trim() -match '^[^@\s]+@[^@\s]+$')
}

function Test-QOdmGuidFormat {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [Guid]::Empty
    return [Guid]::TryParse($Value.Trim(), [ref]$parsed)
}

function Get-QOdmAccountCsvValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Discovery','Mapping')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$CsvPath
    )

    Set-QOdmOperationPhase -Phase ("Validating Quest account {0} CSV" -f $Mode.ToLowerInvariant())
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) { throw "CSV file not found: $CsvPath" }
    $file = Get-Item -LiteralPath $CsvPath -ErrorAction Stop
    if (-not [string]::Equals($file.Extension, '.csv', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Quest account discovery and mapping files must use the .csv extension.'
    }
    if (-not (Test-QOdmAsciiFileName -Path $file.FullName)) {
        throw 'Quest requires an ASCII-only CSV file name. Rename the file so its name contains only ASCII characters.'
    }
    $maximumBytes = 15MB
    if ($file.Length -gt $maximumBytes) {
        throw ('Quest account discovery and mapping CSV files cannot exceed 15 MB. File size: {0:N2} MB.' -f ($file.Length / 1MB))
    }

    $rows = ConvertTo-QOdmObjectArray -InputObject (Import-QOdmCsv -Path $file.FullName)
    $headers = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCsvHeaders -Rows $rows)
    $schema = $null
    $sourceColumn = $null
    $targetColumn = $null
    $typeColumn = $null

    if ($Mode -eq 'Discovery') {
        $hasUpn = Test-QOdmHeaderMatch -Headers $headers -Candidate 'UserPrincipalName'
        $hasObjectId = Test-QOdmHeaderMatch -Headers $headers -Candidate 'ObjectId'
        $hasType = Test-QOdmHeaderMatch -Headers $headers -Candidate 'Type'
        if (-not $hasType) { throw "Discovery CSV is missing required column 'Type'." }
        if ($hasUpn -and $hasObjectId) { throw "Discovery CSV cannot contain both 'UserPrincipalName' and 'ObjectId'. Use exactly one Quest discovery format." }
        if (-not $hasUpn -and -not $hasObjectId) { throw "Discovery CSV must contain either 'UserPrincipalName' or 'ObjectId'." }
        if ($hasUpn) { $schema = 'DiscoveryByUPN'; $sourceColumn = 'UserPrincipalName' }
        else { $schema = 'DiscoveryByObjectId'; $sourceColumn = 'ObjectId' }
        $typeColumn = 'Type'
    }
    else {
        $hasUpnPair = (Test-QOdmHeaderMatch -Headers $headers -Candidate 'SourceUPN') -and (Test-QOdmHeaderMatch -Headers $headers -Candidate 'TargetUPN')
        $hasIdPair = (Test-QOdmHeaderMatch -Headers $headers -Candidate 'SourceObjectId') -and (Test-QOdmHeaderMatch -Headers $headers -Candidate 'TargetObjectId')
        $hasAnyUpn = (Test-QOdmHeaderMatch -Headers $headers -Candidate 'SourceUPN') -or (Test-QOdmHeaderMatch -Headers $headers -Candidate 'TargetUPN')
        $hasAnyId = (Test-QOdmHeaderMatch -Headers $headers -Candidate 'SourceObjectId') -or (Test-QOdmHeaderMatch -Headers $headers -Candidate 'TargetObjectId')
        if ($hasAnyUpn -and -not $hasUpnPair) { throw "Mapping CSV must contain both 'SourceUPN' and 'TargetUPN'." }
        if ($hasAnyId -and -not $hasIdPair) { throw "Mapping CSV must contain both 'SourceObjectId' and 'TargetObjectId'." }
        if ($hasUpnPair -and $hasIdPair) { throw 'Mapping CSV cannot mix UPN and object-ID mapping formats.' }
        if (-not $hasUpnPair -and -not $hasIdPair) {
            throw "Mapping CSV must contain either 'SourceUPN,TargetUPN' or 'SourceObjectId,TargetObjectId'."
        }
        if ($hasUpnPair) { $schema = 'MappingByUPN'; $sourceColumn = 'SourceUPN'; $targetColumn = 'TargetUPN' }
        else { $schema = 'MappingByObjectId'; $sourceColumn = 'SourceObjectId'; $targetColumn = 'TargetObjectId' }
    }

    $validationRows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $validCount = 0
    $invalidCount = 0
    $rowNumber = 1
    foreach ($row in $rows) {
        $rowNumber++
        $source = ([string](Get-QOdmProperty -InputObject $row -Names @($sourceColumn))).Trim()
        $target = if ($targetColumn) { ([string](Get-QOdmProperty -InputObject $row -Names @($targetColumn))).Trim() } else { $null }
        $objectType = if ($typeColumn) { ([string](Get-QOdmProperty -InputObject $row -Names @($typeColumn))).Trim() } else { $null }
        $errors = [System.Collections.Generic.List[string]]::new()

        if ([string]::IsNullOrWhiteSpace($source)) { $errors.Add("$sourceColumn is blank.") | Out-Null }
        elseif ($schema -in @('DiscoveryByUPN','MappingByUPN') -and -not (Test-QOdmUpnFormat -Value $source)) { $errors.Add("$sourceColumn is not a valid UPN.") | Out-Null }
        elseif ($schema -in @('DiscoveryByObjectId','MappingByObjectId') -and -not (Test-QOdmGuidFormat -Value $source)) { $errors.Add("$sourceColumn is not a valid GUID.") | Out-Null }

        if ($targetColumn) {
            if ([string]::IsNullOrWhiteSpace($target)) { $errors.Add("$targetColumn is blank.") | Out-Null }
            elseif ($schema -eq 'MappingByUPN' -and -not (Test-QOdmUpnFormat -Value $target)) { $errors.Add("$targetColumn is not a valid UPN.") | Out-Null }
            elseif ($schema -eq 'MappingByObjectId' -and -not (Test-QOdmGuidFormat -Value $target)) { $errors.Add("$targetColumn is not a valid GUID.") | Out-Null }
        }

        if ($Mode -eq 'Discovery') {
            $normalizedType = $objectType.ToLowerInvariant()
            if ($normalizedType -notin @('user','microsoft 365 group')) {
                $errors.Add("Type must be 'user' or 'Microsoft 365 group'.") | Out-Null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($source)) {
            $duplicateKey = $source.ToLowerInvariant()
            if ($seen.ContainsKey($duplicateKey)) { $errors.Add("Duplicate source identifier; first seen on CSV row $($seen[$duplicateKey]).") | Out-Null }
            else { $seen[$duplicateKey] = $rowNumber }
        }

        if ($errors.Count -eq 0) { $status = 'VALID'; $validCount++ }
        else { $status = 'INVALID'; $invalidCount++ }
        $validationRows.Add([pscustomobject]@{
            RowNumber=$rowNumber; Mode=$Mode; Schema=$schema; SourceIdentifier=$source
            TargetIdentifier=$target; Type=$objectType; Status=$status; Details=($errors -join ' ')
        }) | Out-Null
    }

    [pscustomobject]@{
        Valid=($invalidCount -eq 0); Mode=$Mode; Schema=$schema; CsvPath=$file.FullName
        FileName=$file.Name; FileSizeBytes=$file.Length; Headers=$headers; TotalRows=$rows.Count
        ValidRows=$validCount; InvalidRows=$invalidCount; ValidationRows=$validationRows.ToArray()
    }
}

function Resolve-QOdmCommandParameterName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.CommandInfo]$Command,
        [Parameter(Mandatory = $true)][string[]]$Candidates,
        [bool]$Required = $false,
        [AllowNull()][string]$Purpose = $null
    )

    foreach ($candidate in $Candidates) {
        foreach ($available in (ConvertTo-QOdmObjectArray -InputObject $Command.Parameters.Keys)) {
            if ([string]::Equals([string]$available, [string]$candidate, [StringComparison]::OrdinalIgnoreCase)) { return [string]$available }
        }
    }
    if ($Required) {
        $label = if ([string]::IsNullOrWhiteSpace($Purpose)) { ($Candidates -join '/') } else { $Purpose }
        throw ("{0} does not expose a supported {1} parameter. Available parameters: {2}" -f $Command.Name, $label, (($Command.Parameters.Keys | Sort-Object) -join ', '))
    }
    return $null
}

function ConvertTo-QOdmFileParameterValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.CommandInfo]$Command,
        [Parameter(Mandatory = $true)][string]$ParameterName,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $metadata = $Command.Parameters[$ParameterName]
    $parameterType = if ($null -ne $metadata) { $metadata.ParameterType } else { $null }
    if ($parameterType -eq [System.IO.FileInfo]) { return (Get-Item -LiteralPath $Path -ErrorAction Stop) }
    if ($parameterType -eq [byte[]]) { return [IO.File]::ReadAllBytes($Path) }
    return $Path
}

function Get-QOdmNewTaskParameterPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('DiscoverAll','DiscoverFromCsv','MapFromCsv')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [AllowNull()][string]$CsvPath
    )

    $commandName = if ($Operation -eq 'MapFromCsv') { 'New-OdmMappingFileTask' } else { 'New-OdmDiscoveryTask' }
    if (-not (Test-QOdmCommand -Name $commandName)) { throw "$commandName is not available in the installed OdmApi module. Update OdmApi and retry." }
    $command = Get-Command -Name $commandName -ErrorAction Stop
    $parameters = @{}
    $required = [System.Collections.Generic.List[string]]::new()
    $optional = [System.Collections.Generic.List[string]]::new()

    $nameParameter = Resolve-QOdmCommandParameterName -Command $command -Candidates @('Name','TaskName') -Required $true -Purpose 'task-name'
    $parameters[$nameParameter] = $TaskName
    $required.Add($nameParameter) | Out-Null

    if ($Operation -in @('DiscoverAll','DiscoverFromCsv')) {
        $discoverFlag = Resolve-QOdmCommandParameterName -Command $command -Candidates @('DiscoverUsingCSV','DiscoverUsingCsv','UseCSV','UseCsv','DiscoverFromFile') -Required $true -Purpose 'DiscoverUsingCSV'
        $parameters[$discoverFlag] = ($Operation -eq 'DiscoverFromCsv')
        $required.Add($discoverFlag) | Out-Null

        $discoverGroupsParameter = Resolve-QOdmCommandParameterName -Command $command -Candidates @('DiscoverUsingGroups','UseGroups','DiscoverGroups')
        if ($discoverGroupsParameter) {
            $parameters[$discoverGroupsParameter] = $false
            $optional.Add($discoverGroupsParameter) | Out-Null
        }
        $discoveryFileCandidates = @('DiscoveryFilePath','DiscoveryFile','CsvFilePath','CSVFilePath','CsvPath','CSVPath','FilePath','InputFile','CSVFile','File')
        $discoveryFileParameter = Resolve-QOdmCommandParameterName -Command $command -Candidates $discoveryFileCandidates -Required ($Operation -eq 'DiscoverFromCsv') -Purpose 'CSV-file'
        if ($discoveryFileParameter -and $Operation -eq 'DiscoverFromCsv') {
            $parameters[$discoveryFileParameter] = ConvertTo-QOdmFileParameterValue -Command $command -ParameterName $discoveryFileParameter -Path $CsvPath
            $required.Add($discoveryFileParameter) | Out-Null
        }
    }
    elseif ($Operation -eq 'MapFromCsv') {
        $fileCandidates = @('MappingFilePath','MappingFile','MapFilePath','CsvFilePath','CSVFilePath','CsvPath','CSVPath','FilePath','InputFile','CSVFile','File')
        $fileParameter = Resolve-QOdmCommandParameterName -Command $command -Candidates $fileCandidates -Required $true -Purpose 'CSV-file'
        $parameters[$fileParameter] = ConvertTo-QOdmFileParameterValue -Command $command -ParameterName $fileParameter -Path $CsvPath
        $required.Add($fileParameter) | Out-Null
    }

    $passThruParameter = Resolve-QOdmCommandParameterName -Command $command -Candidates @('PassThru')
    if ($passThruParameter) { $parameters[$passThruParameter] = $true; $optional.Add($passThruParameter) | Out-Null }

    [pscustomobject]@{
        CommandName=$commandName; Parameters=$parameters; RequiredParameters=$required.ToArray(); OptionalParameters=$optional.ToArray()
        AvailableParameters=ConvertTo-QOdmObjectArray -InputObject $command.Parameters.Keys
    }
}

function Invoke-QOdmAccountTaskOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('DiscoverAll','DiscoverFromCsv','MapFromCsv')][string]$Operation,
        [AllowNull()][string]$TaskName,
        [AllowNull()][string]$CsvPath,
        [bool]$Execute = $false,
        [bool]$StartAfterCreate = $false,
        [AllowNull()][string]$OutputDirectory = $null
    )

    Assert-QOdmAccountsWorkload
    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        $prefix = switch ($Operation) {
            'DiscoverAll' { 'Discover All Accounts' }
            'DiscoverFromCsv' { 'Discover Accounts from File' }
            'MapFromCsv' { 'Map Accounts from File' }
        }
        $TaskName = '{0} {1}' -f $prefix, (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    $TaskName = $TaskName.Trim()

    $validation = $null
    $validationRows = [System.Collections.Generic.List[object]]::new()
    if ($Operation -in @('DiscoverFromCsv','MapFromCsv')) {
        if ([string]::IsNullOrWhiteSpace($CsvPath)) { throw 'A Quest CSV template file is required for this operation.' }
        $validationMode = if ($Operation -eq 'MapFromCsv') { 'Mapping' } else { 'Discovery' }
        $validation = Get-QOdmAccountCsvValidation -Mode $validationMode -CsvPath $CsvPath
        foreach ($row in (ConvertTo-QOdmObjectArray -InputObject $validation.ValidationRows)) { $validationRows.Add($row) | Out-Null }
    }
    else {
        $validationRows.Add([pscustomobject]@{ RowNumber=$null; Mode='Discovery'; Schema='DiscoverAll'; SourceIdentifier=$null; TargetIdentifier=$null; Type='All supported accounts'; Status='VALID'; Details='All accounts in the selected source tenant will be discovered.' }) | Out-Null
    }

    $reportPath = New-QOdmReportPath -OutputDirectory $OutputDirectory -BaseName ('Account_{0}_Validation' -f $Operation)
    Export-QOdmCsv -Rows $validationRows.ToArray() -Path $reportPath | Out-Null

    if ($null -ne $validation -and -not [bool]$validation.Valid) {
        return [pscustomobject]@{
            Operation=$Operation; Execute=$Execute; StartAfterCreate=$StartAfterCreate; TaskName=$TaskName
            CsvPath=$CsvPath; Schema=$validation.Schema; Valid=$false; TotalRows=$validation.TotalRows
            ValidRows=$validation.ValidRows; InvalidRows=$validation.InvalidRows; Status='VALIDATION_FAILED'
            Details=("The CSV contains invalid rows. No Quest task was created. Validation report: {0}" -f $reportPath); Task=$null; TaskId=$null
            Created=$false; Started=$false; StartResult=$null; ValidationRows=$validationRows.ToArray()
            Rows=$validationRows.ToArray(); ReportPath=$reportPath; Reports=@($reportPath)
        }
    }

    if ($script:QOdmState.Tasks.Count -eq 0) { $null = Update-QOdmTaskCache }
    $existingMatches = ConvertTo-QOdmObjectArray -InputObject ($script:QOdmState.Tasks.Values | Where-Object {
        [string]::Equals([string](Get-QOdmName $_), $TaskName, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($existingMatches.Count -gt 0) {
        $ids = ($existingMatches | ForEach-Object { Get-QOdmId $_ }) -join ', '
        throw "A task named '$TaskName' already exists in the selected context. Existing task ID(s): $ids"
    }

    $plan = Get-QOdmNewTaskParameterPlan -Operation $Operation -TaskName $TaskName -CsvPath $CsvPath
    if (-not $Execute) {
        $previewRow = [pscustomobject]@{
            Operation=$Operation; TaskName=$TaskName; Command=$plan.CommandName
            Schema=if ($null -ne $validation) { $validation.Schema } else { 'DiscoverAll' }
            CsvPath=$CsvPath; Status='WOULD_CREATE'; Details=if ($StartAfterCreate) { 'The task would be created and then started.' } else { 'The task would be created but not started.' }
        }
        return [pscustomobject]@{
            Operation=$Operation; Execute=$false; StartAfterCreate=$StartAfterCreate; TaskName=$TaskName
            CsvPath=$CsvPath; Schema=$previewRow.Schema; Valid=$true
            TotalRows=if ($null -ne $validation) { $validation.TotalRows } else { 0 }
            ValidRows=if ($null -ne $validation) { $validation.ValidRows } else { 0 }
            InvalidRows=0; Status='WOULD_CREATE'; Details=$previewRow.Details; Task=$null; TaskId=$null
            Created=$false; Started=$false; StartResult=$null; ValidationRows=$validationRows.ToArray()
            Rows=@($previewRow); ReportPath=$reportPath; Reports=@($reportPath)
            Command=$plan.CommandName; CommandParameters=$plan.Parameters.Keys
        }
    }

    Set-QOdmOperationPhase -Phase ("Creating Quest account task '$TaskName'")
    $existingIds = @{}
    foreach ($id in (ConvertTo-QOdmObjectArray -InputObject $script:QOdmState.Tasks.Keys)) { $existingIds[[string]$id] = $true }
    $returned = Invoke-QOdmSupportedCommandArray -CommandName $plan.CommandName -Parameters $plan.Parameters `
        -RequiredParameters $plan.RequiredParameters -OptionalParameters $plan.OptionalParameters
    $task = Resolve-QOdmCreatedEntityAfterWrite -EntityType Task -Name $TaskName -ExistingIds $existingIds -ReturnedObjects $returned
    $taskId = Get-QOdmId $task
    if ($taskId) { $script:QOdmState.Tasks[$taskId] = $task }

    $startResult = $null
    $started = $false
    if ($StartAfterCreate) {
        Set-QOdmOperationPhase -Phase ("Starting Quest account task '$TaskName'")
        $startResult = Start-QOdmTaskSafely -Task $task -DelaySeconds 2
        $started = [bool](Get-QOdmProperty -InputObject $startResult -Names @('StartSucceeded') -Default $false)
    }
    $status = if ($StartAfterCreate) { if ($started) { 'CREATED_AND_STARTED' } else { 'CREATED_START_FAILED' } } else { 'CREATED' }
    $details = if ($StartAfterCreate) { [string](Get-QOdmProperty -InputObject $startResult -Names @('Details')) } else { 'The task was created and was not started.' }
    $resultRow = [pscustomobject]@{
        Operation=$Operation; TaskName=$TaskName; TaskId=$taskId; Command=$plan.CommandName
        Schema=if ($null -ne $validation) { $validation.Schema } else { 'DiscoverAll' }
        CsvPath=$CsvPath; Created=$true; Started=$started; Status=$status; Details=$details
    }
    $null = Update-QOdmTaskCache

    [pscustomobject]@{
        Operation=$Operation; Execute=$true; StartAfterCreate=$StartAfterCreate; TaskName=$TaskName
        CsvPath=$CsvPath; Schema=$resultRow.Schema; Valid=$true
        TotalRows=if ($null -ne $validation) { $validation.TotalRows } else { 0 }
        ValidRows=if ($null -ne $validation) { $validation.ValidRows } else { 0 }
        InvalidRows=0; Status=$status; Details=$details; Task=(ConvertTo-QOdmTaskView $task); TaskId=$taskId
        Created=$true; Started=$started; StartResult=$startResult; ValidationRows=$validationRows.ToArray()
        Rows=@($resultRow); ReportPath=$reportPath; Reports=@($reportPath)
    }
}
