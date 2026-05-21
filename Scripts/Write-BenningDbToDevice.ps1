param(
    [string]$ConfigPath,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common-BenningAutomation.ps1"

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    $paths = Initialize-BenningFolders -Config $config
    Write-BenningLog -Config $config -Message "Starting master database write to SD card"

    $masterDb = Assert-BenningMasterDb -Config $config
    $deviceDb = Find-BenningDeviceDatabase -Config $config

    if (!(Test-Path -LiteralPath $paths.StateHashFile)) {
        throw "No last import hash found. Run BENNING result import first."
    }

    $currentHash = Get-BenningFileHash -Path $deviceDb.FullName
    $lastImportedHash = (Get-Content -LiteralPath $paths.StateHashFile -ErrorAction Stop | Select-Object -First 1).Trim()

    if ($currentHash -ne $lastImportedHash) {
        throw "The database on the SD card has changed since the last import. Overwrite aborted. Run BENNING result import first."
    }

    if (($masterDb.Extension.ToLowerInvariant() -ne $deviceDb.Extension.ToLowerInvariant()) -and !$config.DeviceDatabase.AllowExtensionMismatchOnWrite) {
        throw "Master database extension ($($masterDb.Extension)) does not match device database extension ($($deviceDb.Extension)). Check config.json or deliberately enable AllowExtensionMismatchOnWrite."
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $paths.Archive ("DeviceDB_before_write_{0}{1}" -f $timestamp, $deviceDb.Extension)

    Copy-Item -LiteralPath $deviceDb.FullName -Destination $backupFile -Force
    Copy-Item -LiteralPath $masterDb.FullName -Destination $deviceDb.FullName -Force

    $newHash = Get-BenningFileHash -Path $deviceDb.FullName
    $newHash | Set-Content -LiteralPath $paths.StateHashFile -Encoding ASCII

    Write-BenningLog -Config $config -Message "SD database backup: $backupFile"
    Write-BenningLog -Config $config -Message "Master database written to: $($deviceDb.FullName)"
    Write-BenningLog -Config $config -Message "New hash saved: $newHash"
    Show-BenningMessage -Config $config -Icon "Information" -Message "Test data was successfully written to the device."

    if ($Json) {
        [pscustomobject]@{
            Success = $true
            DeviceDbPath = $deviceDb.FullName
            BackupPath = $backupFile
            Hash = $newHash
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
}
