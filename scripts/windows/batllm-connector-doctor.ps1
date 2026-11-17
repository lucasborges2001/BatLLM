#requires -Version 5.1
<# Read-only OllamaConnector preflight and historical JUnit diagnostics. #>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$Model = '',
    [string]$Url = 'http://127.0.0.1',
    [ValidateRange(1, 65535)][int]$Port = 11434,
    [ValidateRange(1, 30)][int]$TimeoutSeconds = 3,
    [string]$EvidenceDirectory = '',
    [string]$OutputDirectory = '',
    [switch]$SkipStaticDoctor,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$overall = [Diagnostics.Stopwatch]::StartNew()

if (-not $RepoRoot) { $RepoRoot = Join-Path $PSScriptRoot '..\..' }
$repo = [IO.Path]::GetFullPath($RepoRoot)
if (-not (Test-Path -LiteralPath $repo -PathType Container)) { throw "Repository does not exist: $repo" }
try { $uri = [Uri]$Url } catch { throw 'Url must be an absolute HTTP(S) origin.' }
if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https') -or
    -not $uri.IsDefaultPort -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
    throw 'Url must be an HTTP(S) origin without port, path, query, credentials or fragment; use -Port separately.'
}
$hostName = $uri.Host
if ($hostName.Contains(':')) { $hostName = "[$hostName]" }
$endpoint = $uri.Scheme + '://' + $hostName + ':' + $Port

if (-not $EvidenceDirectory) { $EvidenceDirectory = Join-Path $repo 'tmp' }
elseif (-not [IO.Path]::IsPathRooted($EvidenceDirectory)) { $EvidenceDirectory = Join-Path $repo $EvidenceDirectory }
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)

$started = Get-Date
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repo ('tmp\' + $started.ToString('yyyy-MM-dd') + '\' + $started.ToString('HH') + '\ConnectorDoctor')
}
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $repo $OutputDirectory }
$output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
$repoPrefix = $repo.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$tmpRoot = [IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\', '/')
if ($output.Equals($repo.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase) -or
    ($output.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase) -and
     -not ($output.Equals($tmpRoot, [StringComparison]::OrdinalIgnoreCase) -or
           $output.StartsWith($tmpRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)))) {
    throw 'Output inside the checkout is restricted to tmp\; an external output directory is also allowed.'
}

function Invoke-ReadOnlyCommand {
    param([string]$Executable, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = & $Executable @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    catch { $result = @($_.Exception.Message); $code = 1 }
    finally { $ErrorActionPreference = $previous }
    if ($null -eq $code) { $code = 1 }
    [pscustomobject]@{ exit_code = [int]$code; output = (($result | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim() }
}

function Invoke-ApiGet {
    param([string]$Address)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $data = Invoke-RestMethod -Method Get -Uri $Address -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        $watch.Stop()
        [pscustomobject]@{ status = 'PASS'; elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 2); data = $data; error = '' }
    }
    catch {
        $watch.Stop()
        [pscustomobject]@{ status = 'FAIL'; elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 2); data = $null; error = $_.Exception.Message }
    }
}

function Read-JUnit {
    param([string]$Path)
    $result = [ordered]@{ available = $false; tests = 0; failures = 0; errors = 0; skipped = 0; duration_seconds = 0.0; failure_message = '' }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$result }
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw
        $cases = @($xml.SelectNodes('//testcase'))
        $result.available = $true
        $result.tests = $cases.Count
        foreach ($case in $cases) {
            $seconds = 0.0
            [void][double]::TryParse([string]$case.GetAttribute('time'), [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
            $result.duration_seconds += $seconds
            foreach ($node in @($case.SelectNodes('./failure|./error|./skipped'))) {
                if ($node.LocalName -eq 'failure') { $result.failures++ }
                elseif ($node.LocalName -eq 'error') { $result.errors++ }
                elseif ($node.LocalName -eq 'skipped') { $result.skipped++ }
                if (-not $result.failure_message -and $node.LocalName -in @('failure', 'error')) {
                    $message = [string]$node.GetAttribute('message')
                    if (-not $message) { $message = [string]$node.InnerText }
                    if ($message.Length -gt 2000) { $message = $message.Substring(0, 2000) + ' [truncated]' }
                    $result.failure_message = $message.Trim()
                }
            }
        }
        $result.duration_seconds = [Math]::Round($result.duration_seconds, 3)
    }
    catch { $result.failure_message = 'JUnit parse error: ' + $_.Exception.Message }
    [pscustomobject]$result
}

