#requires -Version 5.1
<# Offline/plan-only smoke validation. Never invokes -Apply. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$apply = Join-Path $root 'scripts\windows\batllm-apply.ps1'
$runner = (Get-Process -Id $PID).Path

function Assert-True {
    param([bool]$Condition, [string]$Description)
    if (-not $Condition) { throw ('FAIL: ' + $Description) }
    Write-Output ('PASS: ' + $Description)
}

Assert-True (Test-Path -LiteralPath $apply -PathType Leaf) 'Apply script exists'
$before = ((& git --no-optional-locks -C $root status --porcelain=v1) | Out-String).Trim()
$nonLive = & $runner -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $apply -Mode NonLive
Assert-True ($LASTEXITCODE -eq 0) 'NonLive plan returns success'
Assert-True ((($nonLive | Out-String) -match 'PLAN ONLY')) 'NonLive defaults to read-only plan'
Assert-True ((($nonLive | Out-String) -match 'Python')) 'NonLive plan mentions Python setup'
$gameplay = & $runner -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $apply -Mode Gameplay -InstallOllama -StartOllama -PullModel -Model smollm2 -Launch
Assert-True ($LASTEXITCODE -eq 0) 'Gameplay plan returns success'
Assert-True ((($gameplay | Out-String) -match 'download model')) 'Gameplay plan discloses model download'
Assert-True ((($gameplay | Out-String) -match 'winget')) 'Gameplay plan discloses installer'
$after = ((& git --no-optional-locks -C $root status --porcelain=v1) | Out-String).Trim()
Assert-True ($before -ceq $after) 'Plan did not change Git worktree contents'
Write-Output 'Apply plan smoke tests completed; no installer, service, model, or application was executed.'
