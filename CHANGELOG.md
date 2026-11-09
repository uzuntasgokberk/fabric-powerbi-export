# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.1] - 2026-11-09

### Fixed

- `-List` now returns exit code `1` when a workspace or an `-IncludeFolder` folder could not be listed (it returned `0`).
- `-Workspace "My workspace"` (or `"My workspace.Personal"`) exports the personal workspace; the script used to look only for `<Name>.Workspace`.

### Documentation

- `SECURITY.md`: how to report a vulnerability privately. `CONTRIBUTING.md`: issues first, pull requests by invitation, and the checks to run.
- README: the script can be downloaded from the latest release and checked with its SHA256.

## [1.0.0] - 2026-10-22

### Added

- Export of Power BI reports as PBIP projects, with the bound semantic model (TMDL) next to the report and `definition.pbir` pointing at the local model.
- Export of paginated reports as `.rdl` files.
- Export of semantic models that no exported report uses (`_StandaloneSemanticModels`).
- Root-only export by default; optional top-level folders with `-IncludeFolder`.
- Filters: `-Name` and `-Exclude` (wildcards), `-Type`, `-List` (dry run).
- Usage metrics reports are skipped by default (`-IncludeUsageMetrics` to keep them).
- Handling of long-running definition requests (HTTP 202), HTTP 429 throttling, hung `fab` calls (timeout and retry) and short network outages (retry).
- Items of the same type with the same name in one location get a short ID suffix instead of overwriting each other.
- Safe overwrite: an item is replaced on disk only after it was downloaded completely.
- Log file and CSV summary per run; exit codes for schedulers.
- `.pbip` and `definition.pbir` are written in the Power BI Desktop layout, so saving a report in Desktop does not show them as changed (same output in PowerShell 5.1 and 7).
- Templates (`.gitignore`, `.gitattributes`) for keeping exports in Git; `.gitattributes` normalizes line endings, so service exports (LF) and Desktop saves (CRLF) show only real changes.
