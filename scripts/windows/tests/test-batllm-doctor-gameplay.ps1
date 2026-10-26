#requires -Version 5.1
<# Deterministic Gameplay readiness tests: mocked API, no Ollama process or downloads. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$doctor = Join-Path $repo 'scripts\windows\batllm-doctor.ps1'
$priorLocal = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', 'Process')
$priorProgramFiles = [Environment]::GetEnvironmentVariable('ProgramFiles', 'Process')
$priorHome = [Environment]::GetEnvironmentVariable('BATLLM_HOME', 'Process')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('batllm-doctor-gameplay-' + [guid]::NewGuid().ToString('N'))
$global:BatllmDoctorMockScenario = 'unreachable'
$global:BatllmDoctorApiCalls = 0
$passes = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -cne $Expected) {
        throw ('FAIL: ' + $Label + ': expected [' + $Expected + '], got [' + $Actual + ']')
    }
    $script:passes++
    Write-Output ('PASS: ' + $Label)
}

# Shadow these commands for the script under test. Never contact the real API.
function Get-Command {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name, [string]$CommandType)
    if ($Name -eq 'ollama' -or $Name -eq 'ollama.exe') { return $null }
    return Microsoft.PowerShell.Core\Get-Command -Name $Name -CommandType $CommandType -ErrorAction SilentlyContinue
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Method, [string]$Uri, [int]$TimeoutSec)
    $global:BatllmDoctorApiCalls++
    if ($Method -ne 'Get' -or $Uri -notmatch '^http://127\.0\.0\.1:11434/api/(version|tags)$') {
        throw ('Unexpected API request: ' + $Method + ' ' + $Uri)
    }
    if ($global:BatllmDoctorMockScenario -eq 'unreachable') { throw 'Simulated connection refused' }
    if ($Uri.EndsWith('/version')) { return [pscustomobject]@{ version = 'mock-only' } }
    if ($global:BatllmDoctorMockScenario -eq 'tags-unavailable') { throw 'Simulated API failure' }
    if ($global:BatllmDoctorMockScenario -eq 'no-model') {
        return [pscustomobject]@{ models = @() }
    }
    return [pscustomobject]@{ models = @([pscustomobject]@{ name = 'smollm2:latest' }) }
}

function Get-Report {
    param([ValidateSet('NonLive', 'Gameplay')][string]$Target, [string]$Model = 'smollm2')
    $raw = & $doctor -Target $Target -Model $Model -RepoRoot $repo -Json
    $report = (($raw | Out-String) | ConvertFrom-Json)
    if ($null -eq $report) { throw 'Missing Doctor JSON report' }
    return $report
}

try {
    if (-not (Test-Path -LiteralPath $doctor -PathType Leaf)) { throw 'Doctor script is missing' }
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $env:LOCALAPPDATA = Join-Path $tempRoot 'LocalAppData'
    $env:ProgramFiles = Join-Path $tempRoot 'ProgramFiles'
    $env:BATLLM_HOME = Join-Path $tempRoot 'State'
    $cli = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    $before = ((& git --no-optional-locks -C $repo status --porcelain=v1) | Out-String).Trim()

    $nonLive = Get-Report 'NonLive'
    Assert-Equal $nonLive.target 'NonLive' 'NonLive target unchanged'
    Assert-Equal $global:BatllmDoctorApiCalls 0 'NonLive avoids all API probes'

    $direct = (((& $doctor -Target NonLive -Json) | Out-String) | ConvertFrom-Json)
    Assert-Equal ([IO.Path]::GetFullPath($direct.repository_path).TrimEnd('\', '/')) $repo 'Direct invocation resolves its default RepoRoot'

    $report = Get-Report 'Gameplay'
    Assert-Equal $report.gameplay.state 'NOT_DETECTED' 'Missing CLI and API are not detected'
    Assert-Equal (@($report.checks | Where-Object name -eq 'ollama_service')[0].status) 'FAIL' 'No API is reported as failure'

    New-Item -ItemType Directory -Path (Split-Path -Parent $cli) -Force | Out-Null
    [IO.File]::WriteAllText($cli, '')
    $report = Get-Report 'Gameplay'
    Assert-Equal $report.gameplay.state 'NOT_RUNNING' 'Present CLI and unreachable API'

    $global:BatllmDoctorMockScenario = 'no-model'
    $report = Get-Report 'Gameplay'
    Assert-Equal $report.gameplay.state 'NO_MODEL' 'Present service with empty model inventory'

    $global:BatllmDoctorMockScenario = 'tags-unavailable'
    $report = Get-Report 'Gameplay'
    Assert-Equal $report.gameplay.state 'MODEL_INVENTORY_UNAVAILABLE' 'Unavailable inventory is not confused with no models'

    $global:BatllmDoctorMockScenario = 'with-model'
    $report = Get-Report 'Gameplay' ''
    Assert-Equal $report.gameplay.state 'MODEL_NOT_SELECTED' 'Installed models do not imply a selected model'

    $report = Get-Report 'Gameplay' 'not-installed'
    Assert-Equal $report.gameplay.state 'NO_MODEL' 'Missing requested model is detected'

    $report = Get-Report 'Gameplay' 'smollm2'
    $needed = @('repository', 'virtualenv', 'python', 'dependencies', 'batllm_home')
    $incomplete = @($report.checks | Where-Object { $needed -contains $_.name -and $_.status -ne 'PASS' }).Count -gt 0
    $expected = if ($incomplete) { 'ENVIRONMENT_INCOMPLETE' } else { 'READY' }
    Assert-Equal $report.gameplay.state $expected 'Model readiness respects environment prerequisites'

    Remove-Item -LiteralPath $cli -Force
    $report = Get-Report 'Gameplay' 'smollm2'
    Assert-Equal $report.gameplay.state 'CLI_NOT_DETECTED' 'Responsive API with undiscovered CLI is not called NOT_INSTALLED'

    $after = ((& git --no-optional-locks -C $repo status --porcelain=v1) | Out-String).Trim()
    Assert-Equal $after $before 'No repository files or status changed'
    Write-Output ('Doctor Gameplay mocked tests: ' + $passes + ' PASS')
}
finally {
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $priorLocal, 'Process')
    [Environment]::SetEnvironmentVariable('ProgramFiles', $priorProgramFiles, 'Process')
    [Environment]::SetEnvironmentVariable('BATLLM_HOME', $priorHome, 'Process')
    Remove-Variable -Name BatllmDoctorMockScenario, BatllmDoctorApiCalls -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
