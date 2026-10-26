# Windows Apply (opt-in setup)

`batllm-apply.ps1` is an explicit, repeatable setup workflow for a source checkout
of BatLLM on Windows. It **complements** the read-only
[`Windows Doctor`](WINDOWS_DOCTOR.md). The default is a **plan**, not an action.

## Modes

Use Windows PowerShell 5.1 or PowerShell 7 from the repository root.
If Windows blocks a reviewed unsigned script, run it in a new PowerShell
process with a **process-only** execution-policy override (do not change
your machine-wide policy):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\batllm-apply.ps1 -Mode NonLive
```


```powershell
# Show a read-only plan, suitable for a fresh clone.
.\scripts\windows\batllm-apply.ps1 -Mode NonLive

# Prepare a project-local Python environment for non-live tests (no Ollama).
.\scripts\windows\batllm-apply.ps1 -Mode NonLive -Apply

# Plan full gameplay setup, including explicit Ollama and model opt-ins.
.\scripts\windows\batllm-apply.ps1 -Mode Gameplay `
    -InstallOllama -StartOllama -PullModel -Model smollm2 -Launch

# Actually perform that full setup after reviewing the plan.
.\scripts\windows\batllm-apply.ps1 -Mode Gameplay -Apply `
    -InstallOllama -StartOllama -PullModel -Model smollm2 -Launch
```

`NonLive` creates `.venv_BatLLM` if missing, installs the project's pinned
`requirements.txt` if Doctor reports unmet direct requirements, runs `pip
check`, and runs Doctor again. With `-RunCoreTests`, it also runs the core
suite. It does not contact Ollama or launch the game. An existing compatible
virtual environment is reused.

`Gameplay` performs NonLive setup, then checks the Ollama binary, localhost
API on port 11434, and the requested model. `-InstallOllama` permits a
**separate Windows installation** through winget package `Ollama.Ollama` if
missing. `-StartOllama` permits starting a local service if stopped.
`-PullModel` permits downloading the named model if missing. `-Launch`
launches `run_batllm.py` only when all checks pass. No download, install,
service start, or launch occurs without its explicit option and `-Apply`.

`-RunCoreTests` is optional because the tracked baseline may fail its
configuration-default assertion; report the exact failure rather than
altering the tracked configuration to make the test pass. Never run
`run_tests.py full` through Apply.

## State and safety

Apply sets `BATLLM_HOME` for its own process and child processes only,
using `%APPDATA%\BatLLM\Workshop` by default or an explicit absolute
`-StateDir`. The state directory must be outside the Git checkout.
It creates a minimal `config.yaml` overlay for the selected model only when
no overlay exists. **Existing user configuration is never overwritten**; an
unexpected existing model produces a failure with an explanation. The
tracked `src/configs/config.yaml` remains unchanged.

A successful Python package inventory is not an application launch test.
A successful Ollama CLI detection is not a live-service or model test.
`-Mode Gameplay -Apply` only reaches READY after verifying the API and model.
The script never terminates an already-running Ollama service or removes
models. If Apply starts Ollama, it leaves the service running; manage it
separately through the usual Ollama controls.

Ollama installation and model download can require substantial network,
disk, and memory resources. Inspect the plan and verify the local Ollama
installation and selected model before permitting these operations. The
winget install can also have its own approval prompts.

## Validation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\windows\tests\test-batllm-apply.ps1
.\scripts\windows\batllm-doctor.ps1 -Target NonLive
.\scripts\windows\batllm-apply.ps1 -Mode NonLive
.\.venv_BatLLM\Scripts\python.exe tools\check_docs.py
git diff --check
git status --short --branch
```

The Apply smoke test checks *planning only* and verifies that it does not
change Git contents. Installation, service-start, downloads, and GUI launch
must be validated manually in an intentionally disposable or suitable
Windows environment. Do not claim those flows passed based on a plan test.

Apply is deliberately conservative: it does not edit Git-tracked files,
change user/system environment variables persistently, uninstall tools, or
attempt automatic rollback of a partially completed external installation.
If a step fails, review its output and rerun after fixing the root cause.
