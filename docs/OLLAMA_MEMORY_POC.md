# Ollama memory/context proof of concept

## Purpose

This experiment isolates one question:

> Does the model recover information from a previous request only when the client sends the previous conversation messages again?

It is an **Ollama API-level context-forwarding experiment**. It does not test BatLLM's `OllamaConnector`, `modelito` integration, or the graphical application. Those require a separate product-integration experiment.

## Separation from Windows Doctor

Windows Doctor remains a read-only environment diagnostic. It may check the local Ollama API and whether a requested model is installed, but it must not run inference.

Run the existing preflight:

```powershell
.\scripts\windows\batllm-doctor.ps1 -Target Gameplay -Model smollm2:360m -Json
```

Inspect `gameplay.state` and the individual checks. `READY` means the inspected prerequisites were found; it does not mean the POC or a real game has been executed.

The POC is a separate, explicit model-inference operation.

## Experimental design

Each trial creates a fresh random identifier for each condition. The order alternates between trials to reduce the effect of model warm-up.

### Condition A — without history

1. Send a first user message containing the identifier.
2. Send a second request containing **only** the second question.
3. Check whether the identifier appears in the second response.

### Condition B — with history

1. Send a first user message containing a different identifier.
2. Capture the assistant response.
3. Send a second request containing the first user message, the assistant response, and the second question.
4. Check whether the identifier appears in the second response.

The model, temperature, seed, and output-token limit remain constant. The variable is whether previous messages are included in the second request.

The tool records the exact message arrays sent to each request. It does not assume that an Ollama server maintains a conversation between independent `/api/chat` calls.

## Requirements

- Python 3.10–3.12.
- A reachable local Ollama service.
- The selected model already installed.
- The `ollama` Python client installed in the interpreter used to run the script.

The script does not install packages, start or stop Ollama, download models, alter BatLLM configuration, or access saved game sessions.

## Run

From the repository root in Windows PowerShell:

```powershell
.\scripts\windows\batllm-doctor.ps1 -Target Gameplay -Model smollm2:360m -Json

.\.venv_BatLLM\Scripts\python.exe .\scripts\research\ollama_memory_poc.py `
    --model smollm2:360m `
    --trials 3
```

To save the report outside the repository:

```powershell
.\.venv_BatLLM\Scripts\python.exe .\scripts\research\ollama_memory_poc.py `
    --model smollm2:360m `
    --trials 3 `
    --output "$env:TEMP\batllm-ollama-memory-poc.json"
```

The output path is only written when `--output` is supplied. Existing files are not overwritten unless `--force` is explicitly supplied.

Each trial makes four model requests: two for condition A and two for condition B. Three trials therefore make twelve requests. Reduce `--trials` for a shorter exploratory run.

## Report interpretation

The report records:

- exact request messages and model responses;
- model and Python client versions;
- model options and trial order;
- wall-clock latency for each request;
- Ollama response metrics when provided (`load_duration`, prompt/evaluation token counts and durations);
- whether the identifier appeared in the response; and
- whether the response consisted of the identifier alone.

The recall check and exact-format check are deliberately separate. A response such as `Recibido BATLLM-...` contains the identifier but does not satisfy an instruction to output only the identifier. A condition status of `PASS` means both requests completed; it does not mean the hypothesis passed. Read the separate `summary.conclusion` and per-condition analysis.

`SUPPORTED_ALL_VALID_PAIRS` means every completed pair in that run showed no identifier in A and the identifier in B. It is evidence for this model/configuration and this experiment, not a universal statement about all models or persistent memory.

## Initial exploratory observation — 2 November 2026

One exploratory pair was executed before this repeatable script was prepared, using `smollm2:360m`, `ollama` Python client `0.6.3`, temperature `0`, and seed `42`.

Identifier: `BATLLM-698183539130`.

| Request | Observed response | Identifier present? | Time |
| --- | --- | ---: | ---: |
| A1 — first message | `Recibido BATLLM-698183539130.` | Yes | 8.308 s |
| A2 — second request without history | The model echoed the question, without the identifier | No | 1.899 s |
| B1 — first message | `Recibido BATLLM-698183539130.` | Yes | 1.024 s |
| B2 — second request with history | `Recibido BATLLM-698183539130.` | Yes | 1.566 s |

The observation is consistent with the hypothesis: the identifier was recovered when the previous messages were included and was not recovered when they were omitted.

Neither second response complied with the requested exact output format. The B2 response contained the correct identifier but added text.

This was one exploratory pair, not a repeated validation. The original run used the same identifier for both conditions and always ran A before B. The maintained script uses independent identifiers and alternates condition order.

## Unit tests

The unit tests use a fake client and do not contact Ollama:

```powershell
.\.venv_BatLLM\Scripts\python.exe -m unittest discover `
    -s scripts\research `
    -p "test_*.py" `
    -v
```

## Limits and next experiment

This experiment demonstrates the effect of including messages in a request. It does not demonstrate that BatLLM's application connector constructs or retains the intended history.

After repeated API-level trials, inspect and test `src/game/ollama_connector.py` separately. That product-integration test should capture the actual messages built by BatLLM for independent-context and shared-context modes, without conflating them with the API-level POC.
