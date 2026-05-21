param(
    [Parameter(Mandatory = $true)]
    [string]$UserId,

    [string]$TaskName = "PATflow BENNING Import Watcher",

    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Common-BenningAutomation.ps1"

try {
    $config = Get-BenningConfig -ConfigPath $ConfigPath
    $watcherScript = Join-Path $PSScriptRoot "Watch-BenningImports.ps1"

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
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel LeastPrivilege
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

    Write-BenningLog -Config $config -Message "Registered import watcher logon task '$TaskName' for user '$UserId'"
    Write-Output "Scheduled task registered: $TaskName"
    Write-Output "User: $UserId"
    Write-Output "Watcher: $watcherScript"
} catch {
    if ($config) {
        Write-BenningLog -Config $config -Level "ERROR" -Message "Failed to register import watcher logon task: $($_.Exception.Message)"
    }

    throw
}
