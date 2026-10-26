#requires -Version 5.1
<#
.SYNOPSIS
    Read-only Windows environment checks for BatLLM.
.DESCRIPTION
    Never installs dependencies, contacts Ollama, starts services, or writes reports.
    This initial version intentionally does not validate gameplay or test execution.
.EXAMPLE
    .\scripts\windows\batllm-doctor.ps1 -Target NonLive
.EXAMPLE
    .\scripts\windows\batllm-doctor.ps1 -Target Gameplay -Json
#>
[CmdletBinding()]
param(
    [ValidateSet('NonLive', 'Gameplay')]
    [string]$Target = 'NonLive',
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..\..'),
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checks = New-Object 'System.Collections.Generic.List[object]'

function Add-Check {
    param(
        [string]$Name,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'NOT_CHECKED')][string]$Status,
        [string]$Detail,
        [string]$NextAction = ''
    )
    [void]$checks.Add([pscustomobject][ordered]@{
        name = $Name
        status = $Status
        detail = $Detail
        next_action = $NextAction
    })
}

function Invoke-ReadOnlyCommand {
    param([string]$Executable, [string[]]$Arguments)
    try {
        # Capture stdout and stderr; do not let incidental stderr abort the report.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $Executable @Arguments 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($null -eq $code) { $code = 1 }
        return [pscustomobject]@{
            code = [int]$code
            output = (($output | Out-String).Trim())
        }
    }
    catch {
        return [pscustomobject]@{ code = 1; output = $_.Exception.Message }
    }
}

function Normalize-PackageName {
    param([string]$Name)
    return (($Name.ToLowerInvariant() -replace '[_.]+', '-') -replace '-+', '-')
}

try {
    $repoPath = [System.IO.Path]::GetFullPath($RepoRoot)
}
catch {
    $repoPath = $RepoRoot
}

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Add-Check 'windows' 'PASS' ([Environment]::OSVersion.VersionString)
}
else {
    Add-Check 'windows' 'FAIL' 'This first version targets Windows PowerShell only.'
}

Add-Check 'powershell' 'PASS' ('PowerShell ' + $PSVersionTable.PSVersion.ToString())

$repoValid = $false
if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) {
    Add-Check 'repository' 'FAIL' ('Directory does not exist: ' + $repoPath)
}
elseif (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    Add-Check 'repository' 'FAIL' 'Git executable was not found.'
}
else {
    $rootCheck = Invoke-ReadOnlyCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'rev-parse', '--show-toplevel')
    if ($rootCheck.code -ne 0) {
        Add-Check 'repository' 'FAIL' ('Not a Git checkout: ' + $rootCheck.output)
    }
    else {
        $actualPath = [System.IO.Path]::GetFullPath($rootCheck.output).TrimEnd('\', '/')
        $expectedPath = $repoPath.TrimEnd('\', '/')
        if (-not $actualPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            Add-Check 'repository' 'FAIL' ('Path is inside a different checkout: ' + $actualPath)
        }
        elseif (-not (Test-Path -LiteralPath (Join-Path $repoPath 'run_batllm.py') -PathType Leaf)) {
            Add-Check 'repository' 'FAIL' 'Git checkout is missing the BatLLM entry point.'
        }
        else {
            $repoValid = $true
            $branch = Invoke-ReadOnlyCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'branch', '--show-current')
            $sha = Invoke-ReadOnlyCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'rev-parse', 'HEAD')
            if ($branch.code -eq 0 -and $sha.code -eq 0) {
                Add-Check 'repository' 'PASS' ('branch=' + $branch.output + '; sha=' + $sha.output)
            }
            else {
                Add-Check 'repository' 'FAIL' 'Unable to read branch or commit SHA.'
            }
            $dirty = Invoke-ReadOnlyCommand 'git' @('--no-optional-locks', '-C', $repoPath, 'status', '--porcelain=v1', '--untracked-files=normal')
            if ($dirty.code -ne 0) {
                Add-Check 'worktree' 'NOT_CHECKED' ('Git status failed: ' + $dirty.output)
            }
            elseif ($dirty.output) {
                Add-Check 'worktree' 'WARN' 'Tracked or untracked changes exist; review before committing.'
            }
            else {
                Add-Check 'worktree' 'PASS' 'Working tree is clean.'
            }
        }
    }
}

if (-not $repoValid) {
    Add-Check 'worktree' 'NOT_CHECKED' 'A valid BatLLM checkout is required.'
}

