Set-StrictMode -Version 2.0

function Get-QOdmMmpcEnrollmentFlagState {
    [CmdletBinding()]
    param()

    $resultBase = [ordered]@{
        Supported = $false
        Path      = 'HKLM\SOFTWARE\Microsoft\Enrollments'
        ValueName = 'MmpcEnrollmentFlag'
        Exists    = $false
        Value     = $null
        Message   = $null
    }

    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
        $resultBase.Message = 'The check requires a 64-bit Windows operating system.'
        return [pscustomobject]$resultBase
    }

    $base = $null
    $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        if ($null -eq $base) { throw 'The 64-bit HKLM registry hive could not be opened.' }

        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Enrollments', $false)
        $resultBase.Supported = $true
        if ($null -eq $key) {
            $resultBase.Message = 'The registry key does not exist.'
            return [pscustomobject]$resultBase
        }

        $names = @($key.GetValueNames())
        $exists = ($names -contains 'MmpcEnrollmentFlag')
        $resultBase.Exists = $exists
        if ($exists) {
            $resultBase.Value = $key.GetValue('MmpcEnrollmentFlag', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $resultBase.Message = 'The value exists.'
        }
        else {
            $resultBase.Message = 'The value is not present.'
        }
        return [pscustomobject]$resultBase
    }
    catch {
        $resultBase.Message = $_.Exception.Message
        return [pscustomobject]$resultBase
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Remove-QOdmMmpcEnrollmentFlag {
    [CmdletBinding()]
    param([AllowNull()][string]$LogPath = $null)

    Set-QOdmOperationPhase -Phase 'Checking MMPC enrollment flag'
    $before = Get-QOdmMmpcEnrollmentFlagState
    $supported = [bool](Get-QOdmProperty -InputObject $before -Names @('Supported') -Default $false)
    $beforeMessage = [string](Get-QOdmProperty -InputObject $before -Names @('Message'))
    if (-not $supported) {
        if ([string]::IsNullOrWhiteSpace($beforeMessage)) { $beforeMessage = 'The MMPC enrollment-flag operation is not supported in this environment.' }
        throw $beforeMessage
    }

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = Join-Path -Path (Get-QOdmDefaultLogDirectory) -ChildPath 'Remove-MmpcEnrollmentFlag.log'
    }
    $directory = Split-Path -Parent $LogPath
    if ([string]::IsNullOrWhiteSpace($directory) -or -not (Test-QOdmDirectoryWritable -Path $directory -Create $true)) {
        throw "The preflight log directory is unavailable or not writable: $directory"
    }

    $beforeExists = [bool](Get-QOdmProperty -InputObject $before -Names @('Exists') -Default $false)
    if (-not $beforeExists) {
        $line = '{0} MmpcEnrollmentFlag was not present; no change required.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        return [pscustomobject]@{
            Before=$before; After=$before; Changed=$false; Verified=$true; LogPath=$LogPath; Message='No change was required.'
        }
    }

    Set-QOdmOperationPhase -Phase 'Removing MMPC enrollment flag'
    $base = $null
    $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        if ($null -eq $base) { throw 'The 64-bit HKLM registry hive could not be opened.' }
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Enrollments', $true)
        if ($null -eq $key) { throw 'Unable to open HKLM\SOFTWARE\Microsoft\Enrollments for write access. Run the console elevated.' }
        $key.DeleteValue('MmpcEnrollmentFlag', $false)
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }

    Set-QOdmOperationPhase -Phase 'Verifying MMPC enrollment flag removal'
    $after = Get-QOdmMmpcEnrollmentFlagState
    $afterExists = [bool](Get-QOdmProperty -InputObject $after -Names @('Exists') -Default $false)
    $verified = -not $afterExists
    $line = '{0} Removed MmpcEnrollmentFlag. PreviousValue={1}; ExistsAfter={2}; Verified={3}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `
        (Get-QOdmProperty -InputObject $before -Names @('Value')), `
        $afterExists, `
        $verified
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop

    [pscustomobject]@{
        Before=$before; After=$after; Changed=$verified; Verified=$verified; LogPath=$LogPath
        Message=if ($verified) { 'MmpcEnrollmentFlag was removed and verified absent.' } else { 'The removal command completed, but the value is still present.' }
    }
}

