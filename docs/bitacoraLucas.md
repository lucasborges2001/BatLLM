# BatLLM — Lucas's work log

Workshop record: time reported, verified work, results, and next actions. Hours are not estimates unless explicitly labelled.

## 18–24 October 2026 — 11 h previously reported

- **Sun 18 (3 h):** Prepared for the workshop and explored the project; detailed tasks not recorded.
- **Mon 19 (time not recorded):** Reviewed the repository remotely: documentation, architecture, Ollama, game history and tests. No gameplay execution confirmed. This activity is **not counted again** in the 11 h total.
- **Tue 20 (1 h):** Attended the first workshop meeting; discussed the game, architecture, experiments and contributions.
- **Wed 21 (3 h), Thu 22 (2 h), Fri 23 (1 h), Sat 24 (1 h):** Workshop time previously reported; the specific tasks for these dates still need supporting detail.

**Time reconciliation:** the previous draft of this log listed only 5 h for 18–24 October. The earlier reported weekly total was **11 h** (3 + 1 + 3 + 2 + 1 + 1). Monday's repository review has no separately verified duration; no extra hour is added.

## Mon 26 October 2026 — approximately 4 h reported

**Goal:** Prepare and launch BatLLM on Windows, with reproducible diagnostics and an isolated state directory.

**Work completed**

- Prepared the local checkout on Windows with Python 3.12.6 and `.venv_BatLLM`; introduced read-only **Windows Doctor**, opt-in **Windows Apply**, a `.cmd` launcher, and documentation/checker updates.
- Extended Doctor to distinguish CLI, local Ollama API, installed model and readiness. Added offline/mock tests. Added separate interactive `YES` confirmations before optional Ollama installation, service start and model download.
- Installed **Ollama 0.40.11** using WinGet; verified the CLI and the local API at `127.0.0.1:11434`.
- Downloaded **`smollm2:360m`** (725 MB listed locally) and verified inference with `ollama run smollm2:360m "Reply with exactly OK."` (response: `"OK."`).
- Set `BATLLM_HOME` outside the checkout: `%APPDATA%\BatLLM\Workshop`. Doctor reported **Gameplay `READY`**, with 10 PASS, 1 worktree WARN, and 0 FAIL.
- Found a Windows PowerShell 5.1 argument-splatting bug in `Invoke-DoctorReport` inside Apply; changed the local function to use a named-argument hashtable. The corrected Apply reached **Gameplay `READY`** and created/then reused an isolated `config.yaml` overlay for `smollm2:360m`.
- **Launched the BatLLM 0.3.6 graphical interface** using Apply `-Launch`. The screenshot shows the initial board at **Game 1 / Round 0 / Turn 0**. Closed the application; no gameplay turn, saved session or Game Analyzer run was confirmed.

**Validation evidence**

