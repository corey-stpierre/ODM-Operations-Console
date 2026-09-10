Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:McuEngineVersion = '1.0.0-preview.2'
$script:McuSchemaVersion = '1.0'

function ConvertTo-McuObjectArray {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    $result = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $InputObject) { return $result.ToArray() }

    $value = $InputObject
    try {
        if ($InputObject -is [System.Management.Automation.PSObject] -and $null -ne $InputObject.BaseObject) {
            $value = $InputObject.BaseObject
        }
    }
    catch { $value = $InputObject }

    if ($value -is [string] -or $value -is [System.Collections.IDictionary]) {
        $result.Add($InputObject) | Out-Null
        return $result.ToArray()
    }
    if ($value -is [System.Collections.IEnumerable]) {
        foreach ($item in $value) { $result.Add($item) | Out-Null }
        return $result.ToArray()
    }
    $result.Add($InputObject) | Out-Null
    return $result.ToArray()
}

function Get-McuPropertyValue {
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
                if ([string]::Equals([string]$key, $name, [StringComparison]::OrdinalIgnoreCase)) {
                    $value = $InputObject[$key]
                    if ($null -ne $value) { return $value }
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

function Get-McuMapValue {
    [CmdletBinding()]
    param(
        [AllowNull()][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Map) { return $Default }
    foreach ($key in $Map.Keys) {
        if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
            if ($null -ne $Map[$key]) { return $Map[$key] }
            return $Default
        }
    }
    return $Default
}

function Resolve-McuColumnName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Headers,
        [Parameter(Mandatory = $true)][string[]]$Aliases
    )

    foreach ($alias in $Aliases) {
        foreach ($header in $Headers) {
            if ([string]::Equals($header.Trim(), $alias.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                return $header
            }
        }
    }
    return ''
}

function Split-McuMultiValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    $values = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($candidate in (ConvertTo-McuObjectArray -InputObject $Value)) {
        if ($null -eq $candidate) { continue }
        $text = [string]$candidate
        $parts = @()
        if ($text -match '[\|\r\n]') { $parts = @($text -split '[\|\r\n]+') }
        elseif ($text -match ';') { $parts = @($text -split ';+') }
        else { $parts = @($text) }

        foreach ($part in $parts) {
            $trimmed = ([string]$part).Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            $key = $trimmed.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $values.Add($trimmed) | Out-Null
            }
        }
    }
    return $values.ToArray()
}

function Normalize-McuEmail {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim()
    if ($text -match '^(?i)smtp:') { $text = $text.Substring($text.IndexOf(':') + 1).Trim() }
    return $text.Trim().ToLowerInvariant()
}

function Normalize-McuAlias {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim()
    if ($text.Contains('\')) { $text = $text.Substring($text.LastIndexOf('\') + 1) }
    return $text.ToLowerInvariant()
}

function Normalize-McuGuid {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $guidValue = [Guid]::Empty
    if ([Guid]::TryParse($text, [ref]$guidValue)) { return $guidValue.ToString('D').ToLowerInvariant() }
    return $text.ToLowerInvariant()
}

function Normalize-McuBase64 {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    try {
        $bytes = [Convert]::FromBase64String($text)
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    catch { return $text.ToLowerInvariant() }
}

function Normalize-McuSid {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim().ToLowerInvariant()
}

function Test-McuEmailLike {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $true }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $true }
    if ($text -match '^(?i)smtp:') { $text = $text.Substring($text.IndexOf(':') + 1).Trim() }
    return ($text -match '^[^@\s]+@[^@\s]+$')
}

function Test-McuGuidValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $true }
    $parsed = [Guid]::Empty
    return [Guid]::TryParse(([string]$Value).Trim(), [ref]$parsed)
}

function Test-McuBase64Value {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $true }
    try { $null = [Convert]::FromBase64String(([string]$Value).Trim()); return $true }
    catch { return $false }
}

function Get-McuFileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Get-Command -Name Get-FileHash -ErrorAction SilentlyContinue) {
        return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function New-McuQualityIssueRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Values)

    return [pscustomobject][ordered]@{
        IssueId           = ''
        Severity          = [string](Get-McuMapValue -Map $Values -Name 'Severity' -Default 'Medium')
        Side              = [string](Get-McuMapValue -Map $Values -Name 'Side' -Default '')
        Category          = [string](Get-McuMapValue -Map $Values -Name 'Category' -Default 'InventoryQuality')
        RowNumber         = [int](Get-McuMapValue -Map $Values -Name 'RowNumber' -Default 0)
        ObjectId          = [string](Get-McuMapValue -Map $Values -Name 'ObjectId' -Default '')
        UserPrincipalName = [string](Get-McuMapValue -Map $Values -Name 'UserPrincipalName' -Default '')
        DisplayName       = [string](Get-McuMapValue -Map $Values -Name 'DisplayName' -Default '')
        Attribute         = [string](Get-McuMapValue -Map $Values -Name 'Attribute' -Default '')
        Value             = [string](Get-McuMapValue -Map $Values -Name 'Value' -Default '')
        Details           = [string](Get-McuMapValue -Map $Values -Name 'Details' -Default '')
        RecommendedAction = [string](Get-McuMapValue -Map $Values -Name 'RecommendedAction' -Default '')
    }
}

function New-McuCollisionRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Values)

    return [pscustomobject][ordered]@{
        CollisionId        = ''
        Severity           = [string](Get-McuMapValue -Map $Values -Name 'Severity' -Default 'Medium')
        Category           = [string](Get-McuMapValue -Map $Values -Name 'Category' -Default '')
        Scope              = [string](Get-McuMapValue -Map $Values -Name 'Scope' -Default '')
        AnchorNamespace    = [string](Get-McuMapValue -Map $Values -Name 'AnchorNamespace' -Default '')
        AnchorValue        = [string](Get-McuMapValue -Map $Values -Name 'AnchorValue' -Default '')
        SourceAttribute    = [string](Get-McuMapValue -Map $Values -Name 'SourceAttribute' -Default '')
        TargetAttribute    = [string](Get-McuMapValue -Map $Values -Name 'TargetAttribute' -Default '')
        SourceObjectCount  = [int](Get-McuMapValue -Map $Values -Name 'SourceObjectCount' -Default 0)
        SourceObjectIds    = [string](Get-McuMapValue -Map $Values -Name 'SourceObjectIds' -Default '')
        SourceUPNs         = [string](Get-McuMapValue -Map $Values -Name 'SourceUPNs' -Default '')
        SourceDisplayNames = [string](Get-McuMapValue -Map $Values -Name 'SourceDisplayNames' -Default '')
        TargetObjectCount  = [int](Get-McuMapValue -Map $Values -Name 'TargetObjectCount' -Default 0)
        TargetObjectIds    = [string](Get-McuMapValue -Map $Values -Name 'TargetObjectIds' -Default '')
        TargetUPNs         = [string](Get-McuMapValue -Map $Values -Name 'TargetUPNs' -Default '')
        TargetDisplayNames = [string](Get-McuMapValue -Map $Values -Name 'TargetDisplayNames' -Default '')
        CandidateCount     = [int](Get-McuMapValue -Map $Values -Name 'CandidateCount' -Default 0)
        Evidence           = [string](Get-McuMapValue -Map $Values -Name 'Evidence' -Default '')
        Details            = [string](Get-McuMapValue -Map $Values -Name 'Details' -Default '')
        RecommendedAction  = [string](Get-McuMapValue -Map $Values -Name 'RecommendedAction' -Default '')
    }
}

function Get-McuObjectDisplayList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Objects,
        [Parameter(Mandatory = $true)][ValidateSet('ObjectId','UserPrincipalName','DisplayName')][string]$Property
    )

    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($object in $Objects) {
        $value = [string](Get-McuPropertyValue -InputObject $object -Names @($Property) -Default '')
        if (-not [string]::IsNullOrWhiteSpace($value) -and -not $values.Contains($value)) { $values.Add($value) | Out-Null }
    }
    return ($values.ToArray() -join ' | ')
}