function Read-HistoricalRuns {
    param([string]$Directory)
    $runs = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter 'connector-live-*.json' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 20)
    foreach ($file in $files) {
        try {
            $saved = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $junitPath = [string]$saved.junit_path
            $logPath = [string]$saved.log_path
            if ($junitPath -and -not [IO.Path]::IsPathRooted($junitPath)) { $junitPath = Join-Path $repo $junitPath }
            if ($logPath -and -not [IO.Path]::IsPathRooted($logPath)) { $logPath = Join-Path $repo $logPath }
            $junit = Read-JUnit $junitPath
            $message = [string]$junit.failure_message
            $model = [string]$saved.model_override
            $installed = @()
            $diagnosis = 'TEST_FAILURE_REQUIRES_REVIEW'
            $stage = 'NOT_DETERMINED_FROM_SUMMARY'
            if ($message -match "Model '([^']+)' is not installed") {
                $model = $Matches[1]
                $diagnosis = 'MODEL_NOT_INSTALLED_BEFORE_INFERENCE'
                $stage = 'MODEL_INVENTORY_PREFLIGHT'
                $inventory = [regex]::Match($message, 'Installed models:\s*\[(?<items>[^\]]*)\]')
                if ($inventory.Success) { $installed = @([regex]::Matches($inventory.Groups['items'].Value, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }) }
            }
            elseif ($message -match 'Cannot query the existing Ollama endpoint') { $diagnosis = 'OLLAMA_ENDPOINT_UNAVAILABLE_BEFORE_INFERENCE'; $stage = 'ENDPOINT_PREFLIGHT' }
            elseif ($message -match 'No model configured') { $diagnosis = 'MODEL_NOT_CONFIGURED'; $stage = 'MODEL_CONFIGURATION' }
            elseif ($junit.available -and $junit.tests -gt 0 -and $junit.failures -eq 0 -and $junit.errors -eq 0 -and $junit.skipped -eq 0 -and $saved.result -eq 'PASS') {
                $diagnosis = 'LIVE_TEST_PASS'; $stage = 'TWO_MESSAGE_CONNECTOR_SMOKE'
            }
            elseif ($junit.skipped -gt 0) { $diagnosis = 'TEST_SKIPPED'; $stage = 'TEST_ACTIVATION' }
            elseif (-not $junit.available) { $diagnosis = 'JUNIT_MISSING_OR_INVALID'; $stage = 'EVIDENCE_INCOMPLETE' }
            [void]$runs.Add([pscustomobject]@{
                file = $file.Name; checked_at_utc = $saved.checked_at_utc; branch = $saved.branch; tested_sha = $saved.tested_sha
                result = $saved.result; requested_model = $model; installed_models = $installed
                diagnosis = $diagnosis; stage = $stage; junit = $junit
                log_exists = [bool]($logPath -and (Test-Path -LiteralPath $logPath -PathType Leaf)); failure_message = $message; error = ''
            })
        }
        catch { [void]$runs.Add([pscustomobject]@{ file = $file.Name; tested_sha = 'unknown'; requested_model = 'unknown'; diagnosis = 'REPORT_JSON_INVALID'; junit = $null; installed_models = @(); failure_message = ''; error = $_.Exception.Message }) }
    }
    @($runs.ToArray())
}

$branch = Invoke-ReadOnlyCommand 'git' @('--no-optional-locks', '-C', $repo, 'branch', '--show-current')
$sha = Invoke-ReadOnlyCommand 'git' @('--no-optional-locks', '-C', $repo, 'rev-parse', 'HEAD')
$status = Invoke-ReadOnlyCommand 'git' @('--no-optional-locks', '-C', $repo, 'status', '--porcelain=v1', '--untracked-files=normal')

