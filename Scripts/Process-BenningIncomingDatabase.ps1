param(
    [string]$ConfigPath,

    [string]$IncomingPath,

    [string]$SourceDeviceDbPath,

    [int]$PollSeconds = 5,

    [switch]$Json
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common-BenningAutomation.ps1"

function Wait-ForBenningWorkSession {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$PollSeconds,
        $Config
    )

    $hasObservedLock = $false
    Write-BenningLog -Config $Config -Message "Waiting for PC-Win to use and release database: $Path"

    while ($true) {
        $isFree = Test-BenningFileAccess -Path $Path -Access "ReadWrite"

        if (!$isFree) {
            $hasObservedLock = $true
        } elseif ($hasObservedLock) {
            Write-BenningLog -Config $Config -Message "Database was released by PC-Win: $Path"
            return
        }

        Start-Sleep -Seconds $PollSeconds
    }
}

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    $paths = Initialize-BenningFolders -Config $config
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    if ([string]::IsNullOrWhiteSpace($IncomingPath)) {
        $incomingItem = Get-ChildItem -LiteralPath $paths.Incoming -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if (!$incomingItem) {
            throw "No incoming database found in: $($paths.Incoming)"
        }

        $IncomingPath = $incomingItem.FullName
    }

    if (!(Test-Path -LiteralPath $IncomingPath)) {
        throw "Incoming database not found: $IncomingPath"
    }

    if ([string]::IsNullOrWhiteSpace($SourceDeviceDbPath)) {
        $SourceDeviceDbPath = (Find-BenningDeviceDatabase -Config $config).FullName
    }

    if (!(Test-Path -LiteralPath $SourceDeviceDbPath)) {
        throw "Source device database not found: $SourceDeviceDbPath"
    }

    $incomingItem = Get-Item -LiteralPath $IncomingPath
    $workDbPath = Join-Path $paths.Db $incomingItem.Name

    if (Test-Path -LiteralPath $workDbPath) {
        throw "Working database already exists in DB folder: $workDbPath"
    }

    Move-Item -LiteralPath $incomingItem.FullName -Destination $workDbPath
    Write-BenningLog -Config $config -Message "Moved incoming database to DB folder: $workDbPath"

    if (Test-BenningProgramRunning -Config $config) {
        Show-BenningToastNotification -Config $config -Title "BENNING database ready" -Message "Open and edit database: $workDbPath" | Out-Null
    } else {
        Start-BenningProgram -Config $config -DatabasePath $workDbPath
    }

    Wait-ForBenningWorkSession -Path $workDbPath -PollSeconds $PollSeconds -Config $config

    Wait-BenningFileAccess -Config $config -Path $SourceDeviceDbPath -Access "ReadWrite" -Purpose "archive original SD database"
    Wait-BenningFileAccess -Config $config -Path $workDbPath -Access "Read" -Purpose "copy changed working database back to SD"

    $sourceItem = Get-Item -LiteralPath $SourceDeviceDbPath
    $archiveOriginalPath = Join-Path $paths.Archive ("{0}_sd_original_{1}" -f $timestamp, $sourceItem.Name)
    $archiveChangedPath = Join-Path $paths.Archive ("{0}_pcwin_changed_{1}" -f $timestamp, $incomingItem.Name)

    $originalMovedToArchive = $false
    try {
        Move-Item -LiteralPath $SourceDeviceDbPath -Destination $archiveOriginalPath -Force
        $originalMovedToArchive = $true

        Copy-Item -LiteralPath $workDbPath -Destination $SourceDeviceDbPath -Force
        Move-Item -LiteralPath $workDbPath -Destination $archiveChangedPath -Force
    } catch {
        if ($originalMovedToArchive -and !(Test-Path -LiteralPath $SourceDeviceDbPath) -and (Test-Path -LiteralPath $archiveOriginalPath)) {
            Copy-Item -LiteralPath $archiveOriginalPath -Destination $SourceDeviceDbPath -Force
            Write-BenningLog -Config $config -Level "WARN" -Message "Restored original SD database after write-back failure: $SourceDeviceDbPath"
        }

        throw
    }

    $newHash = Get-BenningFileHash -Path $SourceDeviceDbPath
    $deviceStateHashFile = Get-BenningDeviceStateHashPath -Config $config -DeviceDatabaseName $sourceItem.Name
    $deviceStateMetadataFile = Get-BenningDeviceStateMetadataPath -Config $config -DeviceDatabaseName $sourceItem.Name
    $newHash | Set-Content -LiteralPath $paths.StateHashFile -Encoding ASCII
    $newHash | Set-Content -LiteralPath $deviceStateHashFile -Encoding ASCII
    Get-BenningFileMetadata -File (Get-Item -LiteralPath $SourceDeviceDbPath) |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $deviceStateMetadataFile -Encoding UTF8

    Write-BenningLog -Config $config -Message "Archived original SD database: $archiveOriginalPath"
    Write-BenningLog -Config $config -Message "Copied changed database back to SD: $SourceDeviceDbPath"
    Write-BenningLog -Config $config -Message "Archived changed working database: $archiveChangedPath"
    Show-BenningToastNotification -Config $config -Title "BENNING database written back" -Message "Updated database was copied back to SD: $($sourceItem.Name)" | Out-Null

    if ($Json) {
        [pscustomobject]@{
            Success = $true
            SourceDeviceDbPath = $SourceDeviceDbPath
            ArchivedOriginalPath = $archiveOriginalPath
            ArchivedChangedPath = $archiveChangedPath
            Hash = $newHash
        } | ConvertTo-Json -Depth 4
    }
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message "Incoming database processing failed: $($_.Exception.Message)"
        Show-BenningMessage -Config $config -Icon "Error" -Message "BENNING database processing failed.`n`n$($_.Exception.Message)`n`nError log: $($paths.LogFile)"
    }

    throw
}
