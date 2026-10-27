#requires -Version 5.1
<#
.SYNOPSIS
    Launch BatLLM on Windows with optional external runtime diagnostics.
.DESCRIPTION
    Uses batllm-apply.ps1 for existing Gameplay preflight. Without
    -MonitorPerformance the launcher delegates to the unchanged Apply launch.
    Monitored runs sample the full BatLLM child-process tree, Ollama-labelled
    processes and available physical memory to an isolated CSV.
    -DiagnosticLevel Extended also watches visible GUI responsiveness and the
    Ollama local /api/version endpoint. These are indicators, not proof that a
    gameplay turn, inference, save or replay succeeded.
    -Scenario labels the run; it does not automate the user interface.
    -AlertProfile controls available-RAM percentage thresholds and severity;
    monitoring never stops Ollama or the game because of an alert.
    Timers are sampled estimates, not inference or turn latency.
    No configuration, model, saved session or remote Git state is modified.
.EXAMPLE
    .\scripts\windows\batllm-launch.ps1 -Model smollm2:360m
.EXAMPLE
    .\scripts\windows\batllm-launch.ps1 -Model smollm2:360m -MonitorPerformance -IntervalSeconds 3
.EXAMPLE
    .\scripts\windows\batllm-launch.ps1 -Model smollm2:360m -MonitorPerformance -DiagnosticLevel Extended -Scenario HangRepro -AlertProfile Balanced
.EXAMPLE
    .\scripts\windows\batllm-launch.ps1 -Model smollm2:360m -MonitorPerformance -AlertProfile Custom -WarningRamPercent 12 -CriticalRamPercent 5
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]*$')]
    [string]$Model = 'smollm2:360m',
    [switch]$MonitorPerformance,
    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 3,
    [ValidateSet('Basic', 'Extended')]
    [string]$DiagnosticLevel = 'Basic',
    [ValidateSet('General', 'Startup', 'Idle', 'Gameplay', 'SaveAnalyzer', 'HangRepro')]
    [string]$Scenario = 'General',
    [ValidateSet('Balanced', 'Sensitive', 'Relaxed', 'Custom')]
    [string]$AlertProfile = 'Balanced',
    [ValidateRange(1, 99)]
    [int]$WarningRamPercent = 10,
    [ValidateRange(1, 99)]
    [int]$CriticalRamPercent = 5,
    # Legacy absolute threshold is optional; off by default. Used as an
    # additional WARNING guard when specified explicitly.
    [ValidateRange(0, 16384)]
    [int]$LowRamThresholdMB = 0,
    [ValidateRange(2, 10)]
    [int]$UnresponsiveSamples = 3,
    [switch]$CaptureAppOutput,
    [string]$StateDir = (Join-Path $env:APPDATA 'BatLLM\Workshop')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\', '/')
$applyScript = Join-Path $PSScriptRoot 'batllm-apply.ps1'
$python = Join-Path $repo '.venv_BatLLM\Scripts\python.exe'
$entry = Join-Path $repo 'run_batllm.py'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'BatLLM launcher requires Windows.'
}
if (-not (Test-Path -LiteralPath $applyScript -PathType Leaf)) {
    throw 'batllm-apply.ps1 is required alongside this launcher.'
}
if (-not $MonitorPerformance -and ($DiagnosticLevel -ne 'Basic' -or $Scenario -ne 'General' -or $CaptureAppOutput -or
    $PSBoundParameters.ContainsKey('AlertProfile') -or $PSBoundParameters.ContainsKey('WarningRamPercent') -or
    $PSBoundParameters.ContainsKey('CriticalRamPercent') -or $PSBoundParameters.ContainsKey('LowRamThresholdMB'))) {
    throw 'Diagnostic options require -MonitorPerformance.'
}
if ($CaptureAppOutput -and $DiagnosticLevel -ne 'Extended') {
    throw '-CaptureAppOutput requires -DiagnosticLevel Extended.'
}
if ($AlertProfile -ne 'Custom' -and
    ($PSBoundParameters.ContainsKey('WarningRamPercent') -or $PSBoundParameters.ContainsKey('CriticalRamPercent'))) {
    throw '-WarningRamPercent and -CriticalRamPercent require -AlertProfile Custom.'
}
if ($AlertProfile -eq 'Custom' -and $CriticalRamPercent -ge $WarningRamPercent) {
    throw 'Custom critical RAM percentage must be strictly below warning percentage.'
}

