#requires -Version 5.1
<# Regression: Invoke-DoctorReport must use named splatting, not positional strings.
   A temporary fake Doctor is invoked; no Ollama, installations or game launch. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checkout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$apply = Join-Path $checkout 'scripts\windows\batllm-apply.ps1'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('batllm-apply-splat-' + [guid]::NewGuid().ToString('N'))
$passes = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Description)
    if ($Actual -cne $Expected) {
        throw ('FAIL: ' + $Description + ': expected [' + $Expected + '], got [' + $Actual + ']')
    }
    $script:passes++
    Write-Output ('PASS: ' + $Description)
}

try {
    if (-not (Test-Path -LiteralPath $apply -PathType Leaf)) {
        throw 'Missing batllm-apply.ps1'
    }
    $before = ((& git --no-optional-locks -C $checkout status --porcelain=v1) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect initial Git status.' }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($apply, [ref]$tokens, [ref]$parseErrors)
    Assert-Equal (@($parseErrors).Count) 0 'Apply parses without errors'

    $definitions = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-DoctorReport'
    }, $true))
    Assert-Equal $definitions.Count 1 'One Invoke-DoctorReport function found'

    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $doctor = Join-Path $tempDir 'fake-doctor.ps1'
    @'
[CmdletBinding()]
param(
    [ValidateSet('NonLive', 'Gameplay')][string]$Target,
    [string]$RepoRoot,
    [string]$Model = '',
    [switch]$Json
)
if (-not $Json) { throw 'Mock Doctor requires -Json' }
[pscustomobject]@{
    target = $Target
    repository_path = $RepoRoot
    model = $Model
    json_requested = [bool]$Json
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $doctor -Encoding UTF8

    # Extract only the helper; do not execute Apply's setup path.
    . ([scriptblock]::Create($definitions[0].Extent.Text))
    $repo = Join-Path $tempDir 'mock checkout'

    $nonLive = Invoke-DoctorReport 'NonLive'
    Assert-Equal $nonLive.target 'NonLive' 'NonLive named Target binding'
    Assert-Equal $nonLive.repository_path $repo 'NonLive named RepoRoot binding'
    Assert-Equal $nonLive.json_requested $true 'Doctor JSON switch binding'
    Assert-Equal $nonLive.model '' 'NonLive does not select a model'

    $gameplay = Invoke-DoctorReport 'Gameplay' 'smollm2:360m'
    Assert-Equal $gameplay.target 'Gameplay' 'Gameplay named Target binding'
    Assert-Equal $gameplay.repository_path $repo 'Gameplay named RepoRoot binding'
    Assert-Equal $gameplay.model 'smollm2:360m' 'Gameplay passes the exact model tag'

    $after = ((& git --no-optional-locks -C $checkout status --porcelain=v1) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect final Git status.' }
    Assert-Equal $after $before 'No Git worktree changes caused by test'
    Write-Output ('Apply Doctor splatting regression: ' + $passes + ' PASS')
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