function Test-QOdmProcessIsElevated {
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') { return $false }
    $identity = $null
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $identity) { return $false }
        $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
        return [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
    finally { if ($null -ne $identity) { $identity.Dispose() } }
}

function ConvertTo-QOdmVersionValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    try { return [version]([string]$Value) } catch { return $null }
}

function Get-QOdmApiModuleStatus {
    [CmdletBinding()]
    param([bool]$CheckOnline = $false)

    Set-QOdmOperationPhase -Phase $(if ($CheckOnline) { 'Checking installed, validated, and PowerShell Gallery OdmApi versions' } else { 'Checking installed and validated OdmApi versions' })
    $installed = ConvertTo-QOdmObjectArray -InputObject (Get-Module -ListAvailable -Name 'OdmApi' -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
    $latestInstalled = if ($installed.Count -gt 0) { $installed[0] } else { $null }
    $loaded = Get-QOdmLoadedApiModule
    $installedVersion = if ($null -ne $latestInstalled) { ConvertTo-QOdmVersionValue -Value $latestInstalled.Version } else { $null }
    $loadedVersion = if ($null -ne $loaded) { ConvertTo-QOdmVersionValue -Value $loaded.Version } else { $null }
    $latestOnlineVersion = $null
    $latestOnlineSource = $null
    $onlineSucceeded = $false
    $onlineErrors = [System.Collections.Generic.List[string]]::new()

    $powerShellGetAvailable = [bool](Get-Command -Name 'Find-Module' -ErrorAction SilentlyContinue)
    $installModuleAvailable = [bool](Get-Command -Name 'Install-Module' -ErrorAction SilentlyContinue)
    $psResourceGetAvailable = [bool](Get-Command -Name 'Find-PSResource' -ErrorAction SilentlyContinue)
    $installPsResourceAvailable = [bool](Get-Command -Name 'Install-PSResource' -ErrorAction SilentlyContinue)

    $availableCommandMap = @{}
    foreach ($moduleCandidate in $installed) {
        $exportedCommands = Get-QOdmProperty -InputObject $moduleCandidate -Names @('ExportedCommands')
        if ($exportedCommands -is [System.Collections.IDictionary]) {
            foreach ($exportedName in (ConvertTo-QOdmObjectArray -InputObject $exportedCommands.Keys)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$exportedName)) { $availableCommandMap[[string]$exportedName] = $true }
            }
        }
    }
    if ($null -ne $loaded) {
        foreach ($loadedCommand in (ConvertTo-QOdmObjectArray -InputObject (Get-Command -Module 'OdmApi' -ErrorAction SilentlyContinue))) {
            $loadedCommandName = [string](Get-QOdmProperty -InputObject $loadedCommand -Names @('Name'))
            if (-not [string]::IsNullOrWhiteSpace($loadedCommandName)) { $availableCommandMap[$loadedCommandName] = $true }
        }
    }

    if ($CheckOnline) {
        $originalProtocol = $null
        try {
            try {
                $originalProtocol = [Net.ServicePointManager]::SecurityProtocol
                [Net.ServicePointManager]::SecurityProtocol = $originalProtocol -bor [Net.SecurityProtocolType]::Tls12
            }
            catch { }

            if ($powerShellGetAvailable) {
                try {
                    $found = Find-Module -Name 'OdmApi' -Repository 'PSGallery' -ErrorAction Stop
                    $candidate = ConvertTo-QOdmObjectArray -InputObject $found | Sort-Object Version -Descending | Select-Object -First 1
                    if ($null -ne $candidate) {
                        $latestOnlineVersion = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $candidate -Names @('Version'))
                        if ($null -ne $latestOnlineVersion) { $latestOnlineSource = 'PowerShellGet/PSGallery'; $onlineSucceeded = $true }
                    }
                    if (-not $onlineSucceeded) { throw 'Find-Module returned no usable OdmApi version.' }
                }
                catch { $onlineErrors.Add(('PowerShellGet: {0}' -f $_.Exception.Message)) | Out-Null }
            }

            if (-not $onlineSucceeded -and $psResourceGetAvailable) {
                try {
                    $found = Find-PSResource -Name 'OdmApi' -Repository 'PSGallery' -ErrorAction Stop
                    $candidate = ConvertTo-QOdmObjectArray -InputObject $found | Sort-Object Version -Descending | Select-Object -First 1
                    if ($null -ne $candidate) {
                        $latestOnlineVersion = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $candidate -Names @('Version'))
                        if ($null -ne $latestOnlineVersion) { $latestOnlineSource = 'PSResourceGet/PSGallery'; $onlineSucceeded = $true }
                    }
                    if (-not $onlineSucceeded) { throw 'Find-PSResource returned no usable OdmApi version.' }
                }
                catch { $onlineErrors.Add(('PSResourceGet: {0}' -f $_.Exception.Message)) | Out-Null }
            }

            if (-not $powerShellGetAvailable -and -not $psResourceGetAvailable) {
                $onlineErrors.Add('Neither Find-Module nor Find-PSResource is available. Install PowerShellGet or Microsoft.PowerShell.PSResourceGet.') | Out-Null
            }
        }
        finally {
            if ($null -ne $originalProtocol) { try { [Net.ServicePointManager]::SecurityProtocol = $originalProtocol } catch { } }
        }
    }

    $onlineError = if ($onlineErrors.Count -gt 0) { $onlineErrors.ToArray() -join ' | ' } else { $null }
    $updateAvailable = ($onlineSucceeded -and $null -ne $latestOnlineVersion -and ($null -eq $installedVersion -or $installedVersion -lt $latestOnlineVersion))
    $canInstall = ($installModuleAvailable -or $installPsResourceAvailable)
    $baseStatus = [pscustomobject]@{
        ModuleName='OdmApi'
        Installed=($null -ne $installedVersion)
        InstalledVersion=$installedVersion
        InstalledVersionText=if ($null -ne $installedVersion) { [string]$installedVersion } else { $null }
        InstalledPath=if ($null -ne $latestInstalled) { [string]$latestInstalled.Path } else { $null }
        InstalledVersions=ConvertTo-QOdmObjectArray -InputObject ($installed | ForEach-Object { [string]$_.Version } | Select-Object -Unique)
        Loaded=($null -ne $loaded)
        LoadedVersion=$loadedVersion
        LoadedVersionText=if ($null -ne $loadedVersion) { [string]$loadedVersion } else { $null }
        LoadedPath=if ($null -ne $loaded) { [string]$loaded.Path } else { $null }
        AvailableCommandNames=ConvertTo-QOdmObjectArray -InputObject ($availableCommandMap.Keys | Sort-Object)
        OnlineChecked=$CheckOnline
        OnlineCheckSucceeded=$onlineSucceeded
        OnlineError=$onlineError
        OnlineProviderErrors=$onlineErrors.ToArray()
        LatestOnlineVersion=$latestOnlineVersion
        LatestOnlineVersionText=if ($null -ne $latestOnlineVersion) { [string]$latestOnlineVersion } else { $null }
        LatestOnlineSource=$latestOnlineSource
        UpdateAvailable=$updateAvailable
        CanInstall=$canInstall
        PowerShellGetAvailable=$powerShellGetAvailable
        InstallModuleAvailable=$installModuleAvailable
        PSResourceGetAvailable=$psResourceGetAvailable
        InstallPSResourceAvailable=$installPsResourceAvailable
    }

    $compatibility = Get-QOdmCompatibilityAssessment -ModuleStatus $baseStatus -CheckOnline $CheckOnline
    $missingFeatureCommands = [System.Collections.Generic.List[string]]::new()
    foreach ($feature in (ConvertTo-QOdmObjectArray -InputObject $compatibility.FeatureAssessments)) {
        foreach ($missingCommand in (ConvertTo-QOdmObjectArray -InputObject $feature.MissingCommands)) {
            if (-not $missingFeatureCommands.Contains([string]$missingCommand)) { $missingFeatureCommands.Add([string]$missingCommand) | Out-Null }
        }
    }
    $featureCompatible = -not [bool]$compatibility.Blocking
    $updateRecommended = ($updateAvailable -or $compatibility.CompatibilityStatus -in @('NOT_INSTALLED','BELOW_MINIMUM') -or -not $featureCompatible)
    $recommendedAction = if ($null -eq $installedVersion) { 'InstallValidated' } elseif ($compatibility.CompatibilityStatus -ne 'VALIDATED' -or -not $featureCompatible) { 'InstallValidated' } elseif ($updateAvailable) { 'ReviewLatest' } else { 'None' }
    $statusText = $compatibility.Details
    if ($CheckOnline -and $onlineSucceeded -and $null -ne $latestOnlineVersion) {
        $statusText += " Latest available: $latestOnlineVersion."
    }
    elseif ($CheckOnline -and -not $onlineSucceeded -and -not [string]::IsNullOrWhiteSpace($onlineError)) {
        $statusText += " Online lookup failed: $onlineError"
    }

    Add-Member -InputObject $baseStatus -NotePropertyName Compatibility -NotePropertyValue $compatibility -Force
    Add-Member -InputObject $baseStatus -NotePropertyName MinimumVersionText -NotePropertyValue ([string]$compatibility.MinimumVersion) -Force
    Add-Member -InputObject $baseStatus -NotePropertyName ValidatedVersions -NotePropertyValue (ConvertTo-QOdmObjectArray -InputObject $compatibility.ValidatedVersions) -Force
    Add-Member -InputObject $baseStatus -NotePropertyName PreferredValidatedVersion -NotePropertyValue ([string]$compatibility.PreferredValidatedVersion) -Force
    Add-Member -InputObject $baseStatus -NotePropertyName CompatibilityStatus -NotePropertyValue ([string]$compatibility.CompatibilityStatus) -Force
    Add-Member -InputObject $baseStatus -NotePropertyName CompatibilitySeverity -NotePropertyValue ([string]$compatibility.Severity) -Force
    Add-Member -InputObject $baseStatus -NotePropertyName ValidatedInstalled -NotePropertyValue ([bool]$compatibility.ValidatedInstalled) -Force
    Add-Member -InputObject $baseStatus -NotePropertyName CoreCommandsAvailable -NotePropertyValue ([bool]$compatibility.CoreCommandsAvailable) -Force
    Add-Member -InputObject $baseStatus -NotePropertyName FeatureCompatibilityKnown -NotePropertyValue ($availableCommandMap.Count -gt 0) -Force
    Add-Member -InputObject $baseStatus -NotePropertyName FeatureCompatible -NotePropertyValue $featureCompatible -Force
    Add-Member -InputObject $baseStatus -NotePropertyName MissingFeatureCommands -NotePropertyValue $missingFeatureCommands.ToArray() -Force
    Add-Member -InputObject $baseStatus -NotePropertyName UpdateRecommended -NotePropertyValue $updateRecommended -Force
    Add-Member -InputObject $baseStatus -NotePropertyName RecommendedAction -NotePropertyValue $recommendedAction -Force
    Add-Member -InputObject $baseStatus -NotePropertyName StatusText -NotePropertyValue $statusText -Force
    return $baseStatus
}

