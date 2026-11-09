# Contributing

Thank you for helping. This repository is maintained by one person, so the process is short and fixed.

## Issues first, pull requests by invitation

- **Open an issue** for a bug, an item that was exported wrong, or a question. Use the templates: they ask for the
  versions, the command line and the log lines.
- **Pull requests are by invitation only.** If the fix is agreed in the issue, the maintainer asks you for one; an
  uninvited pull request is closed with a pointer to the issue.
- **Security problems never go into an issue**: see [SECURITY.md](SECURITY.md).
- Never paste tokens, secrets, connection strings or exported files into an issue or a pull request, and replace
  workspace, folder and item names you don't want to share. Reproduce with fake values.

## How a change is made

- Keep it small and tied to a case the script got wrong.
- The script stays one file that runs in Windows PowerShell 5.1 and PowerShell 7, with nothing to install besides the
  Fabric CLI, and stays read-only against Fabric.
- Every change a user notices gets a line in `CHANGELOG.md` under `[Unreleased]`, and `README.md` is updated in the same
  pull request.

## Run the checks locally

The same checks as CI (`.github/workflows/validate.yml`), from the repository root. Run the parse check in both
Windows PowerShell 5.1 (`powershell`) and PowerShell 7 (`pwsh`); both checks must report nothing.

```powershell
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile("$PWD\Export-FabricPowerBI.ps1", [ref]$tokens, [ref]$errors) | Out-Null
$errors

# PowerShell 7
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

## Releases

1. A pull request with the required check `validate` green.
2. The owner merges it.
3. An annotated tag on the merge commit, `git tag -a vX.Y.Z -m "vX.Y.Z" <merge commit>`, pushed with
   `git push origin vX.Y.Z`.
4. A GitHub Release for the tag. Its notes are the `CHANGELOG.md` entry, with `[Unreleased]` renamed to the version and
   date.

Versions follow Semantic Versioning: patch for fixes, minor for a new parameter or behaviour, major for a change that
breaks existing command lines or the output layout.
