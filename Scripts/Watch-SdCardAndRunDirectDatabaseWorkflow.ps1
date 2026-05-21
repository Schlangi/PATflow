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

    $output = & powershell.exe @arguments
    if (!$output) {
        return $null
    }

    return ($output | Out-String | ConvertFrom-Json)
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
    $pollSeconds = Get-ImportWatcherPollSeconds -Config $config
    Write-BenningLog -Config $config -Message "Starting BENNING import watcher. Poll seconds: $pollSeconds"

    do {
        try {
            $result = Invoke-BenningPrepareOnce -ConfigPath $config.ConfigPath

            if ($result -and $result.NoDeviceDatabase) {
                continue
            }

            if ($result -and $result.Success -and $result.Changed) {
                $fileName = Split-Path -Leaf $result.DeviceDbPath
                $message = "New data is ready to import from database: $fileName"
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
}
