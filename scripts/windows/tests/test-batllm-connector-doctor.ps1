#requires -Version 5.1
<# Deterministic Connector Doctor tests. Ollama HTTP is mocked; no inference. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$doctor = Join-Path $repo 'scripts\windows\batllm-connector-doctor.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('batllm-connector-doctor-' + [guid]::NewGuid().ToString('N'))
$evidenceRoot = Join-Path $fixtureRoot 'evidence'
$outputRoot = Join-Path $fixtureRoot 'reports'
$global:BatllmConnectorDoctorScenario = 'ready'
$global:BatllmConnectorDoctorCalls = New-Object 'System.Collections.Generic.List[string]'
$passes = 0

function Assert-True {
    param([bool]$Condition, [string]$Description)
    if (-not $Condition) { throw ('FAIL: ' + $Description) }
    $script:passes++
    Write-Output ('PASS: ' + $Description)
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Method, [string]$Uri, [int]$TimeoutSec)
    [void]$global:BatllmConnectorDoctorCalls.Add($Method + ' ' + $Uri)
    if ($Method -ne 'Get') { throw ('Unexpected non-GET request: ' + $Method) }
    if ($global:BatllmConnectorDoctorScenario -eq 'unreachable') { throw 'Simulated connection refused' }
    if ($Uri.EndsWith('/api/version')) { return [pscustomobject]@{ version = 'mock-1.0' } }
    if ($Uri.EndsWith('/api/tags')) {
        if ($global:BatllmConnectorDoctorScenario -eq 'invalid-tags') { return [pscustomobject]@{ items = @() } }
        return [pscustomobject]@{
            models = @(
                [pscustomobject]@{ name = 'smollm2:360m' },
                [pscustomobject]@{ name = 'qwen2.5:3b' }
            )
        }
    }
    throw ('Unexpected API URI: ' + $Uri)
}

function Invoke-ConnectorDoctor {
    param([string]$Model, [string]$Scenario)
    $global:BatllmConnectorDoctorScenario = $Scenario
    $runOutput = Join-Path $outputRoot ([guid]::NewGuid().ToString('N'))
    $raw = & $doctor -RepoRoot $repo -Model $Model -Url 'http://127.0.0.1' -Port 11434 -EvidenceDirectory $evidenceRoot -OutputDirectory $runOutput -SkipStaticDoctor -Json
    return (($raw | Out-String) | ConvertFrom-Json)
}

try {
    if (-not (Test-Path -LiteralPath $doctor -PathType Leaf)) { throw 'Connector Doctor script is missing' }
    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    # Historical failure fixture: the model alias does not match the installed non-latest tag.
    $prefix = 'connector-live-20261110-213823-509'
    $junitPath = Join-Path $evidenceRoot ($prefix + '.junit.xml')
    $logPath = Join-Path $evidenceRoot ($prefix + '.log')
    $jsonPath = Join-Path $evidenceRoot ($prefix + '.json')
    $junit = @'
<testsuites><testsuite tests="1" failures="1" errors="0" skipped="0"><testcase classname="src.tests.test_ollama_connector_live" name="test_live_connector_sends_two_messages_and_retains_conversation" time="5.10"><failure message="Failed: Model 'smollm2' is not installed at http://localhost:11434. Installed models: ['smollm2:360m']. No download was attempted.">preflight failed</failure></testcase></testsuite></testsuites>
'@
    [IO.File]::WriteAllText($junitPath, $junit, ([System.Text.UTF8Encoding]::new($false)))
    [IO.File]::WriteAllText($logPath, 'F' + [Environment]::NewLine, ([System.Text.UTF8Encoding]::new($false)))
    $historical = [ordered]@{
        checked_at_utc = '2026-11-11T00:38:33Z'
        branch = 'docs/taller-lucas-borges'
        tested_sha = 'ad06d424ce3175f807d3fceba81819c7c6e0be98'
        result = 'FAIL'
        model_override = ''
        endpoint_override = ''
        pytest_exit_code = 1
        junit_path = $junitPath
        log_path = $logPath
    }
    $historical | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $alias = Invoke-ConnectorDoctor 'smollm2' 'ready'
    Assert-True ($alias.ollama.state -eq 'MODEL_NOT_INSTALLED') 'Untagged model does not match a non-latest installed tag'
    Assert-True (@($alias.ollama.related_models) -contains 'smollm2:360m') 'Related installed tag is suggested without auto-selecting it'
    Assert-True ($alias.ollama.api_version -eq 'mock-1.0') 'API version is recorded'
    Assert-True ($alias.ollama.probes.version.elapsed_ms -ge 0) 'Version probe timing is recorded'
    Assert-True ($alias.ollama.probes.tags.elapsed_ms -ge 0) 'Tags probe timing is recorded'
    Assert-True ($alias.historical.runs_found -eq 1) 'Historical Connector report is discovered'
    Assert-True ($alias.historical.runs[0].diagnosis -eq 'MODEL_NOT_INSTALLED_BEFORE_INFERENCE') 'Historical preflight failure is classified before inference'
    Assert-True (@($alias.historical.runs[0].installed_models) -contains 'smollm2:360m') 'Installed model list is recovered from the failure evidence'
    Assert-True ([Math]::Abs([double]$alias.historical.runs[0].junit.duration_seconds - 5.10) -lt 0.001) 'JUnit execution duration is extracted'
    Assert-True (@($global:BatllmConnectorDoctorCalls | Where-Object { $_ -match '^GET ' }).Count -eq 2) 'Only two GET probes are made'

    $exact = Invoke-ConnectorDoctor 'smollm2:360m' 'ready'
    Assert-True ($exact.ollama.state -eq 'READY_FOR_LIVE_TEST') 'Exact installed model passes preflight'
    Assert-True ($exact.ollama.model_match -eq 'EXACT') 'Exact model match is distinguished'

    $latest = Invoke-ConnectorDoctor 'missing-model' 'invalid-tags'
    Assert-True ($latest.ollama.state -eq 'MODEL_INVENTORY_UNAVAILABLE') 'Malformed inventory is not treated as an empty model list'

    $offline = Invoke-ConnectorDoctor 'smollm2:360m' 'unreachable'
    Assert-True ($offline.ollama.state -eq 'ENDPOINT_UNREACHABLE') 'Unreachable endpoint is diagnosed'
    Assert-True ($offline.ollama.probes.tags.status -eq 'NOT_CHECKED') 'Tags are not requested after version endpoint failure'

    $reports = @(Get-ChildItem -LiteralPath $outputRoot -Filter 'connector-doctor-*.json' -File -Recurse)
    Assert-True ($reports.Count -eq 4) 'Each diagnostic run writes one JSON report'
    Assert-True (@(Get-ChildItem -LiteralPath $outputRoot -Filter 'connector-doctor-*.txt' -File -Recurse).Count -eq 4) 'Each diagnostic run writes one text report'
    Assert-True ($alias.safety.inference_executed -eq $false) 'Doctor explicitly records that no inference was executed'
    Write-Output ('Connector Doctor mocked tests: ' + $passes + ' PASS')
}
finally {
    Remove-Variable -Name BatllmConnectorDoctorScenario, BatllmConnectorDoctorCalls -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
