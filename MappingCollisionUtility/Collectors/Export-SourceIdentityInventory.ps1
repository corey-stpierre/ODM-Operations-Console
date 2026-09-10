[CmdletBinding()]
param(
    [ValidateSet('Prompt','ActiveDirectory','EntraID')]
    [string]$DirectoryType = 'Prompt',

    [AllowEmptyString()]
    [string]$OutputPath = '',

    [AllowEmptyString()]
    [string]$Server = '',

    [AllowEmptyString()]
    [string]$SearchBase = '',

    [AllowEmptyString()]
    [string]$TenantId = '',

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$InstallMissingGraphModule
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$inventorySide = 'Source'
$collectorVersion = '1.0.0-preview.1'
$schemaVersion = '1.0'
$collectedAtUtc = [DateTime]::UtcNow.ToString('o')

function ConvertTo-CollectorArray {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    $result = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $InputObject) { return $result.ToArray() }
    $value = $InputObject
    try {
        if ($InputObject -is [System.Management.Automation.PSObject] -and $null -ne $InputObject.BaseObject) { $value = $InputObject.BaseObject }
    }
    catch { $value = $InputObject }
    if ($value -is [string] -or $value -is [System.Collections.IDictionary]) { $result.Add($InputObject) | Out-Null; return $result.ToArray() }
    if ($value -is [System.Collections.IEnumerable]) { foreach ($item in $value) { $result.Add($item) | Out-Null }; return $result.ToArray() }
    $result.Add($InputObject) | Out-Null
    return $result.ToArray()
}

function Get-CollectorProperty {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in $InputObject.Keys) {
                if ([string]::Equals([string]$key,$name,[StringComparison]::OrdinalIgnoreCase)) {
                    if ($null -ne $InputObject[$key]) { return $InputObject[$key] }
                }
            }
        }
        try {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
        }
        catch { }
    }
    return $Default
}

function Join-CollectorValues {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    $values = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($item in (ConvertTo-CollectorArray -InputObject $Value)) {
        if ($null -eq $item) { continue }
        $text = ([string]$item).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $key = $text.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $values.Add($text) | Out-Null }
    }
    return ($values.ToArray() -join '|')
}

function Get-CollectorPrimarySmtp {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ProxyAddresses,
        [AllowEmptyString()][string]$Mail
    )

    $proxies = @(ConvertTo-CollectorArray -InputObject $ProxyAddresses)
    $primary = @($proxies | Where-Object { [string]$_ -cmatch '^SMTP:' } | Select-Object -First 1)
    if ($primary.Count -gt 0) { return ([string]$primary[0]).Substring(([string]$primary[0]).IndexOf(':') + 1) }
    if (-not [string]::IsNullOrWhiteSpace($Mail)) { return $Mail.Trim() }
    return ''
}

function Convert-CollectorGuidToBase64 {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
    try { return [Convert]::ToBase64String(([Guid]$Value).ToByteArray()) }
    catch { return '' }
}

function Convert-CollectorBytesToGuid {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    try {
        $bytes = [byte[]]$Value
        if ($bytes.Length -ne 16) { return '' }
        return ([Guid]::new($bytes)).ToString('D')
    }
    catch { return '' }
}

function Convert-CollectorBytesToBase64 {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    try {
        $bytes = [byte[]]$Value
        if ($bytes.Length -eq 0) { return '' }
        return [Convert]::ToBase64String($bytes)
    }
    catch { return '' }
}

function Get-CollectorFileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Get-Command -Name Get-FileHash -ErrorAction SilentlyContinue) {
        return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Resolve-CollectorOutputPath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$RequestedPath,
        [Parameter(Mandatory = $true)][string]$Type
    )

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        $fileName = '{0}IdentityInventory_{1}_{2}.csv' -f $inventorySide,$Type,(Get-Date -Format 'yyyyMMdd-HHmmss')
        return Join-Path (Get-Location).Path $fileName
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($RequestedPath)
    if ([IO.Path]::GetExtension($expanded) -ne '.csv') {
        if (-not (Test-Path -LiteralPath $expanded)) { New-Item -Path $expanded -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        $fileName = '{0}IdentityInventory_{1}_{2}.csv' -f $inventorySide,$Type,(Get-Date -Format 'yyyyMMdd-HHmmss')
        return Join-Path $expanded $fileName
    }
    $parent = Split-Path -Parent $expanded
    if ([string]::IsNullOrWhiteSpace($parent)) { $parent = (Get-Location).Path; $expanded = Join-Path $parent $expanded }
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    return [IO.Path]::GetFullPath($expanded)
}

