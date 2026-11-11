#requires -Version 5.1
<#
.SYNOPSIS
    Sends two real gameplay messages through OllamaConnector.
.DESCRIPTION
    Uses an already-running Ollama endpoint and an already-installed model.
    Does not start or stop Ollama, download or delete models, or persist settings.
    Reports are written under tmp/YYYY-MM-DD/HH/OllamaConnectorLive.
.EXAMPLE
    .\scripts\windows\batllm-connector-live.ps1
.EXAMPLE
    .\scripts\windows\batllm-connector-live.ps1 -Model "smollm2:latest"
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$OutputDirectory = '',
    [string]$Model = '',
    [string]$Url = '',
    [int]$Port = 0,
    [double]$TimeoutSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$repoPath = [IO.Path]::GetFullPath($RepoRoot)
if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) {
    throw ("Repository directory does not exist: " + $repoPath)
}

$runStarted = Get-Date
$runDate = $runStarted.ToString('yyyy-MM-dd')
$runHour = $runStarted.ToString('HH')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoPath ("tmp\$runDate\$runHour\OllamaConnectorLive")
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$normalizedOutputRoot = $outputRoot.TrimEnd('\', '/')
$normalizedRepoRoot = $repoPath.TrimEnd('\', '/')
if ($normalizedOutputRoot.Equals($normalizedRepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be a dedicated directory, not the repository root.'
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$stamp = $runStarted.ToString('yyyyMMdd-HHmmss-fff')
$junitPath = Join-Path $outputRoot ("connector-live-$stamp.junit.xml")
$logPath = Join-Path $outputRoot ("connector-live-$stamp.log")
$reportPath = Join-Path $outputRoot ("connector-live-$stamp.json")
$cachePath = Join-Path $outputRoot ("pycache-connector-live-$stamp")
$pythonExe = Join-Path $repoPath '.venv_BatLLM\Scripts\python.exe'
$testPath = Join-Path $repoPath 'src\tests\test_ollama_connector_live.py'

if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
    throw 'Project interpreter .venv_BatLLM\Scripts\python.exe is missing.'
}
if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
    throw ("Live Connector test is missing: " + $testPath)
}
if ($Port -lt 0 -or $Port -gt 65535) {
    throw 'Port must be between 1 and 65535 when specified.'
}
if ($TimeoutSeconds -lt 0) {
    throw 'TimeoutSeconds cannot be negative.'
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Arguments = @()
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Executable @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    catch {
        $output = @($_.Exception.Message)
        $code = 1
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($null -eq $code) { $code = 1 }
    $text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{ exit_code = [int]$code; output = $text }
}

function Restore-ProcessEnvironment {
    param([hashtable]$Previous)
    foreach ($name in $Previous.Keys) {
        if ($null -eq $Previous[$name]) {
            Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -LiteralPath ("Env:" + $name) -Value $Previous[$name]
        }
    }
}

$previousEnvironment = @{
    BATLLM_RUN_OLLAMA_CONNECTOR_LIVE = [Environment]::GetEnvironmentVariable('BATLLM_RUN_OLLAMA_CONNECTOR_LIVE', 'Process')
    BATLLM_LIVE_MODEL = [Environment]::GetEnvironmentVariable('BATLLM_LIVE_MODEL', 'Process')
    BATLLM_LIVE_URL = [Environment]::GetEnvironmentVariable('BATLLM_LIVE_URL', 'Process')
    BATLLM_LIVE_PORT = [Environment]::GetEnvironmentVariable('BATLLM_LIVE_PORT', 'Process')
    BATLLM_LIVE_TIMEOUT = [Environment]::GetEnvironmentVariable('BATLLM_LIVE_TIMEOUT', 'Process')
    PYTHONPYCACHEPREFIX = [Environment]::GetEnvironmentVariable('PYTHONPYCACHEPREFIX', 'Process')
    PYTHONDONTWRITEBYTECODE = [Environment]::GetEnvironmentVariable('PYTHONDONTWRITEBYTECODE', 'Process')
    PYTEST_ADDOPTS = [Environment]::GetEnvironmentVariable('PYTEST_ADDOPTS', 'Process')
    PYTHONPATH = [Environment]::GetEnvironmentVariable('PYTHONPATH', 'Process')
    TEMP = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
    TMP = [Environment]::GetEnvironmentVariable('TMP', 'Process')
    TMPDIR = [Environment]::GetEnvironmentVariable('TMPDIR', 'Process')
}

try {
    $gitBefore = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'status', '--porcelain=v1', '--untracked-files=normal')
    $shaBefore = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'rev-parse', 'HEAD')
    $branchResult = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'branch', '--show-current')

    $env:BATLLM_RUN_OLLAMA_CONNECTOR_LIVE = '1'
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $env:BATLLM_LIVE_MODEL = $Model
    }
    else {
        Remove-Item Env:BATLLM_LIVE_MODEL -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        $env:BATLLM_LIVE_URL = $Url
    }
    else {
        Remove-Item Env:BATLLM_LIVE_URL -ErrorAction SilentlyContinue
    }
    if ($Port -gt 0) {
        $env:BATLLM_LIVE_PORT = [string]$Port
    }
    else {
        Remove-Item Env:BATLLM_LIVE_PORT -ErrorAction SilentlyContinue
    }
    if ($TimeoutSeconds -gt 0) {
        $env:BATLLM_LIVE_TIMEOUT = [string]$TimeoutSeconds
    }
    else {
        Remove-Item Env:BATLLM_LIVE_TIMEOUT -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Path $cachePath -Force | Out-Null
    $env:PYTHONPYCACHEPREFIX = $cachePath
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $env:PYTEST_ADDOPTS = '-p no:cacheprovider'
    $env:TEMP = $outputRoot
    $env:TMP = $outputRoot
    $env:TMPDIR = $outputRoot
    $srcPath = Join-Path $repoPath 'src'
    $oldPythonPath = $previousEnvironment.PYTHONPATH
    $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($oldPythonPath)) {
        $srcPath
    }
    else {
        $srcPath + [IO.Path]::PathSeparator + $oldPythonPath
    }

    Push-Location $repoPath
    try {
        $pytestArguments = @('-B', '-m', 'pytest', '-q', '-s', '--junitxml', $junitPath, $testPath)
        $testResult = Invoke-NativeCommand $pythonExe $pytestArguments
    }
    finally {
        Pop-Location
    }
    [IO.File]::WriteAllText($logPath, $testResult.output, ([System.Text.UTF8Encoding]::new($false)))
}
finally {
    Restore-ProcessEnvironment $previousEnvironment
}

