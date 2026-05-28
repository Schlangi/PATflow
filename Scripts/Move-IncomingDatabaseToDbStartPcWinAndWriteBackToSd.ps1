param(
    [string]$ConfigPath,

    [string]$IncomingPath,

    [string]$SourceDeviceDbPath,

    [int]$PollSeconds = 5,

    [switch]$Json
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Shared-BenningAutomationFunctions.ps1"

function Wait-ForBenningWorkSession {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$PollSeconds,
        $Config,
        [int]$StableReleaseSeconds = 15
    )

    $hasObservedLock = !(Test-BenningFileAccess -Path $Path -Access "ReadWrite")
    $releaseCandidateSince = $null
    $releaseCandidateLogged = $false
    $pcWinStillRunningLogged = $false
    Write-BenningLog -Config $Config -Message "Waiting for PC-Win to use and release database: $Path"
    if ($hasObservedLock) {
        Write-BenningLog -Config $Config -Message "Database is already locked by PC-Win: $Path"
    }

    while ($true) {
        $isFree = Test-BenningFileAccess -Path $Path -Access "ReadWrite"
        $isPcWinRunning = Test-BenningProgramRunning -Config $Config

        if (!$isFree) {
            $hasObservedLock = $true
            $releaseCandidateSince = $null
            $releaseCandidateLogged = $false
            $pcWinStillRunningLogged = $false
        } elseif ($hasObservedLock) {
            if ($isPcWinRunning) {
                if (!$pcWinStillRunningLogged) {
                    Write-BenningLog -Config $Config -Message "Database is currently accessible, but BENNING PC-Win is still running. Waiting for stable application close: $Path"
                    $pcWinStillRunningLogged = $true
                }

                $releaseCandidateSince = $null
                $releaseCandidateLogged = $false
            } else {
                if (!$releaseCandidateSince) {
                    $releaseCandidateSince = Get-Date
                }

                if (!$releaseCandidateLogged) {
                    Write-BenningLog -Config $Config -Message "Database release candidate detected. Waiting $StableReleaseSeconds seconds for stable release: $Path"
                    $releaseCandidateLogged = $true
                }

                if (((Get-Date) - $releaseCandidateSince).TotalSeconds -ge $StableReleaseSeconds) {
                    Write-BenningLog -Config $Config -Message "Database was released by PC-Win and stayed accessible for $StableReleaseSeconds seconds: $Path"
                    return
                }
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-BenningConfiguredMasterDbPath {
    param(
        $Config,
        [string]$FallbackPath
    )

    if (![string]::IsNullOrWhiteSpace($Config.MasterDbPath)) {
        return $Config.MasterDbPath
    }

    return $FallbackPath
}

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    $paths = Initialize-BenningFolders -Config $config
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $workflowStatePath = $null
    $sdWriteLockPath = $null

    if ([string]::IsNullOrWhiteSpace($IncomingPath)) {
        $incomingItem = Get-ChildItem -LiteralPath $paths.Incoming -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if (!$incomingItem) {
            throw "No incoming database found in: $($paths.Incoming)"
        }

        $IncomingPath = $incomingItem.FullName
    }

    if (![string]::IsNullOrWhiteSpace($IncomingPath) -and !(Test-Path -LiteralPath $IncomingPath)) {
        Write-BenningLog -Config $config -Message "Incoming database path is not present; continuing with DB/SD state: $IncomingPath"
    }

    if ([string]::IsNullOrWhiteSpace($SourceDeviceDbPath)) {
        $SourceDeviceDbPath = (Find-BenningDeviceDatabase -Config $config).FullName
    }

    if (!(Test-Path -LiteralPath $SourceDeviceDbPath)) {
        throw "Source device database not found: $SourceDeviceDbPath"
    }

    $sourceItem = Get-Item -LiteralPath $SourceDeviceDbPath
    $workflowStatePath = Get-BenningDirectWorkflowStatePath -Config $config -DeviceDatabaseName $sourceItem.Name
    "Started=$(Get-Date -Format o)`nDatabase=$($sourceItem.Name)" | Set-Content -LiteralPath $workflowStatePath -Encoding UTF8

    $incomingItem = $null
    if (![string]::IsNullOrWhiteSpace($IncomingPath) -and (Test-Path -LiteralPath $IncomingPath)) {
        $incomingItem = Get-Item -LiteralPath $IncomingPath
    }

    $databaseName = $sourceItem.Name
    if ($incomingItem) {
        $databaseName = $incomingItem.Name
    }

    $workDbPath = Get-BenningConfiguredMasterDbPath -Config $config -FallbackPath (Join-Path $paths.Db $databaseName)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $workDbPath) | Out-Null
    $workDbExists = Test-Path -LiteralPath $workDbPath

    if ($incomingItem -and $workDbExists) {
        if (!(Test-BenningFileAccess -Path $workDbPath -Access "ReadWrite")) {
            $message = "New SD data was copied to Incoming, but the master database is currently locked by PC-Win. Finish the current PC-Win workflow before importing new SD data. Incoming: $($incomingItem.FullName). Master DB: $workDbPath"
            Write-BenningLog -Config $config -Level "ERROR" -Message $message
            Set-BenningStatus -Config $config -Workflow "Database" -State "Error" -Message "New SD data cannot be imported because the master database is locked." -ErrorMessage $message
            Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung Fehler" -Message "Neue SD-Daten wurden gefunden, aber PC-Win sperrt die Datenbank. Bitte PC-Win zuerst schlie\u00dfen." -Error
            throw $message
        }

        $masterBackupPath = Join-Path $paths.Backups ("{0}_master_before_incoming_{1}" -f $timestamp, (Split-Path -Leaf $workDbPath))
        Copy-BenningFile -Config $config -SourcePath $workDbPath -DestinationPath $masterBackupPath -Purpose "master database backup before incoming replacement"
        Write-BenningLog -Config $config -Message "Master database backup before incoming replacement: $masterBackupPath"
    }

    if ($incomingItem) {
        Copy-BenningFile -Config $config -SourcePath $incomingItem.FullName -DestinationPath $workDbPath -Purpose "incoming database copy to master DB"
        Remove-Item -LiteralPath $incomingItem.FullName -Force
        Write-BenningLog -Config $config -Message "Copied incoming database to master DB path and removed incoming copy: $workDbPath"
    } elseif (!$workDbExists) {
        Copy-BenningFile -Config $config -SourcePath $sourceItem.FullName -DestinationPath $workDbPath -Purpose "unchanged SD database copy to master DB"
        Write-BenningLog -Config $config -Message "Copied unchanged SD database directly to master DB path: $workDbPath"
    } else {
        Write-BenningLog -Config $config -Message "Using existing master database in DB folder: $workDbPath"
    }

    if (Test-BenningProgramRunning -Config $config) {
        Write-BenningLog -Config $config -Message "BENNING PC-Win is already running."
    } else {
        Set-BenningStatus -Config $config -Workflow "Database" -State "StartingPcWin" -Message "Starting PC-Win."
        Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung" -Message "Starte PC Win"
        Start-BenningProgram -Config $config -DatabasePath $workDbPath
    }

    Set-BenningStatus -Config $config -Workflow "Database" -State "WaitingForChangedDatabase" -Message "Waiting for changed database."
    Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung" -Message "Warte auf ge\u00e4nderte Datenbank"
    Wait-ForBenningWorkSession -Path $workDbPath -PollSeconds $PollSeconds -Config $config

    Wait-BenningFileAccess -Config $config -Path $SourceDeviceDbPath -Access "ReadWrite" -Purpose "archive original SD database"
    Wait-BenningFileAccess -Config $config -Path $workDbPath -Access "Read" -Purpose "copy changed working database back to SD"

    $archiveOriginalPath = Join-Path $paths.Archive ("{0}_sd_original_{1}" -f $timestamp, $sourceItem.Name)
    $archiveChangedPath = Join-Path $paths.Archive ("{0}_pcwin_changed_{1}" -f $timestamp, (Split-Path -Leaf $workDbPath))

    $originalMovedToArchive = $false
    try {
        Set-BenningStatus -Config $config -Workflow "Database" -State "CopyingDatabaseToSdCard" -Message "Copying database to SD card. Please wait."
        Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung" -Message "Kopiere Datenbank auf SD Karte, bitte warten!"
        $sdWriteLockPath = Start-BenningSdWriteLock -Config $config -Reason "direct workflow write-back to SD: $SourceDeviceDbPath"
        Write-BenningLog -Config $config -Message "Write-back phase: archive original SD database. Source: $SourceDeviceDbPath Target: $archiveOriginalPath"
        Copy-BenningFile -Config $config -SourcePath $SourceDeviceDbPath -DestinationPath $archiveOriginalPath -Purpose "original SD database archive copy"
        $originalMovedToArchive = $true

        Write-BenningLog -Config $config -Message "Write-back phase: copy changed master database to SD. Source: $workDbPath Target: $SourceDeviceDbPath"
        Copy-BenningFile -Config $config -SourcePath $workDbPath -DestinationPath $SourceDeviceDbPath -Purpose "changed master database write-back to SD"
        Write-BenningLog -Config $config -Message "Write-back phase: archive changed master database. Source: $workDbPath Target: $archiveChangedPath"
        Copy-BenningFile -Config $config -SourcePath $workDbPath -DestinationPath $archiveChangedPath -Purpose "changed master database archive copy"
    } catch {
        if ($originalMovedToArchive -and !(Test-Path -LiteralPath $SourceDeviceDbPath) -and (Test-Path -LiteralPath $archiveOriginalPath)) {
            Copy-BenningFile -Config $config -SourcePath $archiveOriginalPath -DestinationPath $SourceDeviceDbPath -Purpose "restore original SD database after write-back failure"
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
    Write-BenningLog -Config $config -Message "Archived changed master database copy: $archiveChangedPath"
    Set-BenningStatus -Config $config -Workflow "Database" -State "DatabaseWrittenToSdCard" -Message "Database successfully written to SD card. Safely eject the device itself."
    Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung" -Message "Datenbank erfolgreich auf SD Karte geschrieben, Ger\u00e4t selbst sicher entfernen!"

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
        Write-BenningLog -Config $config -Level "ERROR" -Message "Incoming database processing failure type: $($_.Exception.GetType().FullName)"
        Write-BenningLog -Config $config -Level "ERROR" -Message "Incoming database processing stack trace: $($_.ScriptStackTrace)"
        Set-BenningStatus -Config $config -Workflow "Database" -State "Error" -Message "Database processing failed." -ErrorMessage $_.Exception.Message
        Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung Fehler" -Message "Fehler im Datenbank-Workflow. Details stehen im Log." -Error
    }

    throw
} finally {
    if ($workflowStatePath -and (Test-Path -LiteralPath $workflowStatePath)) {
        Remove-Item -LiteralPath $workflowStatePath -Force -ErrorAction SilentlyContinue
    }

    if ($config -and $sdWriteLockPath) {
        Stop-BenningSdWriteLock -Config $config -LockPath $sdWriteLockPath
    }
}
