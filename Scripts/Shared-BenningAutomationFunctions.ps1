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

function ConvertTo-SafeStateFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    return ($Name -replace '[^a-zA-Z0-9._-]', '_')
}

function Get-BenningDeviceStateHashPath {
    param(
        $Config,
        [Parameter(Mandatory = $true)][string]$DeviceDatabaseName
    )

    $paths = Get-BenningPaths -Config $Config
    $safeName = ConvertTo-SafeStateFileName -Name $DeviceDatabaseName
    return Join-Path $paths.State ("last_device_import_hash_{0}.txt" -f $safeName)
}

function Get-BenningDeviceStateMetadataPath {
    param(
        $Config,
        [Parameter(Mandatory = $true)][string]$DeviceDatabaseName
    )

    $paths = Get-BenningPaths -Config $Config
    $safeName = ConvertTo-SafeStateFileName -Name $DeviceDatabaseName
    return Join-Path $paths.State ("last_device_import_metadata_{0}.json" -f $safeName)
}

function Get-BenningDirectWorkflowStatePath {
    param(
        $Config,
        [Parameter(Mandatory = $true)][string]$DeviceDatabaseName
    )

    $paths = Get-BenningPaths -Config $Config
    $safeName = ConvertTo-SafeStateFileName -Name $DeviceDatabaseName
    return Join-Path $paths.State ("direct_workflow_running_{0}.lock" -f $safeName)
}

function Test-BenningDirectWorkflowRunning {
    param(
        $Config,
        [Parameter(Mandatory = $true)][string]$DeviceDatabaseName
    )

    $statePath = Get-BenningDirectWorkflowStatePath -Config $Config -DeviceDatabaseName $DeviceDatabaseName
    return Test-Path -LiteralPath $statePath
}

function Get-BenningSdWriteLockPath {
    param($Config)

    $paths = Get-BenningPaths -Config $Config
    return Join-Path $paths.State "sd_write_in_progress.lock"
}

function Start-BenningSdWriteLock {
    param(
        $Config,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $lockPath = Get-BenningSdWriteLockPath -Config $Config
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
    "Started=$(Get-Date -Format o)`nReason=$Reason" | Set-Content -LiteralPath $lockPath -Encoding UTF8
    Write-BenningLog -Config $Config -Message "SD write lock created: $Reason"
    return $lockPath
}

function Stop-BenningSdWriteLock {
    param(
        $Config,
        [string]$LockPath
    )

    if ([string]::IsNullOrWhiteSpace($LockPath)) {
        $LockPath = Get-BenningSdWriteLockPath -Config $Config
    }

    if (Test-Path -LiteralPath $LockPath) {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        Write-BenningLog -Config $Config -Message "SD write lock removed."
    }
}

function Test-BenningSdWriteInProgress {
    param($Config)

    $lockPath = Get-BenningSdWriteLockPath -Config $Config
    if (!(Test-Path -LiteralPath $lockPath)) {
        return $false
    }

    $lockItem = Get-Item -LiteralPath $lockPath -ErrorAction SilentlyContinue
    if ($lockItem -and $lockItem.LastWriteTime -lt (Get-Date).AddHours(-2)) {
        Write-BenningLog -Config $Config -Level "WARN" -Message "Ignoring stale SD write lock older than 2 hours: $lockPath"
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    return $true
}

function Test-BenningExplorerCopyProgressEnabled {
    param($Config)

    if ($Config.Ui -and $null -ne $Config.Ui.ShowCopyProgressWindow) {
        return [bool]$Config.Ui.ShowCopyProgressWindow
    }

    return $true
}

function Copy-BenningFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        $Config,
        [string]$Purpose = "file copy"
    )

    $sourceItem = Get-Item -LiteralPath $SourcePath
    $destinationFolder = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Force -Path $destinationFolder | Out-Null

    $tempFolder = Join-Path $destinationFolder (".patflow_copy_{0}" -f ([guid]::NewGuid().ToString("N")))
    $copyDestinationPath = Join-Path $tempFolder $sourceItem.Name
    New-Item -ItemType Directory -Force -Path $tempFolder | Out-Null

    if (Test-BenningExplorerCopyProgressEnabled -Config $Config) {
        try {
            $shell = New-Object -ComObject Shell.Application
            $folder = $shell.Namespace($tempFolder)
            if (!$folder) {
                throw "Temporary destination folder could not be opened by Windows Shell: $tempFolder"
            }

            Write-BenningLog -Config $Config -Message "Starting Windows Explorer copy for ${Purpose}: $SourcePath -> $copyDestinationPath"
            $folder.CopyHere($sourceItem.FullName, 16)

            $deadline = (Get-Date).AddMinutes(30)
            do {
                Start-Sleep -Milliseconds 500
                $destinationItem = Get-Item -LiteralPath $copyDestinationPath -ErrorAction SilentlyContinue
                if ($destinationItem -and $destinationItem.Length -eq $sourceItem.Length -and (Test-BenningFileAccess -Path $copyDestinationPath -Access "Read")) {
                    Move-Item -LiteralPath $copyDestinationPath -Destination $DestinationPath -Force
                    Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
                    Write-BenningLog -Config $Config -Message "Windows Explorer copy finished for ${Purpose}: $DestinationPath"
                    return
                }
            } while ((Get-Date) -lt $deadline)

            throw "Windows Explorer copy timed out during ${Purpose}: $DestinationPath"
        } catch {
            Write-BenningLog -Config $Config -Level "WARN" -Message "Windows Explorer copy failed during ${Purpose}, falling back to Copy-Item: $($_.Exception.Message)"
        }
    }

    Copy-Item -LiteralPath $SourcePath -Destination $copyDestinationPath -Force
    Move-Item -LiteralPath $copyDestinationPath -Destination $DestinationPath -Force
    Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue

    Write-BenningLog -Config $Config -Message "File copied for ${Purpose}: $SourcePath -> $DestinationPath"
}