function Select-CollectorDirectoryType {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RequestedType)

    if ($RequestedType -ne 'Prompt') { return $RequestedType }
    Write-Host ''
    Write-Host "Quest ODM Mapping Collision Utility - $inventorySide collector" -ForegroundColor Cyan
    Write-Host 'Choose the directory to inventory:'
    Write-Host '  1. Active Directory Domain Services'
    Write-Host '  2. Microsoft Entra ID'
    do { $selection = Read-Host 'Enter 1 or 2' } until ($selection -in @('1','2'))
    if ($selection -eq '1') { return 'ActiveDirectory' }
    return 'EntraID'
}

function New-CollectorRow {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Values)

    return [pscustomobject][ordered]@{
        SchemaVersion                = $schemaVersion
        CollectorVersion             = $collectorVersion
        InventorySide                = $inventorySide
        DirectoryType                = [string](Get-CollectorProperty -InputObject $Values -Names @('DirectoryType') -Default '')
        EnvironmentName              = [string](Get-CollectorProperty -InputObject $Values -Names @('EnvironmentName') -Default '')
        TenantId                     = [string](Get-CollectorProperty -InputObject $Values -Names @('TenantId') -Default '')
        DomainName                   = [string](Get-CollectorProperty -InputObject $Values -Names @('DomainName') -Default '')
        CollectedAtUtc               = $collectedAtUtc
        ObjectType                   = [string](Get-CollectorProperty -InputObject $Values -Names @('ObjectType') -Default 'User')
        ObjectId                     = [string](Get-CollectorProperty -InputObject $Values -Names @('ObjectId') -Default '')
        ObjectGuid                   = [string](Get-CollectorProperty -InputObject $Values -Names @('ObjectGuid') -Default '')
        ObjectGuidBase64             = [string](Get-CollectorProperty -InputObject $Values -Names @('ObjectGuidBase64') -Default '')
        ConsistencyGuid              = [string](Get-CollectorProperty -InputObject $Values -Names @('ConsistencyGuid') -Default '')
        ConsistencyGuidBase64        = [string](Get-CollectorProperty -InputObject $Values -Names @('ConsistencyGuidBase64') -Default '')
        OnPremisesImmutableId        = [string](Get-CollectorProperty -InputObject $Values -Names @('OnPremisesImmutableId') -Default '')
        Sid                          = [string](Get-CollectorProperty -InputObject $Values -Names @('Sid') -Default '')
        OnPremisesSecurityIdentifier = [string](Get-CollectorProperty -InputObject $Values -Names @('OnPremisesSecurityIdentifier') -Default '')
        DistinguishedName            = [string](Get-CollectorProperty -InputObject $Values -Names @('DistinguishedName') -Default '')
        DisplayName                  = [string](Get-CollectorProperty -InputObject $Values -Names @('DisplayName') -Default '')
        UserPrincipalName            = [string](Get-CollectorProperty -InputObject $Values -Names @('UserPrincipalName') -Default '')
        SamAccountName               = [string](Get-CollectorProperty -InputObject $Values -Names @('SamAccountName') -Default '')
        Mail                         = [string](Get-CollectorProperty -InputObject $Values -Names @('Mail') -Default '')
        MailNickname                 = [string](Get-CollectorProperty -InputObject $Values -Names @('MailNickname') -Default '')
        PrimarySmtpAddress           = [string](Get-CollectorProperty -InputObject $Values -Names @('PrimarySmtpAddress') -Default '')
        ProxyAddresses               = [string](Get-CollectorProperty -InputObject $Values -Names @('ProxyAddresses') -Default '')
        OtherMails                   = [string](Get-CollectorProperty -InputObject $Values -Names @('OtherMails') -Default '')
        SignInNames                  = [string](Get-CollectorProperty -InputObject $Values -Names @('SignInNames') -Default '')
        TargetAddress                = [string](Get-CollectorProperty -InputObject $Values -Names @('TargetAddress') -Default '')
        EmployeeId                   = [string](Get-CollectorProperty -InputObject $Values -Names @('EmployeeId') -Default '')
        AccountEnabled               = [string](Get-CollectorProperty -InputObject $Values -Names @('AccountEnabled') -Default '')
        UserType                     = [string](Get-CollectorProperty -InputObject $Values -Names @('UserType') -Default '')
        IsGuest                      = [string](Get-CollectorProperty -InputObject $Values -Names @('IsGuest') -Default '')
        CreatedDateTime              = [string](Get-CollectorProperty -InputObject $Values -Names @('CreatedDateTime') -Default '')
    }
}

