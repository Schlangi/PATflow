$ErrorActionPreference = "Stop"

function Get-ScriptRootPath {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Resolve-BenningConfigPath {
    param([string]$ConfigPath)

    if ($ConfigPath) {
        return (Resolve-Path -LiteralPath $ConfigPath).Path
    }

    $scriptRoot = Get-ScriptRootPath
    $repoConfig = Join-Path (Split-Path -Parent $scriptRoot) "Config\config.json"
    if (Test-Path -LiteralPath $repoConfig) {
        return (Resolve-Path -LiteralPath $repoConfig).Path
    }

    $defaultConfig = "C:\BenningAutomation\Config\config.json"
    if (Test-Path -LiteralPath $defaultConfig) {
        return $defaultConfig
    }

    throw "Configuration not found. Expected: $repoConfig or $defaultConfig"
}

function Get-BenningConfig {
    param([string]$ConfigPath)

    $resolvedPath = Resolve-BenningConfigPath -ConfigPath $ConfigPath
    $config = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $config | Add-Member -NotePropertyName ConfigPath -NotePropertyValue $resolvedPath -Force
    return $config
}

function Get-BenningPaths {
    param($Config)

    $basePath = $Config.BasePath
    return [pscustomobject]@{
        Base     = $basePath
        Config   = Join-Path $basePath "Config"
        Db       = Join-Path $basePath "DB"
        Incoming = Join-Path $basePath "Incoming"
        Archive  = Join-Path $basePath "Archive"
        Backups  = Join-Path $basePath "Backups"
        Logs     = Join-Path $basePath "Logs"
        State    = Join-Path $basePath "State"
        LogFile  = Join-Path $basePath "Logs\benning_automation.log"
        StateHashFile = Join-Path $basePath "State\last_device_import_hash.txt"
    }
}

function Initialize-BenningFolders {
    param($Config)

    $paths = Get-BenningPaths -Config $Config
    New-Item -ItemType Directory -Force -Path `
        $paths.Config, $paths.Db, $paths.Incoming, $paths.Archive, `
        $paths.Backups, $paths.Logs, $paths.State | Out-Null

    if ($Config.Pdf) {
        New-Item -ItemType Directory -Force -Path `
            $Config.Pdf.ExportPath, $Config.Pdf.ArchivePath, $Config.Pdf.QueuePath | Out-Null
    }

    return $paths
}

function Write-BenningLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = "INFO",
        $Config
    )

    $paths = Get-BenningPaths -Config $Config
    New-Item -ItemType Directory -Force -Path $paths.Logs | Out-Null
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts`t$Level`t$Message" | Add-Content -LiteralPath $paths.LogFile -Encoding UTF8
}

function Show-BenningMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("Information", "Warning", "Error")][string]$Icon = "Information",
        $Config
    )

    if (!$Config.Ui.ShowMessageBox) {
        return
    }

    Add-Type -AssemblyName PresentationFramework
    $messageIcon = [System.Enum]::Parse([System.Windows.MessageBoxImage], $Icon)
    [System.Windows.MessageBox]::Show(
        $Message,
        $Config.Ui.MessageTitle,
        [System.Windows.MessageBoxButton]::OK,
        $messageIcon
    ) | Out-Null
}

function Get-DriveCandidates {
    param($Config)

    $drives = Get-CimInstance Win32_LogicalDisk | Where-Object {
        $_.DriveType -eq 2 -or !$Config.DeviceDatabase.RequireRemovableDrive
    }

    $preferredLabels = @($Config.DeviceDatabase.PreferredVolumeLabels)
    if ($preferredLabels.Count -gt 0) {
        $preferred = $drives | Where-Object { $preferredLabels -contains $_.VolumeName }
        $other = $drives | Where-Object { $preferredLabels -notcontains $_.VolumeName }
        return @($preferred) + @($other)
    }

    return @($drives)
}

function Find-BenningDeviceDatabase {
    param($Config)

    $allowedExtensions = @($Config.DeviceDatabase.AllowedExtensions)
    $candidateNames = @($Config.DeviceDatabase.CandidateFileNames)
    $searchRootOnly = [bool]$Config.DeviceDatabase.SearchRootOnly

    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($drive in (Get-DriveCandidates -Config $Config)) {
        $root = $drive.DeviceID + "\"
        if (!(Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($name in $candidateNames) {
            $candidate = Join-Path $root $name
            if (Test-Path -LiteralPath $candidate) {
                $item = Get-Item -LiteralPath $candidate
                $matches.Add([pscustomobject]@{
                    File = $item
                    Score = 0
                    VolumeName = $drive.VolumeName
                    Drive = $drive.DeviceID
                })
            }
        }

        if ($searchRootOnly) {
            $files = Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue
        } else {
            $files = Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue
        }

        foreach ($file in $files) {
            if ($allowedExtensions -contains $file.Extension.ToLowerInvariant()) {
                $score = 10
                if ($candidateNames -contains $file.Name) {
                    $score = 0
                }

                $matches.Add([pscustomobject]@{
                    File = $file
                    Score = $score
                    VolumeName = $drive.VolumeName
                    Drive = $drive.DeviceID
                })
            }
        }
    }

    $uniqueMatches = $matches |
        Sort-Object @{Expression = "Score"; Ascending = $true}, @{Expression = { $_.File.LastWriteTime }; Descending = $true}, @{Expression = { $_.File.FullName }; Ascending = $true} |
        Group-Object { $_.File.FullName } |
        ForEach-Object { $_.Group[0] }

    if (!$uniqueMatches -or @($uniqueMatches).Count -eq 0) {
        throw "No BENNING device database found. Check the SD card."
    }

    if (@($uniqueMatches).Count -gt 1) {
        $list = ($uniqueMatches | Select-Object -First 5 | ForEach-Object { $_.File.FullName }) -join "; "
        Write-BenningLog -Config $Config -Level "WARN" -Message "Multiple device databases found, using first match: $list"
    }

    return @($uniqueMatches)[0].File
}

function Get-BenningFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-BenningFileAccessTimeout {
    param($Config)

    if ($Config.FileAccessTimeoutSeconds -and [int]$Config.FileAccessTimeoutSeconds -gt 0) {
        return [int]$Config.FileAccessTimeoutSeconds
    }

    return 3
}

function Wait-BenningFileAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet("Read", "ReadWrite")][string]$Access = "Read",
        [string]$Purpose = "file access",
        $Config
    )

    $timeoutSeconds = Get-BenningFileAccessTimeout -Config $Config
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $lastError = $null
    $fileAccess = [System.IO.FileAccess]::$Access

    do {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, $fileAccess, [System.IO.FileShare]::None)
            $stream.Dispose()
            return
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 200
        }
    } while ((Get-Date) -lt $deadline)

    throw "File is locked or not accessible after $timeoutSeconds seconds during ${Purpose}: $Path. Close BENNING PC-Win and try again. Last error: $lastError"
}

function Assert-BenningMasterDb {
    param($Config)

    if (!(Test-Path -LiteralPath $Config.MasterDbPath)) {
        throw "Master database not found: $($Config.MasterDbPath)"
    }

    return (Get-Item -LiteralPath $Config.MasterDbPath)
}