$venvPython = Join-Path $repoPath '.venv_BatLLM\Scripts\python.exe'
$venvAvailable = Test-Path -LiteralPath $venvPython -PathType Leaf
if ($venvAvailable) {
    Add-Check 'virtualenv' 'PASS' 'Local .venv_BatLLM interpreter exists.'
}
else {
    Add-Check 'virtualenv' 'FAIL' 'Local .venv_BatLLM interpreter is missing.' 'Create a virtual environment explicitly during setup.'
}

$pythonExe = $null
$pythonPrefix = @()
if ($venvAvailable) {
    $pythonExe = $venvPython
}
elseif (Get-Command py -CommandType Application -ErrorAction SilentlyContinue) {
    $pythonExe = 'py'
    $pythonPrefix = @('-3')
}
elseif (Get-Command python -CommandType Application -ErrorAction SilentlyContinue) {
    $pythonExe = 'python'
}

if ($null -eq $pythonExe) {
    Add-Check 'python' 'FAIL' 'No Python interpreter could be located.'
}
else {
    $versionCode = 'import sys; print(sys.version_info.major, sys.version_info.minor, sys.version_info.micro, sep=chr(46))'
    $versionResult = Invoke-ReadOnlyCommand $pythonExe ($pythonPrefix + @('-B', '-c', $versionCode))
    if ($versionResult.code -ne 0) {
        Add-Check 'python' 'FAIL' ('Unable to query Python: ' + $versionResult.output)
    }
    else {
        try {
            $version = [version]$versionResult.output
            if ($version -ge [version]'3.10' -and $version -lt [version]'3.13') {
                Add-Check 'python' 'PASS' ('Supported Python ' + $versionResult.output)
            }
            else {
                Add-Check 'python' 'FAIL' ('Unsupported Python ' + $versionResult.output + '; requires 3.10-3.12.')
            }
        }
        catch {
            Add-Check 'python' 'FAIL' ('Unrecognised Python version: ' + $versionResult.output)
        }
    }
}

$requirementsFile = Join-Path $repoPath 'requirements.txt'
if (-not $repoValid -or -not (Test-Path -LiteralPath $requirementsFile -PathType Leaf)) {
    Add-Check 'dependencies' 'NOT_CHECKED' 'A valid checkout and requirements.txt are required.'
}
elseif (-not $venvAvailable) {
    Add-Check 'dependencies' 'NOT_CHECKED' 'Create the project virtual environment first.'
}
else {
    # importlib.metadata is part of Python; no pip invocation or network access.
    $packageCode = "import json, importlib.metadata as m; print(json.dumps({d.metadata.get('Name', '').lower().replace('_', '-').replace('.', '-'): d.version for d in m.distributions()}))"
    $packageResult = Invoke-ReadOnlyCommand $venvPython @('-B', '-c', $packageCode)
    if ($packageResult.code -ne 0) {
        Add-Check 'dependencies' 'FAIL' ('Cannot inspect installed distributions: ' + $packageResult.output)
    }
    else {
        try {
            $installed = $packageResult.output | ConvertFrom-Json
            $issues = New-Object 'System.Collections.Generic.List[string]'
            $count = 0
            foreach ($line in (Get-Content -LiteralPath $requirementsFile)) {
                if ($line -match '^\s*(#|$)') { continue }
                if ($line -notmatch '^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(==|>=)\s*([0-9][A-Za-z0-9.+_-]*)\s*(?:#.*)?$') {
                    [void]$issues.Add('Unsupported requirement syntax: ' + $line)
                    continue
                }
                $name = Normalize-PackageName $Matches[1]
                $comparison = $Matches[2]
                $wanted = $Matches[3]
                $count++
                $distribution = $installed.PSObject.Properties[$name]
                if ($null -eq $distribution) {
                    [void]$issues.Add($name + ' is missing')
                    continue
                }
                $found = [string]$distribution.Value
                if ($comparison -eq '==' -and $found -ne $wanted) {
                    [void]$issues.Add($name + ': installed ' + $found + ', expected ' + $wanted)
                }
                elseif ($comparison -eq '>=') {
                    try {
                        if ([version]$found -lt [version]$wanted) {
                            [void]$issues.Add($name + ': installed ' + $found + ', minimum ' + $wanted)
                        }
                    }
                    catch {
                        [void]$issues.Add($name + ': could not compare ' + $found + ' with ' + $wanted)
                    }
                }
            }
            if ($issues.Count -gt 0) {
                Add-Check 'dependencies' 'FAIL' ($issues -join '; ') 'Use a separately authorised setup step to repair dependencies.'
            }
            elseif ($count -eq 0) {
                Add-Check 'dependencies' 'NOT_CHECKED' 'No supported requirements were found.'
            }
            else {
                Add-Check 'dependencies' 'PASS' ($count.ToString() + ' direct requirements meet declared constraints; transitive health was not checked.')
            }
        }
        catch {
            Add-Check 'dependencies' 'FAIL' ('Unable to parse dependency inventory: ' + $_.Exception.Message)
        }
    }
}

