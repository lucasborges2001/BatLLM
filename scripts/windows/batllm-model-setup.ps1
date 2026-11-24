#requires -Version 5.1
<#
.SYNOPSIS
    Select an installed Ollama model and update BatLLM user preferences.
.DESCRIPTION
    Reads the configured local Ollama API and persists only llm.model through
    BatLLM's AppConfig writer. It does not download, warm up, start, stop or
    unload models. Multiple unmatched models require an interactive choice or
    an explicit -Model value.
.EXAMPLE
    .\\scripts\\windows\\batllm-model-setup.ps1
.EXAMPLE
    .\\scripts\\windows\\batllm-model-setup.ps1 -Model smollm2:360m
.EXAMPLE
    .\\scripts\\windows\\batllm-model-setup.ps1 -NonInteractive
#>
[CmdletBinding()]
param(
    [string]$Model = '',
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\\..'))
$python = Join-Path $repo '.venv_BatLLM\\Scripts\\python.exe'
$source = Join-Path $repo 'src'

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw 'The project interpreter is missing. Create .venv_BatLLM and install requirements.txt first.'
}
if ($Model -and $Model -notmatch '^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$') {
    throw 'Invalid model name. Use the exact installed Ollama name, including its tag.'
}

$pythonArgs = @('-m', 'llm.model_setup')
if ($Model) { $pythonArgs += @('--model', $Model) }
if ($NonInteractive) { $pythonArgs += '--non-interactive' }

$previousPythonPath = $env:PYTHONPATH
if ([string]::IsNullOrWhiteSpace($previousPythonPath)) {
    $env:PYTHONPATH = $source
}
else {
    $env:PYTHONPATH = $source + [IO.Path]::PathSeparator + $previousPythonPath
}

$exitCode = 1
Push-Location -LiteralPath $repo
try {
    & $python @pythonArgs
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
    $env:PYTHONPATH = $previousPythonPath
}

exit $exitCode
