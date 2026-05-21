param(
    [Parameter(Mandatory = $true)]
    [string]$UserId,

    [string]$TaskName = "PATflow BENNING Import Watcher",

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

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    $watcherScript = Join-Path $PSScriptRoot "Watch-SdCardAndRunDirectDatabaseWorkflow.ps1"
    $resolvedUserId = Resolve-BenningScheduledTaskUserId -UserId $UserId

    if (!(Test-Path -LiteralPath $watcherScript)) {
        throw "Import watcher script not found: $watcherScript"
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$watcherScript`"",
        "-ConfigPath",
        "`"$($config.ConfigPath)`""
    ) -join " "

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $resolvedUserId
    $principal = New-ScheduledTaskPrincipal -UserId $resolvedUserId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Starts the PATflow BENNING import watcher when the configured user logs on." `
        -Force | Out-Null

    Write-BenningLog -Config $config -Message "Registered import watcher logon task '$TaskName' for user '$resolvedUserId'"
    Write-Output "Scheduled task registered: $TaskName"
    Write-Output "User: $resolvedUserId"
    Write-Output "Watcher: $watcherScript"
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message "Failed to register import watcher logon task: $($_.Exception.Message)"
    }

    throw
}
