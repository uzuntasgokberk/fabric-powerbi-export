# Security policy

## Report a vulnerability privately

Use GitHub's private vulnerability reporting: the repository's **Security** tab, then **Report a vulnerability**
([direct link](https://github.com/uzuntasgokberk/fabric-powerbi-export/security/advisories/new)). Do not open a
public issue, discussion or pull request for a security problem.

Include:

- the script version (the latest entry in `CHANGELOG.md`, or the commit you downloaded);
- the PowerShell version (`$PSVersionTable.PSVersion`), the Fabric CLI version (`fab --version`) and the operating system;
- the smallest command line that reproduces it, with fake workspace and item names, and what you expected.

**Never send secrets or data**, in a report or anywhere else: no tokens, client secrets, certificates or connection
strings, no exported files, and no log files you have not reviewed (`_logs` holds workspace, folder and item names and
IDs; the `fab` debug log holds whole API responses). Reproduce with fake values; if a credential was exposed, rotate it
first.

This is a personal project maintained on a best-effort basis. Fixes go to the latest `main` only.

## What counts

- The script changes something in the Fabric service. It only lists items and reads their definitions.
- It writes, replaces or deletes a file outside the export folder.
- A token, client secret or password appears in its console output, log file or CSV.

## What is not a vulnerability

- The Fabric CLI session in `~/.config/fab/` (Windows: `%USERPROFILE%\.config\fab\`) lets anyone who can read it act
  as you; protect it like a password ([Fabric CLI notes](README.md#fabric-cli-notes)). The same goes for the `fab`
  debug log and for `encryption_fallback_enabled`, which stores the token in plain text.
- An export contains what the item definitions contain: server and database names, Power Query (M) code, workspace
  names and IDs. Review it before you commit it to a repository others can read.
- Problems in the Fabric CLI or the Fabric service belong to Microsoft: report them through the
  [Microsoft Security Response Center](https://msrc.microsoft.com).