# Threshold selection/classification are pure functions. The alert transition
# state machine can be tested with an in-memory event sink, without the GUI.
function Get-RamAlertThresholds {
    param([string]$Name, [int]$CustomWarning, [int]$CustomCritical)
    switch ($Name) {
        'Balanced'  { return @{ warning = 10; critical = 5 } }
        'Sensitive' { return @{ warning = 15; critical = 8 } }
        'Relaxed'   { return @{ warning = 8; critical = 3 } }
        'Custom'    { return @{ warning = $CustomWarning; critical = $CustomCritical } }
        default     { throw ('Unknown alert profile: ' + $Name) }
    }
}

function Get-RamAlertLevel {
    param([double]$AvailablePercent, [double]$AvailableMb, [int]$WarnPercent,
        [int]$CritPercent, [int]$LegacyWarnMb = 0)
    if ($AvailablePercent -le $CritPercent) { return 'CRITICAL' }
    if ($AvailablePercent -le $WarnPercent -or
        ($LegacyWarnMb -gt 0 -and $AvailableMb -le $LegacyWarnMb)) { return 'WARN' }
    return 'OK'
}

$ramThresholds = Get-RamAlertThresholds -Name $AlertProfile -CustomWarning $WarningRamPercent -CustomCritical $CriticalRamPercent
$warningPct = [int]$ramThresholds.warning
$criticalPct = [int]$ramThresholds.critical

# Existing Apply remains the owner of environment, model and safety checks.
$applyArgs = @{
    Mode = 'Gameplay'
    Apply = $true
    Model = $Model
    StateDir = $StateDir
}
if (-not $MonitorPerformance) {
    $applyArgs['Launch'] = $true
    & $applyScript @applyArgs
    return
}

& $applyScript @applyArgs
if ($LASTEXITCODE -ne 0) {
    throw ('Gameplay preflight failed (exit code {0}); BatLLM was not launched.' -f $LASTEXITCODE)
}
if (-not (Test-Path -LiteralPath $python -PathType Leaf) -or
    -not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    throw 'BatLLM Python entry point is missing after Apply.'
}

# All reports remain outside the checkout in the already validated state directory.
$diagnosticsDir = Join-Path $StateDir 'diagnostics'
[void](New-Item -ItemType Directory -Path $diagnosticsDir -Force)
$runId = 'batllm-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$csvPath = Join-Path $diagnosticsDir ($runId + '.csv')
$eventsPath = Join-Path $diagnosticsDir ($runId + '.events.csv')
$summaryPath = Join-Path $diagnosticsDir ($runId + '.summary.json')
$stdoutPath = Join-Path $diagnosticsDir ($runId + '.stdout.log')
$stderrPath = Join-Path $diagnosticsDir ($runId + '.stderr.log')

