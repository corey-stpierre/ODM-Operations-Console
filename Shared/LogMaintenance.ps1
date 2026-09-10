Set-StrictMode -Version 2.0

function ConvertTo-QOdmLogRetentionDays {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [int]$Default = 30,
        [int]$Minimum = 1,
        [int]$Maximum = 3650
    )

    if ($Default -lt $Minimum) { $Default = $Minimum }
    if ($Default -gt $Maximum) { $Default = $Maximum }

    $parsed = 0
    if ([int]::TryParse([string]$Value,[ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum) {
        return $parsed
    }
    return $Default
}

function Format-QOdmLogByteSize {
    [CmdletBinding()]
    param([long]$Bytes)

    if ($Bytes -lt 0) { $Bytes = 0 }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} bytes' -f $Bytes)
}

function Test-QOdmLogPathEqual {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Left,
        [AllowEmptyString()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    try {
        $trimCharacters = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $leftPath = [IO.Path]::GetFullPath($Left).TrimEnd($trimCharacters)
        $rightPath = [IO.Path]::GetFullPath($Right).TrimEnd($trimCharacters)
        return [string]::Equals($leftPath,$rightPath,[StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Set-QOdmLogTextFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string[]]$Lines
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $temporaryPath = Join-Path $directory ('.{0}.{1}.{2}.tmp' -f ([IO.Path]::GetFileName($Path)),$PID,([Guid]::NewGuid().ToString('N')))
    try {
        $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
        if ($null -eq $Lines -or $Lines.Count -eq 0) {
            [IO.File]::WriteAllText($temporaryPath,'',$encoding)
        }
        else {
            [IO.File]::WriteAllLines($temporaryPath,[string[]]$Lines,$encoding)
        }
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force -ErrorAction Stop
        $temporaryPath = $null
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace([string]$temporaryPath) -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-QOdmOperationHistoryMaintenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Retention','ClearHistorical')][string]$Mode,
        [Parameter(Mandatory = $true)][DateTime]$CutoffUtc
    )

    $result = [ordered]@{ PrunedRecords=0; ReclaimedBytes=[long]0; Changed=$false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$result }

    $before = [long](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
    if ($Mode -eq 'ClearHistorical') {
        Set-QOdmLogTextFileAtomic -Path $Path -Lines @()
        $after = [long](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        $result.ReclaimedBytes = [Math]::Max([long]0,($before - $after))
        $result.Changed = ($before -gt $after)
        return [pscustomobject]$result
    }

    $lines = @([IO.File]::ReadAllLines($Path))
    $kept = [System.Collections.Generic.List[string]]::new()
    $pruned = 0
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $remove = $false
        try {
            $record = [string]$line | ConvertFrom-Json -ErrorAction Stop
            $timestampProperty = $record.PSObject.Properties['Timestamp']
            if ($null -ne $timestampProperty -and -not [string]::IsNullOrWhiteSpace([string]$timestampProperty.Value)) {
                $parsedTimestamp = [DateTimeOffset]::MinValue
                $parsed = [DateTimeOffset]::TryParse(
                    [string]$timestampProperty.Value,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal,
                    [ref]$parsedTimestamp
                )
                if ($parsed -and $parsedTimestamp.UtcDateTime -lt $CutoffUtc) { $remove = $true }
            }
        }
        catch {
            # Preserve malformed lines so retention never destroys evidence that may be needed for support.
            $remove = $false
        }

        if ($remove) { $pruned++ }
        else { $kept.Add([string]$line) | Out-Null }
    }

    if ($pruned -gt 0) {
        Set-QOdmLogTextFileAtomic -Path $Path -Lines $kept.ToArray()
        $after = [long](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        $result.ReclaimedBytes = [Math]::Max([long]0,($before - $after))
        $result.Changed = $true
    }
    $result.PrunedRecords = $pruned
    return [pscustomobject]$result
}

function Invoke-QOdmBootstrapLogMaintenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Retention','ClearHistorical')][string]$Mode,
        [Parameter(Mandatory = $true)][DateTime]$CutoffUtc,
        [long]$MaximumBytes = 5MB,
        [int]$TailLines = 4000
    )

    $result = [ordered]@{ ReclaimedBytes=[long]0; Changed=$false; Action='' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$result }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $before = [long]$item.Length
    $shouldClear = ($Mode -eq 'ClearHistorical') -or ($item.LastWriteTimeUtc -lt $CutoffUtc)
    if ($shouldClear) {
        Set-QOdmLogTextFileAtomic -Path $Path -Lines @()
        $after = [long](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        $result.ReclaimedBytes = [Math]::Max([long]0,($before - $after))
        $result.Changed = ($before -gt $after)
        $result.Action = if ($Mode -eq 'ClearHistorical') { 'Cleared' } else { 'Expired' }
        return [pscustomobject]$result
    }

    if ($MaximumBytes -gt 0 -and $before -gt $MaximumBytes) {
        if ($TailLines -lt 100) { $TailLines = 100 }
        $tail = @(Get-Content -LiteralPath $Path -Tail $TailLines -ErrorAction Stop)
        Set-QOdmLogTextFileAtomic -Path $Path -Lines ([string[]]$tail)
        $after = [long](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        $result.ReclaimedBytes = [Math]::Max([long]0,($before - $after))
        $result.Changed = ($before -gt $after)
        $result.Action = 'Trimmed'
    }
    return [pscustomobject]$result
}

function Invoke-QOdmLogMaintenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('MainConsole','MappingCollisionUtility')][string]$Application,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [AllowEmptyString()][string]$CurrentSessionLogPath,
        [AllowNull()][object]$RetentionDays = 30,
        [ValidateSet('Retention','ClearHistorical')][string]$Mode = 'Retention'
    )

    $days = ConvertTo-QOdmLogRetentionDays -Value $RetentionDays -Default 30 -Minimum 1 -Maximum 3650
    $cutoffUtc = [DateTime]::UtcNow.AddDays(-1 * $days)
    $logDirectory = Join-Path $DataRoot 'Logs'
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $deletedFiles = [System.Collections.Generic.List[string]]::new()
    $resetFiles = [System.Collections.Generic.List[string]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()
    $reclaimedBytes = [long]0
    $prunedHistory = 0

    $sessionPattern = if ($Application -eq 'MainConsole') { 'QuestODMConsole_*.log' } else { 'MappingCollisionUtility_*.log' }
    $sessionFiles = @(Get-ChildItem -LiteralPath $logDirectory -File -Filter $sessionPattern -ErrorAction SilentlyContinue)
    foreach ($file in $sessionFiles) {
        if (Test-QOdmLogPathEqual -Left $file.FullName -Right $CurrentSessionLogPath) { continue }
        $eligible = ($Mode -eq 'ClearHistorical') -or ($file.LastWriteTimeUtc -lt $cutoffUtc)
        if (-not $eligible) { continue }
        try {
            $length = [long]$file.Length
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $deletedFiles.Add($file.FullName) | Out-Null
            $reclaimedBytes += $length
        }
        catch { $failures.Add(('{0}: {1}' -f $file.FullName,$_.Exception.Message)) | Out-Null }
    }

    if ($Application -eq 'MainConsole') {
        $archivedBootstrapFiles = @(Get-ChildItem -LiteralPath $logDirectory -File -Filter 'QuestODMConsole-bootstrap.*.log' -ErrorAction SilentlyContinue)
        foreach ($file in $archivedBootstrapFiles) {
            $eligible = ($Mode -eq 'ClearHistorical') -or ($file.LastWriteTimeUtc -lt $cutoffUtc)
            if (-not $eligible) { continue }
            try {
                $length = [long]$file.Length
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $deletedFiles.Add($file.FullName) | Out-Null
                $reclaimedBytes += $length
            }
            catch { $failures.Add(('{0}: {1}' -f $file.FullName,$_.Exception.Message)) | Out-Null }
        }

        $bootstrapPath = Join-Path $logDirectory 'QuestODMConsole-bootstrap.log'
        try {
            $bootstrapResult = Invoke-QOdmBootstrapLogMaintenance -Path $bootstrapPath -Mode $Mode -CutoffUtc $cutoffUtc
            if ([bool]$bootstrapResult.Changed) {
                $resetFiles.Add($bootstrapPath) | Out-Null
                $reclaimedBytes += [long]$bootstrapResult.ReclaimedBytes
            }
        }
        catch { $failures.Add(('{0}: {1}' -f $bootstrapPath,$_.Exception.Message)) | Out-Null }

        $historyPath = Join-Path $logDirectory 'OperationHistory.jsonl'
        try {
            $historyResult = Invoke-QOdmOperationHistoryMaintenance -Path $historyPath -Mode $Mode -CutoffUtc $cutoffUtc
            $prunedHistory = [int]$historyResult.PrunedRecords
            if ([bool]$historyResult.Changed) {
                $resetFiles.Add($historyPath) | Out-Null
                $reclaimedBytes += [long]$historyResult.ReclaimedBytes
            }
        }
        catch { $failures.Add(('{0}: {1}' -f $historyPath,$_.Exception.Message)) | Out-Null }
    }

    $summary = '{0} historical log file(s) removed; {1} operation-history record(s) pruned; {2} active log store(s) reset or trimmed; {3} reclaimed; {4} failure(s).' -f $deletedFiles.Count,$prunedHistory,$resetFiles.Count,(Format-QOdmLogByteSize -Bytes $reclaimedBytes),$failures.Count

    return [pscustomobject]@{
        Application=$Application
        Mode=$Mode
        RetentionDays=$days
        CutoffUtc=$cutoffUtc.ToString('o')
        DeletedFiles=$deletedFiles.ToArray()
        DeletedFileCount=$deletedFiles.Count
        ResetFiles=$resetFiles.ToArray()
        ResetFileCount=$resetFiles.Count
        PrunedHistoryRecords=$prunedHistory
        ReclaimedBytes=$reclaimedBytes
        ReclaimedDisplay=Format-QOdmLogByteSize -Bytes $reclaimedBytes
        Failures=$failures.ToArray()
        FailureCount=$failures.Count
        Summary=$summary
    }
}