$staticWatch = [Diagnostics.Stopwatch]::StartNew()
$static = $null
$staticStatus = 'NOT_CHECKED'
$staticError = ''
if (-not $SkipStaticDoctor) {
    $staticPath = Join-Path $repo 'scripts\windows\batllm-doctor.ps1'
    if (Test-Path -LiteralPath $staticPath -PathType Leaf) {
        $hostExe = (Get-Process -Id $PID).Path
        $raw = Invoke-ReadOnlyCommand $hostExe @('-NoProfile', '-NonInteractive', '-File', $staticPath, '-RepoRoot', $repo, '-Target', 'NonLive', '-Json')
        if ($raw.exit_code -eq 0) {
            try {
                $static = $raw.output | ConvertFrom-Json
                if ($static.summary.FAIL -gt 0) { $staticStatus = 'FAIL' }
                elseif ($static.summary.WARN -gt 0) { $staticStatus = 'WARN' }
                elseif ($static.summary.NOT_CHECKED -gt 0) { $staticStatus = 'INCOMPLETE' }
                else { $staticStatus = 'PASS' }
            }
            catch { $staticStatus = 'INVALID_REPORT'; $staticError = $_.Exception.Message }
        }
        else { $staticStatus = 'EXECUTION_FAILED'; $staticError = $raw.output }
    }
    else { $staticStatus = 'MISSING'; $staticError = 'Existing batllm-doctor.ps1 was not found.' }
}
$staticWatch.Stop()

$version = Invoke-ApiGet ($endpoint + '/api/version')
$tags = [pscustomobject]@{ status = 'NOT_CHECKED'; elapsed_ms = 0.0; data = $null; error = 'Version endpoint did not return a valid response.' }
$apiVersion = ''
$models = @()
if ($version.status -eq 'PASS' -and $null -ne $version.data -and
    $null -ne $version.data.PSObject.Properties['version'] -and $version.data.version) {
    $apiVersion = [string]$version.data.version
    $tags = Invoke-ApiGet ($endpoint + '/api/tags')
    if ($tags.status -eq 'PASS' -and $null -ne $tags.data -and
        $null -ne $tags.data.PSObject.Properties['models'] -and $null -ne $tags.data.models) {
        foreach ($entry in @($tags.data.models)) {
            if ($null -ne $entry -and $null -ne $entry.PSObject.Properties['name'] -and $entry.name) {
                $models += [string]$entry.name
            }
        }
    }
    elseif ($tags.status -eq 'PASS') { $tags.status = 'FAIL'; $tags.error = 'The /api/tags response has no models collection.' }
}
elseif ($version.status -eq 'PASS') { $version.status = 'FAIL'; $version.error = 'The /api/version response has no version field.' }

$modelMatch = 'NOT_SELECTED'
$related = @()
if ($tags.status -eq 'PASS') {
    if ($models.Count -eq 0) { $modelMatch = 'NO_MODELS_INSTALLED' }
    elseif ($Model) {
        if ($models -ccontains $Model) { $modelMatch = 'EXACT' }
        elseif ($Model -notmatch ':' -and $models -ccontains ($Model + ':latest')) { $modelMatch = 'LATEST_ALIAS' }
        else {
            $modelMatch = 'NOT_FOUND'
            if ($Model -notmatch ':') { $related = @($models | Where-Object { $_.StartsWith($Model + ':', [StringComparison]::OrdinalIgnoreCase) }) }
        }
    }
}
$ollamaState = 'ENDPOINT_UNREACHABLE'
if ($version.status -eq 'PASS' -and $tags.status -ne 'PASS') { $ollamaState = 'MODEL_INVENTORY_UNAVAILABLE' }
elseif ($version.status -eq 'PASS' -and $tags.status -eq 'PASS') {
    switch ($modelMatch) {
        'NO_MODELS_INSTALLED' { $ollamaState = 'NO_MODELS_INSTALLED' }
        'NOT_SELECTED' { $ollamaState = 'MODEL_NOT_SELECTED' }
        'NOT_FOUND' { $ollamaState = 'MODEL_NOT_INSTALLED' }
        default { $ollamaState = 'READY_FOR_LIVE_TEST' }
    }
}

$evidenceWatch = [Diagnostics.Stopwatch]::StartNew()
$history = @(Read-HistoricalRuns $EvidenceDirectory)
$evidenceWatch.Stop()
$overall.Stop()

