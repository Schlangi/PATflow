param(
    [string]$ConfigPath,
    [switch]$Once
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Shared-BenningAutomationFunctions.ps1"

function Get-ImportWatcherPollSeconds {
    param($Config)

    if ($Config.ImportWatcher.PollSeconds -and [int]$Config.ImportWatcher.PollSeconds -gt 0) {
        return [int]$Config.ImportWatcher.PollSeconds
    }

    return 10
}

function Invoke-BenningPrepareOnce {
    param($ConfigPath)

    $prepareScript = Join-Path $PSScriptRoot "Copy-DeviceDatabaseFromSdToIncoming.ps1"
    $arguments = @("-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $prepareScript, "-Json", "-SkipUnchanged", "-SuppressErrorMessage")
    if ($ConfigPath) {
        $arguments += @("-ConfigPath", $ConfigPath)
    }

    $output = & powershell.exe @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()

    if ($exitCode -ne 0) {
        throw "Prepare script failed with exit code $exitCode. Output: $outputText"
    }

    if (!$outputText) {
        return $null
    }

    try {
        return ($outputText | ConvertFrom-Json)
    } catch {
        throw "Prepare script did not return valid JSON. Output: $outputText"
    }
}

function Invoke-BenningIncomingProcessor {
    param(
        $ConfigPath,
        [Parameter(Mandatory = $true)]$PrepareResult
    )

    $processorScript = Join-Path $PSScriptRoot "Move-IncomingDatabaseToDbStartPcWinAndWriteBackToSd.ps1"
    $arguments = @(
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle",
        "Hidden",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$processorScript`"",
        "-IncomingPath",
        "`"$($PrepareResult.DeviceDbPath)`"",
        "-SourceDeviceDbPath",
        "`"$($PrepareResult.SourceDeviceDbPath)`""
    )

    if ($ConfigPath) {
        $arguments += @("-ConfigPath", "`"$ConfigPath`"")
    }

    Start-Process -FilePath "powershell.exe" -ArgumentList ($arguments -join " ") -WindowStyle Hidden
}

function Wait-BenningImportWatcherPoll {
    param(
        [switch]$Once,
        [int]$PollSeconds
    )

    if (!$Once) {
        Start-Sleep -Seconds $PollSeconds
    }
}

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    Initialize-BenningFolders -Config $config | Out-Null
    $watcherMutexCreated = $false
    try {
        $watcherMutex = [System.Threading.Mutex]::new($true, "Global\PATflowBenningSdWatcher", [ref]$watcherMutexCreated)
    } catch {
        Write-BenningLog -Config $config -Level "WARN" -Message "Global SD watcher mutex could not be created, falling back to local mutex: $($_.Exception.Message)"
        $watcherMutex = [System.Threading.Mutex]::new($true, "Local\PATflowBenningSdWatcher", [ref]$watcherMutexCreated)
    }
    if (!$watcherMutexCreated) {
        Write-BenningLog -Config $config -Level "WARN" -Message "SD card workflow watcher is already running. Exiting duplicate watcher instance."
        return
    }

    $pollSeconds = Get-ImportWatcherPollSeconds -Config $config
    $handledDeviceNames = @{}
    $handledChangedHashes = @{}
    $waitingForSdNotified = $false
    Write-BenningLog -Config $config -Message "Starting BENNING import watcher. Poll seconds: $pollSeconds"
    Set-BenningStatus -Config $config -Workflow "Database" -State "WaitingForSdCard" -Message "Waiting for SD card."
    Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung" -Message "Warte auf SD Karte"
    $waitingForSdNotified = $true

    do {
        try {
            if (Test-BenningSdWriteInProgress -Config $config) {
                Write-BenningLog -Config $config -Message "SD write is in progress, skipping watcher cycle."
                Wait-BenningImportWatcherPoll -Once:$Once -PollSeconds $pollSeconds
                continue
            }

            $result = Invoke-BenningPrepareOnce -ConfigPath $config.ConfigPath

            if ($result -and $result.NoDeviceDatabase) {
                $handledDeviceNames.Clear()
                $handledChangedHashes.Clear()
                if (!$waitingForSdNotified) {
                    Set-BenningStatus -Config $config -Workflow "Database" -State "WaitingForSdCard" -Message "Waiting for SD card."
                    Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung" -Message "Warte auf SD Karte"
                    $waitingForSdNotified = $true
                }

                Wait-BenningImportWatcherPoll -Once:$Once -PollSeconds $pollSeconds
                continue
            }

            if ($result -and $result.Success -and $result.SourceDeviceDbPath) {
                $waitingForSdNotified = $false
                $fileName = Split-Path -Leaf $result.SourceDeviceDbPath
                $resultHash = [string]$result.Hash

                if ($result.Changed) {
                    if ($resultHash -and $handledChangedHashes.ContainsKey($fileName) -and $handledChangedHashes[$fileName] -eq $resultHash) {
                        Write-BenningLog -Config $config -Message "Changed database was already handed to the direct workflow during this SD session, skipping cycle: $fileName"
                        Wait-BenningImportWatcherPoll -Once:$Once -PollSeconds $pollSeconds
                        continue
                    }
                } elseif ($handledDeviceNames.ContainsKey($fileName)) {
                    Write-BenningLog -Config $config -Message "Unchanged database was already handled during this SD session, skipping cycle: $fileName"
                    Wait-BenningImportWatcherPoll -Once:$Once -PollSeconds $pollSeconds
                    continue
                }

                if (Test-BenningDirectWorkflowRunning -Config $config -DeviceDatabaseName $fileName) {
                    Write-BenningLog -Config $config -Message "Direct workflow already running for database, skipping cycle: $fileName"
                    Wait-BenningImportWatcherPoll -Once:$Once -PollSeconds $pollSeconds
                    continue
                }

                $handledDeviceNames[$fileName] = $true
                if ($result.Changed -and $resultHash) {
                    $handledChangedHashes[$fileName] = $resultHash
                }

                if ($result.Changed) {
                    $message = "New data is ready to process from database: $fileName"
                } else {
                    $message = "Device database is present and unchanged; starting direct workflow: $fileName"
                }

                Write-BenningLog -Config $config -Message $message

                if (Test-BenningConfigSwitch -Value $config.ImportWatcher.ProcessIncomingDirectly -Default $true) {
                    Set-BenningStatus -Config $config -Workflow "Database" -State "StartingPcWin" -Message "Starting PC-Win."
                    Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung" -Message "Starte PC Win"
                    Invoke-BenningIncomingProcessor -ConfigPath $config.ConfigPath -PrepareResult $result
                } elseif (Test-BenningProgramRunning -Config $config) {
                    if (Test-BenningConfigSwitch -Value $config.ImportWatcher.NotifyWhenBenningIsAlreadyRunning -Default $true) {
                        Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung" -Message ("Neue Daten zum Importieren gefunden: {0}" -f $fileName)
                    }
                } elseif (Test-BenningConfigSwitch -Value $config.ImportWatcher.StartBenningWhenNewDataArrives -Default $true) {
                    Start-BenningProgram -Config $config
                }
            }
        } catch {
            Write-BenningLog -Config $config -Level "ERROR" -Message "Import watcher cycle failed: $($_.Exception.Message)"
            Set-BenningStatus -Config $config -Workflow "Database" -State "Error" -Message "Database watcher cycle failed." -ErrorMessage $_.Exception.Message
            Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung Fehler" -Message "Fehler im Datenbank-Watcher. Details stehen im Log." -Error
        }

        if (!$Once) {
            Start-Sleep -Seconds $pollSeconds
        }
    } while (!$Once)
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message $_.Exception.Message
    }

    throw
} finally {
    if ($watcherMutexCreated -and $watcherMutex) {
        $watcherMutex.ReleaseMutex()
        $watcherMutex.Dispose()
    }
}
