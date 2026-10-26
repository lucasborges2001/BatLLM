#requires -Version 5.1
<#
.SYNOPSIS
    Isolated smoke tests for the BatLLM Windows CMD launcher.
.DESCRIPTION
    Stubs both PowerShell delegates in a temporary directory whose path has spaces.
    No real install, network access, Ollama service, game or project state is touched.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceLauncher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\batllm.cmd'))
if (-not (Test-Path -LiteralPath $sourceLauncher -PathType Leaf)) {
    throw 'The launcher under test is missing.'
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('BatLLM cmd smoke ' + [guid]::NewGuid().ToString('N'))
$scriptDir = Join-Path $root 'checkout with spaces\scripts\windows'
$otherDir = Join-Path $root 'unrelated cwd'
$launcher = Join-Path $scriptDir 'batllm.cmd'
$log = Join-Path $root 'delegate.txt'
$priorLog = [Environment]::GetEnvironmentVariable('BATLLM_LAUNCHER_TEST_LOG', 'Process')
$priorExit = [Environment]::GetEnvironmentVariable('BATLLM_LAUNCHER_TEST_EXIT', 'Process')
$priorHome = [Environment]::GetEnvironmentVariable('BATLLM_HOME', 'Process')
$passed = 0

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Context)
    if ([string]$Actual -cne [string]$Expected) {
        throw ("{0}: expected [{1}], got [{2}]" -f $Context, $Expected, $Actual)
    }
}

function Invoke-TestCase {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [int]$ExpectedExit,
        [string]$ExpectedDelegate = '',
        [string]$ExpectedText = '',
        [int]$DelegateExit = 0,
        [switch]$FromCmd
    )
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    $env:BATLLM_LAUNCHER_TEST_EXIT = [string]$DelegateExit

    Push-Location -LiteralPath $otherDir
    try {
        # In Windows PowerShell 5.1, redirected native stderr can become a
        # terminating NativeCommandError when ErrorActionPreference is Stop.
        # Capture it, then assert the batch exit code and error message.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($FromCmd) {
                # A temporary CMD wrapper tests CALL and ERRORLEVEL without relying
                # on PowerShell 5.1 native argument re-quoting for cmd.exe /S /C.
                # This test invokes only fixed, safe command tokens.
                $cmdRunner = Join-Path $otherDir 'invoke-from-cmd.cmd'
                $cmdLines = @(
                    '@echo off'
                    ('call "' + $launcher + '" ' + ($Arguments -join ' '))
                    'exit /b %ERRORLEVEL%'
                )
                [IO.File]::WriteAllText(
                    $cmdRunner,
                    (($cmdLines -join "`r`n") + "`r`n"),
                    [Text.Encoding]::ASCII
                )
                $captured = @(& $cmdRunner 2>&1)
            }
            else {
                $captured = @(& $launcher @Arguments 2>&1)
            }
            $actualExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
    }
    finally {
        Pop-Location
    }

    if ($actualExit -ne $ExpectedExit) {
        throw ('{0} exit code: expected [{1}], got [{2}]. Output: {3}' -f
            $Name, $ExpectedExit, $actualExit, (($captured | Out-String).Trim()))
    }
    if ($ExpectedText -and (($captured | Out-String) -notlike ('*' + $ExpectedText + '*'))) {
        throw ($Name + ': expected output [' + $ExpectedText + '], got: ' + ($captured | Out-String))
    }
    if ($ExpectedDelegate) {
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) {
            throw ($Name + ': delegate was not called')
        }
        Assert-Equal ([IO.File]::ReadAllText($log)) $ExpectedDelegate ($Name + ' delegation')
    }
    elseif (Test-Path -LiteralPath $log) {
        throw ($Name + ': unexpected delegate invocation')
    }
    $script:passed++
    Write-Output ('PASS: ' + $Name)
}