function Import-McuInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Source','Target')][string]$Side
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Side inventory file was not found: $Path" }
    $rawRows = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
    if ($rawRows.Count -eq 0) { throw "$Side inventory contains no data rows: $Path" }

    $headers = @($rawRows[0].PSObject.Properties.Name)
    $aliases = [ordered]@{
        SchemaVersion                  = @('SchemaVersion','InventorySchemaVersion')
        CollectorVersion               = @('CollectorVersion')
        InventorySide                  = @('InventorySide','Side')
        DirectoryType                  = @('DirectoryType','EnvironmentType','SourceType','TargetType')
        EnvironmentName                = @('EnvironmentName','OrganizationName','TenantName','Domain')
        TenantId                       = @('TenantId','TenantID')
        DomainName                     = @('DomainName','DnsRoot','PrimaryDomain')
        CollectedAtUtc                 = @('CollectedAtUtc','CollectedAt','ExportedAtUtc')
        ObjectType                     = @('ObjectType','Type')
        ObjectId                       = @('ObjectId','Id','AzureAdObjectId','EntraObjectId','SourceObjectId','TargetObjectId')
        ObjectGuid                     = @('ObjectGuid','ObjectGUID','Guid')
        ObjectGuidBase64               = @('ObjectGuidBase64','ObjectGUIDBase64')
        ConsistencyGuid                = @('ConsistencyGuid','mS-DS-ConsistencyGuid','msDSConsistencyGuid')
        ConsistencyGuidBase64          = @('ConsistencyGuidBase64','mS-DS-ConsistencyGuidBase64','msDSConsistencyGuidBase64')
        OnPremisesImmutableId          = @('OnPremisesImmutableId','ImmutableId','ImmutableID')
        Sid                            = @('Sid','SID','ObjectSid','ObjectSID')
        OnPremisesSecurityIdentifier   = @('OnPremisesSecurityIdentifier','OnPremisesSid')
        DistinguishedName              = @('DistinguishedName','DN')
        DisplayName                    = @('DisplayName','Name')
        UserPrincipalName              = @('UserPrincipalName','UPN','SourceUPN','TargetUPN')
        SamAccountName                 = @('SamAccountName','sAMAccountName','SAMAccountName')
        Mail                           = @('Mail','Email','EmailAddress')
        MailNickname                   = @('MailNickname','Alias')
        PrimarySmtpAddress             = @('PrimarySmtpAddress','PrimarySMTP','PrimaryEmail')
        ProxyAddresses                 = @('ProxyAddresses','proxyAddresses','EmailAddresses')
        OtherMails                     = @('OtherMails','AlternateEmails')
        SignInNames                    = @('SignInNames','Identities')
        TargetAddress                  = @('TargetAddress','targetAddress')
        EmployeeId                     = @('EmployeeId','EmployeeID','employeeID')
        AccountEnabled                 = @('AccountEnabled','Enabled')
        UserType                       = @('UserType')
        IsGuest                        = @('IsGuest')
        CreatedDateTime                = @('CreatedDateTime','WhenCreated','Created')
    }

    $resolved = @{}
    foreach ($canonical in $aliases.Keys) {
        $resolved[$canonical] = Resolve-McuColumnName -Headers $headers -Aliases $aliases[$canonical]
    }

    $anchorCapableFields = @(
        'ObjectGuid','ObjectGuidBase64','ConsistencyGuid','ConsistencyGuidBase64','OnPremisesImmutableId',
        'Sid','OnPremisesSecurityIdentifier','UserPrincipalName','SamAccountName','Mail','MailNickname',
        'PrimarySmtpAddress','ProxyAddresses','OtherMails','SignInNames','TargetAddress','EmployeeId'
    )
    $recognizedAnchors = @($anchorCapableFields | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$resolved[$_]) })
    if ($recognizedAnchors.Count -eq 0) {
        throw "$Side inventory does not contain a recognized mapping-anchor column. Use the packaged collector scripts or include UPN, sAMAccountName, mail, proxyAddresses, GUID, SID, employee ID, or immutable-ID fields."
    }

    $objects = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $rowNumber = 1
    foreach ($row in $rawRows) {
        $rowNumber++
        $values = @{}
        foreach ($canonical in $aliases.Keys) {
            $column = [string]$resolved[$canonical]
            if ([string]::IsNullOrWhiteSpace($column)) { $values[$canonical] = '' }
            else { $values[$canonical] = [string](Get-McuPropertyValue -InputObject $row -Names @($column) -Default '') }
        }

        $rawObjectId = ([string]$values.ObjectId).Trim()
        $objectGuid = ([string]$values.ObjectGuid).Trim()
        $upn = ([string]$values.UserPrincipalName).Trim()
        $objectId = $rawObjectId
        if ([string]::IsNullOrWhiteSpace($objectId)) { $objectId = $objectGuid }
        if ([string]::IsNullOrWhiteSpace($objectId)) { $objectId = $upn }
        if ([string]::IsNullOrWhiteSpace($objectId)) { $objectId = '{0}-ROW-{1:D6}' -f $Side,$rowNumber }

        $object = [pscustomobject][ordered]@{
            ObjectKey                      = '{0}|{1:D6}|{2}' -f $Side,$rowNumber,$objectId
            RowNumber                      = $rowNumber
            InventorySide                  = $Side
            RawInventorySide               = ([string]$values.InventorySide).Trim()
            SchemaVersion                  = ([string]$values.SchemaVersion).Trim()
            CollectorVersion               = ([string]$values.CollectorVersion).Trim()
            DirectoryType                  = ([string]$values.DirectoryType).Trim()
            EnvironmentName                = ([string]$values.EnvironmentName).Trim()
            TenantId                       = ([string]$values.TenantId).Trim()
            DomainName                     = ([string]$values.DomainName).Trim()
            CollectedAtUtc                 = ([string]$values.CollectedAtUtc).Trim()
            ObjectType                     = if ([string]::IsNullOrWhiteSpace([string]$values.ObjectType)) { 'User' } else { ([string]$values.ObjectType).Trim() }
            ObjectId                       = $objectId
            RawObjectId                    = $rawObjectId
            ObjectGuid                     = $objectGuid
            ObjectGuidBase64               = ([string]$values.ObjectGuidBase64).Trim()
            ConsistencyGuid                = ([string]$values.ConsistencyGuid).Trim()
            ConsistencyGuidBase64          = ([string]$values.ConsistencyGuidBase64).Trim()
            OnPremisesImmutableId          = ([string]$values.OnPremisesImmutableId).Trim()
            Sid                            = ([string]$values.Sid).Trim()
            OnPremisesSecurityIdentifier   = ([string]$values.OnPremisesSecurityIdentifier).Trim()
            DistinguishedName              = ([string]$values.DistinguishedName).Trim()
            DisplayName                    = ([string]$values.DisplayName).Trim()
            UserPrincipalName              = $upn
            SamAccountName                 = ([string]$values.SamAccountName).Trim()
            Mail                           = ([string]$values.Mail).Trim()
            MailNickname                   = ([string]$values.MailNickname).Trim()
            PrimarySmtpAddress             = ([string]$values.PrimarySmtpAddress).Trim()
            ProxyAddresses                 = ([string]$values.ProxyAddresses).Trim()
            OtherMails                     = ([string]$values.OtherMails).Trim()
            SignInNames                    = ([string]$values.SignInNames).Trim()
            TargetAddress                  = ([string]$values.TargetAddress).Trim()
            EmployeeId                     = ([string]$values.EmployeeId).Trim()
            AccountEnabled                 = ([string]$values.AccountEnabled).Trim()
            UserType                       = ([string]$values.UserType).Trim()
            IsGuest                        = ([string]$values.IsGuest).Trim()
            CreatedDateTime                = ([string]$values.CreatedDateTime).Trim()
            MissingOriginalObjectId        = [string]::IsNullOrWhiteSpace($rawObjectId)
        }
        $objects.Add($object) | Out-Null

        if ($object.MissingOriginalObjectId) {
            $issues.Add((New-McuQualityIssueRecord -Values @{
                Severity='Medium'; Side=$Side; Category='MissingObjectId'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute='ObjectId';
                Details='The row did not contain an explicit object ID. A fallback key was used for analysis.';
                RecommendedAction='Re-export with the packaged collector so mapping results can be traced to a stable object ID.'
            })) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($object.RawInventorySide) -and -not [string]::Equals($object.RawInventorySide,$Side,[StringComparison]::OrdinalIgnoreCase)) {
            $issues.Add((New-McuQualityIssueRecord -Values @{
                Severity='High'; Side=$Side; Category='SideLabelMismatch'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute='InventorySide'; Value=$object.RawInventorySide;
                Details="The CSV row is labeled '$($object.RawInventorySide)' but was loaded as $Side.";
                RecommendedAction='Verify that the source and target CSV files were not reversed.'
            })) | Out-Null
        }

        foreach ($emailProperty in @('UserPrincipalName','Mail','PrimarySmtpAddress','TargetAddress')) {
            $emailValue = [string](Get-McuPropertyValue -InputObject $object -Names @($emailProperty) -Default '')
            if (-not (Test-McuEmailLike -Value $emailValue)) {
                $issues.Add((New-McuQualityIssueRecord -Values @{
                    Severity='Medium'; Side=$Side; Category='MalformedEmailAnchor'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute=$emailProperty; Value=$emailValue;
                    Details="The $emailProperty value is not in a recognizable address format.";
                    RecommendedAction='Correct or remove the malformed value before using it as a mapping anchor.'
                })) | Out-Null
            }
        }
        foreach ($multiEmailProperty in @('OtherMails','SignInNames')) {
            foreach ($emailValue in (Split-McuMultiValue -Value (Get-McuPropertyValue -InputObject $object -Names @($multiEmailProperty) -Default ''))) {
                if (-not (Test-McuEmailLike -Value $emailValue)) {
                    $issues.Add((New-McuQualityIssueRecord -Values @{
                        Severity='Low'; Side=$Side; Category='MalformedEmailAnchor'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute=$multiEmailProperty; Value=$emailValue;
                        Details="A $multiEmailProperty value is not in a recognizable address format.";
                        RecommendedAction='Review the value before treating it as a mapping anchor.'
                    })) | Out-Null
                }
            }
        }
        foreach ($guidProperty in @('ObjectGuid','ConsistencyGuid')) {
            $guidText = [string](Get-McuPropertyValue -InputObject $object -Names @($guidProperty) -Default '')
            if (-not (Test-McuGuidValue -Value $guidText)) {
                $issues.Add((New-McuQualityIssueRecord -Values @{
                    Severity='Medium'; Side=$Side; Category='MalformedGuidAnchor'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute=$guidProperty; Value=$guidText;
                    Details="The $guidProperty value is not a valid GUID.";
                    RecommendedAction='Re-export the inventory or correct the value before using it for mapping.'
                })) | Out-Null
            }
        }
        foreach ($base64Property in @('ObjectGuidBase64','ConsistencyGuidBase64','OnPremisesImmutableId')) {
            $base64Text = [string](Get-McuPropertyValue -InputObject $object -Names @($base64Property) -Default '')
            if (-not (Test-McuBase64Value -Value $base64Text)) {
                $issues.Add((New-McuQualityIssueRecord -Values @{
                    Severity='Medium'; Side=$Side; Category='MalformedImmutableAnchor'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute=$base64Property; Value=$base64Text;
                    Details="The $base64Property value is not valid Base64.";
                    RecommendedAction='Re-export the inventory or correct the immutable-ID value before using it for mapping.'
                })) | Out-Null
            }
        }
        foreach ($sidProperty in @('Sid','OnPremisesSecurityIdentifier')) {
            $sidText = [string](Get-McuPropertyValue -InputObject $object -Names @($sidProperty) -Default '')
            if (-not [string]::IsNullOrWhiteSpace($sidText) -and $sidText -notmatch '^S-\d(?:-\d+)+$') {
                $issues.Add((New-McuQualityIssueRecord -Values @{
                    Severity='Medium'; Side=$Side; Category='MalformedSidAnchor'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute=$sidProperty; Value=$sidText;
                    Details="The $sidProperty value is not a recognizable SID.";
                    RecommendedAction='Re-export the inventory or correct the SID before using it for mapping.'
                })) | Out-Null
            }
        }

        $proxyValues = @(Split-McuMultiValue -Value $object.ProxyAddresses)
        $primaryProxyValues = @($proxyValues | Where-Object { $_ -cmatch '^SMTP:' })
        if ($primaryProxyValues.Count -gt 1) {
            $issues.Add((New-McuQualityIssueRecord -Values @{
                Severity='High'; Side=$Side; Category='MultiplePrimarySmtp'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute='ProxyAddresses'; Value=($primaryProxyValues -join ' | ');
                Details='More than one uppercase SMTP proxy was found, so the primary SMTP address is ambiguous.';
                RecommendedAction='Correct proxyAddresses so exactly one primary SMTP address is designated.'
            })) | Out-Null
        }
        foreach ($proxy in $proxyValues) {
            if ($proxy -match '^(?i)smtp:' -and -not (Test-McuEmailLike -Value $proxy)) {
                $issues.Add((New-McuQualityIssueRecord -Values @{
                    Severity='Medium'; Side=$Side; Category='MalformedProxyAddress'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute='ProxyAddresses'; Value=$proxy;
                    Details='An SMTP proxy value is not in a recognizable address format.';
                    RecommendedAction='Correct or remove the malformed proxy address before migration.'
                })) | Out-Null
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($object.PrimarySmtpAddress) -and $proxyValues.Count -gt 0) {
            $normalizedPrimary = Normalize-McuEmail -Value $object.PrimarySmtpAddress
            $proxySmtp = @($proxyValues | Where-Object { $_ -match '^(?i)smtp:' } | ForEach-Object { Normalize-McuEmail -Value $_ })
            if ($proxySmtp.Count -gt 0 -and $proxySmtp -notcontains $normalizedPrimary) {
                $issues.Add((New-McuQualityIssueRecord -Values @{
                    Severity='Low'; Side=$Side; Category='PrimarySmtpNotInProxySet'; RowNumber=$rowNumber; ObjectId=$objectId; UserPrincipalName=$upn; DisplayName=$object.DisplayName; Attribute='PrimarySmtpAddress'; Value=$object.PrimarySmtpAddress;
                    Details='The PrimarySmtpAddress value is not present in the SMTP proxy-address set.';
                    RecommendedAction='Verify which address should be treated as primary before mapping.'
                })) | Out-Null
            }
        }
    }

    $idGroups = @{}
    foreach ($object in $objects.ToArray()) {
        if ([string]::IsNullOrWhiteSpace($object.RawObjectId)) { continue }
        $key = $object.RawObjectId.Trim().ToLowerInvariant()
        if (-not $idGroups.ContainsKey($key)) { $idGroups[$key] = [System.Collections.Generic.List[object]]::new() }
        $idGroups[$key].Add($object) | Out-Null
    }
    foreach ($key in $idGroups.Keys) {
        $duplicates = @($idGroups[$key].ToArray())
        if ($duplicates.Count -le 1) { continue }
        foreach ($object in $duplicates) {
            $issues.Add((New-McuQualityIssueRecord -Values @{
                Severity='High'; Side=$Side; Category='DuplicateObjectIdRow'; RowNumber=$object.RowNumber; ObjectId=$object.ObjectId; UserPrincipalName=$object.UserPrincipalName; DisplayName=$object.DisplayName; Attribute='ObjectId'; Value=$object.RawObjectId;
                Details="The object ID appears in $($duplicates.Count) rows in the same inventory.";
                RecommendedAction='Remove duplicate rows or re-export the inventory before analyzing mappings.'
            })) | Out-Null
        }
    }

    return [pscustomobject]@{
        Side       = $Side
        Path       = [IO.Path]::GetFullPath($Path)
        Hash       = Get-McuFileHash -Path $Path
        Headers    = $headers
        Resolved   = $resolved
        Objects    = $objects.ToArray()
        Issues     = $issues.ToArray()
    }
}

