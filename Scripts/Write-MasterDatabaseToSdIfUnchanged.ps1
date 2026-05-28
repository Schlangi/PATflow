param(
    [string]$ConfigPath,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Shared-BenningAutomationFunctions.ps1"

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    $paths = Initialize-BenningFolders -Config $config
    $sdWriteLockPath = $null
    Write-BenningLog -Config $config -Message "Starting master database write to SD card"

    $masterDb = Assert-BenningMasterDb -Config $config
    $deviceDb = Find-BenningDeviceDatabase -Config $config

    Wait-BenningFileAccess -Config $config -Path $deviceDb.FullName -Access "Read" -Purpose "device database hash check"
    Wait-BenningFileAccess -Config $config -Path $masterDb.FullName -Access "Read" -Purpose "master database write source check"

    $deviceStateHashFile = Get-BenningDeviceStateHashPath -Config $config -DeviceDatabaseName $deviceDb.Name
    $stateHashFile = $deviceStateHashFile
    if (!(Test-Path -LiteralPath $stateHashFile)) {
        $stateHashFile = $paths.StateHashFile
    }

    if (!(Test-Path -LiteralPath $stateHashFile)) {
        throw "No last import hash found. Run BENNING result import first."
    }

    $currentHash = Get-BenningFileHash -Path $deviceDb.FullName
    $lastImportedHash = (Get-Content -LiteralPath $stateHashFile -ErrorAction Stop | Select-Object -First 1).Trim()

    if ($currentHash -ne $lastImportedHash) {
        throw "The database on the SD card has changed since the last import. Overwrite aborted. Run BENNING result import first."
    }

    if (($masterDb.Extension.ToLowerInvariant() -ne $deviceDb.Extension.ToLowerInvariant()) -and !$config.DeviceDatabase.AllowExtensionMismatchOnWrite) {
        throw "Master database extension ($($masterDb.Extension)) does not match device database extension ($($deviceDb.Extension)). Check config.json or deliberately enable AllowExtensionMismatchOnWrite."
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $paths.Backups ("{0}_sd_before_master_write_{1}" -f $timestamp, $deviceDb.Name)

    Wait-BenningFileAccess -Config $config -Path $deviceDb.FullName -Access "ReadWrite" -Purpose "device database overwrite"

    $sdWriteLockPath = Start-BenningSdWriteLock -Config $config -Reason "master database write to SD: $($deviceDb.FullName)"
    Copy-BenningFile -Config $config -SourcePath $deviceDb.FullName -DestinationPath $backupFile -Purpose "SD database backup before master write"
    Copy-BenningFile -Config $config -SourcePath $masterDb.FullName -DestinationPath $deviceDb.FullName -Purpose "master database write to SD"

    $newHash = Get-BenningFileHash -Path $deviceDb.FullName
    $newHash | Set-Content -LiteralPath $paths.StateHashFile -Encoding ASCII
    $newHash | Set-Content -LiteralPath $deviceStateHashFile -Encoding ASCII
    $deviceStateMetadataFile = Get-BenningDeviceStateMetadataPath -Config $config -DeviceDatabaseName $deviceDb.Name
    Get-BenningFileMetadata -File (Get-Item -LiteralPath $deviceDb.FullName) |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $deviceStateMetadataFile -Encoding UTF8

    Write-BenningLog -Config $config -Message "SD database backup before master write: $backupFile"
    Write-BenningLog -Config $config -Message "Master database written to: $($deviceDb.FullName)"
    Write-BenningLog -Config $config -Message "New hash saved: $newHash"
    Write-BenningLog -Config $config -Message "Device-specific hash file: $deviceStateHashFile"
    Write-BenningLog -Config $config -Message "Device-specific metadata file: $deviceStateMetadataFile"
    Show-BenningToastNotification -Config $config -Title "BENNING SD card updated" -Message "Test data was successfully written to the device: $($deviceDb.Name)" | Out-Null
    Show-BenningMessage -Config $config -Icon "Information" -Message "Test data was successfully written to the device."

    if ($Json) {
        [pscustomobject]@{
            Success = $true
            DeviceDbPath = $deviceDb.FullName
            BackupPath = $backupFile
            Hash = $newHash
            DeviceStateHashPath = $deviceStateHashFile
            DeviceStateMetadataPath = $deviceStateMetadataFile
        } | ConvertTo-Json -Depth 4
    } else {
        Write-Output $deviceDb.FullName
    }
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message $_.Exception.Message
        Show-BenningMessage -Config $config -Icon "Error" -Message "BENNING test data could not be written to the device.`n`n$($_.Exception.Message)`n`nError log: $($paths.LogFile)"
    }

    throw
} finally {
    if ($config -and $sdWriteLockPath) {
        Stop-BenningSdWriteLock -Config $config -LockPath $sdWriteLockPath
    }
}