function Get-ActiveDirectoryInventory {
    [CmdletBinding()]
    param()

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw 'The ActiveDirectory PowerShell module is not installed. Install the Windows RSAT Active Directory module, then rerun this collector.'
    }
    Import-Module ActiveDirectory -ErrorAction Stop

    $domainParameters = @{}
    if (-not [string]::IsNullOrWhiteSpace($Server)) { $domainParameters.Server = $Server }
    if ($null -ne $Credential) { $domainParameters.Credential = $Credential }
    $domain = Get-ADDomain @domainParameters -ErrorAction Stop
    $environmentName = [string]$domain.Name
    $domainName = [string]$domain.DNSRoot

    $properties = @('DisplayName','UserPrincipalName','SamAccountName','mail','mailNickname','proxyAddresses','targetAddress','ObjectGUID','objectSid','mS-DS-ConsistencyGuid','employeeID','Enabled','DistinguishedName','CanonicalName','whenCreated')
    $parameters = @{ Filter='*'; Properties=$properties; ResultSetSize=$null }
    if (-not [string]::IsNullOrWhiteSpace($Server)) { $parameters.Server = $Server }
    if (-not [string]::IsNullOrWhiteSpace($SearchBase)) { $parameters.SearchBase = $SearchBase }
    if ($null -ne $Credential) { $parameters.Credential = $Credential }

    Write-Host "Collecting Active Directory users from $domainName..." -ForegroundColor Cyan
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($user in (Get-ADUser @parameters -ErrorAction Stop)) {
        $proxyAddresses = @(ConvertTo-CollectorArray -InputObject $user.proxyAddresses)
        $consistencyBytes = $user.'mS-DS-ConsistencyGuid'
        $guidText = if ($null -ne $user.ObjectGUID) { ([Guid]$user.ObjectGUID).ToString('D') } else { '' }
        $created = ''
        if ($null -ne $user.whenCreated) { try { $created = ([DateTime]$user.whenCreated).ToUniversalTime().ToString('o') } catch { $created = [string]$user.whenCreated } }
        $rows.Add((New-CollectorRow -Values @{
            DirectoryType='ActiveDirectory'; EnvironmentName=$environmentName; DomainName=$domainName; ObjectType='User';
            ObjectId=$guidText; ObjectGuid=$guidText; ObjectGuidBase64=(Convert-CollectorGuidToBase64 -Value $guidText);
            ConsistencyGuid=(Convert-CollectorBytesToGuid -Value $consistencyBytes); ConsistencyGuidBase64=(Convert-CollectorBytesToBase64 -Value $consistencyBytes);
            Sid=[string]$user.SID; DistinguishedName=[string]$user.DistinguishedName; DisplayName=[string]$user.DisplayName;
            UserPrincipalName=[string]$user.UserPrincipalName; SamAccountName=[string]$user.SamAccountName; Mail=[string]$user.mail; MailNickname=[string]$user.mailNickname;
            PrimarySmtpAddress=(Get-CollectorPrimarySmtp -ProxyAddresses $proxyAddresses -Mail ([string]$user.mail)); ProxyAddresses=(Join-CollectorValues -Value $proxyAddresses);
            TargetAddress=[string]$user.targetAddress; EmployeeId=[string]$user.employeeID; AccountEnabled=[string][bool]$user.Enabled; UserType='Member'; IsGuest='False'; CreatedDateTime=$created
        })) | Out-Null
    }
    return $rows.ToArray()
}