try {
    New-Item -ItemType Directory -Path $scriptDir, $otherDir -Force | Out-Null
    Copy-Item -LiteralPath $sourceLauncher -Destination $launcher

    $stub = @'
[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$Mode = '',
    [string]$RepoRoot = '',
    [switch]$Json,
    [switch]$Apply
)
if ($Target) {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw 'Doctor must receive an explicit RepoRoot.'
    }
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $actualRoot = [IO.Path]::GetFullPath($RepoRoot)
    if (-not $actualRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Doctor RepoRoot mismatch: ' + $actualRoot)
    }
}
$record = 'target=' + $Target + ';mode=' + $Mode + ';json=' + [bool]$Json + ';apply=' + [bool]$Apply
[IO.File]::WriteAllText($env:BATLLM_LAUNCHER_TEST_LOG, $record)
exit [int]$env:BATLLM_LAUNCHER_TEST_EXIT
'@
    [IO.File]::WriteAllText((Join-Path $scriptDir 'batllm-doctor.ps1'), $stub)
    [IO.File]::WriteAllText((Join-Path $scriptDir 'batllm-apply.ps1'), $stub)
    $env:BATLLM_LAUNCHER_TEST_LOG = $log
    $env:BATLLM_HOME = (Join-Path $root 'isolated state')

    Invoke-TestCase -Name 'default help has no side effects' -Arguments @() -ExpectedExit 0
    Invoke-TestCase -Name 'explicit help' -Arguments @('help') -ExpectedExit 0
    Invoke-TestCase -Name 'Doctor default is NonLive' -Arguments @('doctor') -ExpectedExit 0 -ExpectedDelegate 'target=NonLive;mode=;json=False;apply=False'
    Invoke-TestCase -Name 'Doctor Gameplay JSON' -Arguments @('doctor', 'Gameplay', 'json') -ExpectedExit 0 -ExpectedDelegate 'target=Gameplay;mode=;json=True;apply=False'
    Invoke-TestCase -Name 'Apply default is plan-only NonLive' -Arguments @('apply') -ExpectedExit 0 -ExpectedDelegate 'target=;mode=NonLive;json=False;apply=False'
    Invoke-TestCase -Name 'Apply Gameplay plan' -Arguments @('apply', 'Gameplay', 'plan') -ExpectedExit 0 -ExpectedDelegate 'target=;mode=Gameplay;json=False;apply=False'
    Invoke-TestCase -Name 'Apply NonLive execute requires explicit token' -Arguments @('apply', 'NonLive', 'execute') -ExpectedExit 0 -ExpectedDelegate 'target=;mode=NonLive;json=False;apply=True'
    Invoke-TestCase -Name 'Apply propagates delegate exit code' -Arguments @('apply', 'Gameplay', 'execute') -ExpectedExit 19 -DelegateExit 19 -ExpectedDelegate 'target=;mode=Gameplay;json=False;apply=True'
    Invoke-TestCase -Name 'Unknown command rejected' -Arguments @('unknown') -ExpectedExit 2 -ExpectedText 'ERROR: Invalid arguments.'
    Invoke-TestCase -Name 'Unexpected Doctor option rejected' -Arguments @('doctor', 'Gameplay', 'execute') -ExpectedExit 2 -ExpectedText 'ERROR: Invalid arguments.'
    Invoke-TestCase -Name 'Unexpected Apply option rejected' -Arguments @('apply', 'NonLive', 'execute', 'extra') -ExpectedExit 2 -ExpectedText 'ERROR: Invalid arguments.'
    Invoke-TestCase -Name 'CMD invocation from another directory' -Arguments @('doctor', 'Gameplay') -ExpectedExit 0 -FromCmd -ExpectedDelegate 'target=Gameplay;mode=;json=False;apply=False'

    Remove-Item -LiteralPath (Join-Path $scriptDir 'batllm-doctor.ps1') -Force
    Invoke-TestCase -Name 'Missing delegate has nonzero exit' -Arguments @('doctor') -ExpectedExit 3 -ExpectedText 'ERROR: Missing Windows Doctor script:'

    Write-Output ("BatLLM CMD launcher smoke: {0} PASS" -f $passed)
}
finally {
    [Environment]::SetEnvironmentVariable('BATLLM_LAUNCHER_TEST_LOG', $priorLog, 'Process')
    [Environment]::SetEnvironmentVariable('BATLLM_LAUNCHER_TEST_EXIT', $priorExit, 'Process')
    [Environment]::SetEnvironmentVariable('BATLLM_HOME', $priorHome, 'Process')
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
