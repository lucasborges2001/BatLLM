#requires -Version 5.1
<#
.SYNOPSIS
    Plan or apply an isolated Windows setup for a BatLLM source checkout.
.DESCRIPTION
    Plan mode is read-only (the default). -Apply explicitly allows changes.
    NonLive prepares Python dependencies without Ollama.
    Gameplay additionally checks local Ollama and a selected model; installation,
    service startup, model downloads, and app launch require separate switches.
    Does not edit tracked files, global Python, or persistent environment variables.
.EXAMPLE
    .\scripts\windows\batllm-apply.ps1 -Mode NonLive
.EXAMPLE
    .\scripts\windows\batllm-apply.ps1 -Mode NonLive -Apply
.EXAMPLE
    .\scripts\windows\batllm-apply.ps1 -Mode Gameplay -Apply -InstallOllama -StartOllama -PullModel -Model smollm2 -Launch
#>
[CmdletBinding()]
param(
    [ValidateSet('NonLive', 'Gameplay')][string]$Mode = 'NonLive',
    [switch]$Apply,
    [switch]$InstallOllama,
    [switch]$StartOllama,
    [switch]$PullModel,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]*$')][string]$Model = 'smollm2',
    [switch]$Launch,
    [switch]$RunCoreTests,
    [string]$StateDir = (Join-Path $env:APPDATA 'BatLLM\Workshop')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Success {
    param([string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} failed (exit code {1})." -f $Operation, $LASTEXITCODE)
    }
}

function Get-Check {
    param($Report, [string]$Name)
    $matching = @($Report.checks | Where-Object { $_.name -eq $Name })
    if ($matching.Count -ne 1) { throw ('Missing Doctor check: ' + $Name) }
    return $matching[0]
}

function Invoke-DoctorReport {
    param([string]$Target)
    $raw = & $doctor -Target $Target -RepoRoot $repo -Json
    if ($LASTEXITCODE -ne 0) { throw 'Doctor execution failed.' }
    return (($raw | Out-String) | ConvertFrom-Json)
}

