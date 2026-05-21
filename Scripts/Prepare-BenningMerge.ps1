param(
    [string]$ConfigPath,
    [switch]$Json,
    [switch]$SkipUnchanged,
    [switch]$SuppressErrorMessage
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

    $incomingFile = Join-Path $paths.Incoming $deviceDb.Name
    $archiveFile = Join-Path $paths.Archive ("{0}_{1}" -f $timestamp, $deviceDb.Name)
    $backupFile = Join-Path $paths.Backups ("BENNING_Master_before_merge_{0}{1}" -f $timestamp, $masterDb.Extension)
    $deviceStateHashFile = Get-BenningDeviceStateHashPath -Config $config -DeviceDatabaseName $deviceDb.Name
    $deviceStateMetadataFile = Get-BenningDeviceStateMetadataPath -Config $config -DeviceDatabaseName $deviceDb.Name
    $currentMetadata = Get-BenningFileMetadata -File $deviceDb

    if ($SkipUnchanged -and (Test-Path -LiteralPath $deviceStateMetadataFile) -and (Test-Path -LiteralPath $incomingFile)) {
        $previousMetadata = Get-Content -LiteralPath $deviceStateMetadataFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if (Test-BenningFileMetadataUnchanged -CurrentMetadata $currentMetadata -PreviousMetadata $previousMetadata) {
            $previousHash = $null
            if (Test-Path -LiteralPath $deviceStateHashFile) {
                $previousHash = (Get-Content -LiteralPath $deviceStateHashFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
            }

            Write-BenningLog -Config $config -Message "Device database metadata unchanged, skipping import copy: $($deviceDb.FullName)"
            if ($Json) {
                [pscustomobject]@{
                    Success = $true
                    Changed = $false
                    DeviceDbPath = $incomingFile
                    SourceDeviceDbPath = $deviceDb.FullName
                    Hash = $previousHash
                    DeviceStateHashPath = $deviceStateHashFile
                    DeviceStateMetadataPath = $deviceStateMetadataFile
                } | ConvertTo-Json -Depth 4
            }

            return
        }
    }

    $hash = Get-BenningFileHash -Path $deviceDb.FullName

    if ($SkipUnchanged -and (Test-Path -LiteralPath $deviceStateHashFile)) {
        $previousHash = (Get-Content -LiteralPath $deviceStateHashFile -ErrorAction Stop | Select-Object -First 1).Trim()
        if ($hash -eq $previousHash -and (Test-Path -LiteralPath $incomingFile)) {
            Write-BenningLog -Config $config -Message "Device database unchanged, skipping import copy: $($deviceDb.FullName)"
            if ($Json) {
                [pscustomobject]@{
                    Success = $true
                    Changed = $false
                    DeviceDbPath = $incomingFile
                    SourceDeviceDbPath = $deviceDb.FullName
                    Hash = $hash
                    DeviceStateHashPath = $deviceStateHashFile
                } | ConvertTo-Json -Depth 4
            }

            return
        }
    }

    Copy-Item -LiteralPath $deviceDb.FullName -Destination $incomingFile -Force
    Copy-Item -LiteralPath $deviceDb.FullName -Destination $archiveFile -Force
    Copy-Item -LiteralPath $masterDb.FullName -Destination $backupFile -Force

    $hash | Set-Content -LiteralPath $paths.StateHashFile -Encoding ASCII
    $hash | Set-Content -LiteralPath $deviceStateHashFile -Encoding ASCII
    $currentMetadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $deviceStateMetadataFile -Encoding UTF8

    Write-BenningLog -Config $config -Message "Device database found: $($deviceDb.FullName)"
    Write-BenningLog -Config $config -Message "Import copy: $incomingFile"
    Write-BenningLog -Config $config -Message "Archive copy: $archiveFile"
    Write-BenningLog -Config $config -Message "Master database backup: $backupFile"
    Write-BenningLog -Config $config -Message "Hash saved: $hash"
    Write-BenningLog -Config $config -Message "Device-specific hash file: $deviceStateHashFile"
    Write-BenningLog -Config $config -Message "Device-specific metadata file: $deviceStateMetadataFile"
    Write-BenningLog -Config $config -Message "Preparation completed"

    if ($Json) {
        [pscustomobject]@{
            Success = $true
            Changed = $true
            DeviceDbPath = $incomingFile
            SourceDeviceDbPath = $deviceDb.FullName
            ArchivePath = $archiveFile
            BackupPath = $backupFile
            Hash = $hash
            DeviceStateHashPath = $deviceStateHashFile
            DeviceStateMetadataPath = $deviceStateMetadataFile
        } | ConvertTo-Json -Depth 4
    } else {
        Write-Output $incomingFile
    }
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message $_.Exception.Message
        if (!$SuppressErrorMessage) {
            Show-BenningMessage -Config $config -Icon "Error" -Message "BENNING result import could not be prepared.`nPlease do not perform any further tests.`n`nError log: $((Get-BenningPaths -Config $config).LogFile)"
        }
    }

    throw
}
