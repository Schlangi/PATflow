param(
    [string]$ConfigPath,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common-BenningAutomation.ps1"

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    $paths = Initialize-BenningFolders -Config $config
    Write-BenningLog -Config $config -Message "Starting BENNING merge preparation"

    $masterDb = Assert-BenningMasterDb -Config $config
    $deviceDb = Find-BenningDeviceDatabase -Config $config
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    Wait-BenningFileAccess -Config $config -Path $deviceDb.FullName -Access "Read" -Purpose "device database import copy"
    Wait-BenningFileAccess -Config $config -Path $masterDb.FullName -Access "Read" -Purpose "master database backup"

    $incomingFile = Join-Path $paths.Incoming ("latest_from_device" + $deviceDb.Extension)
    $archiveFile = Join-Path $paths.Archive ("DeviceDB_{0}{1}" -f $timestamp, $deviceDb.Extension)
    $backupFile = Join-Path $paths.Backups ("BENNING_Master_before_merge_{0}{1}" -f $timestamp, $masterDb.Extension)

    Copy-Item -LiteralPath $deviceDb.FullName -Destination $incomingFile -Force
    Copy-Item -LiteralPath $deviceDb.FullName -Destination $archiveFile -Force
    Copy-Item -LiteralPath $masterDb.FullName -Destination $backupFile -Force

    $hash = Get-BenningFileHash -Path $deviceDb.FullName
    $hash | Set-Content -LiteralPath $paths.StateHashFile -Encoding ASCII

    Write-BenningLog -Config $config -Message "Device database found: $($deviceDb.FullName)"
    Write-BenningLog -Config $config -Message "Import copy: $incomingFile"
    Write-BenningLog -Config $config -Message "Archive copy: $archiveFile"
    Write-BenningLog -Config $config -Message "Master database backup: $backupFile"
    Write-BenningLog -Config $config -Message "Hash saved: $hash"
    Write-BenningLog -Config $config -Message "Preparation completed"

    if ($Json) {
        [pscustomobject]@{
            Success = $true
            DeviceDbPath = $incomingFile
            SourceDeviceDbPath = $deviceDb.FullName
            ArchivePath = $archiveFile
            BackupPath = $backupFile
            Hash = $hash
        } | ConvertTo-Json -Depth 4
    } else {
        Write-Output $incomingFile
    }
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message $_.Exception.Message
        Show-BenningMessage -Config $config -Icon "Error" -Message "BENNING result import could not be prepared.`nPlease do not perform any further tests.`n`nError log: $((Get-BenningPaths -Config $config).LogFile)"
    }

    throw
}
