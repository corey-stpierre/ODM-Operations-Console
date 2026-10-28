<#
Purpose:
  Quest ODM / Intune preflight cleanup.

Action:
  Removes only this registry VALUE:
    HKLM\SOFTWARE\Microsoft\Enrollments\MmpcEnrollmentFlag

Important:
  Does NOT delete HKLM\SOFTWARE\Microsoft\Enrollments.
  Does NOT run dsregcmd /leave.
  Does NOT reboot the machine.
#>

$ErrorActionPreference = 'Stop'

$SubKeyName = 'SOFTWARE\Microsoft\Enrollments'
$ValueName  = 'MmpcEnrollmentFlag'
$LogDir     = 'C:\ProgramData\ODM-Preflight'
$LogFile    = Join-Path $LogDir 'Remove-MmpcEnrollmentFlag.log'

New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

function Write-ODMLog {
    param([string]$Message)

    $Line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $Message
    Add-Content -Path $LogFile -Value $Line
    Write-Output $Line
}

try {
    Write-ODMLog "Starting ODM preflight cleanup. Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    # Use the 64-bit registry view explicitly so the script does not accidentally
    # inspect HKLM\SOFTWARE\WOW6432Node when launched from a 32-bit agent context.
    $RegistryView = if ([Environment]::Is64BitOperatingSystem) {
        [Microsoft.Win32.RegistryView]::Registry64
    }
    else {
        [Microsoft.Win32.RegistryView]::Default
    }

    $BaseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        $RegistryView
    )

    $EnrollmentsKey = $BaseKey.OpenSubKey($SubKeyName, $true)

    if ($null -eq $EnrollmentsKey) {
        Write-ODMLog "Registry key HKLM:\$SubKeyName does not exist. Nothing to remove."
        exit 0
    }

    $ExistingValue = $EnrollmentsKey.GetValue($ValueName, $null)

    if ($null -eq $ExistingValue) {
        Write-ODMLog "Registry value $ValueName is not present. Device is already compliant."
        $EnrollmentsKey.Close()
        $BaseKey.Close()
        exit 0
    }

    Write-ODMLog "Found $ValueName with value: $ExistingValue. Removing value."

    $EnrollmentsKey.DeleteValue($ValueName, $false)

    $VerifyValue = $EnrollmentsKey.GetValue($ValueName, $null)

    if ($null -ne $VerifyValue) {
        Write-ODMLog "ERROR: $ValueName still exists after attempted removal."
        $EnrollmentsKey.Close()
        $BaseKey.Close()
        exit 1
    }

    $EnrollmentsKey.Close()
    $BaseKey.Close()

    Write-ODMLog "Successfully removed $ValueName."
    exit 0
}
catch {
    Write-ODMLog "ERROR: $($_.Exception.Message)"
    exit 1
}