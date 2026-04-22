[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet("chat", "gateway", "dashboard", "setup", "doctor", "model", "config", "custom")]
    [string]$Mode = "chat",

    [string]$RepoRoot = "",

    [string]$HermesHome = "",

    [string]$PythonPath = "",

    [switch]$NoVenv,

    [switch]$NoBootstrap,

    [switch]$PrintOnly,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$HermesArgs
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    } else {
        $RepoRoot = (Get-Location).Path
    }
}

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

function Resolve-HermesHomePath {
    param([string]$RequestedHome)

    if (-not [string]::IsNullOrWhiteSpace($RequestedHome)) {
        return (Resolve-AbsolutePath $RequestedHome)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:HERMES_HOME)) {
        return $env:HERMES_HOME
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA "hermes")
    }

    return (Join-Path $HOME ".hermes")
}

function Ensure-HermesHomeLayout {
    param(
        [string]$HomePath,
        [string]$RepoPath
    )

    $subdirs = @(
        "cron",
        "sessions",
        "logs",
        "pairing",
        "hooks",
        "image_cache",
        "audio_cache",
        "memories",
        "skills",
        "whatsapp\session"
    )

    New-Item -ItemType Directory -Force -Path $HomePath | Out-Null

    foreach ($subdir in $subdirs) {
        New-Item -ItemType Directory -Force -Path (Join-Path $HomePath $subdir) | Out-Null
    }

    $envPath = Join-Path $HomePath ".env"
    $envExamplePath = Join-Path $RepoPath ".env.example"
    if (-not (Test-Path -LiteralPath $envPath)) {
        if (Test-Path -LiteralPath $envExamplePath) {
            Copy-Item -LiteralPath $envExamplePath -Destination $envPath
        } else {
            New-Item -ItemType File -Force -Path $envPath | Out-Null
        }
    }

    $configPath = Join-Path $HomePath "config.yaml"
    $configExamplePath = Join-Path $RepoPath "cli-config.yaml.example"
    if (-not (Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $configExamplePath)) {
        Copy-Item -LiteralPath $configExamplePath -Destination $configPath
    }

    $soulPath = Join-Path $HomePath "SOUL.md"
    if (-not (Test-Path -LiteralPath $soulPath)) {
        $soulContent = @"
# Hermes Agent Persona

<!-- Edit this file to customize how Hermes communicates. -->

You are Hermes, a helpful AI assistant.
"@
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($soulPath, $soulContent, $utf8NoBom)
    }
}

function Resolve-PythonLauncher {
    param(
        [string]$RepoPath,
        [string]$RequestedPython,
        [switch]$SkipVenvLookup
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPython)) {
        $resolved = Resolve-AbsolutePath $RequestedPython
        if (Test-Path -LiteralPath $resolved) {
            return @{
                Command = $resolved
                Prefix = @()
            }
        }

        $cmd = Get-Command $RequestedPython -ErrorAction SilentlyContinue
        if ($cmd) {
            return @{
                Command = $cmd.Source
                Prefix = @()
            }
        }

        throw "Python launcher '$RequestedPython' was not found."
    }

    if (-not $SkipVenvLookup) {
        $venvCandidates = @(
            (Join-Path $RepoPath ".venv\Scripts\python.exe"),
            (Join-Path $RepoPath "venv\Scripts\python.exe")
        )

        foreach ($candidate in $venvCandidates) {
            if (Test-Path -LiteralPath $candidate) {
                return @{
                    Command = $candidate
                    Prefix = @()
                }
            }
        }
    }

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        return @{
            Command = $pythonCmd.Source
            Prefix = @()
        }
    }

    $pyCmd = Get-Command py -ErrorAction SilentlyContinue
    if ($pyCmd) {
        return @{
            Command = $pyCmd.Source
            Prefix = @("-3")
        }
    }

    throw "Python was not found. Run scripts/install.ps1 first, or pass -PythonPath."
}

