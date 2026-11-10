#requires -Version 5.1
<#
.SYNOPSIS
    Runs the focused, no-live OllamaConnector contract audit.
.DESCRIPTION
    Executes the dedicated payload/history tests plus selected existing
    timeout, mode-reset, cancellation, and game-generation tests.
    The client is mocked; no model inference or Ollama service operation occurs.
    JUnit, JSON, logs, and Python caches default to the ignored repository-local tmp/Audits/Connector directory.
.EXAMPLE
    .\scripts\windows\batllm-connector-audit.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}
$repoPath = [IO.Path]::GetFullPath($RepoRoot)

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoPath 'tmp\Audits\Connector'
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$normalizedOutputRoot = $outputRoot.TrimEnd('\', '/')
$normalizedRepoRoot = $repoPath.TrimEnd('\', '/')
if ($normalizedOutputRoot.Equals($normalizedRepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be a dedicated directory, not the repository root.'
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$junitPath = Join-Path $outputRoot ("connector-audit-$stamp.junit.xml")
$logPath = Join-Path $outputRoot ("connector-audit-$stamp.log")
$reportPath = Join-Path $outputRoot ("connector-audit-$stamp.json")
$cachePath = Join-Path $outputRoot ("pycache-connector-$stamp")

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

$testNodes = @(
    'src/tests/test_ollama_connector_contract.py',
    'src/tests/test_gameplay_deterministic.py::test_ollama_connector_ensure_system_message_inserts_header_once',
    'src/tests/test_gameplay_deterministic.py::test_ollama_connector_retries_once_after_timeout',
    'src/tests/test_gameplay_deterministic.py::test_ollama_connector_timeout_raises_typed_error_and_rolls_back_prompt',
    'src/tests/test_gameplay_deterministic.py::test_new_game_replaces_connector_history_generation',
    'src/tests/test_gameplay_deterministic.py::test_completed_game_restart_replaces_connector_history_generation',
    'src/tests/test_post_merge_repairs.py::test_ui_mode_changes_reset_history_before_building_header',
    'src/tests/test_post_merge_repairs.py::test_round_cancellation_cannot_restore_history_from_previous_context_mode'
)

try {
    if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) {
        throw ("Repository directory does not exist: " + $repoPath)
    }
    $pythonExe = Join-Path $repoPath '.venv_BatLLM\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        throw 'Project interpreter .venv_BatLLM\Scripts\python.exe is missing.'
    }
    foreach ($relativePath in @(
        'src/tests/test_ollama_connector_contract.py',
        'src/tests/test_gameplay_deterministic.py',
        'src/tests/test_post_merge_repairs.py'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $repoPath $relativePath) -PathType Leaf)) {
            throw ("Required test file is missing: " + $relativePath)
        }
    }

    $gitBefore = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'status', '--porcelain=v1', '--untracked-files=normal')
    $shaBefore = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'rev-parse', 'HEAD')
    $branchResult = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'branch', '--show-current')

    $previousEnvironment = @{
        PYTHONPYCACHEPREFIX = [Environment]::GetEnvironmentVariable('PYTHONPYCACHEPREFIX', 'Process')
        PYTHONDONTWRITEBYTECODE = [Environment]::GetEnvironmentVariable('PYTHONDONTWRITEBYTECODE', 'Process')
        PYTEST_ADDOPTS = [Environment]::GetEnvironmentVariable('PYTEST_ADDOPTS', 'Process')
        PYTHONPATH = [Environment]::GetEnvironmentVariable('PYTHONPATH', 'Process')
    }
    try {
        New-Item -ItemType Directory -Path $cachePath -Force | Out-Null
        $env:PYTHONPYCACHEPREFIX = $cachePath
        $env:PYTHONDONTWRITEBYTECODE = '1'
        $env:PYTEST_ADDOPTS = '-p no:cacheprovider'
        $srcPath = Join-Path $repoPath 'src'
        $oldPythonPath = $previousEnvironment.PYTHONPATH
        $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($oldPythonPath)) {
            $srcPath
        }
        else {
            $srcPath + [IO.Path]::PathSeparator + $oldPythonPath
        }

        $pytestArguments = @('-B', '-m', 'pytest', '-q', '--junitxml', $junitPath) + $testNodes
        $testResult = Invoke-NativeCommand $pythonExe $pytestArguments
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
        $warnings += 'One or more selected tests were skipped; inspect the JUnit report.'
    }
    $result = if ($testResult.exit_code -ne 0 -or -not (Test-Path -LiteralPath $junitPath -PathType Leaf) -or
        $junitCounts.tests -le 0 -or $junitCounts.tests -eq $junitCounts.skipped -or
        $shaBefore.exit_code -ne 0 -or $shaAfter.exit_code -ne 0) {
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
        tool = 'batllm-connector-audit'
        checked_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        repository_path = $repoPath
        branch = if ($branchResult.exit_code -eq 0) { $branchResult.output } else { $null }
        tested_sha = if ($shaBefore.exit_code -eq 0) { $shaBefore.output } else { $null }
        result = $result
        no_live_ollama = $true
        method = 'pytest with a mocked game.ollama_connector.Client; requests are deep-copied and inspected before responses are returned.'
        test_nodes = $testNodes
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

    Write-Output ("BatLLM OllamaConnector audit: " + $result)
    Write-Output ("Tests: " + $junitCounts.tests + "; failures: " + $junitCounts.failures + "; errors: " + $junitCounts.errors + "; skipped: " + $junitCounts.skipped)
    Write-Output ("Tested SHA: " + $report.tested_sha)
    Write-Output ("JUnit: " + $junitPath)
    Write-Output ("Report: " + $reportPath)

    if ($result -eq 'FAIL') { exit 1 }
    if ($result -eq 'WARN') { exit 2 }
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
