param(
    [Parameter(Mandatory = $true)]
    [string]$UserId,

    [string]$TaskNamePrefix = "PATflow",

    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Shared-BenningAutomationFunctions.ps1"

function Resolve-BenningScheduledTaskUserId {
    param([Parameter(Mandatory = $true)][string]$UserId)

    $normalizedUserId = $UserId.Trim()
    if ($normalizedUserId.StartsWith(".\")) {
        $normalizedUserId = "$env:COMPUTERNAME\$($normalizedUserId.Substring(2))"
    }

    try {
        $account = [System.Security.Principal.NTAccount]::new($normalizedUserId)
        $null = $account.Translate([System.Security.Principal.SecurityIdentifier])
        return $normalizedUserId
    } catch {
        throw "Windows cannot resolve user '$UserId' (normalized as '$normalizedUserId'). Check the exact Windows login name. For local users use '$env:COMPUTERNAME\UserName'."
    }
}

function Register-PATflowLogonTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$ResolvedUserId,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Trigger,
        [Parameter(Mandatory = $true)]$Principal,
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (!(Test-Path -LiteralPath $ScriptPath)) {
        throw "Task script not found: $ScriptPath"
    }

    $arguments = @(
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle",
        "Hidden",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$ScriptPath`"",
        "-ConfigPath",
        "`"$($Config.ConfigPath)`""
    ) -join " "

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings `
        -Description $Description `
        -Force | Out-Null

    Write-BenningLog -Config $Config -Message "Registered logon task '$TaskName' for user '$ResolvedUserId': $ScriptPath"
    Write-Output "Scheduled task registered: $TaskName"
    Write-Output "Script: $ScriptPath"
}

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    $sdWatcherScript = Join-Path $PSScriptRoot "Watch-SdCardAndRunDirectDatabaseWorkflow.ps1"
    $pdfWatcherScript = Join-Path $PSScriptRoot "Watch-PdfExportAndPrintNewPdfs.ps1"
    $resolvedUserId = Resolve-BenningScheduledTaskUserId -UserId $UserId

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $resolvedUserId
    $principal = New-ScheduledTaskPrincipal -UserId $resolvedUserId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    Register-PATflowLogonTask `
        -TaskName "$TaskNamePrefix SD Card Workflow Watcher" `
        -ScriptPath $sdWatcherScript `
        -ResolvedUserId $resolvedUserId `
        -Config $config `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Starts the PATflow SD card direct database workflow watcher when the configured user logs on."

    Register-PATflowLogonTask `
        -TaskName "$TaskNamePrefix PDF Print Watcher" `
        -ScriptPath $pdfWatcherScript `
        -ResolvedUserId $resolvedUserId `
        -Config $config `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Starts the PATflow PDF export print watcher when the configured user logs on."

    Write-Output "User: $resolvedUserId"
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message "Failed to register PATflow logon tasks: $($_.Exception.Message)"
    }

    throw
}
