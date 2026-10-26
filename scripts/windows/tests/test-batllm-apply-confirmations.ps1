#requires -Version 5.1
<# Offline guard tests. Do not call -Apply or run winget, Ollama or the game. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$apply = Join-Path $repo 'scripts\windows\batllm-apply.ps1'
$runner = (Get-Process -Id $PID).Path
$passes = 0
$script:PromptAnswer = ''
$script:PromptThrows = $false

function Assert-True {
    param([bool]$Condition, [string]$Description)
    if (-not $Condition) { throw ('FAIL: ' + $Description) }
    $script:passes++
    Write-Output ('PASS: ' + $Description)
}

# Mocks only the host prompt. Never permit an actual network/system action.
function Read-Host {
    param([string]$Prompt)
    if ($script:PromptThrows) { throw 'Mock non-interactive host' }
    return $script:PromptAnswer
}

function Test-Blocked {
    param([string]$Expected, [string]$Label)
    $errorText = ''
    try { $null = Confirm-ExternalChange -Action 'PullModel' -Impact 'test-only model' }
    catch { $errorText = $_.Exception.Message }
    Assert-True ($errorText -match $Expected) $Label
}

Assert-True (Test-Path -LiteralPath $apply -PathType Leaf) 'Apply script exists'
$before = ((& git --no-optional-locks -C $repo status --porcelain=v1) | Out-String).Trim()

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($apply, [ref]$tokens, [ref]$parseErrors)
Assert-True (@($parseErrors).Count -eq 0) 'Apply parses without syntax errors'

$defs = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Confirm-ExternalChange'
}, $true))
Assert-True ($defs.Count -eq 1) 'Single confirmation function exists'
. ([scriptblock]::Create($defs[0].Extent.Text))

$script:PromptAnswer = ''
Test-Blocked 'CANCELLED' 'Empty reply declines a model download'
$script:PromptAnswer = 'yes'
Test-Blocked 'CANCELLED' 'Lowercase yes is not silently accepted'
$script:PromptAnswer = 'NO'
Test-Blocked 'CANCELLED' 'Explicit NO declines a model download'
$script:PromptThrows = $true
Test-Blocked 'BLOCKED' 'Missing interactive host denies the action'
$script:PromptThrows = $false
$script:PromptAnswer = 'YES'
$approvedText = ((Confirm-ExternalChange -Action 'PullModel' -Impact 'test-only model') | Out-String)
Assert-True ($approvedText -match 'IMPACT:') 'Exact YES permits the guard only and prints impact'

# Contract assertions: each concrete side-effect call remains behind its guard.
$code = [IO.File]::ReadAllText($apply)
$guards = @(
    @("Confirm-ExternalChange -Action 'InstallOllama'", '& winget install'),
    @("Confirm-ExternalChange -Action 'StartOllama'", 'Start-Process -FilePath $ollama'),
    @("Confirm-ExternalChange -Action 'PullModel'", '& $ollama pull $Model')
)
foreach ($pair in $guards) {
    $guardIndex = $code.IndexOf($pair[0], [StringComparison]::Ordinal)
    $actionIndex = $code.IndexOf($pair[1], [StringComparison]::Ordinal)
    Assert-True ($guardIndex -ge 0 -and $actionIndex -gt $guardIndex) ('External action guarded: ' + $pair[1])
}
Assert-True ($code.Contains('$gameReport = Invoke-DoctorReport ''Gameplay'' $Model')) 'Gameplay model forwarded to Doctor'
Assert-True ($code.Contains("gameReport.gameplay.state -ne 'READY'")) 'Doctor READY required before reporting Apply readiness'
Assert-True (-not $code.Contains('--accept-package-agreements')) 'No silent package-agreement acceptance'
Assert-True (-not $code.Contains('--accept-source-agreements')) 'No silent source-agreement acceptance'

$plan = & $runner -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $apply `
    -Mode Gameplay -InstallOllama -StartOllama -PullModel -Model 'smollm2:360m'
Assert-True ($LASTEXITCODE -eq 0) 'Gameplay planning returns success'
Assert-True ((($plan | Out-String) -match 'PLAN ONLY')) 'Gameplay planning remains read-only'
Assert-True ((($plan | Out-String) -match 'smollm2:360m')) 'Planning preserves exact model tag'
Assert-True ((($plan | Out-String) -match 'typed YES')) 'Plan explains interactive confirmations'

$after = ((& git --no-optional-locks -C $repo status --porcelain=v1) | Out-String).Trim()
Assert-True ($before -ceq $after) 'Tests did not modify Git worktree contents'
Write-Output ('Apply confirmation guard tests: ' + $passes + ' PASS')