function Ensure-CollectorGraphModule {
    [CmdletBinding()]
    param()

    if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication) { return }
    $install = $InstallMissingGraphModule.IsPresent
    if (-not $install) {
        $answer = Read-Host 'Microsoft.Graph.Authentication is not installed. Install it for the current user now? [Y/N]'
        $install = ($answer -match '^(?i)y(?:es)?$')
    }
    if (-not $install) { throw 'Microsoft.Graph.Authentication is required for Entra ID collection.' }
    if (-not (Get-Command -Name Install-Module -ErrorAction SilentlyContinue)) { throw 'Install-Module is unavailable. Install PowerShellGet and Microsoft.Graph.Authentication manually.' }
    Write-Host 'Installing Microsoft.Graph.Authentication for the current user...' -ForegroundColor Cyan
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}

function Invoke-CollectorGraphPagedRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Uri)

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while (-not [string]::IsNullOrWhiteSpace($next)) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
        foreach ($item in (ConvertTo-CollectorArray -InputObject (Get-CollectorProperty -InputObject $response -Names @('value') -Default @()))) { $items.Add($item) | Out-Null }
        $next = [string](Get-CollectorProperty -InputObject $response -Names @('@odata.nextLink','odata.nextLink') -Default '')
    }
    return $items.ToArray()
}

