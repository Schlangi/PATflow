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

function Get-BenningStatusPath {
    param($Config)

    $paths = Get-BenningPaths -Config $Config
    return Join-Path $paths.State "status.json"
}

function Get-EmptyBenningStatus {
    return [pscustomobject]@{
        UpdatedAt = $null
        DatabaseWorkflow = [pscustomobject]@{
            State = "Unknown"
            Message = ""
            UpdatedAt = $null
        }
        PdfWorkflow = [pscustomobject]@{
            State = "Unknown"
            Message = ""
            UpdatedAt = $null
        }
        LastError = $null
    }
}

function Get-BenningStatus {
    param($Config)

    $statusPath = Get-BenningStatusPath -Config $Config
    if (!(Test-Path -LiteralPath $statusPath)) {
        return Get-EmptyBenningStatus
    }

    try {
        $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return Get-EmptyBenningStatus
    }

    if (!$status.DatabaseWorkflow) {
        $status | Add-Member -NotePropertyName DatabaseWorkflow -NotePropertyValue (Get-EmptyBenningStatus).DatabaseWorkflow -Force
    }

    if (!$status.PdfWorkflow) {
        $status | Add-Member -NotePropertyName PdfWorkflow -NotePropertyValue (Get-EmptyBenningStatus).PdfWorkflow -Force
    }

    if ($null -eq $status.PSObject.Properties["LastError"]) {
        $status | Add-Member -NotePropertyName LastError -NotePropertyValue $null -Force
    }

    return $status
}

