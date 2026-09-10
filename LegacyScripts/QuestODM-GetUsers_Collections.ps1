<#
Identify-OdmUserCollectionMembership.ps1

Goal:
- Input: CSV of Source UPNs
- Output: CSV mapping each user -> collections they are currently in
- Also outputs a "RemovalPlan" CSV you can feed into a removal script
  (CollectionId + ObjectId)

How it works:
- Builds a lookup of ODM objects from Accounts workload
  (SourceUserPrincipalName / SourceEmail)
- Pulls ALL collections once
- For each collection, gets its objects (Get-OdmObject -All) and
  intersects with your input users
- Exports:
    1) UserCollectionMembership_<timestamp>.csv (human-friendly)
    2) RemovalPlan_Collections_<timestamp>.csv (machine-friendly)
    3) UnresolvedUPNs_<timestamp>.csv (if any input UPNs not found in ODM)

Run in Windows PowerShell 5.1 (OdmApi types are required).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("US","EU","AU","CA","UK","us","eu","au","ca","uk")]
    [string]$Region,

    [Parameter(Mandatory)]
    [string]$OrganizationId,

    [Parameter(Mandatory)]
    [string]$ProjectId,

    # Use Accounts workload id if you are resolving users from the Accounts workload
    [Parameter(Mandatory)]
    [string]$AccountsProjectWorkloadId,

    # CSV containing SourceUPN (preferred) or UPN/UserPrincipalName
    [Parameter(Mandatory)]
    [string]$UserCsvPath,

    # Optional: restrict to collections with names matching these regex patterns
    [string[]]$CollectionNamePatterns = @(),

    # Output folder
    [string]$OutDir = "C:\Temp\ODM_Reports"
)

function Get-UpnFromRow {
    param($Row)

    foreach ($col in @("SourceUPN","UserPrincipalName","UPN","SourceUserPrincipalName","SourceUpn")) {
        if ($Row.PSObject.Properties.Name -contains $col) {
            $v = $Row.$col
            if ($v -and $v.ToString().Trim()) {
                return $v.ToString().Trim().ToLower()
            }
        }
    }

    return $null
}

function Add-LookupEntry {
    param(
        [hashtable]$Lookup,
        [string]$Key,
        $Obj
    )

    if ([string]::IsNullOrWhiteSpace($Key)) { return }

    $k = $Key.Trim().ToLower()
    if (-not $Lookup.ContainsKey($k)) {
        $Lookup[$k] = $Obj
    }
}

# --- Preflight ---
if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw "Run in Windows PowerShell 5.1."
}

if (-not (Test-Path $UserCsvPath)) {
    throw "User CSV not found: $UserCsvPath"
}