function New-McuAnchorEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Attribute,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$NormalizedValue,
        [Parameter(Mandatory = $true)][int]$Weight,
        [bool]$ExpectedUnique = $true
    )

    return [pscustomobject][ordered]@{
        Side                  = $Object.InventorySide
        ObjectKey             = $Object.ObjectKey
        ObjectId              = $Object.ObjectId
        ObjectType            = $Object.ObjectType
        DisplayName           = $Object.DisplayName
        UserPrincipalName     = $Object.UserPrincipalName
        DirectoryType         = $Object.DirectoryType
        Namespace             = $Namespace
        Attribute             = $Attribute
        Value                 = $Value
        NormalizedValue       = $NormalizedValue
        Weight                = $Weight
        ExpectedUnique        = $ExpectedUnique
        Strength              = if ($Weight -ge 90) { 'Strong' } elseif ($Weight -ge 40) { 'Standard' } else { 'Weak' }
    }
}

function Get-McuAnchorEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Objects,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Options
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $includeEmployee = [bool](Get-McuMapValue -Map $Options -Name 'IncludeEmployeeId' -Default $true)
    $includeWeakAlias = [bool](Get-McuMapValue -Map $Options -Name 'IncludeWeakAliasMatches' -Default $true)

    foreach ($object in $Objects) {
        $specs = @(
            [pscustomobject]@{Property='ObjectGuid';Namespace='ObjectGuid';Attribute='ObjectGuid';Weight=100;Kind='Guid';Unique=$true},
            [pscustomobject]@{Property='ConsistencyGuid';Namespace='ConsistencyGuid';Attribute='ConsistencyGuid';Weight=95;Kind='Guid';Unique=$true},
            [pscustomobject]@{Property='ObjectGuidBase64';Namespace='ImmutableId';Attribute='ObjectGuidBase64';Weight=95;Kind='Base64';Unique=$true},
            [pscustomobject]@{Property='ConsistencyGuidBase64';Namespace='ImmutableId';Attribute='ConsistencyGuidBase64';Weight=95;Kind='Base64';Unique=$true},
            [pscustomobject]@{Property='OnPremisesImmutableId';Namespace='ImmutableId';Attribute='OnPremisesImmutableId';Weight=95;Kind='Base64';Unique=$true},
            [pscustomobject]@{Property='Sid';Namespace='SecurityId';Attribute='Sid';Weight=100;Kind='Sid';Unique=$true},
            [pscustomobject]@{Property='OnPremisesSecurityIdentifier';Namespace='SecurityId';Attribute='OnPremisesSecurityIdentifier';Weight=100;Kind='Sid';Unique=$true},
            [pscustomobject]@{Property='UserPrincipalName';Namespace='EmailAddress';Attribute='UserPrincipalName';Weight=60;Kind='Email';Unique=$true},
            [pscustomobject]@{Property='PrimarySmtpAddress';Namespace='EmailAddress';Attribute='PrimarySmtpAddress';Weight=55;Kind='Email';Unique=$true},
            [pscustomobject]@{Property='Mail';Namespace='EmailAddress';Attribute='Mail';Weight=45;Kind='Email';Unique=$true},
            [pscustomobject]@{Property='TargetAddress';Namespace='EmailAddress';Attribute='TargetAddress';Weight=35;Kind='Email';Unique=$true},
            [pscustomobject]@{Property='SamAccountName';Namespace='Alias';Attribute='SamAccountName';Weight=40;Kind='Alias';Unique=$true}
        )
        if ($includeWeakAlias) {
            $specs += [pscustomobject]@{Property='MailNickname';Namespace='Alias';Attribute='MailNickname';Weight=25;Kind='Alias';Unique=$true}
        }
        if ($includeEmployee) {
            $specs += [pscustomobject]@{Property='EmployeeId';Namespace='EmployeeId';Attribute='EmployeeId';Weight=30;Kind='Alias';Unique=$true}
        }

        foreach ($spec in $specs) {
            $rawValue = [string](Get-McuPropertyValue -InputObject $object -Names @($spec.Property) -Default '')
            if ([string]::IsNullOrWhiteSpace($rawValue)) { continue }
            if ($spec.Kind -eq 'Email' -and -not (Test-McuEmailLike -Value $rawValue)) { continue }
            if ($spec.Kind -eq 'Guid' -and -not (Test-McuGuidValue -Value $rawValue)) { continue }
            if ($spec.Kind -eq 'Base64' -and -not (Test-McuBase64Value -Value $rawValue)) { continue }
            if ($spec.Kind -eq 'Sid' -and $rawValue -notmatch '^S-\d(?:-\d+)+$') { continue }
            $normalized = switch ($spec.Kind) {
                'Guid'   { Normalize-McuGuid -Value $rawValue }
                'Base64' { Normalize-McuBase64 -Value $rawValue }
                'Sid'    { Normalize-McuSid -Value $rawValue }
                'Email'  { Normalize-McuEmail -Value $rawValue }
                default  { Normalize-McuAlias -Value $rawValue }
            }
            if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
            $dedupeKey = '{0}|{1}|{2}|{3}' -f $object.ObjectKey,$spec.Namespace,$spec.Attribute,$normalized
            if (-not $seen.ContainsKey($dedupeKey)) {
                $seen[$dedupeKey] = $true
                $entries.Add((New-McuAnchorEntry -Object $object -Namespace $spec.Namespace -Attribute $spec.Attribute -Value $rawValue -NormalizedValue $normalized -Weight $spec.Weight -ExpectedUnique $spec.Unique)) | Out-Null
            }
        }

        foreach ($propertyName in @('OtherMails','SignInNames')) {
            foreach ($rawValue in (Split-McuMultiValue -Value (Get-McuPropertyValue -InputObject $object -Names @($propertyName) -Default ''))) {
                if (-not (Test-McuEmailLike -Value $rawValue)) { continue }
                $normalized = Normalize-McuEmail -Value $rawValue
                if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
                $dedupeKey = '{0}|EmailAddress|{1}|{2}' -f $object.ObjectKey,$propertyName,$normalized
                if (-not $seen.ContainsKey($dedupeKey)) {
                    $seen[$dedupeKey] = $true
                    $entries.Add((New-McuAnchorEntry -Object $object -Namespace 'EmailAddress' -Attribute $propertyName -Value $rawValue -NormalizedValue $normalized -Weight 30 -ExpectedUnique $true)) | Out-Null
                }
            }
        }

        foreach ($proxy in (Split-McuMultiValue -Value $object.ProxyAddresses)) {
            $namespace = 'ProxyAddress'
            $attribute = 'ProxyOther'
            $weight = 20
            $normalized = $proxy.Trim().ToLowerInvariant()
            if ($proxy -match '^(?i)smtp:') {
                if (-not (Test-McuEmailLike -Value $proxy)) { continue }
                $namespace = 'EmailAddress'; $attribute = 'ProxySmtpAddress'; $weight = 50; $normalized = Normalize-McuEmail -Value $proxy
            }
            elseif ($proxy -match '^(?i)sip:') {
                $namespace = 'SipAddress'; $attribute = 'ProxySipAddress'; $weight = 25; $normalized = $proxy.Substring($proxy.IndexOf(':') + 1).Trim().ToLowerInvariant()
            }
            elseif ($proxy -match '^(?i)x500:') {
                $namespace = 'X500Address'; $attribute = 'ProxyX500Address'; $weight = 35; $normalized = $proxy.Substring($proxy.IndexOf(':') + 1).Trim().ToLowerInvariant()
            }
            if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
            $dedupeKey = '{0}|{1}|{2}|{3}' -f $object.ObjectKey,$namespace,$attribute,$normalized
            if (-not $seen.ContainsKey($dedupeKey)) {
                $seen[$dedupeKey] = $true
                $entries.Add((New-McuAnchorEntry -Object $object -Namespace $namespace -Attribute $attribute -Value $proxy -NormalizedValue $normalized -Weight $weight -ExpectedUnique $true)) | Out-Null
            }
        }
    }
    return $entries.ToArray()
}