$warnings = @()
$junitCounts = [ordered]@{
    tests = 0
    failures = 0
    errors = 0
    skipped = 0
}
if (Test-Path -LiteralPath $junitPath -PathType Leaf) {
    try {
        [xml]$junit = Get-Content -LiteralPath $junitPath -Raw
        $suites = @($junit.SelectNodes('//testsuite'))
        if ($suites.Count -gt 0) {
            foreach ($suite in $suites) {
                $junitCounts.tests += [int]$suite.tests
                $junitCounts.failures += [int]$suite.failures
                $junitCounts.errors += [int]$suite.errors
                $junitCounts.skipped += [int]$suite.skipped
            }
        }
        else {
            $warnings += 'JUnit report contains no testsuite nodes.'
        }
    }
    catch {
        $warnings += 'JUnit report exists but could not be parsed: ' + $_.Exception.Message
    }
}
else {
    $warnings += 'Pytest did not produce a JUnit report.'
}

$gitAfter = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'status', '--porcelain=v1', '--untracked-files=normal')
$shaAfter = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'rev-parse', 'HEAD')
$repoStatusUnchanged = ($gitBefore.exit_code -eq 0 -and $gitAfter.exit_code -eq 0 -and $gitBefore.output -ceq $gitAfter.output)
$shaUnchanged = ($shaBefore.exit_code -eq 0 -and $shaAfter.exit_code -eq 0 -and $shaBefore.output -ceq $shaAfter.output)

if ($junitCounts.skipped -gt 0) {
    $warnings += 'The live test was skipped; inspect the JUnit report and activation environment.'
}
$result = if ($testResult.exit_code -ne 0 -or -not (Test-Path -LiteralPath $junitPath -PathType Leaf) -or
    $junitCounts.tests -ne 1 -or $junitCounts.failures -gt 0 -or $junitCounts.errors -gt 0 -or
    $junitCounts.skipped -gt 0 -or $shaBefore.exit_code -ne 0 -or $shaAfter.exit_code -ne 0) {
    'FAIL'
}
elseif (-not $repoStatusUnchanged -or -not $shaUnchanged -or $warnings.Count -gt 0) {
    'WARN'
}
else {
    'PASS'
}

$report = [ordered]@{
    schema_version = 1
    tool = 'batllm-connector-live'
    checked_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    repository_path = $repoPath
    branch = if ($branchResult.exit_code -eq 0) { $branchResult.output } else { $null }
    tested_sha = if ($shaBefore.exit_code -eq 0) { $shaBefore.output } else { $null }
    result = $result
    live_ollama = $true
    service_lifecycle = 'not_started_or_stopped'
    model_operations = 'no_download_or_delete'
    method = 'Two real messages sent through game.ollama_connector.OllamaConnector and the configured Modelito transport.'
    model_override = if ([string]::IsNullOrWhiteSpace($Model)) { $null } else { $Model }
    endpoint_override = if ([string]::IsNullOrWhiteSpace($Url) -and $Port -eq 0) { $null } else { ($Url + ':' + [string]$Port) }
    pytest_exit_code = $testResult.exit_code
    junit = $junitCounts
    repository_status_unchanged = $repoStatusUnchanged
    sha_unchanged = $shaUnchanged
    repository_status_before = $gitBefore.output
    repository_status_after = $gitAfter.output
    junit_path = $junitPath
    log_path = $logPath
    report_path = $reportPath
    warnings = @($warnings)
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Output ("BatLLM OllamaConnector live smoke: " + $result)
Write-Output ("Tests: " + $junitCounts.tests + "; failures: " + $junitCounts.failures + "; errors: " + $junitCounts.errors + "; skipped: " + $junitCounts.skipped)
Write-Output ("Tested SHA: " + $report.tested_sha)
Write-Output ("JUnit: " + $junitPath)
Write-Output ("Log: " + $logPath)
Write-Output ("Report: " + $reportPath)

if ($result -eq 'FAIL') { exit 1 }
if ($result -eq 'WARN') { exit 2 }
exit 0
