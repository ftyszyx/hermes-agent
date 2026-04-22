[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "uninstall", "status", "run", "stop")]
    [string]$Action = "status",

    [string]$TaskName = "HermesGateway",

    [string]$HermesHome = "",

    [string]$PythonPath = "",

    [switch]$NoVenv,

    [switch]$NoBootstrap,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GatewayArgs
)

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Resolve-AbsolutePath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ""
    }

    $resolved = Resolve-Path -LiteralPath $PathValue -ErrorAction SilentlyContinue
    if ($resolved) {
        return $resolved.Path
    }

    return [System.IO.Path]::GetFullPath($PathValue)
}

function Quote-CommandLineArgument {
    param([string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-TaskOrNull {
    param([string]$Name)

    return Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
}

function Get-StartWindowsScriptPath {
    $scriptPath = Join-Path $PSScriptRoot "start-windows.ps1"
    $resolved = Resolve-AbsolutePath $scriptPath
    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "Cannot find start-windows.ps1 at '$resolved'."
    }
    return $resolved
}

function Build-TaskAction {
    param(
        [string]$StartScript,
        [string]$RepoRoot,
        [string]$RequestedHermesHome,
        [string]$RequestedPythonPath,
        [switch]$SkipVenv,
        [switch]$SkipBootstrap,
        [string[]]$ExtraGatewayArgs
    )

    $powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellExe)) {
        throw "Windows PowerShell was not found at '$powerShellExe'."
    }

    $actionArgs = @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $StartScript,
        "-Mode", "gateway"
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedHermesHome)) {
        $actionArgs += @("-HermesHome", $RequestedHermesHome)
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedPythonPath)) {
        $actionArgs += @("-PythonPath", $RequestedPythonPath)
    }

    if ($SkipVenv) {
        $actionArgs += "-NoVenv"
    }

    if ($SkipBootstrap) {
        $actionArgs += "-NoBootstrap"
    }

    if ($ExtraGatewayArgs) {
        $actionArgs += $ExtraGatewayArgs
    }

    $argumentString = ($actionArgs | ForEach-Object { Quote-CommandLineArgument $_ }) -join " "
    return New-ScheduledTaskAction -Execute $powerShellExe -Argument $argumentString -WorkingDirectory $RepoRoot
}

function Install-GatewayTask {
    param(
        [string]$Name,
        [string]$RequestedHermesHome,
        [string]$RequestedPythonPath,
        [switch]$SkipVenv,
        [switch]$SkipBootstrap,
        [string[]]$ExtraGatewayArgs
    )

    $startScript = Get-StartWindowsScriptPath
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $action = Build-TaskAction `
        -StartScript $startScript `
        -RepoRoot $repoRoot `
        -RequestedHermesHome $RequestedHermesHome `
        -RequestedPythonPath $RequestedPythonPath `
        -SkipVenv:$SkipVenv `
        -SkipBootstrap:$SkipBootstrap `
        -ExtraGatewayArgs $ExtraGatewayArgs

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    $description = "Start Hermes gateway at user logon without Windows Service."

    Register-ScheduledTask `
        -TaskName $Name `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description $description `
        -Force | Out-Null

    Write-Info "Scheduled task installed: $Name"
    Write-Info "Trigger: At logon for $currentUser"
    Write-Info "Run command: $($action.Execute) $($action.Arguments)"
}

function Show-GatewayTaskStatus {
    param([string]$Name)

    $task = Get-TaskOrNull -Name $Name
    if (-not $task) {
        Write-Warn "Scheduled task '$Name' is not installed."
        return
    }

    $info = Get-ScheduledTaskInfo -TaskName $Name
    $action = $task.Actions | Select-Object -First 1

    Write-Info "Scheduled task found: $Name"
    Write-Host ("State:          " + $task.State)
    Write-Host ("Last run time:  " + $info.LastRunTime)
    Write-Host ("Last result:    " + $info.LastTaskResult)
    Write-Host ("Next run time:  " + $info.NextRunTime)
    if ($action) {
        Write-Host ("Execute:        " + $action.Execute)
        Write-Host ("Arguments:      " + $action.Arguments)
        Write-Host ("Working dir:    " + $action.WorkingDirectory)
    }
}

function Uninstall-GatewayTask {
    param([string]$Name)

    $task = Get-TaskOrNull -Name $Name
    if (-not $task) {
        Write-Warn "Scheduled task '$Name' is not installed."
        return
    }

    Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    Write-Info "Scheduled task removed: $Name"
}

function Start-GatewayTaskNow {
    param([string]$Name)

    $task = Get-TaskOrNull -Name $Name
    if (-not $task) {
        throw "Scheduled task '$Name' is not installed."
    }

    Start-ScheduledTask -TaskName $Name
    Write-Info "Scheduled task started: $Name"
}

function Stop-GatewayTaskNow {
    param([string]$Name)

    $task = Get-TaskOrNull -Name $Name
    if (-not $task) {
        throw "Scheduled task '$Name' is not installed."
    }

    Stop-ScheduledTask -TaskName $Name
    Write-Info "Scheduled task stopped: $Name"
}

if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    throw "ScheduledTasks module is not available on this Windows installation."
}

$resolvedHermesHome = Resolve-AbsolutePath $HermesHome
$resolvedPythonPath = Resolve-AbsolutePath $PythonPath

switch ($Action) {
    "install" {
        Install-GatewayTask `
            -Name $TaskName `
            -RequestedHermesHome $resolvedHermesHome `
            -RequestedPythonPath $resolvedPythonPath `
            -SkipVenv:$NoVenv `
            -SkipBootstrap:$NoBootstrap `
            -ExtraGatewayArgs $GatewayArgs
    }
    "uninstall" {
        Uninstall-GatewayTask -Name $TaskName
    }
    "status" {
        Show-GatewayTaskStatus -Name $TaskName
    }
    "run" {
        Start-GatewayTaskNow -Name $TaskName
    }
    "stop" {
        Stop-GatewayTaskNow -Name $TaskName
    }
}