function Get-EntraInventory {
    [CmdletBinding()]
    param()

    Ensure-CollectorGraphModule
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $connectParameters = @{ Scopes=@('Directory.Read.All','User.Read.All') }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $connectParameters.TenantId = $TenantId }
    $connectCommand = Get-Command -Name Connect-MgGraph -ErrorAction Stop
    if ($connectCommand.Parameters.ContainsKey('NoWelcome')) { $connectParameters.NoWelcome = $true }
    Write-Host 'Connecting to Microsoft Entra ID with interactive authentication...' -ForegroundColor Cyan
    Connect-MgGraph @connectParameters -ErrorAction Stop | Out-Null

    try {
        $context = Get-MgContext
        $effectiveTenantId = [string](Get-CollectorProperty -InputObject $context -Names @('TenantId') -Default $TenantId)
        $environmentName = $effectiveTenantId
        $domainName = ''
        try {
            $organizationResponse = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName,verifiedDomains' -OutputType PSObject -ErrorAction Stop
            $organization = @(ConvertTo-CollectorArray -InputObject (Get-CollectorProperty -InputObject $organizationResponse -Names @('value') -Default @())) | Select-Object -First 1
            if ($null -ne $organization) {
                $environmentName = [string](Get-CollectorProperty -InputObject $organization -Names @('displayName') -Default $effectiveTenantId)
                $verifiedDomains = @(ConvertTo-CollectorArray -InputObject (Get-CollectorProperty -InputObject $organization -Names @('verifiedDomains') -Default @()))
                $defaultDomain = @($verifiedDomains | Where-Object { [bool](Get-CollectorProperty -InputObject $_ -Names @('isDefault') -Default $false) } | Select-Object -First 1)
                if ($defaultDomain.Count -eq 0) { $defaultDomain = @($verifiedDomains | Select-Object -First 1) }
                if ($defaultDomain.Count -gt 0) { $domainName = [string](Get-CollectorProperty -InputObject $defaultDomain[0] -Names @('name') -Default '') }
            }
        }
        catch { Write-Warning "Organization metadata could not be read: $($_.Exception.Message)" }

        $select = 'id,displayName,userPrincipalName,mail,mailNickname,proxyAddresses,otherMails,identities,onPremisesSamAccountName,onPremisesSecurityIdentifier,onPremisesImmutableId,accountEnabled,userType,employeeId,createdDateTime,onPremisesDistinguishedName'
        $uri = "https://graph.microsoft.com/v1.0/users?`$select=$select&`$top=999"
        Write-Host "Collecting Entra ID users from $environmentName..." -ForegroundColor Cyan
        $users = @(Invoke-CollectorGraphPagedRequest -Uri $uri)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($user in $users) {
            $proxyAddresses = @(ConvertTo-CollectorArray -InputObject (Get-CollectorProperty -InputObject $user -Names @('proxyAddresses') -Default @()))
            $identities = @(ConvertTo-CollectorArray -InputObject (Get-CollectorProperty -InputObject $user -Names @('identities') -Default @()))
            $signInNames = @($identities | ForEach-Object { Get-CollectorProperty -InputObject $_ -Names @('issuerAssignedId') -Default '' } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $mail = [string](Get-CollectorProperty -InputObject $user -Names @('mail') -Default '')
            $userType = [string](Get-CollectorProperty -InputObject $user -Names @('userType') -Default '')
            $rows.Add((New-CollectorRow -Values @{
                DirectoryType='EntraID'; EnvironmentName=$environmentName; TenantId=$effectiveTenantId; DomainName=$domainName; ObjectType='User';
                ObjectId=[string](Get-CollectorProperty -InputObject $user -Names @('id') -Default ''); OnPremisesImmutableId=[string](Get-CollectorProperty -InputObject $user -Names @('onPremisesImmutableId') -Default '');
                OnPremisesSecurityIdentifier=[string](Get-CollectorProperty -InputObject $user -Names @('onPremisesSecurityIdentifier') -Default ''); DistinguishedName=[string](Get-CollectorProperty -InputObject $user -Names @('onPremisesDistinguishedName') -Default '');
                DisplayName=[string](Get-CollectorProperty -InputObject $user -Names @('displayName') -Default ''); UserPrincipalName=[string](Get-CollectorProperty -InputObject $user -Names @('userPrincipalName') -Default '');
                SamAccountName=[string](Get-CollectorProperty -InputObject $user -Names @('onPremisesSamAccountName') -Default ''); Mail=$mail; MailNickname=[string](Get-CollectorProperty -InputObject $user -Names @('mailNickname') -Default '');
                PrimarySmtpAddress=(Get-CollectorPrimarySmtp -ProxyAddresses $proxyAddresses -Mail $mail); ProxyAddresses=(Join-CollectorValues -Value $proxyAddresses);
                OtherMails=(Join-CollectorValues -Value (Get-CollectorProperty -InputObject $user -Names @('otherMails') -Default @())); SignInNames=(Join-CollectorValues -Value $signInNames);
                EmployeeId=[string](Get-CollectorProperty -InputObject $user -Names @('employeeId') -Default ''); AccountEnabled=[string](Get-CollectorProperty -InputObject $user -Names @('accountEnabled') -Default '');
                UserType=$userType; IsGuest=[string]([string]::Equals($userType,'Guest',[StringComparison]::OrdinalIgnoreCase)); CreatedDateTime=[string](Get-CollectorProperty -InputObject $user -Names @('createdDateTime') -Default '')
            })) | Out-Null
        }
        return $rows.ToArray()
    }
    finally {
        if (Get-Command -Name Disconnect-MgGraph -ErrorAction SilentlyContinue) {
            try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }
}

if ($env:OS -ne 'Windows_NT') { throw 'This collector is intended for Windows PowerShell or PowerShell 7 on Windows.' }
$selectedType = Select-CollectorDirectoryType -RequestedType $DirectoryType
$resolvedOutputPath = Resolve-CollectorOutputPath -RequestedPath $OutputPath -Type $selectedType
$rows = if ($selectedType -eq 'ActiveDirectory') { @(Get-ActiveDirectoryInventory) } else { @(Get-EntraInventory) }
if ($rows.Count -eq 0) { throw "No $selectedType users were returned. No inventory file was created." }
$rows | Export-Csv -LiteralPath $resolvedOutputPath -NoTypeInformation -Encoding UTF8 -Force

$hash = Get-CollectorFileHash -Path $resolvedOutputPath
$manifestPath = [IO.Path]::ChangeExtension($resolvedOutputPath,'.manifest.json')
$manifest = [ordered]@{
    Product='Quest ODM Mapping Collision Utility Collector'
    CollectorVersion=$collectorVersion
    SchemaVersion=$schemaVersion
    InventorySide=$inventorySide
    DirectoryType=$selectedType
    CollectedAtUtc=$collectedAtUtc
    ObjectCount=$rows.Count
    CsvPath=$resolvedOutputPath
    CsvSha256=$hash
    ComputerName=$env:COMPUTERNAME
    PowerShellVersion=[string]$PSVersionTable.PSVersion
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host ''
Write-Host "$inventorySide inventory complete." -ForegroundColor Green
Write-Host "Objects:  $($rows.Count)"
Write-Host "CSV:      $resolvedOutputPath"
Write-Host "Manifest: $manifestPath"
Write-Host "SHA-256:  $hash"

[pscustomobject]@{
    InventorySide=$inventorySide
    DirectoryType=$selectedType
    ObjectCount=$rows.Count
    CsvPath=$resolvedOutputPath
    ManifestPath=$manifestPath
    Sha256=$hash
}
