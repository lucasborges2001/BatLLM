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
