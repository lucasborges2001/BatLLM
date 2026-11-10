#requires -Version 5.1
<#
.SYNOPSIS
    Captures a read-only BatLLM environment and core-test baseline.
.DESCRIPTION
    Reuses scripts/windows/batllm-doctor.ps1, records Python and Modelito,
    captures Git metadata, and runs only python run_tests.py core.
    Reports and Python caches default to tmp/YYYY-MM-DD/HH/Baseline inside the ignored repository-local tmp directory.
    Does not install packages, contact Ollama, or modify tracked repository files.
.EXAMPLE
    .\scripts\windows\batllm-baseline.ps1
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
$runStarted = Get-Date
$runDate = $runStarted.ToString('yyyy-MM-dd')
$runHour = $runStarted.ToString('HH')

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoPath ("tmp\$runDate\$runHour\Baseline")
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$normalizedOutputRoot = $outputRoot.TrimEnd('\', '/')
$normalizedRepoRoot = $repoPath.TrimEnd('\', '/')
if ($normalizedOutputRoot.Equals($normalizedRepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be a dedicated directory, not the repository root.'
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$stamp = $runStarted.ToString('yyyyMMdd-HHmmss-fff')
$reportPath = Join-Path $outputRoot ("baseline-$stamp.json")
$coreLogPath = Join-Path $outputRoot ("baseline-core-$stamp.log")
$cachePath = Join-Path $outputRoot ("pycache-baseline-$stamp")

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

$git = [ordered]@{
    valid = $false
    branch = $null
    sha = $null
    upstream = $null
    worktree_clean = $null
    status = $null
    status_after = $null
    status_unchanged = $null
    sha_unchanged = $null
}
$doctorReport = $null
$pythonInfo = $null
$requiredModelito = $null
$modelitoMatchesRequirement = $false
$core = [ordered]@{
    status = 'NOT_RUN'
    exit_code = $null
    scope = 'run_tests.py core runs src/tests/test_history_compact.py only.'
    log = $coreLogPath
}
$hardFailures = New-Object 'System.Collections.Generic.List[string]'
$warnings = New-Object 'System.Collections.Generic.List[string]'

try {
    if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) {
        throw ("Repository directory does not exist: " + $repoPath)
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repoPath 'run_tests.py') -PathType Leaf)) {
        throw 'RepoRoot does not look like a BatLLM checkout (run_tests.py is missing).'
    }

    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $rootResult = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'rev-parse', '--show-toplevel')
        if ($rootResult.exit_code -eq 0) {
            $actualRoot = [IO.Path]::GetFullPath($rootResult.output).TrimEnd('\', '/')
            $expectedRoot = $repoPath.TrimEnd('\', '/')
            if ($actualRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $branchResult = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'branch', '--show-current')
                $shaResult = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'rev-parse', 'HEAD')
                $upstreamResult = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
                $statusResult = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'status', '--porcelain=v1', '--untracked-files=normal')
                $git.branch = if ($branchResult.exit_code -eq 0) { $branchResult.output } else { $null }
                $git.sha = if ($shaResult.exit_code -eq 0) { $shaResult.output } else { $null }
                $git.upstream = if ($upstreamResult.exit_code -eq 0) { $upstreamResult.output } else { $null }
                $git.status = $statusResult.output
                $git.worktree_clean = [string]::IsNullOrWhiteSpace($statusResult.output)
                $git.valid = ($branchResult.exit_code -eq 0 -and $shaResult.exit_code -eq 0 -and $statusResult.exit_code -eq 0)
            }
        }
    }
    if (-not $git.valid) {
        $hardFailures.Add('Unable to verify the repository root, branch, SHA, or working-tree status.')
    }
    elseif (-not $git.worktree_clean) {
        $warnings.Add('The working tree is not clean; inspect the recorded Git status before treating this as a pristine baseline.')
    }

    $doctorPath = Join-Path $repoPath 'scripts\windows\batllm-doctor.ps1'
    if (-not (Test-Path -LiteralPath $doctorPath -PathType Leaf)) {
        $hardFailures.Add('Existing batllm-doctor.ps1 was not found.')
    }
    else {
        $doctorRaw = & $doctorPath -Target NonLive -RepoRoot $repoPath -Json
        $doctorText = (($doctorRaw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        $doctorReport = $doctorText | ConvertFrom-Json
        foreach ($requiredName in @('repository', 'virtualenv', 'python', 'dependencies')) {
            $doctorChecks = @($doctorReport.checks | Where-Object { $_.name -eq $requiredName })
            if ($doctorChecks.Count -ne 1) {
                $hardFailures.Add("Windows Doctor prerequisite '$requiredName' returned $($doctorChecks.Count) checks; expected exactly one.")
            }
            elseif ($doctorChecks[0].status -ne 'PASS') {
                $detail = [string]$doctorChecks[0].detail
                $hardFailures.Add("Windows Doctor prerequisite '$requiredName' is $($doctorChecks[0].status): $detail")
            }
        }
        if ([int]$doctorReport.summary.WARN -gt 0) {
            $warnings.Add('Windows Doctor reported one or more warnings; inspect the embedded checks.')
        }
    }

    $pythonExe = Join-Path $repoPath '.venv_BatLLM\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        $hardFailures.Add('Project interpreter .venv_BatLLM\Scripts\python.exe is missing.')
    }
    else {
        $metadataCode = "import importlib.metadata as m, json, sys; print(json.dumps({'python': '.'.join(str(x) for x in sys.version_info[:3]), 'executable': sys.executable, 'modelito': m.version('modelito')}))"
        $metadataResult = Invoke-NativeCommand $pythonExe @('-B', '-c', $metadataCode)
        if ($metadataResult.exit_code -eq 0) {
            try {
                $pythonInfo = $metadataResult.output | ConvertFrom-Json
            }
            catch {
                $hardFailures.Add('Could not parse the Python/Modelito metadata response.')
            }
        }
        else {
            $hardFailures.Add('Could not read Python or installed Modelito metadata: ' + $metadataResult.output)
        }

        $requirementsPath = Join-Path $repoPath 'requirements.txt'
        if (Test-Path -LiteralPath $requirementsPath -PathType Leaf) {
            foreach ($line in (Get-Content -LiteralPath $requirementsPath)) {
                if ($line -match '^\s*modelito\s*==\s*([0-9A-Za-z.+_-]+)') {
                    $requiredModelito = $Matches[1]
                    break
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($requiredModelito)) {
            $hardFailures.Add('Could not find a pinned modelito== requirement in requirements.txt.')
        }
        elseif ($null -ne $pythonInfo) {
            $modelitoMatchesRequirement = ([string]$pythonInfo.modelito -eq $requiredModelito)
            if (-not $modelitoMatchesRequirement) {
                $hardFailures.Add("Installed Modelito $($pythonInfo.modelito) does not match requirements.txt ($requiredModelito). No automatic upgrade was attempted.")
            }
        }

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
            $coreResult = Invoke-NativeCommand $pythonExe @('-B', (Join-Path $repoPath 'run_tests.py'), 'core')
            $core.status = if ($coreResult.exit_code -eq 0) { 'PASS' } else { 'FAIL' }
            $core.exit_code = $coreResult.exit_code
            [IO.File]::WriteAllText($coreLogPath, $coreResult.output, ([System.Text.UTF8Encoding]::new($false)))
            if ($coreResult.exit_code -ne 0) {
                $hardFailures.Add('run_tests.py core failed; inspect the captured log.')
            }
        }
        finally {
            Restore-ProcessEnvironment $previousEnvironment
        }
    }

    if ($git.valid) {
        $statusAfterResult = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'status', '--porcelain=v1', '--untracked-files=normal')
        $shaAfterResult = Invoke-NativeCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'rev-parse', 'HEAD')
        $git.status_after = $statusAfterResult.output
        $git.status_unchanged = ($statusAfterResult.exit_code -eq 0 -and $git.status -ceq $statusAfterResult.output)
        $git.sha_unchanged = ($shaAfterResult.exit_code -eq 0 -and $git.sha -ceq $shaAfterResult.output)
        if (-not $git.status_unchanged) {
            $warnings.Add('Git working-tree status changed while the baseline was running.')
        }
        if (-not $git.sha_unchanged) {
            $hardFailures.Add('HEAD changed while the baseline was running.')
        }
    }

    $result = if ($hardFailures.Count -gt 0) { 'FAIL' } elseif ($warnings.Count -gt 0) { 'WARN' } else { 'PASS' }
    $report = [ordered]@{
        schema_version = 1
        tool = 'batllm-baseline'
        checked_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        repository_path = $repoPath
        repository_read_only = $true
        result = $result
        git = $git
        python = $pythonInfo
        modelito = [ordered]@{
            installed = if ($null -ne $pythonInfo) { $pythonInfo.modelito } else { $null }
            required = $requiredModelito
            matches_requirement = $modelitoMatchesRequirement
        }
        doctor = $doctorReport
        core = $core
        failures = @($hardFailures.ToArray())
        warnings = @($warnings.ToArray())
        report_path = $reportPath
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Output ("BatLLM baseline: " + $result)
    Write-Output ("Branch: " + $git.branch)
    Write-Output ("SHA: " + $git.sha)
    Write-Output ("Python: " + $(if ($null -ne $pythonInfo) { $pythonInfo.python } else { 'NOT_CHECKED' }))
    Write-Output ("Modelito: " + $(if ($null -ne $pythonInfo) { $pythonInfo.modelito } else { 'NOT_CHECKED' }) + " (required: " + $requiredModelito + ")")
    Write-Output ("Core tests: " + $core.status + " (exit " + $core.exit_code + ")")
    foreach ($failure in $hardFailures) {
        Write-Output ("FAILURE: " + $failure)
    }
    foreach ($warning in $warnings) {
        Write-Output ("WARNING: " + $warning)
    }
    Write-Output ("Report: " + $reportPath)
    if ($result -eq 'FAIL') { exit 1 }
    if ($result -eq 'WARN') { exit 2 }
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