- Launcher smoke tests: **13 PASS**; original Doctor smoke tests: **14 PASS**; mocked Gameplay Doctor tests: **13 PASS**.
- Apply plan smoke tests: **8 PASS**; Apply confirmation guard tests: **20 PASS**; documentation validation: **PASS**.
- Full non-live Python test collection (`pytest -q src/tests`): **193 PASS, 1 FAIL, 2 SKIP**. The failure is the previously documented baseline mismatch: `test_shipped_llm_config_uses_smollm2_first_install_defaults` expects `smollm2`, but the shipped config selects another model (upstream issue [#59](https://github.com/krahd/BatLLM/issues/59)). `run_tests.py core` and `non-live` remain blocked by that same initial failure; no claim that either runner passed.
- Kivy/KivyMD emitted deprecation and class re-declaration warnings during launch; these did not prevent the GUI from appearing. No inference through the game UI was verified.

**Published commits on `docs/bitacora-batllm-2026` (fork only; as of this entry)**

- `6b5f982` — read-only Windows Doctor.
- `22f148e` — opt-in Windows Apply.
- `0203c7b` — documentation checker virtualenv exclusion.
- `0246af5` — Windows Doctor/Apply documentation.
- `c162809` — safe Windows `.cmd` launcher and smoke tests.
- `542c2d9` — Gameplay readiness diagnostics and mocked tests.
- `dab2be0` — interactive confirmation guards for external Ollama actions.

**Not yet published at the time of writing:** the local named-parameter splatting correction in Apply and this updated work log. No pull request or upstream change was confirmed.

## Next actions

1. Add and run a regression test for named splatting in `Invoke-DoctorReport`; commit and push that fix separately from this work log.
2. Commit this work log to the same fork branch; confirm the remote SHA and leave upstream untouched.
3. Run a short **actual game turn** with `smollm2:360m`, verify model behaviour and record any warnings/errors.
4. Save a session in the isolated user-state directory; open it with Game Analyzer and record results.
5. Resume the workshop experiments: compare prompting with/without history, review architecture/traces, and read *From Prompt to State*.
6. **Tue 27 October:** next meeting planned, **not yet attended** as of the end of 26 October.

**Recorded time through 26 October:** 11 h previously reported (18–24 October) + approximately 4 h (26 October) = **approximately 15 h**, excluding any unquantified additional time. Do not turn these approximations into exact time entries.

---

## Tue 27 October 2026 — workshop experiments, Windows diagnostics and publication

**Scope:** Exercise BatLLM with local Ollama, investigate a GUI hang, develop an external monitor with alert profiles, and publish only the resulting diagnostic scripts to the fork.

**Reconciliation with 26 October:** The 26 October entry above already documents the verified setup, tests and initial GUI launch. No extra activity or hours have been added retrospectively. Its “Next actions” and publication notes are a dated snapshot, superseded where applicable by this entry.

**Gameplay and investigation**

- Used the isolated `BATLLM_HOME` at `%APPDATA%\BatLLM\Workshop`, Windows PowerShell 5.1, Python 3.12.6, Ollama 0.40.11 and `smollm2:360m`. Gameplay preflight continued to report **READY**.
- Submitted `Respond with exactly M and nothing else.` for both players. The board advanced and showed `M` commands for both players; a later screenshot showed **Game 1 / Round 1 / Turn 1**. This is visual evidence of gameplay progress, not a complete automated gameplay validation.
- A separate run with mixed-language prompts (`hola, move a x 5` and `hola, move en y 3`) left the game at **Game 1 / Round 1 / Turn 0**; Windows displayed **Not responding**, and the application had to be closed forcibly. The root cause was **not established**. Those phrases are not valid BatLLM command strings, but that alone does not explain the GUI hang.
- Queried Windows Application events `1000`, `1001` and `1002` between 18:37 and 19:30, first with application text filtering and then without it. Neither query returned a matching event; this does **not** rule out the observed hang.
- Traced the Python launcher/child relationship. In one measurement, the launcher (PID `7668`) used about **4.1 MB RSS**, while the GUI child (PID `13356`) used about **221.4 MB RSS**. The first monitoring prototype was tracking mainly the launcher and therefore understated BatLLM's memory use.

**Diagnostic work (v1–v3)**

- Introduced an opt-in PowerShell launcher at `scripts/windows/batllm-launch.ps1`. It samples BatLLM's observed process tree, labelled Ollama processes, process-level CPU/RSS/threads and available physical memory. Reports are written outside the checkout to `%APPDATA%\BatLLM\Workshop\diagnostics`.
- Added `Basic` and `Extended` diagnostics, scenario labels (`Startup`, `Idle`, `Gameplay`, `SaveAnalyzer`, `HangRepro`), GUI responsiveness probes, local Ollama `/api/version` probes and run-specific metrics CSV, event CSV and summary JSON. These signals do not verify the semantic correctness of a model response, saved session or replay.
- Added configurable RAM alert profiles: **Sensitive** (warning at ≤15%, critical at ≤8%), **Balanced** (≤10%, ≤5%) and **Relaxed** (≤8%, ≤3%), plus **Custom**. Warnings require two consecutive observations, critical alerts are immediate, and recovery uses 2 percentage points of hysteresis. Alerts record transitions without stopping BatLLM or Ollama.
- Added sampled timing information: run elapsed time, approximate duration of alert states, time until a responsive GUI was first observed, child-process discovery and local API probe latency. **API probe latency is not model inference latency**, and the times between samples are approximate.
- In an `Extended` **Gameplay** run starting at **19:29:39**, the monitor collected **8 samples** over **28.4 seconds**. First responsive GUI: **3.6 s**; minimum RAM available: **1,660.6 MB (20.6%)**; peak BatLLM RSS sum: **228.0 MB**; observed BatLLM CPU around **10.9–12.5%**; Ollama API probe latency **5.4–5.8 ms**. All observed GUI samples were responsive and API probes ready; highest alert severity **INFO**; launcher exit code **0**. No pressure threshold was crossed in that short run.
- An earlier `HangRepro` run starting at **19:06:42** showed responsive GUI and ready API across the available console samples, with fluctuating available RAM and two to three processes detected. It did **not** reproduce the prior unresponsive-window condition in the supplied evidence.

**Validation and publication**

- PowerShell 5.1 syntax parsing: **PASS** for both `batllm-launch.ps1` and `scripts/windows/tests/test-batllm-launch-alerts.ps1`.
- Offline regression test: **23 PASS** assertions covering profile thresholds, severity classification, alert transitions, debounce and recovery. A normal monitored run passed, but deliberately simulated warning/critical transitions were not exercised in live Windows memory conditions; the offline test covers that logic.
- Reviewed and staged only the two new scripts (**703 inserted lines**). Committed as `5699993d8ba1a326d3bcdbd5833f2d5bf59d0862` — `feat(windows): add runtime diagnostics and alert profiles` — and successfully pushed to **`origin/docs/bitacora-batllm-2026`** on the `lucasborges2001/BatLLM` fork. Local HEAD, remote HEAD and `git ls-remote` matched; the reported worktree was clean. No upstream push, PR or merge was performed.
- Confirmed that the earlier named-parameter fix in `Invoke-DoctorReport` is present in the current published `batllm-apply.ps1`. The earlier log's “not yet published” statement describes its state at the time; this entry does not assign an unverified date or separate commit to the correction.

**Limitations and evidence still required**

- Session saving was attempted / discussed, but there is **no confirmed saved JSON file** in the shared evidence, and **Game Analyzer replay was not verified**.
- The GUI hang remains unresolved; neither the mixed-language prompt nor memory pressure has been established as its cause.
- Need per-request model inference and full-turn timings, correlated with GUI/process measurements; local Ollama API health latency alone is insufficient.
- The Python suite's previously recorded **193 PASS, 1 baseline FAIL, 2 SKIP** remains a separate known result; it was not rerun or claimed fixed on 27 October.
- Attendance at the planned 27 October workshop meeting was **not verified** from the available record.

**Updated next actions:** Confirm a saved session exists in the isolated state folder and opens/replays in Game Analyzer; reproduce and instrument the GUI hang without stressing system RAM deliberately; measure model request/response and turn durations; compare prompts with and without history; retain baseline failure #59 as an open upstream issue unless independently resolved.

**Time accounting:** **approximately 15 hours reported through 26 October** (11 h for 18–24 October and approximately 4 h on 26 October). Work performed on 27 October is recorded **without a reported hour total**. No estimated hours were added.

**Repository status at this close:** fork branch `docs/bitacora-batllm-2026`, published HEAD `5699993d8ba1a326d3bcdbd5833f2d5bf59d0862`. This work-log update is supplied separately; **it has not been committed or pushed**.