if (-not (Test-Path $OutDir)) {
    New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$membershipPath = Join-Path $OutDir "UserCollectionMembership_$stamp.csv"
$removalPlanPath = Join-Path $OutDir "RemovalPlan_Collections_$stamp.csv"
$unresolvedPath = Join-Path $OutDir "UnresolvedUPNs_$stamp.csv"

# --- Connect + context ---
Connect-OdmService -Region $Region.ToLower() | Out-Null
Select-OdmOrganization -OrganizationId $OrganizationId | Out-Null

$proj = Get-OdmProject | Where-Object { $_.Id -eq $ProjectId }
if (-not $proj) {
    throw "Project with Id '$ProjectId' not found."
}

Select-OdmProjectWorkload -ProjectWorkloadId $AccountsProjectWorkloadId | Out-Null

# --- Load input UPNs (dedupe) ---
$csv = Import-Csv -Path $UserCsvPath
if (-not $csv) {
    throw "CSV empty/unreadable: $UserCsvPath"
}

$upns = $csv |
    ForEach-Object { Get-UpnFromRow $_ } |
    Where-Object { $_ } |
    Sort-Object -Unique

if (-not $upns -or $upns.Count -eq 0) {
    throw "No UPNs found. Need SourceUPN/UPN/UserPrincipalName column."
}

Write-Host "Input UPNs: $($upns.Count)"

# --- Build object lookup from Accounts workload ---
Write-Host "Loading ODM objects (Accounts workload)..." -ForegroundColor Cyan

$allObjects = @()
try {
    $allObjects = Get-OdmObject -All
}
catch {
    $allObjects = Get-OdmObject
}

if (-not $allObjects -or $allObjects.Count -eq 0) {
    throw "Get-OdmObject returned 0 objects. Wrong context?"
}

$lookup = @{}
foreach ($o in $allObjects) {
    foreach ($p in @("SourceUserPrincipalName","SourceEmail")) {
        if ($o.PSObject.Properties.Name -contains $p) {
            $val = $o.$p
            if ($val) {
                Add-LookupEntry -Lookup $lookup -Key $val -Obj $o
            }
        }
    }
}

# --- Resolve input UPNs -> ODM objects ---
$resolved = New-Object System.Collections.Generic.List[object]
$unresolved = New-Object System.Collections.Generic.List[object]

foreach ($u in $upns) {
    if ($lookup.ContainsKey($u)) {
        $obj = $lookup[$u]
        $resolved.Add([pscustomobject]@{
            SourceUPN = $u
            ObjectId  = $obj.Id
            Object    = $obj
        }) | Out-Null
    }
    else {
        $unresolved.Add([pscustomobject]@{
            SourceUPN = $u
        }) | Out-Null
    }
}

Write-Host "Resolved:   $($resolved.Count)" -ForegroundColor Green
Write-Host "Unresolved: $($unresolved.Count)" -ForegroundColor Yellow

if ($unresolved.Count -gt 0) {
    $unresolved |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path $unresolvedPath
    Write-Host "Unresolved exported: $unresolvedPath" -ForegroundColor Yellow
}

if ($resolved.Count -eq 0) {
    throw "No UPNs resolved to ODM objects."
}

# --- Build fast set of ObjectIds we care about ---
$targetIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($r in $resolved) {
    [void]$targetIds.Add([string]$r.ObjectId)
}

# Map ObjectId -> SourceUPN for reporting
$idToUpn = @{}
foreach ($r in $resolved) {
    $idToUpn[[string]$r.ObjectId] = $r.SourceUPN
}

# --- Pull collections ---
Write-Host "Loading collections..." -ForegroundColor Cyan

$collections = @()
try {
    $collections = Get-OdmCollection -All
}
catch {
    $collections = Get-OdmCollection
}

if (-not $collections) {
    throw "No collections returned."
}

if ($CollectionNamePatterns -and $CollectionNamePatterns.Count -gt 0) {
    $collections = $collections | Where-Object {
        $n = $_.Name
        foreach ($pat in $CollectionNamePatterns) {
            if ($n -match $pat) { return $true }
        }
        return $false
    }
    Write-Host "Collections after name filtering: $($collections.Count)"
}
else {
    Write-Host "Collections returned: $($collections.Count)"
}

# --- Scan collection memberships ---
$membershipRows = New-Object System.Collections.Generic.List[object]
$removalRows    = New-Object System.Collections.Generic.List[object]

$collectionIndex = 0
foreach ($c in $collections) {
    $collectionIndex++

    if ($collectionIndex % 25 -eq 0) {
        Write-Host "Scanning collection $collectionIndex / $($collections.Count)..."
    }

    $collectionObjs = @()
    try {
        $collectionObjs = $c | Get-OdmObject -All
    }
    catch {
        continue
    }

    if (-not $collectionObjs) { continue }

    foreach ($o in $collectionObjs) {
        if (-not $o.Id) { continue }

        $oid = [string]$o.Id
        if ($targetIds.Contains($oid)) {
            $upn = $idToUpn[$oid]

            $membershipRows.Add([pscustomobject]@{
                SourceUPN      = $upn
                ObjectId       = $oid
                CollectionName = $c.Name
                CollectionId   = $c.Id
            }) | Out-Null

            $removalRows.Add([pscustomobject]@{
                CollectionId   = $c.Id
                CollectionName = $c.Name
                ObjectId       = $oid
                SourceUPN      = $upn
            }) | Out-Null
        }
    }
}

# --- Export outputs ---
$membershipRows |
    Sort-Object SourceUPN, CollectionName |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $membershipPath

$removalRows |
    Sort-Object CollectionName, SourceUPN |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $removalPlanPath

Write-Host ""
Write-Host "Exported:" -ForegroundColor Green
Write-Host "  Membership report: $membershipPath"
Write-Host "  Removal plan:      $removalPlanPath"
Write-Host ""

Write-Host "Next step: use RemovalPlan CSV with a remove script to remove ObjectId from CollectionId (without deleting the collections)."