function Initialize-QOdmPowerShellGalleryForInstall {
    [CmdletBinding()]
    param()

    $result = [ordered]@{ RepositoryRegistered=$false; PreviousPolicy=$null; PolicyChanged=$false; NuGetReady=$false }
    if (Get-Command -Name 'Get-PSRepository' -ErrorAction SilentlyContinue) {
        $repository = Get-PSRepository -Name 'PSGallery' -ErrorAction SilentlyContinue
        if ($null -eq $repository -and (Get-Command -Name 'Register-PSRepository' -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction Stop
            $repository = Get-PSRepository -Name 'PSGallery' -ErrorAction Stop
        }
        if ($null -ne $repository) {
            $result.RepositoryRegistered = $true
            $result.PreviousPolicy = [string](Get-QOdmProperty -InputObject $repository -Names @('InstallationPolicy'))
            if (-not [string]::Equals($result.PreviousPolicy, 'Trusted', [StringComparison]::OrdinalIgnoreCase) -and (Get-Command -Name 'Set-PSRepository' -ErrorAction SilentlyContinue)) {
                Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction Stop
                $result.PolicyChanged = $true
            }
        }
    }

    if (Get-Command -Name 'Get-PackageProvider' -ErrorAction SilentlyContinue) {
        $nuget = Get-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue
        if ($null -eq $nuget -and (Get-Command -Name 'Install-PackageProvider' -ErrorAction SilentlyContinue)) {
            $command = Get-Command -Name 'Install-PackageProvider' -ErrorAction Stop
            $parameters = @{ Name='NuGet'; Force=$true; ErrorAction='Stop' }
            if ($command.Parameters.ContainsKey('MinimumVersion')) { $parameters.MinimumVersion = '2.8.5.201' }
            if ($command.Parameters.ContainsKey('Scope')) { $parameters.Scope = 'CurrentUser' }
            Install-PackageProvider @parameters | Out-Null
            $nuget = Get-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue
        }
        $result.NuGetReady = ($null -ne $nuget)
    }
    return [pscustomobject]$result
}

function Restore-QOdmPowerShellGalleryPolicy {
    [CmdletBinding()]
    param([AllowNull()][object]$Initialization)

    if ($null -eq $Initialization) { return }
    if ([bool](Get-QOdmProperty -InputObject $Initialization -Names @('PolicyChanged') -Default $false)) {
        $previous = [string](Get-QOdmProperty -InputObject $Initialization -Names @('PreviousPolicy'))
        if (-not [string]::IsNullOrWhiteSpace($previous) -and (Get-Command -Name 'Set-PSRepository' -ErrorAction SilentlyContinue)) {
            try { Set-PSRepository -Name 'PSGallery' -InstallationPolicy $previous -ErrorAction Stop } catch { Add-QOdmWarning -Message ("PSGallery policy could not be restored: {0}" -f $_.Exception.Message) }
        }
    }
}

function Install-QOdmApiModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install','Update')][string]$Action,
        [ValidateSet('Validated','Latest')][string]$Target = 'Validated'
    )

    Set-QOdmOperationPhase -Phase ("Preparing to {0} OdmApi ({1} target)" -f $Action.ToLowerInvariant(),$Target.ToLowerInvariant())
    $before = Get-QOdmApiModuleStatus -CheckOnline $true
    if (-not [bool]$before.CanInstall) { throw 'Neither Install-Module nor Install-PSResource is available. Install PowerShellGet or Microsoft.PowerShell.PSResourceGet first.' }

    $targetVersion = $null
    if ($Target -eq 'Validated') {
        $targetVersion = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $before -Names @('PreferredValidatedVersion'))
        if ($null -eq $targetVersion) { throw 'The console compatibility policy does not contain a usable validated OdmApi version.' }
    }
    else {
        $targetVersion = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $before -Names @('LatestOnlineVersionText'))
        if ($null -eq $targetVersion) { throw 'The latest OdmApi version could not be determined from PowerShell Gallery. Use Install validated version or retry the online check.' }
    }

    $installedVersion = ConvertTo-QOdmVersionValue -Value (Get-QOdmProperty -InputObject $before -Names @('InstalledVersionText'))
    if ($null -ne $installedVersion -and $installedVersion -eq $targetVersion -and [bool](Get-QOdmProperty -InputObject $before -Names @('FeatureCompatible') -Default $false)) {
        return [pscustomobject]@{Action=$Action;Target=$Target;TargetVersion=[string]$targetVersion;Changed=$false;RequiresWorkerRestart=$false;Before=$before;After=$before;Provider=$null;ProviderErrors=@();Status='ALREADY_TARGET';Details="OdmApi $targetVersion is already installed and compatible."}
    }

    $originalProtocol = $null
    $provider = $null
    $providerErrors = [System.Collections.Generic.List[string]]::new()
    $installedSuccessfully = $false
    try {
        try {
            $originalProtocol = [Net.ServicePointManager]::SecurityProtocol
            [Net.ServicePointManager]::SecurityProtocol = $originalProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        catch { }

        if (Get-Command -Name 'Install-Module' -ErrorAction SilentlyContinue) {
            $galleryInitialization = $null
            try {
                $galleryInitialization = Initialize-QOdmPowerShellGalleryForInstall
                $command = Get-Command -Name 'Install-Module' -ErrorAction Stop
                $parameters = @{ Name='OdmApi'; ErrorAction='Stop' }
                if ($command.Parameters.ContainsKey('Scope')) { $parameters.Scope = 'CurrentUser' }
                if ($command.Parameters.ContainsKey('Repository')) { $parameters.Repository = 'PSGallery' }
                if ($command.Parameters.ContainsKey('Force')) { $parameters.Force = $true }
                if ($command.Parameters.ContainsKey('AllowClobber')) { $parameters.AllowClobber = $true }
                if ($command.Parameters.ContainsKey('AcceptLicense')) { $parameters.AcceptLicense = $true }
                if ($command.Parameters.ContainsKey('RequiredVersion')) { $parameters.RequiredVersion = [string]$targetVersion }
                Install-Module @parameters
                $provider = 'PowerShellGet'
                $installedSuccessfully = $true
            }
            catch { $providerErrors.Add(('PowerShellGet: {0}' -f $_.Exception.Message)) | Out-Null }
            finally { Restore-QOdmPowerShellGalleryPolicy -Initialization $galleryInitialization }
        }

        if (-not $installedSuccessfully -and (Get-Command -Name 'Install-PSResource' -ErrorAction SilentlyContinue)) {
            try {
                $command = Get-Command -Name 'Install-PSResource' -ErrorAction Stop
                $parameters = @{ Name='OdmApi'; ErrorAction='Stop' }
                if ($command.Parameters.ContainsKey('Scope')) { $parameters.Scope = 'CurrentUser' }
                if ($command.Parameters.ContainsKey('Repository')) { $parameters.Repository = 'PSGallery' }
                if ($command.Parameters.ContainsKey('TrustRepository')) { $parameters.TrustRepository = $true }
                if ($command.Parameters.ContainsKey('Quiet')) { $parameters.Quiet = $true }
                if ($command.Parameters.ContainsKey('Reinstall')) { $parameters.Reinstall = $true }
                if ($command.Parameters.ContainsKey('Version')) { $parameters.Version = [string]$targetVersion }
                Install-PSResource @parameters
                $provider = 'PSResourceGet'
                $installedSuccessfully = $true
            }
            catch { $providerErrors.Add(('PSResourceGet: {0}' -f $_.Exception.Message)) | Out-Null }
        }

        if (-not $installedSuccessfully) {
            $details = if ($providerErrors.Count -gt 0) { $providerErrors.ToArray() -join ' | ' } else { 'No supported installer completed successfully.' }
            throw "OdmApi installation failed. $details"
        }
    }
    finally {
        if ($null -ne $originalProtocol) { try { [Net.ServicePointManager]::SecurityProtocol = $originalProtocol } catch { } }
    }

    Set-QOdmOperationPhase -Phase 'Verifying OdmApi installation'
    $after = Get-QOdmApiModuleStatus -CheckOnline $true
    $allInstalledVersions = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $after -Names @('InstalledVersions') -Default @())
    if (-not ($allInstalledVersions -contains [string]$targetVersion)) {
        throw "The installer completed, but OdmApi $targetVersion is not visible in the current user module path."
    }
    $changed = ($null -eq $installedVersion -or $installedVersion -ne $targetVersion)
    Enable-QOdmSafeMode -Reason 'Safe Mode reset because the OdmApi module was installed or updated.' | Out-Null
    [pscustomobject]@{
        Action=$Action;Target=$Target;TargetVersion=[string]$targetVersion;Changed=$changed;RequiresWorkerRestart=$true;Before=$before;After=$after;Provider=$provider
        ProviderErrors=$providerErrors.ToArray();Status=if ($changed) {'INSTALLED_OR_UPDATED'} else {'INSTALLED_VERIFIED'}
        Details=("OdmApi {0} was installed for the current user. Restart the console worker and reconnect before using Quest operations." -f $targetVersion)
    }
}