function Get-McuIndexKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$NormalizedValue
    )
    return '{0}::{1}' -f $Namespace.ToLowerInvariant(),$NormalizedValue
}

function New-McuAnchorIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries)

    $index = @{}
    foreach ($entry in $Entries) {
        $key = Get-McuIndexKey -Namespace $entry.Namespace -NormalizedValue $entry.NormalizedValue
        if (-not $index.ContainsKey($key)) { $index[$key] = [System.Collections.Generic.List[object]]::new() }
        $index[$key].Add($entry) | Out-Null
    }
    return $index
}

function Get-McuDuplicateSeverity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Namespace)

    switch ($Namespace) {
        'ObjectGuid'      { return 'Critical' }
        'ConsistencyGuid' { return 'Critical' }
        'ImmutableId'     { return 'Critical' }
        'SecurityId'      { return 'Critical' }
        'EmailAddress'    { return 'High' }
        'X500Address'     { return 'High' }
        'SipAddress'      { return 'Medium' }
        'Alias'           { return 'Medium' }
        'EmployeeId'      { return 'Medium' }
        default           { return 'Medium' }
    }
}

function Get-McuCandidateScore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Evidence)

    $namespaceMax = @{}
    $namespaceValues = @{}
    foreach ($item in $Evidence) {
        $namespace = [string]$item.Namespace
        if (-not $namespaceMax.ContainsKey($namespace) -or [int]$item.Weight -gt [int]$namespaceMax[$namespace]) {
            $namespaceMax[$namespace] = [int]$item.Weight
        }
        if (-not $namespaceValues.ContainsKey($namespace)) { $namespaceValues[$namespace] = @{} }
        $namespaceValues[$namespace][[string]$item.NormalizedValue] = $true
    }

    $score = 0
    foreach ($namespace in $namespaceMax.Keys) {
        $component = [int]$namespaceMax[$namespace]
        if ($namespace -eq 'EmailAddress') {
            $extra = [Math]::Min(20, ([Math]::Max(0, $namespaceValues[$namespace].Count - 1) * 10))
            $component += $extra
        }
        elseif ($namespace -eq 'Alias') {
            $component = [Math]::Min(40, $component)
        }
        elseif ($namespace -eq 'EmployeeId') {
            $component = [Math]::Min(30, $component)
        }
        $score += $component
    }
    return [Math]::Min(100, $score)
}

function Get-McuSeverityRank {
    [CmdletBinding()]
    param([AllowNull()][string]$Severity)

    switch ($Severity) {
        'Critical' { return 1 }
        'High'     { return 2 }
        'Medium'   { return 3 }
        'Low'      { return 4 }
        default    { return 5 }
    }
}

function Export-McuCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Columns
    )

    if ($Rows.Count -gt 0) {
        $Rows | Select-Object -Property $Columns | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Force
        return
    }
    $quoted = @($Columns | ForEach-Object { '"{0}"' -f ([string]$_).Replace('"','""') })
    [IO.File]::WriteAllText($Path, ($quoted -join ',') + [Environment]::NewLine, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
}

function ConvertTo-McuHtmlFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Columns,
        [int]$MaximumRows = 500
    )

    if ($Rows.Count -eq 0) { return '<p class="empty">No rows.</p>' }
    $limited = @($Rows | Select-Object -First $MaximumRows | Select-Object -Property $Columns)
    $fragment = $limited | ConvertTo-Html -Fragment
    if ($Rows.Count -gt $MaximumRows) {
        $fragment += '<p class="note">Only the first {0:N0} of {1:N0} rows are shown. Use the CSV export for the complete dataset.</p>' -f $MaximumRows,$Rows.Count
    }
    return ($fragment -join [Environment]::NewLine)
}