function Get-BenningFileMetadata {
    param([Parameter(Mandatory = $true)]$File)

    return [pscustomobject]@{
        Length = [int64]$File.Length
        LastWriteTimeUtcTicks = [int64]$File.LastWriteTimeUtc.Ticks
    }
}

function Test-BenningFileMetadataUnchanged {
    param(
        [Parameter(Mandatory = $true)]$CurrentMetadata,
        [Parameter(Mandatory = $true)]$PreviousMetadata
    )

    return ([int64]$CurrentMetadata.Length -eq [int64]$PreviousMetadata.Length) -and
        ([int64]$CurrentMetadata.LastWriteTimeUtcTicks -eq [int64]$PreviousMetadata.LastWriteTimeUtcTicks)
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
    $owner = New-Object System.Windows.Window
    $owner.Topmost = $true
    $owner.ShowInTaskbar = $false
    $owner.WindowStyle = "None"
    $owner.Width = 0
    $owner.Height = 0
    $owner.Left = -32000
    $owner.Top = -32000
    $owner.Show()
    try {
        [System.Windows.MessageBox]::Show(
            $owner,
            $Message,
            $Config.Ui.MessageTitle,
            [System.Windows.MessageBoxButton]::OK,
            $messageIcon
        ) | Out-Null
    } finally {
        $owner.Close()
    }
}

function Escape-BenningXmlText {
    param([AllowNull()][string]$Text)

    return [System.Security.SecurityElement]::Escape($Text)
}

function Show-BenningToastNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        $Config
    )

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $appId = $Config.Ui.MessageTitle
        if ([string]::IsNullOrWhiteSpace($appId)) {
            $appId = "PATflow BENNING Automation"
        }

        $xmlText = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$(Escape-BenningXmlText -Text $Title)</text>
      <text>$(Escape-BenningXmlText -Text $Message)</text>
    </binding>
  </visual>
</toast>
"@

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($xmlText)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        Write-BenningLog -Config $Config -Message "Toast notification shown: $Title - $Message"
        return $true
    } catch {
        Write-BenningLog -Config $Config -Level "WARN" -Message "Toast notification failed: $($_.Exception.Message)"
        Show-BenningMessage -Config $Config -Icon "Information" -Message "$Title`n`n$Message"
        return $false
    }
}