function Find-UvCommand {
    $uvCmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($uvCmd) {
        return $uvCmd.Source
    }

    $fallbacks = @(
        (Join-Path $HOME ".local\bin\uv.exe"),
        (Join-Path $HOME ".cargo\bin\uv.exe")
    )

    foreach ($candidate in $fallbacks) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Build-HermesCommandArgs {
    param(
        [string]$LaunchMode,
        [string[]]$ExtraArgs
    )

    $baseArgs = @("-m", "hermes_cli.main")

    switch ($LaunchMode) {
        "chat" {
            return $baseArgs + $ExtraArgs
        }
        "gateway" {
            if (-not $ExtraArgs -or $ExtraArgs.Count -eq 0) {
                return $baseArgs + @("gateway", "run")
            }

            $firstArg = $ExtraArgs[0]
            if (-not [string]::IsNullOrWhiteSpace($firstArg) -and $firstArg.StartsWith("-")) {
                return $baseArgs + @("gateway", "run") + $ExtraArgs
            }

            return $baseArgs + @("gateway") + $ExtraArgs
        }
        "dashboard" {
            return $baseArgs + @("dashboard") + $ExtraArgs
        }
        "setup" {
            return $baseArgs + @("setup") + $ExtraArgs
        }
        "doctor" {
            return $baseArgs + @("doctor") + $ExtraArgs
        }
        "model" {
            return $baseArgs + @("model") + $ExtraArgs
        }
        "config" {
            return $baseArgs + @("config") + $ExtraArgs
        }
        "custom" {
            if (-not $ExtraArgs -or $ExtraArgs.Count -eq 0) {
                throw "Mode 'custom' requires Hermes arguments, for example: -Mode custom gateway status"
            }
            return $baseArgs + $ExtraArgs
        }
    }

    throw "Unsupported mode '$LaunchMode'."
}

function Get-HermesPythonCheckResult {
    param(
        [string]$PythonCommand,
        [string[]]$PrefixArgs,
        [string]$LaunchMode = "chat"
    )

    $requiredModules = @("yaml", "rich", "prompt_toolkit", "dotenv")
    if ($LaunchMode -eq "dashboard") {
        $requiredModules += @("fastapi", "uvicorn")
    }

    $requiredJson = ($requiredModules | ConvertTo-Json -Compress)
    $probeCode = @'
import importlib.util
import json
import sys

required = __REQUIRED_MODULES__
missing = [name for name in required if importlib.util.find_spec(name) is None]
print(json.dumps({"missing": missing}))
sys.exit(0 if not missing else 3)
'@.Replace("__REQUIRED_MODULES__", $requiredJson)

    $probeFile = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-python-probe-" + [System.Guid]::NewGuid().ToString("N") + ".py")
    Set-Content -LiteralPath $probeFile -Value $probeCode -Encoding UTF8

    $probeArgs = @()
    $probeArgs += $PrefixArgs
    $probeArgs += @($probeFile)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $probeOutput = (& $PythonCommand @probeArgs 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
        $probeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
    }

    $missing = @()
    try {
        $probeResult = $probeOutput | ConvertFrom-Json
        if ($probeResult.missing) {
            $missing = @($probeResult.missing)
        }
    } catch {
        # Fall through to the generic error below.
    }

    return @{
        Ready = ($probeExitCode -eq 0)
        Missing = $missing
        Output = $probeOutput
        ExitCode = $probeExitCode
    }
}

function Test-HermesPythonReady {
    param(
        [string]$PythonCommand,
        [string[]]$PrefixArgs,
        [string]$LaunchMode = "chat"
    )

    $check = Get-HermesPythonCheckResult -PythonCommand $PythonCommand -PrefixArgs $PrefixArgs -LaunchMode $LaunchMode
    if ($check.Ready) {
        return
    }

    $installHint = "uv pip install -e "".[all]"""
    if ($LaunchMode -eq "dashboard") {
        $installHint = "uv pip install -e "".[web]"""
    }

    if ($check.Missing.Count -gt 0) {
        $missingList = $check.Missing -join ", "
        throw (
            "Python launcher '$PythonCommand' is missing Hermes dependencies: $missingList.`n" +
            "Run scripts/install.ps1 first, or install the repo into a venv with: $installHint"
        )
    }

    throw (
        "Python launcher '$PythonCommand' could not pass the Hermes dependency check.`n" +
        "Probe output: $($check.Output)"
    )
}

function Install-HermesRuntime {
    param(
        [string]$RepoPath,
        [string]$BootstrapPython,
        [string[]]$BootstrapPrefixArgs,
        [string]$LaunchMode
    )

    $venvDir = Join-Path $RepoPath ".venv"
    $venvPython = Join-Path $venvDir "Scripts\python.exe"
    $uvCommand = Find-UvCommand

    $installSpecs = @(".[all]", ".")
    if ($LaunchMode -eq "dashboard") {
        $installSpecs = @(".[web]", ".[all]", ".")
    } elseif ($LaunchMode -eq "gateway") {
        $installSpecs = @(".[all]", ".[messaging,cron,mcp,honcho,acp,web]", ".")
    }

    if ($uvCommand) {
        if (-not (Test-Path -LiteralPath $venvPython)) {
            Write-Info "No local Hermes virtual environment found. Creating .venv with uv..."

            $created = $false
            $createAttempts = @(
                @("venv", ".venv", "--python", "3.11"),
                @("venv", ".venv", "--python", $BootstrapPython)
            )

            foreach ($attempt in $createAttempts) {
                & $uvCommand @attempt
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $venvPython)) {
                    $created = $true
                    break
                }
            }

            if (-not $created) {
                throw "Failed to create .venv with uv."
            }
        }

        foreach ($spec in $installSpecs) {
            Write-Info "Installing Hermes dependencies into .venv with uv: $spec"
            Push-Location $RepoPath
            try {
                & $uvCommand pip install --python $venvPython -e $spec
            } finally {
                Pop-Location
            }

            if ($LASTEXITCODE -eq 0) {
                return @{
                    Command = $venvPython
                    Prefix = @()
                }
            }

            Write-Warn "Dependency install failed for $spec, trying the next fallback..."
        }

        throw "Failed to install Hermes dependencies with uv."
    }

    if (-not (Test-Path -LiteralPath $venvPython)) {
        Write-Info "No local Hermes virtual environment found. Creating .venv..."
        & $BootstrapPython @BootstrapPrefixArgs -m venv .venv
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $venvPython)) {
            throw "Failed to create .venv with the current Python launcher."
        }
    }

    & $venvPython -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Failed to upgrade pip inside .venv. Continuing with the bundled pip."
    }

    foreach ($spec in $installSpecs) {
        Write-Info "Installing Hermes dependencies into .venv: $spec"
        Push-Location $RepoPath
        try {
            & $venvPython -m pip install -e $spec
        } finally {
            Pop-Location
        }

        if ($LASTEXITCODE -eq 0) {
            return @{
                Command = $venvPython
                Prefix = @()
            }
        }

        Write-Warn "Dependency install failed for $spec, trying the next fallback..."
    }

    throw "Failed to install Hermes dependencies into .venv."
}