$csvHeader = 'timestamp_utc,elapsed_s,kind,name,pid,cpu_pct_total,rss_mb,private_mb,threads,system_free_ram_mb,exit_code,run_id,scenario,parent_pid,ui_responding,ollama_api,warning_code,system_total_ram_mb,system_available_ram_pct,ram_alert_level,ollama_api_latency_ms'
$eventHeader = 'timestamp_utc,elapsed_s,run_id,scenario,code,detail,severity,alert_profile'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function New-ExclusiveTextFile {
    param([string]$Path, [string]$Header)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $writer = [IO.StreamWriter]::new($stream, $utf8)
        try { $writer.WriteLine($Header) }
        finally { $writer.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Csv-Value {
    param($Value)
    if ($null -eq $Value) { return '' }
    $string = [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($string.Contains(',') -or $string.Contains('"') -or $string.Contains("`n")) {
        return ('"' + $string.Replace('"', '""') + '"')
    }
    return $string
}

function Csv-Row {
    param([object[]]$Fields)
    return (($Fields | ForEach-Object { Csv-Value $_ }) -join ',')
}

New-ExclusiveTextFile -Path $csvPath -Header $csvHeader
New-ExclusiveTextFile -Path $eventsPath -Header $eventHeader
$watch = [Diagnostics.Stopwatch]::StartNew()
$logicalCpus = [Math]::Max(1, [Environment]::ProcessorCount)
$priorCpu = @{}
$knownGamePids = @{}
$sampleCount = 0
$minFreeMb = $null
$minAvailablePct = $null
$maxGameRssMb = 0.0
$maxOllamaRssMb = 0.0
$maxGameCpuPct = 0.0
$maxOllamaCpuPct = 0.0
$guiNoResponseCount = 0
$guiWarningActive = $false
$lastApiCheckSeconds = -9999.0
$apiState = 'not_checked'
$apiLatencyMs = $null
$apiWarningActive = $false
$ramAlertLevel = 'UNKNOWN'
$pendingWarnSamples = 0
$maxSeverity = 'INFO'
$severityCounts = @{ INFO = 0; WARN = 0; CRITICAL = 0 }
$eventCounts = @{}
$sampleErrors = 0
$maxApiLatencyMs = $null
$firstGuiReadySeconds = $null
$firstGameChildSeconds = $null
$lastSampleElapsed = $null
$previousSampleRamLevel = 'UNKNOWN'
$previousSampleGuiStatus = 'unknown'
$previousSampleApiState = 'not_checked'
$secondsInRamWarning = 0.0
$secondsInRamCritical = 0.0
$secondsGuiUnresponsive = 0.0
$secondsApiUnready = 0.0
$lastGameProcessCount = $null

function Add-DiagnosticEvent {
    param([string]$Code, [string]$Detail,
        [ValidateSet('INFO', 'WARN', 'CRITICAL')][string]$Severity = 'INFO')
    $stamp = [DateTime]::UtcNow.ToString('o')
    $line = Csv-Row @($stamp, [Math]::Round($watch.Elapsed.TotalSeconds, 2), $runId,
        $Scenario, $Code, $Detail, $Severity, $AlertProfile)
    [IO.File]::AppendAllText($eventsPath, ($line + [Environment]::NewLine), $utf8)
    if (-not $eventCounts.ContainsKey($Code)) { $eventCounts[$Code] = 0 }
    $eventCounts[$Code]++
    $severityCounts[$Severity]++
    if ($Severity -eq 'CRITICAL' -or ($Severity -eq 'WARN' -and $maxSeverity -eq 'INFO')) {
        $script:maxSeverity = $Severity
    }
    Write-Host ('DIAG [{0}] {1}: {2}' -f $Severity, $Code, $Detail)
}

function Update-SampledDurations {
    param([double]$Elapsed, [string]$NewRamLevel, [string]$NewGuiStatus,
        [string]$NewApiState)
    if ($null -ne $lastSampleElapsed) {
        # Attribute elapsed time to the PREVIOUS observation. Sampling is not
        # precise enough to time transitions within an interval.
        $delta = [Math]::Max(0.0, $Elapsed - [double]$lastSampleElapsed)
        if ($previousSampleRamLevel -eq 'WARN') { $script:secondsInRamWarning += $delta }
        if ($previousSampleRamLevel -eq 'CRITICAL') { $script:secondsInRamCritical += $delta }
        if ($previousSampleGuiStatus -eq 'false') { $script:secondsGuiUnresponsive += $delta }
        if ($previousSampleApiState -in @('unreachable', 'invalid_response')) {
            $script:secondsApiUnready += $delta
        }
    }
    $script:lastSampleElapsed = $Elapsed
    $script:previousSampleRamLevel = $NewRamLevel
    $script:previousSampleGuiStatus = $NewGuiStatus
    $script:previousSampleApiState = $NewApiState
}

function Update-RamAlert {
    param([double]$Percent, [double]$FreeMb)
    $observed = Get-RamAlertLevel -AvailablePercent $Percent -AvailableMb $FreeMb `
        -WarnPercent $warningPct -CritPercent $criticalPct -LegacyWarnMb $LowRamThresholdMB
    if ($ramAlertLevel -eq 'UNKNOWN') { $script:ramAlertLevel = 'OK' }
    # CRITICAL triggers immediately; WARN requires two consecutive samples.
    # Recovery uses +2 percentage points of hysteresis to avoid flapping.
    if ($observed -eq 'CRITICAL') {
        $script:pendingWarnSamples = 0
        if ($ramAlertLevel -ne 'CRITICAL') {
            Add-DiagnosticEvent 'RAM_CRITICAL' ('RAM available {0:N1}% ({1:N1} MB), critical at <= {2}%.' -f $Percent, $FreeMb, $criticalPct) 'CRITICAL'
        }
        $script:ramAlertLevel = 'CRITICAL'
    }
    elseif ($ramAlertLevel -eq 'CRITICAL' -and $Percent -le ($criticalPct + 2)) {
        return
    }
    elseif ($ramAlertLevel -eq 'WARN' -and $observed -eq 'OK' -and
        ($Percent -le ($warningPct + 2) -or ($LowRamThresholdMB -gt 0 -and $FreeMb -le ($LowRamThresholdMB + 128)))) {
        return
    }
    elseif ($observed -eq 'WARN') {
        $script:pendingWarnSamples++
        if ($ramAlertLevel -eq 'CRITICAL' -or $pendingWarnSamples -ge 2 -or $ramAlertLevel -eq 'WARN') {
            if ($ramAlertLevel -ne 'WARN') {
                Add-DiagnosticEvent 'RAM_WARNING' ('RAM available {0:N1}% ({1:N1} MB), warning threshold <= {2}% or optional legacy guard {3} MB.' -f $Percent, $FreeMb, $warningPct, $LowRamThresholdMB) 'WARN'
            }
            $script:ramAlertLevel = 'WARN'
        }
    }
    else {
        $script:pendingWarnSamples = 0
        if ($ramAlertLevel -in @('WARN', 'CRITICAL')) {
            Add-DiagnosticEvent 'RAM_RECOVERED' ('RAM available recovered to {0:N1}% ({1:N1} MB).' -f $Percent, $FreeMb)
        }
        $script:ramAlertLevel = 'OK'
    }
}

function Get-CpuPercent {
    param($Process, [DateTime]$Timestamp)
    $key = [string]$Process.Id
    try {
        $seconds = [double]$Process.CPU
        $pct = $null
        if ($priorCpu.ContainsKey($key)) {
            $previous = $priorCpu[$key]
            $wallSeconds = ($Timestamp - $previous.time).TotalSeconds
            $cpuSeconds = $seconds - $previous.cpu
            if ($wallSeconds -gt 0 -and $cpuSeconds -ge 0) {
                $pct = [Math]::Round(100 * $cpuSeconds / ($wallSeconds * $logicalCpus), 1)
            }
        }
        $priorCpu[$key] = @{ time = $Timestamp; cpu = $seconds }
        return $pct
    }
    catch { return $null }
}

function Get-GameProcessTree {
    param([int]$RootProcessId)
    $cimProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Select-Object ProcessId, ParentProcessId)
    $parents = @{}
    foreach ($item in $cimProcesses) {
        $parents[[int]$item.ProcessId] = [int]$item.ParentProcessId
    }
    # Keep previously observed descendants in case a Python launcher exits
    # while its real GUI process continues running.
    $found = @{}
    if ($parents.ContainsKey($RootProcessId)) { $found[$RootProcessId] = $true }
    foreach ($pidText in @($knownGamePids.Keys)) {
        $childId = [int]$pidText
        if ($parents.ContainsKey($childId)) { $found[$childId] = $true }
    }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($candidate in $parents.Keys) {
            if (-not $found.ContainsKey($candidate) -and $found.ContainsKey($parents[$candidate])) {
                $found[$candidate] = $true
                $changed = $true
            }
        }
    }
    $idList = New-Object 'System.Collections.Generic.List[int]'
    foreach ($k in $found.Keys) {
        $knownGamePids[$k] = $true
        [void]$idList.Add([int]$k)
    }
    return [pscustomobject]@{ ids = $idList.ToArray(); parents = $parents }
}

function Test-OllamaEndpoint {
    $probe = [Diagnostics.Stopwatch]::StartNew()
    $status = 'unreachable'
    try {
        $response = Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 2 -ErrorAction Stop
        if ($response -and $response.version) { $status = 'ready' }
        else { $status = 'invalid_response' }
    }
    catch { $status = 'unreachable' }
    finally { $probe.Stop() }
    return [pscustomobject]@{
        status = $status
        latency_ms = [Math]::Round($probe.Elapsed.TotalMilliseconds, 1)
    }
}

function Add-RuntimeSample {
    param([int]$RootProcessId)
    $now = [DateTime]::UtcNow
    $stamp = $now.ToString('o')
    $elapsed = [Math]::Round($watch.Elapsed.TotalSeconds, 2)
    $freeMb = $null
    $totalMb = $null
    $availablePct = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $freeMb = [Math]::Round(([double]$os.FreePhysicalMemory / 1024), 1)
        $totalMb = [Math]::Round(([double]$os.TotalVisibleMemorySize / 1024), 1)
        if ($totalMb -le 0) { throw 'TotalVisibleMemorySize is zero or negative.' }
        $availablePct = [Math]::Round(100.0 * $freeMb / $totalMb, 1)
    }
    catch { Add-DiagnosticEvent 'SAMPLE_WARNING' 'Could not query valid Windows physical memory totals.' 'WARN' }

    if ($null -ne $freeMb -and $null -ne $availablePct) {
        if ($null -eq $minFreeMb -or $freeMb -lt $minFreeMb) { $script:minFreeMb = $freeMb }
        if ($null -eq $script:minAvailablePct -or $availablePct -lt $script:minAvailablePct) {
            $script:minAvailablePct = $availablePct
        }
        Update-RamAlert -Percent $availablePct -FreeMb $freeMb
    }

    $tree = Get-GameProcessTree -RootProcessId $RootProcessId
    $allProcesses = @(Get-Process -ErrorAction SilentlyContinue)
    $gameRss = 0.0
    $ollamaRss = 0.0
    $gameCpu = 0.0
    $ollamaCpu = 0.0
    $gameCount = 0
    $ollamaCount = 0
    $guiPid = $null
    $guiStatus = 'unknown'
    $records = New-Object 'System.Collections.Generic.List[object]'

    foreach ($p in $allProcesses) {
        $isGame = $tree.ids -contains [int]$p.Id
        $isOllama = $p.ProcessName -like 'ollama*'
        if (-not $isGame -and -not $isOllama) { continue }
        $kind = if ($isGame) { 'BatLLM' } else { 'Ollama' }
        $cpuPct = Get-CpuPercent -Process $p -Timestamp $now
        try {
            $rss = [Math]::Round(([double]$p.WorkingSet64 / 1MB), 1)
            $private = [Math]::Round(([double]$p.PrivateMemorySize64 / 1MB), 1)
        }
        catch { continue }
        $threads = $null
        try { $threads = $p.Threads.Count } catch { }
        $parentId = $null
        if ($tree.parents.ContainsKey([int]$p.Id)) { $parentId = $tree.parents[[int]$p.Id] }
        $responding = ''
        if ($DiagnosticLevel -eq 'Extended' -and $isGame) {
            try {
                if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                    $responding = if ($p.Responding) { 'true' } else { 'false' }
                    $guiPid = [int]$p.Id
                    $guiStatus = $responding
                }
            }
            catch { }
        }
        if ($isGame) {
            $gameCount++
            $gameRss += $rss
            if ($null -ne $cpuPct) { $gameCpu += $cpuPct }
        }
        else {
            $ollamaCount++
            $ollamaRss += $rss
            if ($null -ne $cpuPct) { $ollamaCpu += $cpuPct }
        }
        [void]$records.Add([pscustomobject]@{
            kind = $kind; name = $p.ProcessName; pid = $p.Id; parent = $parentId
            cpu = $cpuPct; rss = $rss; private = $private; threads = $threads
            responding = $responding
        })
    }
    if ($null -eq $firstGameChildSeconds -and $gameCount -ge 2) {
        $script:firstGameChildSeconds = $elapsed
    }
    if ($null -eq $lastGameProcessCount -or $gameCount -ne $lastGameProcessCount) {
        Add-DiagnosticEvent 'PROCESS_TREE_COUNT' ('Observed BatLLM process count changed to {0}.' -f $gameCount)
        $script:lastGameProcessCount = $gameCount
    }
    if ($gameRss -gt $maxGameRssMb) { $script:maxGameRssMb = [Math]::Round($gameRss, 1) }
    if ($ollamaRss -gt $maxOllamaRssMb) { $script:maxOllamaRssMb = [Math]::Round($ollamaRss, 1) }
    if ($gameCpu -gt $maxGameCpuPct) { $script:maxGameCpuPct = [Math]::Round($gameCpu, 1) }
    if ($ollamaCpu -gt $maxOllamaCpuPct) { $script:maxOllamaCpuPct = [Math]::Round($ollamaCpu, 1) }

    if ($DiagnosticLevel -eq 'Extended') {
        if ($elapsed - $lastApiCheckSeconds -ge [Math]::Max(15, $IntervalSeconds)) {
            $apiProbe = Test-OllamaEndpoint
            $script:apiState = $apiProbe.status
            $script:apiLatencyMs = $apiProbe.latency_ms
            if ($null -eq $maxApiLatencyMs -or $apiLatencyMs -gt $maxApiLatencyMs) {
                $script:maxApiLatencyMs = $apiLatencyMs
            }
            $script:lastApiCheckSeconds = $elapsed
            if ($apiState -ne 'ready' -and -not $apiWarningActive) {
                Add-DiagnosticEvent 'OLLAMA_API_UNREADY' ('Local Ollama API status: ' + $apiState) 'WARN'
                $script:apiWarningActive = $true
            }
            elseif ($apiState -eq 'ready' -and $apiWarningActive) {
                Add-DiagnosticEvent 'OLLAMA_API_RECOVERED' 'Local Ollama API is reachable again.'
                $script:apiWarningActive = $false
            }
        }
        if ($guiStatus -eq 'true' -and $null -eq $firstGuiReadySeconds) {
            $script:firstGuiReadySeconds = $elapsed
            Add-DiagnosticEvent 'GUI_FIRST_RESPONSIVE' ('First responsive GUI detected after {0:N1}s.' -f $elapsed)
        }
        if ($guiStatus -eq 'false') {
            $script:guiNoResponseCount++
            if ($guiNoResponseCount -ge $UnresponsiveSamples -and -not $guiWarningActive) {
                Add-DiagnosticEvent 'GUI_UNRESPONSIVE' ('Visible BatLLM window on PID {0} was unresponsive in {1} consecutive polls.' -f $guiPid, $guiNoResponseCount) 'CRITICAL'
                $script:guiWarningActive = $true
            }
        }
        elseif ($guiStatus -eq 'true') {
            $script:guiNoResponseCount = 0
            if ($guiWarningActive) {
                Add-DiagnosticEvent 'GUI_RECOVERED' 'BatLLM GUI is responding again.'
                $script:guiWarningActive = $false
            }
        }
        else { $script:guiNoResponseCount = 0 }
    }

    Update-SampledDurations -Elapsed $elapsed -NewRamLevel $ramAlertLevel `
        -NewGuiStatus $guiStatus -NewApiState $apiState

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($r in $records) {
        [void]$lines.Add((Csv-Row @($stamp, $elapsed, $r.kind, $r.name, $r.pid, $r.cpu,
            $r.rss, $r.private, $r.threads, $freeMb, '', $runId, $Scenario,
            $r.parent, $r.responding, $apiState, '', $totalMb, $availablePct,
            $ramAlertLevel, $apiLatencyMs)))
    }
    [void]$lines.Add((Csv-Row @($stamp, $elapsed, 'System', 'Windows', '', '', '', '', '',
        $freeMb, '', $runId, $Scenario, '', $guiStatus, $apiState, '',
        $totalMb, $availablePct, $ramAlertLevel, $apiLatencyMs)))
    [IO.File]::AppendAllLines($csvPath, $lines, $utf8)
    $script:sampleCount++
    $gameDisplay = if ($gameCount -eq 0) { 'none' } else { '{0:N1} MB ({1} processes)' -f $gameRss, $gameCount }
    $ramDisplay = if ($null -eq $freeMb) { 'N/A' } else {
        '{0:N1} MB ({1:N1}%)' -f $freeMb, $availablePct
    }
    $guiDisplay = if ($DiagnosticLevel -eq 'Basic') { 'not checked' } else { $guiStatus }
    Write-Output ('PERF {0} | RAM {1} [{2}] | BatLLM RSS {3}, CPU {4:N1}% | Ollama RSS {5:N1} MB ({6} processes), CPU {7:N1}% | GUI {8} | API {9} ({10}ms) | elapsed {11:N1}s' -f
        $now.ToLocalTime().ToString('HH:mm:ss'), $ramDisplay, $ramAlertLevel,
        $gameDisplay, $gameCpu, $ollamaRss, $ollamaCount, $ollamaCpu,
        $guiDisplay, $apiState, $(if ($null -ne $apiLatencyMs) { $apiLatencyMs } else { 'N/A' }), $elapsed)
}

Write-Output ('DIAG: run={0}; scenario={1}; level={2}; interval={3}s' -f $runId, $Scenario, $DiagnosticLevel, $IntervalSeconds)
Write-Output ('DIAG ALERT PROFILE: {0}; WARNING <= {1}% RAM; CRITICAL <= {2}% RAM; warning requires 2 polls; recover with +2pp hysteresis; legacy guard {3} MB' -f
    $AlertProfile, $warningPct, $criticalPct, $LowRamThresholdMB)
Write-Output ('DIAG: metrics={0}; events={1}; summary={2}' -f $csvPath, $eventsPath, $summaryPath)
Write-Output 'DIAG: RSS sums are not unique physical memory; Ollama may be shared with other tools.'
Write-Output 'DIAG: Healthy CPU/RAM/API does NOT demonstrate gameplay turn, saved JSON or analyzer correctness.'
if ($CaptureAppOutput) {
    Write-Output 'DIAG: stdout/stderr capture enabled; logs may contain prompts or paths. Do not publish them without review.'
}

$game = $null
$exitCode = $null
$launchError = $null
Push-Location $repo
try {
    # Start the same entry point as Apply, with a pollable process wrapper.
    $startArgs = @{
        FilePath = $python
        ArgumentList = ('"{0}"' -f $entry)
        NoNewWindow = $true
        PassThru = $true
    }
    if ($CaptureAppOutput) {
        $startArgs['RedirectStandardOutput'] = $stdoutPath
        $startArgs['RedirectStandardError'] = $stderrPath
    }
    $game = Start-Process @startArgs
    Add-DiagnosticEvent 'LAUNCH' ('BatLLM launcher PID=' + $game.Id)
    do {
        try { Add-RuntimeSample -RootProcessId $game.Id }
        catch {
            $script:sampleErrors++
            Add-DiagnosticEvent 'SAMPLE_WARNING' ('Sampling exception: ' + $_.Exception.Message) 'WARN'
        }
    } while (-not $game.WaitForExit($IntervalSeconds * 1000))
    $game.WaitForExit()
    $exitCode = [int]$game.ExitCode
}
catch {
    $launchError = $_.Exception.Message
    Add-DiagnosticEvent 'LAUNCH_ERROR' 'Launch or monitoring stopped unexpectedly; consult the invoking PowerShell output.' 'CRITICAL'
}
finally {
    Pop-Location
    $watch.Stop()
    if ($null -ne $exitCode) {
        $stamp = [DateTime]::UtcNow.ToString('o')
        $line = Csv-Row @($stamp, [Math]::Round($watch.Elapsed.TotalSeconds, 2),
            'Exit', 'BatLLM', $(if ($null -ne $game) { $game.Id } else { '' }),
            '', '', '', '', '', $exitCode, $runId, $Scenario, '', '', $apiState, '',
            '', '', $ramAlertLevel, $apiLatencyMs)
        [IO.File]::AppendAllText($csvPath, ($line + [Environment]::NewLine), $utf8)
        Add-DiagnosticEvent 'PROCESS_EXIT' ('BatLLM launcher exit code=' + $exitCode) $(if ($exitCode -eq 0) { 'INFO' } else { 'CRITICAL' })
    }
    $result = if ($null -ne $launchError) { 'MONITOR_ERROR' }
        elseif ($null -eq $exitCode) { 'UNKNOWN_EXIT' }
        elseif ($exitCode -eq 0) { 'PROCESS_EXIT_0' }
        else { 'PROCESS_EXIT_NONZERO' }
    $summary = [ordered]@{
        run_id = $runId
        scenario = $Scenario
        diagnostic_level = $DiagnosticLevel
        interval_seconds = $IntervalSeconds
        profile = $AlertProfile
        warning_ram_percent = $warningPct
        critical_ram_percent = $criticalPct
        legacy_low_ram_mb = $LowRamThresholdMB
        elapsed_seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 2)
        samples = $sampleCount
        root_pid = $(if ($null -ne $game) { $game.Id } else { $null })
        process_exit_code = $exitCode
        result = $result
        minimum_available_ram_mb = $minFreeMb
        minimum_available_ram_percent = $minAvailablePct
        last_ram_alert_level = $ramAlertLevel
        maximum_alert_severity = $maxSeverity
        alert_events_by_severity = $severityCounts
        sampled_ram_warning_seconds = [Math]::Round($secondsInRamWarning, 1)
        sampled_ram_critical_seconds = [Math]::Round($secondsInRamCritical, 1)
        sampled_gui_unresponsive_seconds = [Math]::Round($secondsGuiUnresponsive, 1)
        sampled_ollama_api_unready_seconds = [Math]::Round($secondsApiUnready, 1)
        time_to_first_gui_responsive_seconds = $firstGuiReadySeconds
        time_to_first_child_process_seconds = $firstGameChildSeconds
        maximum_ollama_api_probe_latency_ms = $maxApiLatencyMs
        peak_batllm_rss_sum_mb = $maxGameRssMb
        peak_ollama_rss_sum_mb = $maxOllamaRssMb
        peak_batllm_cpu_pct_total = $maxGameCpuPct
        peak_ollama_cpu_pct_total = $maxOllamaCpuPct
        sample_errors = $sampleErrors
        event_counts = $eventCounts
        metrics_csv = [IO.Path]::GetFileName($csvPath)
        events_csv = [IO.Path]::GetFileName($eventsPath)
        gameplay_validated = $false
        session_validated = $false
        analyzer_validated = $false
    }
    $json = $summary | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($summaryPath, $json, $utf8)
    Write-Output ('DIAG RESULT: {0}; samples={1}; min RAM available={2} MB ({3}%); peak BatLLM RSS={4} MB; max alert={5}; time={6:N1}s' -f
        $result, $sampleCount, $minFreeMb, $minAvailablePct, $maxGameRssMb, $maxSeverity,
        $watch.Elapsed.TotalSeconds)
    Write-Output ('DIAG FILES: {0} | {1} | {2}' -f $csvPath, $eventsPath, $summaryPath)
}
if ($null -ne $launchError) { throw $launchError }
if ($null -ne $exitCode -and $exitCode -ne 0) {
    [Console]::Error.WriteLine(('Run BatLLM failed (exit code {0}); diagnostics: {1}' -f $exitCode, $summaryPath))
    exit $exitCode
}
