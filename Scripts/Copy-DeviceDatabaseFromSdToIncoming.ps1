param(
    [string]$ConfigPath,
    [switch]$Json,
    [switch]$SkipUnchanged,
    [switch]$SuppressErrorMessage
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Shared-BenningAutomationFunctions.ps1"

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    $paths = Initialize-BenningFolders -Config $config
    Write-BenningLog -Config $config -Message "Starting BENNING merge preparation"

    if (Test-BenningSdWriteInProgress -Config $config) {
        Write-BenningLog -Config $config -Message "SD write is in progress, skipping device database copy."
        if ($Json) {
            [pscustomobject]@{
                Success = $true
                Changed = $false
                SdWriteInProgress = $true
                Message = "SD write is in progress."
            } | ConvertTo-Json -Depth 4
        }

        return
    }

    $deviceDb = Find-BenningDeviceDatabase -Config $config
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    Wait-BenningFileAccess -Config $config -Path $deviceDb.FullName -Access "Read" -Purpose "device database import copy"

    $incomingFile = Join-Path $paths.Incoming $deviceDb.Name
    $archiveFile = Join-Path $paths.Archive ("{0}_{1}" -f $timestamp, $deviceDb.Name)
    $deviceStateHashFile = Get-BenningDeviceStateHashPath -Config $config -DeviceDatabaseName $deviceDb.Name
    $deviceStateMetadataFile = Get-BenningDeviceStateMetadataPath -Config $config -DeviceDatabaseName $deviceDb.Name
    $currentMetadata = Get-BenningFileMetadata -File $deviceDb

    if ($SkipUnchanged -and (Test-Path -LiteralPath $deviceStateMetadataFile)) {
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

    if (Test-BenningSdWriteInProgress -Config $config) {
        Write-BenningLog -Config $config -Message "SD write started while preparing copy, skipping device database copy."
        if ($Json) {
            [pscustomobject]@{
                Success = $true
                Changed = $false
                SdWriteInProgress = $true
                Message = "SD write started while preparing copy."
            } | ConvertTo-Json -Depth 4
        }

        return
    }

    if ($SkipUnchanged -and (Test-Path -LiteralPath $deviceStateHashFile)) {
        $previousHash = (Get-Content -LiteralPath $deviceStateHashFile -ErrorAction Stop | Select-Object -First 1).Trim()
        if ($hash -eq $previousHash) {
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

    Set-BenningStatus -Config $config -Workflow "Database" -State "CopyingDatabaseFromSdCard" -Message "Copying database from SD card."
    Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung" -Message "Kopiere Datenbank von SD Karte"

    Copy-BenningFile -Config $config -SourcePath $deviceDb.FullName -DestinationPath $incomingFile -Purpose "device database import copy"
    Copy-BenningFile -Config $config -SourcePath $deviceDb.FullName -DestinationPath $archiveFile -Purpose "device database archive copy"

    $hash | Set-Content -LiteralPath $paths.StateHashFile -Encoding ASCII
    $hash | Set-Content -LiteralPath $deviceStateHashFile -Encoding ASCII
    $currentMetadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $deviceStateMetadataFile -Encoding UTF8

    Write-BenningLog -Config $config -Message "Device database found: $($deviceDb.FullName)"
    Write-BenningLog -Config $config -Message "Import copy: $incomingFile"
    Write-BenningLog -Config $config -Message "Archive copy: $archiveFile"
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
            Hash = $hash
            DeviceStateHashPath = $deviceStateHashFile
            DeviceStateMetadataPath = $deviceStateMetadataFile
        } | ConvertTo-Json -Depth 4
    } else {
        Write-Output $incomingFile
    }
} catch {
    if ($config) {
        $isNoDeviceDatabase = Test-BenningNoDeviceDatabaseError -Message $_.Exception.Message

        if ($isNoDeviceDatabase -and $SuppressErrorMessage) {
            Write-BenningLog -Config $config -Message "No device database found. Waiting for removable media."
            if ($Json) {
                [pscustomobject]@{
                    Success = $true
                    Changed = $false
                    NoDeviceDatabase = $true
                    Message = $_.Exception.Message
                } | ConvertTo-Json -Depth 4
            }

            return
        }

        Write-BenningLog -Config $config -Level "ERROR" -Message $_.Exception.Message
        Set-BenningStatus -Config $config -Workflow "Database" -State "Error" -Message "Database preparation failed." -ErrorMessage $_.Exception.Message
        Show-PatflowWorkflowToast -Config $config -Workflow "Database" -Title "PATflow Datenbank Automatisierung Fehler" -Message "Fehler beim Kopieren von der SD-Karte. Details stehen im Log." -Error
    }

    throw
}