function Get-BenningProcessName {
    param($Config)

    if (![string]::IsNullOrWhiteSpace($Config.BenningProcessName)) {
        return $Config.BenningProcessName
    }

    if ([string]::IsNullOrWhiteSpace($Config.BenningProgramPath)) {
        throw "BenningProgramPath is not configured."
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($Config.BenningProgramPath)
}

function Test-BenningConfigSwitch {
    param(
        $Value,
        [bool]$Default = $true
    )

    if ($null -eq $Value) {
        return $Default
    }

    return [bool]$Value
}

function Test-BenningProgramRunning {
    param($Config)

    $processName = Get-BenningProcessName -Config $Config
    return $null -ne (Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Start-BenningProgram {
    param(
        $Config,
        [string]$DatabasePath
    )

    if ([string]::IsNullOrWhiteSpace($Config.BenningProgramPath)) {
        throw "BenningProgramPath is not configured."
    }

    if (!(Test-Path -LiteralPath $Config.BenningProgramPath)) {
        throw "BENNING program not found: $($Config.BenningProgramPath)"
    }

    $startProcessParameters = @{
        FilePath = $Config.BenningProgramPath
        WindowStyle = "Maximized"
    }

    if (![string]::IsNullOrWhiteSpace($Config.BenningProgramArguments)) {
        $arguments = $Config.BenningProgramArguments
        if ($DatabasePath) {
            $arguments = $arguments.Replace("{DatabasePath}", $DatabasePath)
        }

        $startProcessParameters.ArgumentList = $arguments
    }

    Start-Process @startProcessParameters
    Write-BenningLog -Config $Config -Message "BENNING PC-Win started: $($Config.BenningProgramPath)"
}

function Get-DriveCandidates {
    param($Config)

    $searchRoots = @($Config.DeviceDatabase.SearchRoots) | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
    if ($searchRoots.Count -gt 0) {
        return $searchRoots | ForEach-Object {
            $root = $_
            if (!$root.EndsWith("\")) {
                $root = $root + "\"
            }

            [pscustomobject]@{
                Root = $root
                VolumeName = ""
                Drive = $root.TrimEnd("\")
                DriveType = "Configured"
            }
        }
    }

    $requireRemovableDrive = [bool]$Config.DeviceDatabase.RequireRemovableDrive
    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object {
        $_.IsReady -and ($_.DriveType -eq [System.IO.DriveType]::Removable -or !$requireRemovableDrive)
    } | ForEach-Object {
        [pscustomobject]@{
            Root = $_.RootDirectory.FullName
            VolumeName = $_.VolumeLabel
            Drive = $_.Name.TrimEnd("\")
            DriveType = $_.DriveType.ToString()
        }
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
    $preferExactCandidateMatch = $true
    if ($null -ne $Config.DeviceDatabase.PreferExactCandidateMatch) {
        $preferExactCandidateMatch = [bool]$Config.DeviceDatabase.PreferExactCandidateMatch
    }

    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($drive in (Get-DriveCandidates -Config $Config)) {
        $root = $drive.Root
        if (!(Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($name in $candidateNames) {
            $candidate = Join-Path $root $name
            if (Test-Path -LiteralPath $candidate) {
                $item = Get-Item -LiteralPath $candidate
                if ($preferExactCandidateMatch) {
                    Write-BenningLog -Config $Config -Message "Exact device database match found: $($item.FullName)"
                    return $item
                }

                $matches.Add([pscustomobject]@{
                    File = $item
                    Score = 0
                    VolumeName = $drive.VolumeName
                    Drive = $drive.Drive
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
                    Drive = $drive.Drive
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

function Test-BenningNoDeviceDatabaseError {
    param([Parameter(Mandatory = $true)][string]$Message)

    return $Message -like "No BENNING device database found*"
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

function Test-BenningFileAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet("Read", "ReadWrite")][string]$Access = "Read"
    )

    $fileAccess = [System.IO.FileAccess]::$Access
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, $fileAccess, [System.IO.FileShare]::None)
        $stream.Dispose()
        return $true
    } catch {
        return $false
    }
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