$stamp = $started.ToString('yyyyMMdd-HHmmss-fff')
New-Item -ItemType Directory -Path $output -Force | Out-Null
$jsonPath = Join-Path $output ('connector-doctor-' + $stamp + '.json')
$textPath = Join-Path $output ('connector-doctor-' + $stamp + '.txt')
$staticSummary = $null
$staticChecks = @()
if ($static) { $staticSummary = $static.summary; $staticChecks = @($static.checks) }
$report = [ordered]@{
    schema_version = 1; tool = 'batllm-connector-doctor'; checked_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    repository = [ordered]@{ path = $repo; branch = $branch.output; sha = $sha.output; git_available = ($branch.exit_code -eq 0 -and $sha.exit_code -eq 0); worktree_clean_before_report = ($status.exit_code -eq 0 -and -not $status.output); status_before_report = $status.output }
    static_doctor = [ordered]@{ status = $staticStatus; elapsed_ms = [Math]::Round($staticWatch.Elapsed.TotalMilliseconds, 2); summary = $staticSummary; checks = $staticChecks; error = $staticError; skipped = [bool]$SkipStaticDoctor }
    ollama = [ordered]@{ endpoint = $endpoint; state = $ollamaState; requested_model = $Model; model_match = $modelMatch; api_version = $apiVersion; installed_models = $models; related_models = $related; probes = [ordered]@{ version = [ordered]@{ status = $version.status; elapsed_ms = $version.elapsed_ms; error = $version.error }; tags = [ordered]@{ status = $tags.status; elapsed_ms = $tags.elapsed_ms; error = $tags.error } } }
    historical = [ordered]@{ evidence_directory = $EvidenceDirectory; runs_found = $history.Count; runs = $history }
    timing = [ordered]@{ static_doctor_ms = [Math]::Round($staticWatch.Elapsed.TotalMilliseconds, 2); api_version_ms = $version.elapsed_ms; api_tags_ms = $tags.elapsed_ms; evidence_scan_ms = [Math]::Round($evidenceWatch.Elapsed.TotalMilliseconds, 2); diagnostic_elapsed_ms = [Math]::Round($overall.Elapsed.TotalMilliseconds, 2) }
    safety = [ordered]@{ api_methods = @('GET'); inference_executed = $false; service_started_or_stopped = $false; models_downloaded_or_deleted = $false; application_configuration_changed = $false; reports_written = $true }
    limitations = @('READY_FOR_LIVE_TEST means only that the API and requested model were detected; no inference or Connector behaviour was tested.', 'Historical duration is the sum of JUnit testcase time values, not total process/setup time.', 'The existing NonLive Doctor does not contact Ollama.')
    output = [ordered]@{ json = $jsonPath; text = $textPath }
}
$lines = @(
    'BatLLM Connector Doctor', 'Checked UTC: ' + $report.checked_at_utc, 'Repository: ' + $repo,
    'Branch: ' + $branch.output, 'SHA: ' + $sha.output,
    'Worktree clean before report: ' + [string]$report.repository.worktree_clean_before_report,
    'Static Doctor: ' + $staticStatus + ' (' + $report.timing.static_doctor_ms + ' ms)',
    'Ollama endpoint: ' + $endpoint, 'Ollama state: ' + $ollamaState, 'API version: ' + $apiVersion,
    'GET /api/version: ' + $version.status + ' (' + $version.elapsed_ms + ' ms)',
    'GET /api/tags: ' + $tags.status + ' (' + $tags.elapsed_ms + ' ms)',
    'Requested model: ' + $(if ($Model) { $Model } else { 'NOT SELECTED' }), 'Model match: ' + $modelMatch,
    'Installed models: ' + $(if ($models.Count) { $models -join ', ' } else { 'NONE / NOT AVAILABLE' })
)
if ($related.Count) { $lines += 'Related tagged models (select explicitly): ' + ($related -join ', ') }
foreach ($run in $history) {
    $duration = 'n/a'
    if ($null -ne $run.junit) { $duration = $run.junit.duration_seconds }
    $lines += '- ' + $run.file + ': ' + $run.diagnosis + '; SHA=' + $run.tested_sha + '; model=' + $run.requested_model + '; duration=' + $duration + ' s'
    if ($run.failure_message) { $lines += '  Failure: ' + $run.failure_message }
    if (@($run.installed_models).Count) { $lines += '  Models reported by failure: ' + ($run.installed_models -join ', ') }
    if ($run.error) { $lines += '  Report error: ' + $run.error }
}
$lines += @('', 'Diagnostic elapsed: ' + $report.timing.diagnostic_elapsed_ms + ' ms', 'Inference executed: NO', 'Ollama started/stopped: NO', 'Models downloaded/deleted: NO', 'JSON: ' + $jsonPath, 'TXT: ' + $textPath)
$jsonText = $report | ConvertTo-Json -Depth 12
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($jsonPath, $jsonText, $utf8)
[IO.File]::WriteAllText($textPath, ($lines -join [Environment]::NewLine), $utf8)
if ($Json) { Write-Output $jsonText } else { Write-Output ($lines -join [Environment]::NewLine) }
