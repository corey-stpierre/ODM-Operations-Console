# Paths
$InputCsv    = "C:\Temp\source-emails.csv"
$OutputCsv   = "C:\Temp\odm-matched-objects.csv"
$NotFoundCsv = "C:\Temp\odm-not-found.csv"

# CSV column containing the source email addresses
$EmailColumn = "SourceEmail"

# Import CSV
$csvRows = Import-Csv -Path $InputCsv

if (-not $csvRows) {
    throw "Input CSV is empty: $InputCsv"
}

if (-not ($csvRows[0].PSObject.Properties.Name -contains $EmailColumn)) {
    throw "CSV does not contain a column named '$EmailColumn'. Update `$EmailColumn in the script."
}

Write-Host "Loading ODM objects..."

$odmObjects = Get-OdmObject -All | Select-Object `
    Id,
    DisplayName,
    SourceUserPrincipalName,
    TargetUserPrincipalName,
    SourceEmail,
    TargetEmail,
    ObjectStatus

Write-Host "Building lookup table using SourceEmail..."

# Build a case-insensitive lookup by SourceEmail
$lookup = @{}

foreach ($obj in $odmObjects) {
    $sourceEmail = [string]$obj.SourceEmail

    if ([string]::IsNullOrWhiteSpace($sourceEmail)) {
        continue
    }

    $key = $sourceEmail.Trim().ToLowerInvariant()

    if (-not $lookup.ContainsKey($key)) {
        $lookup[$key] = New-Object System.Collections.ArrayList
    }

    [void]$lookup[$key].Add($obj)
}

$matched  = New-Object System.Collections.Generic.List[object]
$notFound = New-Object System.Collections.Generic.List[object]

Write-Host "Matching CSV email addresses..."

foreach ($row in $csvRows) {
    $inputEmail = [string]$row.PSObject.Properties[$EmailColumn].Value

    if ([string]::IsNullOrWhiteSpace($inputEmail)) {
        continue
    }

    $inputEmail = $inputEmail.Trim()
    $key = $inputEmail.ToLowerInvariant()

    if ($lookup.ContainsKey($key)) {
        foreach ($obj in $lookup[$key]) {
            $matched.Add([pscustomobject]@{
                InputSourceEmail        = $inputEmail
                Id                      = $obj.Id
                DisplayName             = $obj.DisplayName
                SourceUserPrincipalName = $obj.SourceUserPrincipalName
                TargetUserPrincipalName = $obj.TargetUserPrincipalName
                SourceEmail             = $obj.SourceEmail
                TargetEmail             = $obj.TargetEmail
                ObjectStatus            = $obj.ObjectStatus
            })
        }
    }
    else {
        $notFound.Add([pscustomobject]@{
            InputSourceEmail = $inputEmail
            Result           = "Not found"
        })
    }
}

Write-Host "Exporting matched objects to $OutputCsv"
$matched | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "Exporting not-found emails to $NotFoundCsv"
$notFound | Export-Csv -Path $NotFoundCsv -NoTypeInformation -Encoding UTF8

Write-Host "Done."
Write-Host "Matched:   $($matched.Count)"
Write-Host "Not found: $($notFound.Count)"