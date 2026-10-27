#requires -Version 5.1
<#
Offline tests: parse launch script; extract only pure alert functions and
its in-memory state machine. Does not run Apply, Ollama, Python or GUI.
Execute from any directory with PowerShell 5.1.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptFile = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\batllm-launch.ps1'))
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$parseErrors)
if ($null -ne $parseErrors -and @($parseErrors).Count -ne 0) {
    foreach ($e in $parseErrors) { Write-Error $e.ToString() }
    throw 'PowerShell parse failed.'
}
$names = @('Get-RamAlertThresholds', 'Get-RamAlertLevel', 'Update-RamAlert')
foreach ($name in $names) {
    $matched = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $n.Name
    }, $true) | Where-Object { $_.Name -eq $name })
    if ($matched.Count -ne 1) { throw ('Cannot locate precisely one ' + $name) }
    . ([scriptblock]::Create($matched[0].Extent.Text))
}
$passed = 0
function Assert-Equal {
    param($Actual, $Expected, [string]$Reason)
    if ([string]$Actual -cne [string]$Expected) {
        throw ('FAIL {0}: expected {1}, got {2}' -f $Reason, $Expected, $Actual)
    }
    $script:passed++
}
foreach ($case in @(
    @{ profile='Balanced'; warning=10; critical=5 },
    @{ profile='Sensitive'; warning=15; critical=8 },
    @{ profile='Relaxed'; warning=8; critical=3 },
    @{ profile='Custom'; warning=12; critical=6 }
)) {
    $t = Get-RamAlertThresholds -Name $case.profile -CustomWarning 12 -CustomCritical 6
    Assert-Equal $t.warning $case.warning ('warning profile ' + $case.profile)
    Assert-Equal $t.critical $case.critical ('critical profile ' + $case.profile)
}
foreach ($case in @(
    @{ pct=11; mb=850; want='OK' },
    @{ pct=10; mb=820; want='WARN' },
    @{ pct=6; mb=492; want='WARN' },
    @{ pct=5; mb=410; want='CRITICAL' },
    @{ pct=2; mb=164; want='CRITICAL' }
)) {
    $level = Get-RamAlertLevel -AvailablePercent $case.pct -AvailableMb $case.mb `
        -WarnPercent 10 -CritPercent 5
    Assert-Equal $level $case.want ('available percent ' + $case.pct)
}
Assert-Equal (Get-RamAlertLevel -AvailablePercent 15 -AvailableMb 700 `
        -WarnPercent 10 -CritPercent 5 -LegacyWarnMb 768) 'WARN' 'legacy MB guard'

$script:events = New-Object 'System.Collections.Generic.List[string]'
function Add-DiagnosticEvent {
    param([string]$Code, [string]$Detail,
        [ValidateSet('INFO', 'WARN', 'CRITICAL')][string]$Severity='INFO')
    [void]$script:events.Add(($Severity + ':' + $Code))
}
$script:warningPct=10
$script:criticalPct=5
$script:LowRamThresholdMB=0
$script:pendingWarnSamples=0
$script:ramAlertLevel='UNKNOWN'
Update-RamAlert -Percent 12.5 -FreeMb 1024
Assert-Equal $ramAlertLevel 'OK' 'normal sample'
Update-RamAlert -Percent 9.5 -FreeMb 778
Assert-Equal $ramAlertLevel 'OK' 'warning debounce sample one'
Update-RamAlert -Percent 9.2 -FreeMb 752
Assert-Equal $ramAlertLevel 'WARN' 'warning debounce sample two'
Update-RamAlert -Percent 4.8 -FreeMb 393
Assert-Equal $ramAlertLevel 'CRITICAL' 'critical immediate escalation'
Update-RamAlert -Percent 6.0 -FreeMb 492
Assert-Equal $ramAlertLevel 'CRITICAL' 'critical hysteresis'
Update-RamAlert -Percent 7.4 -FreeMb 606
Assert-Equal $ramAlertLevel 'WARN' 'critical to warning downgrade'
Update-RamAlert -Percent 11.1 -FreeMb 909
Assert-Equal $ramAlertLevel 'WARN' 'warning hysteresis'
Update-RamAlert -Percent 12.3 -FreeMb 1007
Assert-Equal $ramAlertLevel 'OK' 'alert recovery'
Assert-Equal (($events -join '|')) 'WARN:RAM_WARNING|CRITICAL:RAM_CRITICAL|WARN:RAM_WARNING|INFO:RAM_RECOVERED' 'transition events without flooding'
Write-Output ('PASS: {0} alert profile, threshold and transition assertions; script parses.' -f $passed)
