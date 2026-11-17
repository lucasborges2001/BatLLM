# OllamaConnector Doctor

## Purpose

The existing Windows Doctor checks general source and Gameplay prerequisites. The Connector Doctor adds a focused, read-only preflight for the Ollama endpoint and the model name passed to the live Connector runner. It also summarises historical **connector-live-*.json** and JUnit evidence.

It does not execute inference, launch or stop Ollama, download or delete models, change application configuration, or modify product files. Its only writes are JSON and TXT diagnostic reports under the ignored **tmp/** directory (or an explicitly supplied output directory).

## Commands

From the repository root in Windows PowerShell 5.1 or PowerShell 7:

~~~powershell
# Inspect the local API and historical Connector reports.
.\scripts\windows\batllm-connector-doctor.ps1 -Model "smollm2:360m"

# Reproduce the historical model-name mismatch without running inference.
.\scripts\windows\batllm-connector-doctor.ps1 -Model "smollm2" -Json

# Point at another local Ollama host/port. Url is an origin; pass the port separately.
.\scripts\windows\batllm-connector-doctor.ps1 -Model "model:tag" -Url "http://127.0.0.1" -Port 11434

# Run deterministic mocked checks; no Ollama service is contacted.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\tests\test-batllm-connector-doctor.ps1
~~~

**-Model** is an inspection target only. An untagged name matches the exact local name or **:latest**; it does not match an arbitrary tag. If **smollm2** is requested while **smollm2:360m** is installed, the report returns **MODEL_NOT_INSTALLED** and lists **smollm2:360m** as a related candidate. The operator must select that exact name explicitly before running the live test.

The API probes are timed GET requests to **/api/version** and **/api/tags**. The script reuses **batllm-doctor.ps1 -Target NonLive** for repository, Python and dependency checks; it does not invoke the existing Gameplay Doctor, avoiding a second fixed-endpoint probe.

## Report contents

Each run writes under **tmp/YYYY-MM-DD/HH/ConnectorDoctor** by default. A custom output path inside the checkout is accepted only under **tmp/**; an external directory is also allowed. Reports include the repository path, endpoint and installed model names, so review them before sharing.

Each run writes:

- **connector-doctor-<timestamp>.json**: structured repository identity, static checks, endpoint state, API version, installed models, exact model match, historical run classifications and timings.
- **connector-doctor-<timestamp>.txt**: concise human-readable summary.

Historical durations are read from JUnit **testcase time** attributes. They measure pytest test execution, not the complete setup or process lifetime. **diagnostic_elapsed_ms** covers the checks and evidence scan, excluding the final report-file writes. The report records the tested SHA from each historical JSON file; it does not infer that a historical result validates the current HEAD.

**READY_FOR_LIVE_TEST** means only that the endpoint and requested model were detected. It is not a product PASS. The live Connector runner remains responsible for the two real messages and history assertions.

## Confirmed historical diagnosis — 10 November 2026

The two live attempts used SHA **ad06d424ce3175f807d3fceba81819c7c6e0be98** and both failed before inference:

| Attempt | Requested model | Ollama inventory | JUnit duration | Diagnosis |
| --- | --- | --- | ---: | --- |
| 1 | **smollm2** | **smollm2:360m** | 5.10 s | Model name did not match the installed tag |
| 2 | **modelo:tag** | **smollm2:360m** | 5.41 s | Literal placeholder was not installed |

Both reports show one failed test, zero errors and zero skips. The model-inventory guard runs before **OllamaConnector** is instantiated, so neither attempt sent a gameplay request or executed inference. These are precondition failures, not evidence of an Ollama inference or Connector defect. The next live attempt must use the exact installed model name reported by the local API, then record its own SHA and JUnit/JSON/log evidence.

## Validation boundaries

- The mocked test covers endpoint success, malformed inventory, unreachable endpoint, exact model matching, the untagged/non-latest mismatch, historical failure classification and JUnit timing extraction.
- The mocked test does not contact Ollama and does not execute the Connector.
- The real endpoint preflight must be run on the Windows workstation.
- The live Connector smoke must be run separately after the preflight reports **READY_FOR_LIVE_TEST**.

After the preflight reports **READY_FOR_LIVE_TEST**, run the real Connector smoke with the same exact model name:

~~~powershell
.\scripts\windows\batllm-connector-live.ps1 -Model "smollm2:360m"
~~~