$ollamaPaths = New-Object 'System.Collections.Generic.List[string]'
$ollamaCommand = Get-Command ollama -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $ollamaCommand) {
    [void]$ollamaPaths.Add($ollamaCommand.Source)
}
if ($env:LOCALAPPDATA) {
    [void]$ollamaPaths.Add((Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'))
}
if ($env:ProgramFiles) {
    [void]$ollamaPaths.Add((Join-Path $env:ProgramFiles 'Ollama\ollama.exe'))
}
$ollamaFound = $null
foreach ($path in $ollamaPaths) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $ollamaFound = $path
        break
    }
}
if ($null -ne $ollamaFound) {
    Add-Check 'ollama_cli' 'PASS' ('Executable detected: ' + $ollamaFound + '. Service and models not checked.')
}
elseif ($Target -eq 'Gameplay') {
    Add-Check 'ollama_cli' 'FAIL' 'Ollama executable was not detected; gameplay requires an Ollama runtime.'
}
else {
    Add-Check 'ollama_cli' 'WARN' 'Ollama executable was not detected; optional for non-live checks.'
}

$batllmHomeValue = [Environment]::GetEnvironmentVariable('BATLLM_HOME', 'Process')
if ([string]::IsNullOrWhiteSpace($batllmHomeValue)) {
    Add-Check 'batllm_home' 'WARN' 'BATLLM_HOME is not set; launching from source can write into the checkout.' 'Set BATLLM_HOME outside the repository before launching.'
}
elseif (-not [IO.Path]::IsPathRooted($batllmHomeValue)) {
    Add-Check 'batllm_home' 'FAIL' 'BATLLM_HOME must be an absolute path outside the checkout.'
}
else {
    try {
        $fullHome = [IO.Path]::GetFullPath($batllmHomeValue).TrimEnd('\', '/')
        $fullRepo = $repoPath.TrimEnd('\', '/')
        $inside = (
            $fullHome.Equals($fullRepo, [StringComparison]::OrdinalIgnoreCase) -or
            $fullHome.StartsWith($fullRepo + '\', [StringComparison]::OrdinalIgnoreCase)
        )
        if ($inside) {
            Add-Check 'batllm_home' 'WARN' 'BATLLM_HOME is inside the checkout.'
        }
        else {
            Add-Check 'batllm_home' 'PASS' ('BATLLM_HOME points outside the checkout: ' + $fullHome)
        }
    }
    catch {
        Add-Check 'batllm_home' 'FAIL' 'BATLLM_HOME is not a valid absolute path.'
    }
}

$results = $checks.ToArray()
$report = [ordered]@{
    schema_version = 1
    tool = 'batllm-windows-doctor'
    target = $Target
    read_only = $true
    checked_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    repository_path = $repoPath
    checks = $results
    summary = [ordered]@{
        PASS = @($results | Where-Object status -eq 'PASS').Count
        WARN = @($results | Where-Object status -eq 'WARN').Count
        FAIL = @($results | Where-Object status -eq 'FAIL').Count
        NOT_CHECKED = @($results | Where-Object status -eq 'NOT_CHECKED').Count
    }
}

if ($Json) {
    $report | ConvertTo-Json -Depth 7
}
else {
    Write-Output ('BatLLM Windows Doctor | target=' + $Target + ' | read-only')
    foreach ($check in $results) {
        Write-Output ('[{0}] {1}: {2}' -f $check.status, $check.name, $check.detail)
        if ($check.next_action) {
            Write-Output ('       Next: ' + $check.next_action)
        }
    }
    Write-Output ('Summary: PASS={0} WARN={1} FAIL={2} NOT_CHECKED={3}' -f $report.summary.PASS, $report.summary.WARN, $report.summary.FAIL, $report.summary.NOT_CHECKED)
}
