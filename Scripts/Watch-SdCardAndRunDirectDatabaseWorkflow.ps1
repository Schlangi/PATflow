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
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $prepareScript, "-Json", "-SkipUnchanged", "-SuppressErrorMessage")
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

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    Initialize-BenningFolders -Config $config | Out-Null
    $watcherMutexCreated = $false
    $watcherMutex = [System.Threading.Mutex]::new($true, "Local\PATflowBenningSdWatcher", [ref]$watcherMutexCreated)
    if (!$watcherMutexCreated) {
        Write-BenningLog -Config $config -Level "WARN" -Message "SD card workflow watcher is already running. Exiting duplicate watcher instance."
        return
    }

    $pollSeconds = Get-ImportWatcherPollSeconds -Config $config
    $handledDeviceNames = @{}
    $handledChangedHashes = @{}
    Write-BenningLog -Config $config -Message "Starting BENNING import watcher. Poll seconds: $pollSeconds"

    do {
        try {
            if (Test-BenningSdWriteInProgress -Config $config) {
                Write-BenningLog -Config $config -Message "SD write is in progress, skipping watcher cycle."
                if (!$Once) {
                    Start-Sleep -Seconds $pollSeconds
                }

                continue
            }

            $result = Invoke-BenningPrepareOnce -ConfigPath $config.ConfigPath

            if ($result -and $result.NoDeviceDatabase) {
                $handledDeviceNames.Clear()
                $handledChangedHashes.Clear()
                continue
            }

            if ($result -and $result.Success -and $result.SourceDeviceDbPath) {
                $fileName = Split-Path -Leaf $result.SourceDeviceDbPath
                $resultHash = [string]$result.Hash

                if ($result.Changed) {
                    if ($resultHash -and $handledChangedHashes.ContainsKey($fileName) -and $handledChangedHashes[$fileName] -eq $resultHash) {
                        Write-BenningLog -Config $config -Message "Changed database was already handed to the direct workflow during this SD session, skipping cycle: $fileName"
                        continue
                    }
                } elseif ($handledDeviceNames.ContainsKey($fileName)) {
                    Write-BenningLog -Config $config -Message "Unchanged database was already handled during this SD session, skipping cycle: $fileName"
                    continue
                }

                if (Test-BenningDirectWorkflowRunning -Config $config -DeviceDatabaseName $fileName) {
                    Write-BenningLog -Config $config -Message "Direct workflow already running for database, skipping cycle: $fileName"
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
                    Invoke-BenningIncomingProcessor -ConfigPath $config.ConfigPath -PrepareResult $result
                } elseif (Test-BenningProgramRunning -Config $config) {
                    if (Test-BenningConfigSwitch -Value $config.ImportWatcher.NotifyWhenBenningIsAlreadyRunning -Default $true) {
                        Show-BenningToastNotification -Config $config -Title "BENNING import required" -Message $message | Out-Null
                    }
                } elseif (Test-BenningConfigSwitch -Value $config.ImportWatcher.StartBenningWhenNewDataArrives -Default $true) {
                    Start-BenningProgram -Config $config
                }
            }
        } catch {
            Write-BenningLog -Config $config -Level "ERROR" -Message "Import watcher cycle failed: $($_.Exception.Message)"
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