function Get-OllamaExecutable {
    $items = New-Object 'System.Collections.Generic.List[string]'
    $cmd = Get-Command 'ollama.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $cmd) { [void]$items.Add($cmd.Source) }
    if ($env:LOCALAPPDATA) {
        [void]$items.Add((Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'))
    }
    if ($env:ProgramFiles) {
        [void]$items.Add((Join-Path $env:ProgramFiles 'Ollama\ollama.exe'))
    }
    foreach ($candidate in $items) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-OllamaApi {
    param([string]$Path)
    try {
        return Invoke-RestMethod -Method Get -Uri ('http://127.0.0.1:11434' + $Path) -TimeoutSec 3
    }
    catch {
        return $null
    }
}

function Assert-ConfigModel {
    param([string]$ConfigPath, [string]$ExpectedModel)
    # Existing user configuration is never overwritten or silently merged.
    $code = "import sys, yaml; p=sys.argv[1]; d=yaml.safe_load(open(p, encoding='utf-8')) or {}; print((d.get('llm') or {}).get('model') or '')"
    $configured = (& $venvPython -B -c $code $ConfigPath | Out-String).Trim()
    Assert-Success 'Read existing isolated model configuration'
    if ($configured -ne $ExpectedModel) {
        throw ("Existing {0} selects model '{1}', not '{2}'. Review it manually; Apply will not overwrite it." -f $ConfigPath, $configured, $ExpectedModel)
    }
}

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\', '/')
$doctor = Join-Path $PSScriptRoot 'batllm-doctor.ps1'
$requirements = Join-Path $repo 'requirements.txt'
$venvPython = Join-Path $repo '.venv_BatLLM\Scripts\python.exe'
$configPath = $null

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'BatLLM Apply currently supports Windows only.'
}
if (-not (Test-Path -LiteralPath $doctor -PathType Leaf)) {
    throw 'batllm-doctor.ps1 is missing; apply the Doctor commit first.'
}
if (-not (Test-Path -LiteralPath $requirements -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $repo 'run_batllm.py') -PathType Leaf)) {
    throw 'The BatLLM repository is incomplete.'
}
if ($Mode -eq 'NonLive' -and ($InstallOllama -or $StartOllama -or $PullModel -or $Launch)) {
    throw 'Ollama and application-launch switches require -Mode Gameplay.'
}
if ($PullModel -and -not $StartOllama) {
    Write-Output 'INFO: Model download requires an already running service or -StartOllama.'
}
if ([string]::IsNullOrWhiteSpace($StateDir) -or -not [IO.Path]::IsPathRooted($StateDir)) {
    throw 'StateDir must be an absolute path outside the checkout.'
}
$stateFull = [IO.Path]::GetFullPath($StateDir).TrimEnd('\', '/')
if ($stateFull.Equals($repo, [StringComparison]::OrdinalIgnoreCase) -or
    $stateFull.StartsWith(($repo + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'StateDir must be outside the Git checkout.'
}
$configPath = Join-Path $stateFull 'config.yaml'

# No writes before -Apply. Planning is possible without Python or Ollama.
if (-not $Apply) {
    Write-Output 'BatLLM Windows Apply | PLAN ONLY | no changes made'
    Write-Output ('Mode: ' + $Mode)
    Write-Output ('Checkout: ' + $repo)
    Write-Output ('State: ' + $stateFull)
    Write-Output '1. Reuse or create .venv_BatLLM with supported Python.'
    Write-Output '2. Install requirements.txt only if Doctor reports missing dependencies.'
    Write-Output '3. Verify pip dependencies and re-run Doctor.'
    if ($Mode -eq 'Gameplay') {
        Write-Output ('4. Require Ollama at localhost:11434 and installed model ' + $Model)
        if ($InstallOllama) { Write-Output '   - If missing: install Ollama using exact winget ID Ollama.Ollama.' }
        if ($StartOllama) { Write-Output '   - If stopped: start local Ollama, never stop it automatically.' }
        if ($PullModel) { Write-Output ('   - If missing: download model ' + $Model + ' (disk/network impact).') }
        Write-Output '5. Create isolated config.yaml only if absent; never overwrite it.'
        if ($Launch) { Write-Output '6. Launch BatLLM in the current terminal.' }
    }
    if ($RunCoreTests) { Write-Output 'Optional: run core tests; a known baseline test may fail.' }
    exit 0
}

# Apply is opt-in, and mutates the venv and external StateDir only.
$gitRoot = (& git --no-optional-locks -C $repo rev-parse --show-toplevel | Out-String).Trim()
Assert-Success 'Inspect Git checkout'
if (-not [IO.Path]::GetFullPath($gitRoot).TrimEnd('\', '/').Equals($repo, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Apply must run from its own BatLLM Git checkout.'
}

if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    $launcher = Get-Command py -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $launcher) {
        throw 'Python launcher py.exe is missing. Install Python 3.12 and retry.'
    }
    $check = (& py -3.12 -c 'import sys; print(sys.version_info[:2] == (3, 12))' | Out-String).Trim()
    Assert-Success 'Locate Python 3.12'
    if ($check -ne 'True') { throw 'Python 3.12 was not found.' }
    Write-Output 'CREATE: project .venv_BatLLM using Python 3.12'
    & py -3.12 -m venv (Join-Path $repo '.venv_BatLLM')
    Assert-Success 'Create virtual environment'
}

$venvVersion = (& $venvPython -B -c 'import sys; print(sys.version_info.major, sys.version_info.minor, sep=chr(46))' | Out-String).Trim()
Assert-Success 'Inspect project Python'
if (@('3.10', '3.11', '3.12') -notcontains $venvVersion) {
    throw ('Unsupported existing virtualenv Python: ' + $venvVersion)
}

# Set state path for this process and launched child processes; no global persistence.
$env:BATLLM_HOME = $stateFull
$before = Invoke-DoctorReport 'NonLive'
if ((Get-Check $before 'dependencies').status -ne 'PASS') {
    Write-Output 'INSTALL: project dependencies into .venv_BatLLM'
    & $venvPython -m pip install -r $requirements
    Assert-Success 'Install requirements.txt'
}
& $venvPython -m pip check
Assert-Success 'pip check'
$after = Invoke-DoctorReport 'NonLive'
foreach ($key in @('repository', 'virtualenv', 'python', 'dependencies', 'batllm_home')) {
    $check = Get-Check $after $key
    Write-Output ('[{0}] {1}: {2}' -f $check.status, $key, $check.detail)
    if ($check.status -ne 'PASS') { throw ('Apply prerequisite failed: ' + $key) }
}
Write-Output 'READY: NonLive Python environment, independent of Ollama.'

if ($RunCoreTests) {
    Write-Output 'TEST: core (non-live). Known upstream configuration mismatch may fail.'
    & $venvPython (Join-Path $repo 'run_tests.py') core
    Assert-Success 'Core tests'
}

if ($Mode -eq 'NonLive') { exit 0 }

$ollama = Get-OllamaExecutable
if ($null -eq $ollama -and $InstallOllama) {
    if (-not (Get-Command winget -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'winget is unavailable. Use the official Ollama Windows installer manually and retry.'
    }
    Write-Output 'INSTALL: Ollama using winget (external application, opt-in).'
    & winget install --id Ollama.Ollama --exact --source winget --accept-package-agreements --accept-source-agreements
    Assert-Success 'Install Ollama'
    $ollama = Get-OllamaExecutable
}
if ($null -eq $ollama) {
    throw 'Ollama is missing. Re-run with -InstallOllama or install it manually.'
}

$version = Get-OllamaApi '/api/version'
if ($null -eq $version -and $StartOllama) {
    Write-Output 'START: Ollama (will remain running after Apply exits).'
    Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    for ($try = 0; $try -lt 30; $try++) {
        Start-Sleep -Seconds 1
        $version = Get-OllamaApi '/api/version'
        if ($null -ne $version) { break }
    }
}
if ($null -eq $version -or -not $version.version) {
    throw 'Ollama API at http://127.0.0.1:11434 is not ready. Use -StartOllama or inspect the service.'
}
Write-Output ('READY: Ollama ' + $version.version)

$tags = Get-OllamaApi '/api/tags'
if ($null -eq $tags -or $null -eq $tags.models) {
    throw 'Ollama model list could not be read.'
}
$installedNames = @($tags.models | ForEach-Object { [string]$_.name })
$acceptableModelNames = @($Model, ($Model + ':latest'))
$hasModel = @($installedNames | Where-Object { $acceptableModelNames -contains $_ }).Count -gt 0
if (-not $hasModel -and $PullModel) {
    Write-Output ('DOWNLOAD: Ollama model ' + $Model + ' (may use significant disk space).')
    & $ollama pull $Model
    Assert-Success 'Pull Ollama model'
    $tags = Get-OllamaApi '/api/tags'
    if ($null -eq $tags -or $null -eq $tags.models) { throw 'Cannot verify downloaded Ollama model.' }
    $installedNames = @($tags.models | ForEach-Object { [string]$_.name })
    $hasModel = @($installedNames | Where-Object { $acceptableModelNames -contains $_ }).Count -gt 0
}
if (-not $hasModel) {
    throw ('Ollama model ' + $Model + ' is not installed. Re-run with -PullModel if download is approved.')
}

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    # Use a minimal user overlay. Never modify src/configs/config.yaml.
    New-Item -ItemType Directory -Path $stateFull -Force | Out-Null
    $payload = "llm:`r`n  model: '$Model'`r`n"
    [IO.File]::WriteAllText($configPath, $payload, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output ('CREATE: isolated config overlay ' + $configPath)
}
else {
    Assert-ConfigModel $configPath $Model
    Write-Output 'KEEP: existing isolated config matches the selected model.'
}

$gameReport = Invoke-DoctorReport 'Gameplay'
foreach ($key in @('ollama_cli', 'batllm_home')) {
    $check = Get-Check $gameReport $key
    if ($check.status -ne 'PASS') { throw ('Gameplay Doctor prerequisite failed: ' + $key) }
}
Write-Output ('READY: Gameplay prerequisites and installed model ' + $Model)
Write-Output ('BATLLM_HOME (this process): ' + $env:BATLLM_HOME)
if ($Launch) {
    Write-Output 'LAUNCH: BatLLM (GUI). Ollama will not be stopped automatically by Apply.'
    Push-Location $repo
    try {
        & $venvPython (Join-Path $repo 'run_batllm.py')
        Assert-Success 'Run BatLLM'
    }
    finally {
        Pop-Location
    }
}
