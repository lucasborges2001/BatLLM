# Windows Doctor (read-only, initial version)

This developer tool checks whether a Windows source checkout appears ready for
non-live validation or model-backed gameplay. It deliberately does **not**
install packages or Ollama, start or stop services, contact the Ollama API,
launch BatLLM, run product tests, or create report files.

Run from the repository root in Windows PowerShell 5.1 or PowerShell 7:

```powershell
.\scripts\windows\batllm-doctor.ps1 -Target NonLive
.\scripts\windows\batllm-doctor.ps1 -Target Gameplay
.\scripts\windows\batllm-doctor.ps1 -Target NonLive -Json
```

The `-RepoRoot` option can target another checkout; the default is the checkout
containing the script. JSON output goes to standard output and has schema
version `1`. A JSON report includes the checkout path and commit SHA, so review
it before sharing. There is no implicit file output.

Checks include: Windows and PowerShell versions, Git root/branch/SHA and working
tree, a project virtual environment, supported Python, direct requirements
(including declared version constraints), the Ollama executable in common
Windows locations, and the effective `BATLLM_HOME` environment variable.

## Meaning of results

- `PASS`: the specific static check met its documented expectation.
- `WARN`: an optional dependency is unavailable or a configuration risk exists.
- `FAIL`: a prerequisite is missing, incompatible, or otherwise invalid.
- `NOT_CHECKED`: prerequisites for that diagnostic were unavailable.

A `PASS` for dependencies does not prove that transitive dependencies import
correctly or that the application works. Detecting the Ollama executable does
not prove that the service is running or that a model is available. The initial
tool does not inspect the service or saved sessions.

`NonLive` does not require Ollama; `Gameplay` treats a missing Ollama executable
as a failure. Both modes remain read-only. The tool reports findings rather
than repairing them. The first version always finishes normally when it can
print a report; inspect the reported statuses instead of relying on its
process exit code as a readiness signal.

## Safety and validation

`BATLLM_HOME` should be set outside the checkout before launching the game,
because a source checkout without it can write to tracked configuration.
The Doctor itself does not set this variable.

Run the dependency-free PowerShell smoke test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\tests\test-batllm-doctor.ps1
```

Then inspect the Git worktree and run the maintained documentation validator:

```powershell
git status --short --branch
.\.venv_BatLLM\Scripts\python.exe tools\check_docs.py
```

The smoke test exercises the report format, valid and missing repository
handling, and absence of directory creation for a missing checkout. It is not
a replacement for product tests. Test the command on Windows before claiming
Windows compatibility; remote inspection or syntax review is insufficient.

Future work may add explicit service/model checks and a separate, opt-in setup
command. Do not extend the Doctor with implicit downloads, service mutations,
or installers.
