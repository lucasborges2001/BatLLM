# Windows Doctor (read-only diagnostics)

Windows Doctor checks whether a source checkout meets the prerequisites for
non-live validation or model-backed Gameplay. It never installs dependencies,
starts or stops Ollama, downloads models, launches BatLLM, or writes a report.

`NonLive` does **not** contact Ollama. `Gameplay` performs only local HTTP
**GET** requests to `http://127.0.0.1:11434/api/version` and `/api/tags`
with short timeouts. These are diagnostic requests, not gameplay or model calls.

## Commands

Run in Windows PowerShell 5.1 or PowerShell 7, from the repository root:

```powershell
.\scripts\windows\batllm-doctor.ps1 -Target NonLive
.\scripts\windows\batllm-doctor.ps1 -Target Gameplay
.\scripts\windows\batllm-doctor.ps1 -Target Gameplay -Model smollm2 -Json

# Existing CMD launcher: it does not select a model.
.\scripts\windows\batllm.cmd doctor Gameplay
```

`-Model` selects a **target to inspect**, not a change to the installed models
or active application configuration. Without `-Model`, the tool can report
installed models but cannot claim that a model has been selected. The script
accepts `-RepoRoot` for another checkout; by default it uses its own checkout.

JSON output is schema `1` with existing check objects and summary fields. For
Gameplay, it adds `gameplay.state`, `gameplay.requested_model` and
`gameplay.detected_api_version`. No file is written. The report contains a
repository path and commit SHA: review it before sharing.

## Results and limits

Existing check statuses retain their meaning:

- `PASS`: that particular check succeeded.
- `WARN`: optional prerequisite or configuration risk.
- `FAIL`: prerequisite not met or a required check failed.
- `NOT_CHECKED`: verification was not possible or applicable.

Gameplay states are:

| State | Meaning |
| --- | --- |
| `NOT_DETECTED` | Neither a CLI in the checked locations nor a valid local API response was found; this is **not proof** that Ollama is absent everywhere. |
| `NOT_RUNNING` | An Ollama CLI was found, but no valid local API version response was obtained; the service may be stopped or unreachable. |
| `CLI_NOT_DETECTED` | The API answered, but no CLI was found in the checked locations. Do not classify this as not installed. |
| `MODEL_INVENTORY_UNAVAILABLE` | API version responded, but `/api/tags` did not provide a valid model list. |
| `NO_MODEL` | The list is empty or the explicitly requested model is absent. |
| `MODEL_NOT_SELECTED` | The API listed models but no `-Model` target was supplied. |
| `ENVIRONMENT_INCOMPLETE` | The CLI, API and requested model were found, but repository, Python, dependencies or `BATLLM_HOME` prerequisites failed. |
| `READY` | Static checks, local API and the requested model met the inspected prerequisites. **A real game has not been tested.** |

An untagged target such as `smollm2` matches an exact local name or
`smollm2:latest`, not arbitrary other tags. A tagged name requires an exact
match. An API responding on loopback is not evidence that all model requests
or graphical application features work.

The process continues to return exit code 0 after producing a valid diagnostic
report, even if checks are `FAIL`. This preserves version 1 behaviour: callers
must inspect the JSON state and individual check results, not treat exit 0
as Gameplay readiness.

`BATLLM_HOME` should be set to a directory outside the checkout before
launching a game, because running from source without it can write to tracked
configuration. Doctor does not set or create that directory.

## Tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\tests\test-batllm-doctor.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\tests\test-batllm-doctor-gameplay.ps1
.\.venv_BatLLM\Scripts\python.exe tools\check_docs.py
git diff --check
git status --short --branch
```

The new Gameplay test shadows the local API client and prevents real HTTP
requests. It simulates missing CLI, an unreachable service, empty or broken
model inventories, selected and missing models, and a responsive API with no
CLI. Neither test runs a game or starts Ollama. Real local Gameplay readiness
remains a separate manual observation, and `run_tests.py core` and `non-live`
remain separate product suites.
