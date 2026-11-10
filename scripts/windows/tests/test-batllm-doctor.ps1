#requires -Version 5.1
<# Basic smoke tests without Pester or service access. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$doctor = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\batllm-doctor.ps1'))
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$hostExe = (Get-Process -Id $PID).Path

function Assert-True {
    param([bool]$Condition, [string]$Description)
    if (-not $Condition) { throw ('FAIL: ' + $Description) }
    Write-Output ('PASS: ' + $Description)
}

function Invoke-Doctor {
    param([string]$Root, [string]$Target)
    $json = & $hostExe -NoProfile -NonInteractive -File $doctor -RepoRoot $Root -Target $Target -Json
    if ($LASTEXITCODE -ne 0) {
        throw ('Doctor failed to produce JSON for ' + $Target)
    }
    return (($json | Out-String) | ConvertFrom-Json)
}

function Check-Status {
    param($Report, [string]$Name)
    $check = @($Report.checks | Where-Object { $_.name -eq $Name })
    if ($check.Count -ne 1) { throw ('Expected one result for ' + $Name) }
    return [string]$check[0].status
}

function Invoke-PipCommand {
    param([string[]]$Arguments)

    # Windows PowerShell 5.1 can turn native stderr into a terminating
    # NativeCommandError when the caller uses ErrorActionPreference=Stop.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $projectPython @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($null -eq $exitCode) { $exitCode = 1 }
    $text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{
        exit_code = [int]$exitCode
        output = $text
    }
}

Assert-True (Test-Path -LiteralPath $doctor -PathType Leaf) 'Doctor script exists'
$before = ((& git --no-optional-locks -C $repo status --porcelain=v1) | Out-String).Trim()
$report = Invoke-Doctor $repo 'NonLive'
Assert-True ($report.schema_version -eq 1) 'Report schema version is 1'
Assert-True ($report.read_only -eq $true) 'Report declares read-only semantics'
Assert-True ($report.target -eq 'NonLive') 'NonLive target selected'

# BATLLM_HOME is optional: the application has a safe Windows platform default.
$previousBatllmHome = [Environment]::GetEnvironmentVariable('BATLLM_HOME', 'Process')
try {
    [Environment]::SetEnvironmentVariable('BATLLM_HOME', $null, 'Process')
    $defaultHomeReport = Invoke-Doctor $repo 'NonLive'
    Assert-True ((Check-Status $defaultHomeReport 'batllm_home') -eq 'PASS') 'Windows platform default BATLLM home is outside checkout'

    $insideHome = Join-Path $repo 'tmp\tests\doctor-home-inside-checkout'
    [Environment]::SetEnvironmentVariable('BATLLM_HOME', $insideHome, 'Process')
    $insideHomeReport = Invoke-Doctor $repo 'NonLive'
    Assert-True ((Check-Status $insideHomeReport 'batllm_home') -eq 'WARN') 'Explicit BATLLM_HOME inside checkout is warned'
}
finally {
    [Environment]::SetEnvironmentVariable('BATLLM_HOME', $previousBatllmHome, 'Process')
}
Assert-True ((Check-Status $report 'repository') -eq 'PASS') 'Valid repository recognised'
Assert-True (@('PASS', 'FAIL') -contains (Check-Status $report 'python')) 'Python version was assessed'
$projectPython = Join-Path $repo '.venv_BatLLM\Scripts\python.exe'
if (Test-Path -LiteralPath $projectPython -PathType Leaf) {
    $directVersion = (& $projectPython --version 2>&1 | Out-String).Trim()
    if ($directVersion -match '^Python 3\.(10|11|12)\.') {
        Assert-True ((Check-Status $report 'python') -eq 'PASS') 'Supported project Python must pass'
    }
}
$depCheck = @($report.checks | Where-Object { $_.name -eq 'dependencies' })[0]
Assert-True (-not ($depCheck.detail -match 'Unsupported requirement syntax|Unable to parse dependency inventory')) 'PEP 508/440 requirement syntax is accepted'
Assert-True (@('PASS', 'WARN', 'FAIL', 'NOT_CHECKED') -contains (Check-Status $report 'dependencies')) 'Dependencies check is reported'

# Exercise both sides of a comma-separated version range using the installed
# pip distribution. The dry-run cannot access an index or install packages.
if (Test-Path -LiteralPath $projectPython -PathType Leaf) {
    $pipVersionOutput = & $projectPython -B -c 'import pip; print(pip.__version__)'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the installed pip version.' }
    $pipVersionText = (($pipVersionOutput | Out-String).Trim())
    $pipVersion = [version]$pipVersionText
    $fixtureRoot = Join-Path $repo ('tmp\tests\doctor-dependencies-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    try {
        $validRequirements = Join-Path $fixtureRoot 'valid.txt'
        $invalidRequirements = Join-Path $fixtureRoot 'upper-bound.txt'
        $validRange = 'pip>=' + $pipVersionText + ',<' + ($pipVersion.Major + 1).ToString()
        [IO.File]::WriteAllText($validRequirements, $validRange + [Environment]::NewLine, ([System.Text.UTF8Encoding]::new($false)))
        [IO.File]::WriteAllText($invalidRequirements, 'pip<0.1' + [Environment]::NewLine, ([System.Text.UTF8Encoding]::new($false)))

        $pipArguments = @(
            '-B', '-m', 'pip', 'install',
            '--isolated', '--dry-run', '--no-index', '--no-deps',
            '--no-cache-dir', '--disable-pip-version-check'
        )
        $validArguments = $pipArguments + @('-r', $validRequirements)
        $validResult = Invoke-PipCommand $validArguments
        Assert-True ($validResult.exit_code -eq 0) 'Compound lower/upper range accepts installed pip'

        $invalidArguments = $pipArguments + @('-r', $invalidRequirements)
        $invalidResult = Invoke-PipCommand $invalidArguments
        Assert-True ($invalidResult.exit_code -ne 0) 'Upper version bound rejects an installed version above the limit'
        Assert-True ($invalidResult.output -match 'pip<0\.1') 'Unsatisfied version range reports the rejected pip constraint'
        Assert-True (-not ($invalidResult.output -match 'Invalid requirement|Invalid specifier|Expected matching')) 'Unsatisfied version range is distinguished from invalid syntax'
    }
    finally {
        if (Test-Path -LiteralPath $fixtureRoot) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
    }
}
$gameplay = Invoke-Doctor $repo 'Gameplay'
if ((Check-Status $report 'ollama_cli') -eq 'WARN') {
    Assert-True ((Check-Status $gameplay 'ollama_cli') -eq 'FAIL') 'Gameplay requires an Ollama executable'
}
else {
    Assert-True ((Check-Status $gameplay 'ollama_cli') -eq 'PASS') 'Gameplay detects an existing Ollama executable'
}

# A path that does not exist must fail cleanly without creating it.
$missingRoot = Join-Path $repo ('tmp\tests\missing-checkout-' + [guid]::NewGuid().ToString('N'))
$missing = Invoke-Doctor $missingRoot 'Gameplay'
Assert-True ((Check-Status $missing 'repository') -eq 'FAIL') 'Missing repository is diagnosed'
Assert-True (-not (Test-Path -LiteralPath $missingRoot)) 'Doctor did not create a repository directory'
Assert-True ($missing.target -eq 'Gameplay') 'Gameplay target selected'
$after = ((& git --no-optional-locks -C $repo status --porcelain=v1) | Out-String).Trim()
Assert-True ($before -ceq $after) 'Doctor did not change Git worktree contents'
Write-Output 'Doctor smoke tests completed. No application or Ollama tests were executed.'