function Find-GitBash {
    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($env:HERMES_GIT_BASH_PATH)) {
        $candidates += $env:HERMES_GIT_BASH_PATH
    }

    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($bashCmd) {
        $candidates += $bashCmd.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += (Join-Path $env:ProgramFiles "Git\bin\bash.exe")
    }

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "Git\bin\bash.exe")
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe")
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

$resolvedRepoRoot = Resolve-AbsolutePath $RepoRoot
if (-not (Test-Path -LiteralPath $resolvedRepoRoot)) {
    throw "Repo root '$resolvedRepoRoot' does not exist."
}

$resolvedHermesHome = Resolve-HermesHomePath $HermesHome
Ensure-HermesHomeLayout -HomePath $resolvedHermesHome -RepoPath $resolvedRepoRoot
$env:HERMES_HOME = $resolvedHermesHome

$launcher = Resolve-PythonLauncher -RepoPath $resolvedRepoRoot -RequestedPython $PythonPath -SkipVenvLookup:$NoVenv
$commandArgs = @()
$commandArgs += $launcher.Prefix
$commandArgs += Build-HermesCommandArgs -LaunchMode $Mode -ExtraArgs $HermesArgs

$gitBashPath = Find-GitBash
if (-not $gitBashPath) {
    Write-Warn "Git Bash was not found. Hermes can still start, but terminal-backed tools may fail until Git for Windows is installed."
}

Write-Info "Repo root: $resolvedRepoRoot"
Write-Info "HERMES_HOME: $resolvedHermesHome"
Write-Info "Python: $($launcher.Command)"
Write-Info ("Command: " + ($commandArgs -join " "))

if ($PrintOnly) {
    exit 0
}

Push-Location $resolvedRepoRoot
try {
    $check = Get-HermesPythonCheckResult -PythonCommand $launcher.Command -PrefixArgs $launcher.Prefix -LaunchMode $Mode
    if (-not $check.Ready) {
        if ($NoBootstrap -or $NoVenv) {
            Test-HermesPythonReady -PythonCommand $launcher.Command -PrefixArgs $launcher.Prefix -LaunchMode $Mode
        }

        if ($check.Missing.Count -gt 0) {
            $missingList = $check.Missing -join ", "
            Write-Info "Current Python is missing Hermes dependencies: $missingList"
            Write-Info "Bootstrapping a local .venv for this repository..."
        } else {
            Write-Info "Current Python is not ready for Hermes. Bootstrapping a local .venv..."
        }

        $launcher = Install-HermesRuntime `
            -RepoPath $resolvedRepoRoot `
            -BootstrapPython $launcher.Command `
            -BootstrapPrefixArgs $launcher.Prefix `
            -LaunchMode $Mode

        Write-Info "Python: $($launcher.Command)"
        $check = Get-HermesPythonCheckResult -PythonCommand $launcher.Command -PrefixArgs $launcher.Prefix -LaunchMode $Mode
        if (-not $check.Ready) {
            Test-HermesPythonReady -PythonCommand $launcher.Command -PrefixArgs $launcher.Prefix -LaunchMode $Mode
        }
    }

    & $launcher.Command @commandArgs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