function Set-BenningStatus {
    param(
        $Config,
        [ValidateSet("Database", "Pdf")][string]$Workflow,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$ErrorMessage
    )

    $statusMutex = $null
    $statusMutexTaken = $false
    try {
        try {
            $statusMutex = [System.Threading.Mutex]::new($false, "Global\PATflowStatusJson")
        } catch {
            $statusMutex = [System.Threading.Mutex]::new($false, "Local\PATflowStatusJson")
        }

        $statusMutexTaken = $statusMutex.WaitOne([TimeSpan]::FromSeconds(5))
        if (!$statusMutexTaken) {
            throw "Timed out waiting for PATflow status.json lock."
        }

        $status = Get-BenningStatus -Config $Config
        $now = Get-Date -Format o
        $status.UpdatedAt = $now

        $entry = [pscustomobject]@{
            State = $State
            Message = $Message
            UpdatedAt = $now
        }

        if ($Workflow -eq "Database") {
            $status.DatabaseWorkflow = $entry
        } else {
            $status.PdfWorkflow = $entry
        }

        if (![string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $status.LastError = [pscustomobject]@{
                Workflow = $Workflow
                State = $State
                Message = $ErrorMessage
                OccurredAt = $now
            }
        }

        $statusPath = Get-BenningStatusPath -Config $Config
        $statusFolder = Split-Path -Parent $statusPath
        New-Item -ItemType Directory -Force -Path $statusFolder | Out-Null
        $statusTempPath = Join-Path $statusFolder (".patflow_status_{0}.tmp" -f ([guid]::NewGuid().ToString("N")))
        $status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusTempPath -Encoding UTF8
        Move-Item -LiteralPath $statusTempPath -Destination $statusPath -Force
    } finally {
        if ($statusMutexTaken -and $statusMutex) {
            $statusMutex.ReleaseMutex()
        }

        if ($statusMutex) {
            $statusMutex.Dispose()
        }
    }
}

function Show-PatflowWorkflowToast {
    param(
        $Config,
        [ValidateSet("Database", "Pdf")][string]$Workflow,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$Error
    )

    $identifier = "PATflow-$Workflow"
    if ($Error) {
        $identifier = "PATflow-$Workflow-Error-$([guid]::NewGuid().ToString("N"))"
    }

    Show-BenningToastNotification -Config $Config -Title $Title -Message $Message -UniqueIdentifier $identifier | Out-Null
}

function ConvertFrom-BenningEscapedText {
    param([string]$Text)

    if ($null -eq $Text) {
        return $null
    }

    return [regex]::Replace($Text, "\\u([0-9a-fA-F]{4})", {
        param($Match)
        return [string][char][Convert]::ToInt32($Match.Groups[1].Value, 16)
    })
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

function Copy-BenningFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        $Config,
        [string]$Purpose = "file copy"
    )

    $sourceItem = Get-Item -LiteralPath $SourcePath
    $destinationFolder = Split-Path -Parent $DestinationPath
    if ([string]::IsNullOrWhiteSpace($destinationFolder)) {
        throw "Destination folder could not be resolved for: $DestinationPath"
    }

    if (!(Test-Path -LiteralPath $destinationFolder)) {
        New-Item -ItemType Directory -Force -Path $destinationFolder | Out-Null
    }

    $destinationName = Split-Path -Leaf $DestinationPath
    $shortId = ([guid]::NewGuid().ToString("N")).Substring(0, 8)
    $copyDestinationName = "PF$shortId.tmp"
    $replaceBackupName = "PF$shortId.bak"
    $copyDestinationPath = Join-Path $destinationFolder $copyDestinationName
    $replaceBackupPath = Join-Path $destinationFolder $replaceBackupName

    Write-BenningLog -Config $Config -Message "Copying file for ${Purpose}: $SourcePath -> $copyDestinationPath"
    Copy-Item -LiteralPath $SourcePath -Destination $copyDestinationPath -Force

    $copyItem = Get-Item -LiteralPath $copyDestinationPath
    if ($copyItem.Length -ne $sourceItem.Length) {
        Remove-Item -LiteralPath $copyDestinationPath -Force -ErrorAction SilentlyContinue
        throw "Copied file size mismatch for ${Purpose}: $SourcePath -> $copyDestinationPath"
    }

    $destinationWasMoved = $false
    try {
        if (Test-Path -LiteralPath $DestinationPath) {
            Move-Item -LiteralPath $DestinationPath -Destination $replaceBackupPath -Force
            $destinationWasMoved = $true
            Move-Item -LiteralPath $copyDestinationPath -Destination $DestinationPath -Force
            Remove-Item -LiteralPath $replaceBackupPath -Force -ErrorAction SilentlyContinue
        } else {
            Move-Item -LiteralPath $copyDestinationPath -Destination $DestinationPath -Force
        }
    } catch {
        if ($destinationWasMoved -and !(Test-Path -LiteralPath $DestinationPath) -and (Test-Path -LiteralPath $replaceBackupPath)) {
            Move-Item -LiteralPath $replaceBackupPath -Destination $DestinationPath -Force -ErrorAction SilentlyContinue
        }

        Remove-Item -LiteralPath $copyDestinationPath -Force -ErrorAction SilentlyContinue
        throw
    }

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

    try {
        $paths = Get-BenningPaths -Config $Config
        New-Item -ItemType Directory -Force -Path $paths.Logs | Out-Null
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "$ts`t$Level`t$Message"

        $logMutex = $null
        $logMutexTaken = $false
        try {
            try {
                $logMutex = [System.Threading.Mutex]::new($false, "Global\PATflowLogFile")
            } catch {
                $logMutex = [System.Threading.Mutex]::new($false, "Local\PATflowLogFile")
            }

            $logMutexTaken = $logMutex.WaitOne([TimeSpan]::FromSeconds(3))
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                try {
                    $line | Add-Content -LiteralPath $paths.LogFile -Encoding UTF8
                    return
                } catch {
                    Start-Sleep -Milliseconds 150
                }
            }
        } finally {
            if ($logMutexTaken -and $logMutex) {
                $logMutex.ReleaseMutex()
            }

            if ($logMutex) {
                $logMutex.Dispose()
            }
        }
    } catch {
        return
    }
}

function Show-BenningMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("Information", "Warning", "Error")][string]$Icon = "Information",
        $Config
    )

    $title = $Config.Ui.MessageTitle
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "PATflow BENNING Automatisierung"
    }

    Show-BenningToastNotification -Config $Config -Title $title -Message $Message | Out-Null
}

function Show-BenningToastNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$UniqueIdentifier,
        $Config
    )

    try {
        $Title = ConvertFrom-BenningEscapedText -Text $Title
        $Message = ConvertFrom-BenningEscapedText -Text $Message

        if (!(Get-Module -ListAvailable -Name BurntToast | Select-Object -First 1)) {
            throw "PowerShell module BurntToast is not installed."
        }

        Import-Module BurntToast -ErrorAction Stop
        $toastParameters = @{
            Text = @($Title, $Message)
            Silent = $true
            ErrorAction = "Stop"
        }
        if (![string]::IsNullOrWhiteSpace($UniqueIdentifier)) {
            $toastParameters.UniqueIdentifier = $UniqueIdentifier
        }

        New-BurntToastNotification @toastParameters
        Write-BenningLog -Config $Config -Message "BurntToast notification shown: $Title - $Message"
        return $true
    } catch {
        Write-BenningLog -Config $Config -Level "WARN" -Message "BurntToast notification failed: $($_.Exception.Message). Notification text: $Title - $Message"
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