function Invoke-MappingCollisionAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceCsvPath,
        [Parameter(Mandatory = $true)][string]$TargetCsvPath,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [hashtable]$Options = @{}
    )

    $started = [DateTime]::UtcNow
    $runId = [Guid]::NewGuid().ToString('N')
    $effectiveOptions = [ordered]@{
        CheckInternalDuplicates  = [bool](Get-McuMapValue -Map $Options -Name 'CheckInternalDuplicates' -Default $true)
        CheckCrossAttribute      = [bool](Get-McuMapValue -Map $Options -Name 'CheckCrossAttribute' -Default $true)
        IncludeEmployeeId        = [bool](Get-McuMapValue -Map $Options -Name 'IncludeEmployeeId' -Default $true)
        IncludeWeakAliasMatches  = [bool](Get-McuMapValue -Map $Options -Name 'IncludeWeakAliasMatches' -Default $true)
        MaxCandidatePairs        = [int](Get-McuMapValue -Map $Options -Name 'MaxCandidatePairs' -Default 250000)
    }
    if ($effectiveOptions.MaxCandidatePairs -lt 1000) { $effectiveOptions.MaxCandidatePairs = 1000 }

    $sourceInventory = Import-McuInventory -Path $SourceCsvPath -Side Source
    $targetInventory = Import-McuInventory -Path $TargetCsvPath -Side Target

    $qualityIssues = [System.Collections.Generic.List[object]]::new()
    foreach ($issue in (ConvertTo-McuObjectArray -InputObject $sourceInventory.Issues)) { $qualityIssues.Add($issue) | Out-Null }
    foreach ($issue in (ConvertTo-McuObjectArray -InputObject $targetInventory.Issues)) { $qualityIssues.Add($issue) | Out-Null }
    if ([string]::Equals($sourceInventory.Hash,$targetInventory.Hash,[StringComparison]::OrdinalIgnoreCase)) {
        $qualityIssues.Add((New-McuQualityIssueRecord -Values @{
            Severity='Critical'; Side='Both'; Category='IdenticalInputFiles'; RowNumber=0; Attribute='FileHash'; Value=$sourceInventory.Hash;
            Details='The source and target files have the same SHA-256 hash. The same inventory may have been selected twice.';
            RecommendedAction='Select the correct source and target exports before relying on the analysis.'
        })) | Out-Null
    }

    $sourceObjects = @($sourceInventory.Objects)
    $targetObjects = @($targetInventory.Objects)
    $sourceAnchors = @(Get-McuAnchorEntries -Objects $sourceObjects -Options $effectiveOptions)
    $targetAnchors = @(Get-McuAnchorEntries -Objects $targetObjects -Options $effectiveOptions)

    $anchorCountByObject = @{}
    foreach ($entry in @($sourceAnchors + $targetAnchors)) {
        if (-not $anchorCountByObject.ContainsKey($entry.ObjectKey)) { $anchorCountByObject[$entry.ObjectKey] = 0 }
        $anchorCountByObject[$entry.ObjectKey] = [int]$anchorCountByObject[$entry.ObjectKey] + 1
    }
    foreach ($object in @($sourceObjects + $targetObjects)) {
        if (-not $anchorCountByObject.ContainsKey($object.ObjectKey) -or [int]$anchorCountByObject[$object.ObjectKey] -eq 0) {
            $qualityIssues.Add((New-McuQualityIssueRecord -Values @{
                Severity='High'; Side=$object.InventorySide; Category='NoUsableAnchors'; RowNumber=$object.RowNumber; ObjectId=$object.ObjectId; UserPrincipalName=$object.UserPrincipalName; DisplayName=$object.DisplayName;
                Details='The object does not contain any usable mapping anchor.';
                RecommendedAction='Populate or export at least one stable anchor such as UPN, proxy address, sAMAccountName, SID, GUID, or immutable ID.'
            })) | Out-Null
        }
    }

    $sourceObjectLookup = @{}
    foreach ($object in $sourceObjects) { $sourceObjectLookup[$object.ObjectKey] = $object }
    $targetObjectLookup = @{}
    foreach ($object in $targetObjects) { $targetObjectLookup[$object.ObjectKey] = $object }

    $sourceIndex = New-McuAnchorIndex -Entries $sourceAnchors
    $targetIndex = New-McuAnchorIndex -Entries $targetAnchors
    $collisions = [System.Collections.Generic.List[object]]::new()
    $duplicateSourceKeys = @{}
    $duplicateTargetKeys = @{}

    if ($effectiveOptions.CheckInternalDuplicates) {
        foreach ($sideRecord in @(
            [pscustomobject]@{Side='Source';Index=$sourceIndex;Lookup=$sourceObjectLookup;DuplicateKeys=$duplicateSourceKeys},
            [pscustomobject]@{Side='Target';Index=$targetIndex;Lookup=$targetObjectLookup;DuplicateKeys=$duplicateTargetKeys}
        )) {
            foreach ($indexKey in $sideRecord.Index.Keys) {
                $entries = @($sideRecord.Index[$indexKey].ToArray())
                $objectKeys = @($entries.ObjectKey | Select-Object -Unique)
                if ($objectKeys.Count -le 1) { continue }
                $namespace = [string]$entries[0].Namespace
                $objects = @($objectKeys | ForEach-Object { $sideRecord.Lookup[$_] })
                $sideRecord.DuplicateKeys[$indexKey] = $true
                $value = [string]$entries[0].Value
                $attributes = @($entries.Attribute | Select-Object -Unique) -join ', '
                $collisionValues = @{
                    Severity=(Get-McuDuplicateSeverity -Namespace $namespace); Category='InternalDuplicate'; Scope=$sideRecord.Side; AnchorNamespace=$namespace; AnchorValue=$value; CandidateCount=$objects.Count;
                    Evidence="Attributes: $attributes";
                    Details="$($objects.Count) $($sideRecord.Side.ToLowerInvariant()) objects expose the same $namespace anchor value.";
                    RecommendedAction='Resolve the duplicate or explicitly exclude the affected objects before creating migration mappings.'
                }
                if ($sideRecord.Side -eq 'Source') {
                    $collisionValues.SourceObjectCount = $objects.Count
                    $collisionValues.SourceObjectIds = Get-McuObjectDisplayList -Objects $objects -Property ObjectId
                    $collisionValues.SourceUPNs = Get-McuObjectDisplayList -Objects $objects -Property UserPrincipalName
                    $collisionValues.SourceDisplayNames = Get-McuObjectDisplayList -Objects $objects -Property DisplayName
                }
                else {
                    $collisionValues.TargetObjectCount = $objects.Count
                    $collisionValues.TargetObjectIds = Get-McuObjectDisplayList -Objects $objects -Property ObjectId
                    $collisionValues.TargetUPNs = Get-McuObjectDisplayList -Objects $objects -Property UserPrincipalName
                    $collisionValues.TargetDisplayNames = Get-McuObjectDisplayList -Objects $objects -Property DisplayName
                }
                $collisions.Add((New-McuCollisionRecord -Values $collisionValues)) | Out-Null
            }
        }
    }

    $pairMap = @{}
    $pairCount = 0
    $pairCapReached = $false
    foreach ($sourceEntry in $sourceAnchors) {
        $indexKey = Get-McuIndexKey -Namespace $sourceEntry.Namespace -NormalizedValue $sourceEntry.NormalizedValue
        if (-not $targetIndex.ContainsKey($indexKey)) { continue }
        foreach ($targetEntry in @($targetIndex[$indexKey].ToArray())) {
            $pairKey = '{0}>>{1}' -f $sourceEntry.ObjectKey,$targetEntry.ObjectKey
            if (-not $pairMap.ContainsKey($pairKey)) {
                if ($pairCount -ge $effectiveOptions.MaxCandidatePairs) { $pairCapReached = $true; break }
                $pairMap[$pairKey] = [pscustomobject]@{
                    SourceObjectKey = $sourceEntry.ObjectKey
                    TargetObjectKey = $targetEntry.ObjectKey
                    Evidence        = [System.Collections.Generic.List[object]]::new()
                    EvidenceKeys    = @{}
                }
                $pairCount++
            }
            $evidenceKey = '{0}|{1}|{2}|{3}' -f $sourceEntry.Attribute,$targetEntry.Attribute,$sourceEntry.Namespace,$sourceEntry.NormalizedValue
            if (-not $pairMap[$pairKey].EvidenceKeys.ContainsKey($evidenceKey)) {
                $pairMap[$pairKey].EvidenceKeys[$evidenceKey] = $true
                $pairMap[$pairKey].Evidence.Add([pscustomobject][ordered]@{
                    Namespace       = $sourceEntry.Namespace
                    SourceAttribute = $sourceEntry.Attribute
                    TargetAttribute = $targetEntry.Attribute
                    Value           = $sourceEntry.Value
                    NormalizedValue = $sourceEntry.NormalizedValue
                    Weight          = [Math]::Max([int]$sourceEntry.Weight,[int]$targetEntry.Weight)
                    SourceWeight    = $sourceEntry.Weight
                    TargetWeight    = $targetEntry.Weight
                }) | Out-Null
            }
        }
        if ($pairCapReached) { break }
    }
    if ($pairCapReached) {
        $qualityIssues.Add((New-McuQualityIssueRecord -Values @{
            Severity='Critical'; Side='Both'; Category='CandidatePairLimitReached'; RowNumber=0; Attribute='MaxCandidatePairs'; Value=[string]$effectiveOptions.MaxCandidatePairs;
            Details='The candidate-pair safety limit was reached. Highly duplicated anchors caused the potential mapping cross-product to exceed the configured limit.';
            RecommendedAction='Resolve the reported internal duplicates, then rerun the analysis. Results from this run are intentionally incomplete.'
        })) | Out-Null
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($pairKey in $pairMap.Keys) {
        $pair = $pairMap[$pairKey]
        $sourceObject = $sourceObjectLookup[$pair.SourceObjectKey]
        $targetObject = $targetObjectLookup[$pair.TargetObjectKey]
        $evidence = @($pair.Evidence.ToArray())
        $score = Get-McuCandidateScore -Evidence $evidence
        $namespaces = @($evidence.Namespace | Select-Object -Unique)
        $values = @($evidence.Value | Select-Object -Unique)
        $hasStrong = @($evidence | Where-Object { $_.Weight -ge 90 }).Count -gt 0
        $confidence = if ($hasStrong -or $score -ge 75) { 'High' } elseif ($score -ge 45) { 'Medium' } else { 'Low' }
        $evidenceText = @($evidence | Sort-Object Namespace,SourceAttribute,TargetAttribute,Value | ForEach-Object { '{0}->{1} [{2}]: {3}' -f $_.SourceAttribute,$_.TargetAttribute,$_.Namespace,$_.Value }) -join '; '
        $candidates.Add([pscustomobject][ordered]@{
            CandidateId              = ''
            Disposition              = ''
            Confidence               = $confidence
            Score                    = $score
            SourceObjectKey          = $sourceObject.ObjectKey
            SourceObjectId           = $sourceObject.ObjectId
            SourceDisplayName        = $sourceObject.DisplayName
            SourceUPN                = $sourceObject.UserPrincipalName
            SourceSamAccountName     = $sourceObject.SamAccountName
            SourceDirectoryType      = $sourceObject.DirectoryType
            TargetObjectKey          = $targetObject.ObjectKey
            TargetObjectId           = $targetObject.ObjectId
            TargetDisplayName        = $targetObject.DisplayName
            TargetUPN                = $targetObject.UserPrincipalName
            TargetSamAccountName     = $targetObject.SamAccountName
            TargetDirectoryType      = $targetObject.DirectoryType
            SourceCandidateCount     = 0
            TargetClaimCount         = 0
            HasStrongIdentity        = $hasStrong
            InternalDuplicateEvidence = $false
            EvidenceCount            = $evidence.Count
            MatchedNamespaces        = ($namespaces -join ' | ')
            MatchedValues            = ($values -join ' | ')
            Evidence                 = $evidenceText
            EvidenceObjects          = $evidence
        }) | Out-Null
    }

    $candidatesBySource = @{}
    $candidatesByTarget = @{}
    foreach ($candidate in $candidates.ToArray()) {
        if (-not $candidatesBySource.ContainsKey($candidate.SourceObjectKey)) { $candidatesBySource[$candidate.SourceObjectKey] = [System.Collections.Generic.List[object]]::new() }
        $candidatesBySource[$candidate.SourceObjectKey].Add($candidate) | Out-Null
        if (-not $candidatesByTarget.ContainsKey($candidate.TargetObjectKey)) { $candidatesByTarget[$candidate.TargetObjectKey] = [System.Collections.Generic.List[object]]::new() }
        $candidatesByTarget[$candidate.TargetObjectKey].Add($candidate) | Out-Null
    }

    foreach ($candidate in $candidates.ToArray()) {
        $candidate.SourceCandidateCount = @($candidatesBySource[$candidate.SourceObjectKey].ToArray()).Count
        $candidate.TargetClaimCount = @($candidatesByTarget[$candidate.TargetObjectKey].ToArray()).Count
        $hasDuplicateEvidence = $false
        foreach ($evidence in (ConvertTo-McuObjectArray -InputObject $candidate.EvidenceObjects)) {
            $key = Get-McuIndexKey -Namespace $evidence.Namespace -NormalizedValue $evidence.NormalizedValue
            if ($duplicateSourceKeys.ContainsKey($key) -or $duplicateTargetKeys.ContainsKey($key)) { $hasDuplicateEvidence = $true; break }
        }
        $candidate.InternalDuplicateEvidence = $hasDuplicateEvidence
        if ($candidate.SourceCandidateCount -gt 1 -or $candidate.TargetClaimCount -gt 1 -or $candidate.InternalDuplicateEvidence) {
            $candidate.Disposition = 'Blocked - Ambiguous'
        }
        elseif ($candidate.Confidence -eq 'High') { $candidate.Disposition = 'Recommended' }
        elseif ($candidate.Confidence -eq 'Medium') { $candidate.Disposition = 'Review' }
        else { $candidate.Disposition = 'Weak' }
    }

    $ambiguousMappings = [System.Collections.Generic.List[object]]::new()
    foreach ($sourceKey in $candidatesBySource.Keys) {
        $sourceCandidates = @($candidatesBySource[$sourceKey].ToArray() | Sort-Object Score -Descending)
        if ($sourceCandidates.Count -le 1) { continue }
        $sourceObject = $sourceObjectLookup[$sourceKey]
        $hasStrong = @($sourceCandidates | Where-Object { $_.HasStrongIdentity }).Count -gt 0
        $strongCount = @($sourceCandidates | Where-Object { $_.Score -ge 60 }).Count
        $category = if ($strongCount -gt 1 -or $hasStrong) { 'SplitAnchorConflict' } else { 'AmbiguousSourceMapping' }
        $severity = if ($hasStrong -or $strongCount -gt 1) { 'Critical' } else { 'High' }
        $targets = @($sourceCandidates | ForEach-Object { $targetObjectLookup[$_.TargetObjectKey] })
        $collisions.Add((New-McuCollisionRecord -Values @{
            Severity=$severity; Category=$category; Scope='CrossEnvironment'; AnchorNamespace='Multiple'; SourceObjectCount=1; SourceObjectIds=$sourceObject.ObjectId; SourceUPNs=$sourceObject.UserPrincipalName; SourceDisplayNames=$sourceObject.DisplayName;
            TargetObjectCount=$targets.Count; TargetObjectIds=(Get-McuObjectDisplayList -Objects $targets -Property ObjectId); TargetUPNs=(Get-McuObjectDisplayList -Objects $targets -Property UserPrincipalName); TargetDisplayNames=(Get-McuObjectDisplayList -Objects $targets -Property DisplayName); CandidateCount=$sourceCandidates.Count;
            Evidence=(@($sourceCandidates | ForEach-Object { '{0} score {1}: {2}' -f $_.TargetObjectId,$_.Score,$_.Evidence }) -join ' || ');
            Details="One source object resolves to $($sourceCandidates.Count) different target objects through the available anchors.";
            RecommendedAction='Do not auto-map this source object. Correct conflicting anchors or provide an explicit, independently verified mapping.'
        })) | Out-Null
        foreach ($candidate in $sourceCandidates) {
            $ambiguousMappings.Add([pscustomobject][ordered]@{
                AmbiguityId       = ''
                AmbiguityType     = 'OneSourceToMultipleTargets'
                Severity          = $severity
                SourceObjectId    = $candidate.SourceObjectId
                SourceDisplayName = $candidate.SourceDisplayName
                SourceUPN         = $candidate.SourceUPN
                TargetObjectId    = $candidate.TargetObjectId
                TargetDisplayName = $candidate.TargetDisplayName
                TargetUPN         = $candidate.TargetUPN
                Score             = $candidate.Score
                Confidence        = $candidate.Confidence
                Evidence          = $candidate.Evidence
                RecommendedAction = 'Hold mapping until the source has exactly one verified target candidate.'
            }) | Out-Null
        }
    }

    foreach ($targetKey in $candidatesByTarget.Keys) {
        $targetCandidates = @($candidatesByTarget[$targetKey].ToArray() | Sort-Object Score -Descending)
        if ($targetCandidates.Count -le 1) { continue }
        $targetObject = $targetObjectLookup[$targetKey]
        $hasStrong = @($targetCandidates | Where-Object { $_.HasStrongIdentity -or $_.Score -ge 60 }).Count -gt 0
        $severity = if ($hasStrong) { 'Critical' } else { 'High' }
        $sources = @($targetCandidates | ForEach-Object { $sourceObjectLookup[$_.SourceObjectKey] })
        $collisions.Add((New-McuCollisionRecord -Values @{
            Severity=$severity; Category='ManyToOneMapping'; Scope='CrossEnvironment'; AnchorNamespace='Multiple'; SourceObjectCount=$sources.Count; SourceObjectIds=(Get-McuObjectDisplayList -Objects $sources -Property ObjectId); SourceUPNs=(Get-McuObjectDisplayList -Objects $sources -Property UserPrincipalName); SourceDisplayNames=(Get-McuObjectDisplayList -Objects $sources -Property DisplayName);
            TargetObjectCount=1; TargetObjectIds=$targetObject.ObjectId; TargetUPNs=$targetObject.UserPrincipalName; TargetDisplayNames=$targetObject.DisplayName; CandidateCount=$targetCandidates.Count;
            Evidence=(@($targetCandidates | ForEach-Object { '{0} score {1}: {2}' -f $_.SourceObjectId,$_.Score,$_.Evidence }) -join ' || ');
            Details="$($targetCandidates.Count) source objects claim the same target object through one or more anchors.";
            RecommendedAction='Do not create mappings until only one independently verified source object claims this target.'
        })) | Out-Null
        foreach ($candidate in $targetCandidates) {
            $ambiguousMappings.Add([pscustomobject][ordered]@{
                AmbiguityId       = ''
                AmbiguityType     = 'MultipleSourcesToOneTarget'
                Severity          = $severity
                SourceObjectId    = $candidate.SourceObjectId
                SourceDisplayName = $candidate.SourceDisplayName
                SourceUPN         = $candidate.SourceUPN
                TargetObjectId    = $candidate.TargetObjectId
                TargetDisplayName = $candidate.TargetDisplayName
                TargetUPN         = $candidate.TargetUPN
                Score             = $candidate.Score
                Confidence        = $candidate.Confidence
                Evidence          = $candidate.Evidence
                RecommendedAction = 'Hold mapping until the target is claimed by exactly one verified source object.'
            }) | Out-Null
        }
    }

    if ($effectiveOptions.CheckCrossAttribute) {
        $crossSeen = @{}
        foreach ($candidate in $candidates.ToArray()) {
            foreach ($evidence in (ConvertTo-McuObjectArray -InputObject $candidate.EvidenceObjects)) {
                if ([string]::Equals([string]$evidence.SourceAttribute,[string]$evidence.TargetAttribute,[StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($evidence.Namespace -notin @('EmailAddress','Alias','ImmutableId','SecurityId')) { continue }
                $crossKey = '{0}|{1}|{2}|{3}|{4}' -f $candidate.SourceObjectKey,$candidate.TargetObjectKey,$evidence.Namespace,$evidence.SourceAttribute,$evidence.TargetAttribute
                if ($crossSeen.ContainsKey($crossKey)) { continue }
                $crossSeen[$crossKey] = $true
                $severity = 'Low'
                if ($candidate.Disposition -eq 'Blocked - Ambiguous') { $severity = 'High' }
                elseif ($evidence.Namespace -eq 'EmailAddress') { $severity = 'Medium' }
                elseif ($evidence.Namespace -in @('ImmutableId','SecurityId')) { $severity = 'Low' }
                $collisions.Add((New-McuCollisionRecord -Values @{
                    Severity=$severity; Category='CrossAttributeAnchorMatch'; Scope='CrossEnvironment'; AnchorNamespace=$evidence.Namespace; AnchorValue=$evidence.Value; SourceAttribute=$evidence.SourceAttribute; TargetAttribute=$evidence.TargetAttribute;
                    SourceObjectCount=1; SourceObjectIds=$candidate.SourceObjectId; SourceUPNs=$candidate.SourceUPN; SourceDisplayNames=$candidate.SourceDisplayName;
                    TargetObjectCount=1; TargetObjectIds=$candidate.TargetObjectId; TargetUPNs=$candidate.TargetUPN; TargetDisplayNames=$candidate.TargetDisplayName; CandidateCount=$candidate.SourceCandidateCount;
                    Evidence=$candidate.Evidence;
                    Details="The same anchor value appears in different source and target attributes ($($evidence.SourceAttribute) to $($evidence.TargetAttribute)).";
                    RecommendedAction='Confirm that the cross-attribute match is intentional and does not point to a stale alias or the wrong target object.'
                })) | Out-Null
            }
        }
    }

    $unmatched = [System.Collections.Generic.List[object]]::new()
    foreach ($sourceObject in $sourceObjects) {
        if ($candidatesBySource.ContainsKey($sourceObject.ObjectKey)) { continue }
        $objectAnchors = @($sourceAnchors | Where-Object { $_.ObjectKey -eq $sourceObject.ObjectKey })
        $unmatched.Add([pscustomobject][ordered]@{
            SourceObjectId       = $sourceObject.ObjectId
            SourceDisplayName    = $sourceObject.DisplayName
            SourceUPN            = $sourceObject.UserPrincipalName
            SourceSamAccountName = $sourceObject.SamAccountName
            SourceDirectoryType  = $sourceObject.DirectoryType
            AnchorCount          = $objectAnchors.Count
            AnchorSummary        = (@($objectAnchors | ForEach-Object { '{0}: {1}' -f $_.Attribute,$_.Value }) -join '; ')
            RecommendedAction    = 'Verify whether a target object should exist, then provide a controlled explicit mapping if automatic anchors cannot identify one.'
        }) | Out-Null
    }

    $collisionRows = @($collisions.ToArray() | Sort-Object @{Expression={ Get-McuSeverityRank -Severity $_.Severity }},Category,Scope,AnchorNamespace,AnchorValue,SourceObjectIds,TargetObjectIds)
    $candidateRows = @($candidates.ToArray() | Sort-Object @{Expression={ [int]$_.Score };Descending=$true},SourceUPN,TargetUPN,SourceObjectId,TargetObjectId)
    $ambiguousRows = @($ambiguousMappings.ToArray() | Sort-Object @{Expression={ Get-McuSeverityRank -Severity $_.Severity }},AmbiguityType,SourceUPN,TargetUPN,SourceObjectId,TargetObjectId)
    $qualityRows = @($qualityIssues.ToArray() | Sort-Object @{Expression={ Get-McuSeverityRank -Severity $_.Severity }},Side,Category,RowNumber,ObjectId)
    $unmatchedRows = @($unmatched.ToArray() | Sort-Object SourceUPN,SourceObjectId)

    $collisionNumber = 0
    foreach ($row in $collisionRows) {
        $collisionNumber++
        $row.CollisionId = 'COL-{0:D6}' -f $collisionNumber
    }
    $candidateNumber = 0
    foreach ($row in $candidateRows) { $candidateNumber++; $row.CandidateId = 'MAP-{0:D6}' -f $candidateNumber }
    $ambiguityNumber = 0
    foreach ($row in $ambiguousRows) { $ambiguityNumber++; $row.AmbiguityId = 'AMB-{0:D6}' -f $ambiguityNumber }
    $issueNumber = 0
    foreach ($row in $qualityRows) { $issueNumber++; $row.IssueId = 'ISS-{0:D6}' -f $issueNumber }

    $criticalCount = @($collisionRows | Where-Object Severity -eq 'Critical').Count
    $highCount = @($collisionRows | Where-Object Severity -eq 'High').Count
    $mediumCount = @($collisionRows | Where-Object Severity -eq 'Medium').Count
    $lowCount = @($collisionRows | Where-Object Severity -eq 'Low').Count
    $recommendedCount = @($candidateRows | Where-Object Disposition -eq 'Recommended').Count
    $blockedCandidateCount = @($candidateRows | Where-Object Disposition -like 'Blocked*').Count

    $baseOutput = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputDirectory))
    if (-not (Test-Path -LiteralPath $baseOutput)) { New-Item -Path $baseOutput -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    $runFolder = Join-Path $baseOutput ('MappingCollision_{0}_{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),$runId.Substring(0,8))
    New-Item -Path $runFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null

    $collisionPath = Join-Path $runFolder 'CollisionDetails.csv'
    $candidatePath = Join-Path $runFolder 'MappingCandidates.csv'
    $ambiguousPath = Join-Path $runFolder 'AmbiguousMappings.csv'
    $qualityPath = Join-Path $runFolder 'InventoryQualityIssues.csv'
    $unmatchedPath = Join-Path $runFolder 'UnmatchedSourceObjects.csv'
    $manifestPath = Join-Path $runFolder 'RunManifest.json'
    $htmlPath = Join-Path $runFolder 'MappingCollisionSummary.html'

    $collisionColumns = @('CollisionId','Severity','Category','Scope','AnchorNamespace','AnchorValue','SourceAttribute','TargetAttribute','SourceObjectCount','SourceObjectIds','SourceUPNs','SourceDisplayNames','TargetObjectCount','TargetObjectIds','TargetUPNs','TargetDisplayNames','CandidateCount','Evidence','Details','RecommendedAction')
    $candidateColumns = @('CandidateId','Disposition','Confidence','Score','SourceObjectId','SourceDisplayName','SourceUPN','SourceSamAccountName','SourceDirectoryType','TargetObjectId','TargetDisplayName','TargetUPN','TargetSamAccountName','TargetDirectoryType','SourceCandidateCount','TargetClaimCount','HasStrongIdentity','InternalDuplicateEvidence','EvidenceCount','MatchedNamespaces','MatchedValues','Evidence')
    $ambiguousColumns = @('AmbiguityId','AmbiguityType','Severity','SourceObjectId','SourceDisplayName','SourceUPN','TargetObjectId','TargetDisplayName','TargetUPN','Score','Confidence','Evidence','RecommendedAction')
    $qualityColumns = @('IssueId','Severity','Side','Category','RowNumber','ObjectId','UserPrincipalName','DisplayName','Attribute','Value','Details','RecommendedAction')
    $unmatchedColumns = @('SourceObjectId','SourceDisplayName','SourceUPN','SourceSamAccountName','SourceDirectoryType','AnchorCount','AnchorSummary','RecommendedAction')

    Export-McuCsv -Path $collisionPath -Rows $collisionRows -Columns $collisionColumns
    Export-McuCsv -Path $candidatePath -Rows $candidateRows -Columns $candidateColumns
    Export-McuCsv -Path $ambiguousPath -Rows $ambiguousRows -Columns $ambiguousColumns
    Export-McuCsv -Path $qualityPath -Rows $qualityRows -Columns $qualityColumns
    Export-McuCsv -Path $unmatchedPath -Rows $unmatchedRows -Columns $unmatchedColumns

    $completed = [DateTime]::UtcNow
    $summary = [pscustomobject][ordered]@{
        RunId                  = $runId
        EngineVersion          = $script:McuEngineVersion
        StartedAtUtc           = $started.ToString('o')
        CompletedAtUtc         = $completed.ToString('o')
        DurationSeconds        = [Math]::Round(($completed - $started).TotalSeconds,3)
        SourceObjectCount      = $sourceObjects.Count
        TargetObjectCount      = $targetObjects.Count
        SourceAnchorCount      = $sourceAnchors.Count
        TargetAnchorCount      = $targetAnchors.Count
        CollisionCount         = $collisionRows.Count
        CriticalCollisionCount = $criticalCount
        HighCollisionCount     = $highCount
        MediumCollisionCount   = $mediumCount
        LowCollisionCount      = $lowCount
        CandidateCount         = $candidateRows.Count
        RecommendedCount       = $recommendedCount
        BlockedCandidateCount  = $blockedCandidateCount
        AmbiguousMappingCount  = $ambiguousRows.Count
        QualityIssueCount      = $qualityRows.Count
        UnmatchedSourceCount   = $unmatchedRows.Count
        CandidatePairCapReached = $pairCapReached
    }

    $criticalHigh = @($collisionRows | Where-Object { $_.Severity -in @('Critical','High') } | Sort-Object @{Expression={ Get-McuSeverityRank -Severity $_.Severity }},Category | Select-Object -First 500)
    $recommended = @($candidateRows | Where-Object Disposition -eq 'Recommended' | Select-Object -First 500)
    $blocked = @($candidateRows | Where-Object Disposition -like 'Blocked*' | Select-Object -First 500)
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Mapping Collision Summary</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f6fbfe;color:#273142}.header{background:#2e4778;color:#fff;padding:24px 32px}.header h1{margin:0;font-size:28px}.header p{margin:7px 0 0;color:#dce8ff}.content{padding:24px 32px}.metrics{display:grid;grid-template-columns:repeat(6,minmax(140px,1fr));gap:12px;margin-bottom:22px}.metric{background:#fff;border:1px solid #d0d8e5;border-radius:7px;padding:14px;box-shadow:0 1px 7px #00000018}.metric .label{color:#657086;font-size:12px}.metric .value{font-size:27px;font-weight:600;color:#2e4778;margin-top:4px}.critical .value{color:#b54343}.warning .value{color:#a86b18}section{background:#fff;border:1px solid #d0d8e5;border-radius:7px;padding:18px;margin:0 0 18px;box-shadow:0 1px 7px #00000012}h2{margin:0 0 12px;color:#2e4778}table{border-collapse:collapse;width:100%;font-size:12px}th,td{border:1px solid #d0d8e5;padding:6px 8px;text-align:left;vertical-align:top}th{background:#e8f7fb;color:#2e4778;position:sticky;top:0}.note,.empty{color:#657086}.notice{background:#fff5df;border:1px solid #e3b76a;border-radius:7px;padding:12px;margin-bottom:18px}.paths code{word-break:break-all}footer{color:#657086;font-size:12px;padding:0 32px 24px}</style>
</head>
<body>
<div class="header"><h1>Mapping Collision Summary</h1><p>Run $runId | Completed $($completed.ToString('u')) UTC</p></div>
<div class="content">
<div class="notice"><strong>Advisory output:</strong> A recommended candidate is not authorization to map. Validate the object owner, migration scope, and target state before importing any mapping.</div>
<div class="metrics">
<div class="metric"><div class="label">Source objects</div><div class="value">$($sourceObjects.Count)</div></div>
<div class="metric"><div class="label">Target objects</div><div class="value">$($targetObjects.Count)</div></div>
<div class="metric critical"><div class="label">Critical collisions</div><div class="value">$criticalCount</div></div>
<div class="metric warning"><div class="label">High collisions</div><div class="value">$highCount</div></div>
<div class="metric"><div class="label">Ambiguous mappings</div><div class="value">$($ambiguousRows.Count)</div></div>
<div class="metric"><div class="label">Recommended candidates</div><div class="value">$recommendedCount</div></div>
</div>
<section><h2>Critical and high collisions</h2>$(ConvertTo-McuHtmlFragment -Rows $criticalHigh -Columns @('CollisionId','Severity','Category','AnchorNamespace','AnchorValue','SourceUPNs','TargetUPNs','Details','RecommendedAction'))</section>
<section><h2>Ambiguous mappings</h2>$(ConvertTo-McuHtmlFragment -Rows $ambiguousRows -Columns @('AmbiguityId','AmbiguityType','Severity','SourceUPN','TargetUPN','Score','Evidence','RecommendedAction'))</section>
<section><h2>Blocked candidates</h2>$(ConvertTo-McuHtmlFragment -Rows $blocked -Columns @('CandidateId','Disposition','Score','SourceUPN','TargetUPN','SourceCandidateCount','TargetClaimCount','Evidence'))</section>
<section><h2>Recommended candidates</h2>$(ConvertTo-McuHtmlFragment -Rows $recommended -Columns @('CandidateId','Disposition','Score','SourceUPN','TargetUPN','MatchedNamespaces','MatchedValues','Evidence'))</section>
<section><h2>Inventory quality issues</h2>$(ConvertTo-McuHtmlFragment -Rows $qualityRows -Columns @('IssueId','Severity','Side','Category','RowNumber','UserPrincipalName','Attribute','Value','Details','RecommendedAction'))</section>
<section class="paths"><h2>Output files</h2><p><code>$collisionPath</code></p><p><code>$candidatePath</code></p><p><code>$ambiguousPath</code></p><p><code>$qualityPath</code></p><p><code>$unmatchedPath</code></p><p><code>$manifestPath</code></p></section>
</div>
<footer>Quest ODM Mapping Collision Utility $($script:McuEngineVersion). Read-only analysis; no Quest, Active Directory, or Entra object is modified.</footer>
</body>
</html>
"@
    [IO.File]::WriteAllText($htmlPath,$html,(New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))

    $reportFiles = @(
        [ordered]@{Name='CollisionDetails.csv';ReportType='CollisionDetails';Path=$collisionPath;RowCount=$collisionRows.Count;Sha256=(Get-McuFileHash -Path $collisionPath)},
        [ordered]@{Name='MappingCandidates.csv';ReportType='MappingCandidates';Path=$candidatePath;RowCount=$candidateRows.Count;Sha256=(Get-McuFileHash -Path $candidatePath)},
        [ordered]@{Name='AmbiguousMappings.csv';ReportType='AmbiguousMappings';Path=$ambiguousPath;RowCount=$ambiguousRows.Count;Sha256=(Get-McuFileHash -Path $ambiguousPath)},
        [ordered]@{Name='InventoryQualityIssues.csv';ReportType='InventoryQualityIssues';Path=$qualityPath;RowCount=$qualityRows.Count;Sha256=(Get-McuFileHash -Path $qualityPath)},
        [ordered]@{Name='UnmatchedSourceObjects.csv';ReportType='UnmatchedSourceObjects';Path=$unmatchedPath;RowCount=$unmatchedRows.Count;Sha256=(Get-McuFileHash -Path $unmatchedPath)},
        [ordered]@{Name='MappingCollisionSummary.html';ReportType='HtmlSummary';Path=$htmlPath;RowCount=$null;Sha256=(Get-McuFileHash -Path $htmlPath)}
    )
    $manifest = [ordered]@{
        Product='Quest ODM Mapping Collision Utility'
        EngineVersion=$script:McuEngineVersion
        SchemaVersion=$script:McuSchemaVersion
        HashAlgorithm='SHA256'
        RunId=$runId
        StartedAtUtc=$started.ToString('o')
        CompletedAtUtc=$completed.ToString('o')
        Source=[ordered]@{Path=$sourceInventory.Path;Sha256=$sourceInventory.Hash;ObjectCount=$sourceObjects.Count;AnchorCount=$sourceAnchors.Count}
        Target=[ordered]@{Path=$targetInventory.Path;Sha256=$targetInventory.Hash;ObjectCount=$targetObjects.Count;AnchorCount=$targetAnchors.Count}
        Options=$effectiveOptions
        Summary=$summary
        Reports=[ordered]@{CollisionDetails=$collisionPath;MappingCandidates=$candidatePath;AmbiguousMappings=$ambiguousPath;InventoryQualityIssues=$qualityPath;UnmatchedSourceObjects=$unmatchedPath;HtmlSummary=$htmlPath;RunManifest=$manifestPath}
        ReportFiles=$reportFiles
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    return [pscustomobject][ordered]@{
        RunId                 = $runId
        Summary               = $summary
        Collisions            = $collisionRows
        MappingCandidates     = $candidateRows
        AmbiguousMappings     = $ambiguousRows
        InventoryQualityIssues = $qualityRows
        UnmatchedSourceObjects = $unmatchedRows
        Reports               = [pscustomobject][ordered]@{
            OutputDirectory       = $runFolder
            CollisionDetails      = $collisionPath
            MappingCandidates     = $candidatePath
            AmbiguousMappings     = $ambiguousPath
            InventoryQualityIssues = $qualityPath
            UnmatchedSourceObjects = $unmatchedPath
            Manifest              = $manifestPath
            HtmlSummary           = $htmlPath
        }
    }
}

Export-ModuleMember -Function Invoke-MappingCollisionAnalysis