function Get-QOdmEnvironmentInfo {
    [CmdletBinding()]
    param()

    $moduleStatus = Get-QOdmApiModuleStatus -CheckOnline $false
    $modules = ConvertTo-QOdmObjectArray -InputObject (Get-Module -ListAvailable -Name 'OdmApi' | Sort-Object Version -Descending)
    $latest = $modules | Select-Object -First 1
    $loaded = Get-QOdmLoadedApiModule
    $apiSurface = Get-QOdmApiSurfaceReport
    $runtimeProbe = if ($null -ne $loaded) {
        $stateProbe = Get-QOdmProperty -InputObject $script:QOdmState -Names @('ModuleRuntimeProbe')
        if ($null -ne $stateProbe) { $stateProbe } else { Test-QOdmApiRuntimeInitialization -Module $loaded }
    } else { $null }
    $preload = Get-QOdmWorkerModulePreload
    $dataRoot = Get-QOdmDefaultDataRoot
    $reportDirectory = Get-QOdmOutputDirectory -OutputDirectory $null
    $logDirectory = Get-QOdmDefaultLogDirectory
    $logDirectoryWritable = Test-QOdmDirectoryWritable -Path $logDirectory -Create $true
    $processPath = $null
    try { $processPath = [string](Get-QOdmProperty -InputObject (Get-Process -Id $PID -ErrorAction Stop) -Names @('Path')) } catch { }

    [pscustomobject]@{
        ComputerName               = $env:COMPUTERNAME
        UserName                   = [Environment]::UserName
        ProcessPath                = $processPath
        ProcessId                  = $PID
        IsElevated                 = Test-QOdmProcessIsElevated
        Is64BitProcess             = [Environment]::Is64BitProcess
        Is64BitOperatingSystem     = [Environment]::Is64BitOperatingSystem
        PowerShellVersion          = [string]$PSVersionTable.PSVersion
        PowerShellEdition          = [string]$PSVersionTable.PSEdition
        ApartmentState             = [Threading.Thread]::CurrentThread.ApartmentState.ToString()
        DataRoot                   = $dataRoot
        DefaultReportDirectory     = $reportDirectory
        DefaultLogDirectory        = $logDirectory
        DefaultLogWritable         = $logDirectoryWritable
        OdmApiInstalled            = ($modules.Count -gt 0 -or $null -ne $loaded)
        OdmApiLoaded               = ($null -ne $loaded)
        OdmApiVersion              = if ($null -ne $loaded) { [string]$loaded.Version } elseif ($null -ne $latest) { [string]$latest.Version } else { $null }
        OdmApiPath                 = if ($null -ne $loaded) { [string]$loaded.Path } elseif ($null -ne $latest) { [string]$latest.Path } else { $null }
        OdmApiModuleStatus         = $moduleStatus
        OdmApiPreload              = $preload
        OdmApiPreloadStatus        = [string](Get-QOdmProperty -InputObject $preload -Names @('Status') -Default 'NOT_RUN')
        OdmApiRuntimeProbe         = $runtimeProbe
        OdmApiRuntimeProbeStatus   = [string](Get-QOdmProperty -InputObject $runtimeProbe -Names @('Status') -Default 'NOT_RUN')
        OdmApiScopeValidated       = [bool](Get-QOdmProperty -InputObject $runtimeProbe -Names @('Passed') -Default $false)
        ApiSurface                 = $apiSurface
        BuildInfo                  = Get-QOdmBuildInfo
        Compatibility              = Get-QOdmCompatibilityAssessment -ModuleStatus $moduleStatus
        SafeMode                   = Get-QOdmSafeModeState
        EngineState                = Get-QOdmContextState
    }
}
