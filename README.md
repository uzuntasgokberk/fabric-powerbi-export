# Fabric Power BI Export

[![Validate](https://github.com/uzuntasgokberk/fabric-powerbi-export/actions/workflows/validate.yml/badge.svg)](https://github.com/uzuntasgokberk/fabric-powerbi-export/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-blue)

Back up the Power BI content of Microsoft Fabric workspaces as plain files you can open, diff and keep in Git. It's a single PowerShell script that uses the official [Fabric CLI](https://aka.ms/fabric-cli) (`fab`). For SQL Server Reporting Services and Power BI Report Server, see [ssrs-reportserver-export](https://github.com/uzuntasgokberk/ssrs-reportserver-export).

| In Fabric | On disk |
|---|---|
| Report | PBIP project: `.pbip` + `.Report` + its semantic model (TMDL), ready to open in Power BI Desktop |
| Paginated report | `.rdl` file |
| Semantic model that no exported report uses | `.SemanticModel` folder (TMDL) |

## Features

- **Opens in Power BI Desktop.** Each report is saved together with its semantic model, and `definition.pbir` is pointed at the local model. The original service connection is kept next to it.
- **Workspace root only, by default.** Folders such as `Archive` or `Backup` are skipped unless you list them with `-IncludeFolder`.
- **Pick what you need.** Use `-Name` / `-Exclude` (wildcards), `-Type`, or a dry run with `-List`.
- **Safe overwrite.** An item is replaced on disk only after it was downloaded completely, so a failed run never destroys the last good export.
- **Built for unattended runs:**
  - Waits for long-running definition requests (HTTP 202).
  - Retries on throttling (HTTP 429).
  - Kills and retries a hung `fab` call.
  - Writes a log and a CSV for every run.
  - Returns exit codes that schedulers can check.
- **Read-only against Fabric.** It only lists items and reads item definitions; nothing is changed in the service.
- **Windows PowerShell 5.1 and PowerShell 7.** Nothing to install besides the Fabric CLI.

## Output

```text
export\
├── _logs\
│   ├── export_20260101_080000.log
│   └── export_20260101_080000.csv
└── Sales Analytics\                              ← one folder per workspace
    ├── PBIP\
    │   ├── Monthly Revenue\
    │   │   ├── Monthly Revenue.pbip              ← open this in Power BI Desktop
    │   │   ├── Monthly Revenue.Report\           ← report definition (PBIR or legacy report.json)
    │   │   ├── Monthly Revenue.SemanticModel\    ← model definition (TMDL)
    │   │   └── _ServiceReference\definition.pbir ← original connection to the service model
    │   └── _StandaloneSemanticModels\
    │       └── Customer Master.SemanticModel\
    ├── RDL\
    │   └── Invoice Detail.rdl
    └── Archive\                                  ← only with -IncludeFolder "Archive"
        ├── PBIP\
        └── RDL\
```

## Requirements

| Requirement | Details |
|---|---|
| PowerShell | Windows PowerShell 5.1 or PowerShell 7+ |
| Fabric CLI | `pip install ms-fabric-cli` with Python 3.10–3.13. Tested with `fab` 1.8.0 on Python 3.13. See [Fabric CLI notes](#fabric-cli-notes) |
| Permissions | Contributor (or higher) on the workspaces. The Get Definition APIs need **read and write** permission on the item, so a Viewer gets HTTP 403 |
| Optional | Power BI Desktop to open `.pbip` files, Power BI Report Builder to open `.rdl` files |

Tested on Windows with PowerShell 5.1 and 7. The script is written to be platform-neutral, but Linux and macOS have not been tested yet.

## Quick start

```powershell
pip install ms-fabric-cli
fab auth login                     # sign in (opens the browser)
fab ls                             # lists the workspaces you can access

git clone https://github.com/uzuntasgokberk/fabric-powerbi-export.git
cd fabric-powerbi-export

.\Export-FabricPowerBI.ps1 -Workspace "Sales Analytics" -List      # dry run: what would be exported
.\Export-FabricPowerBI.ps1 -Workspace "Sales Analytics"            # export to .\export
```

If PowerShell refuses to run the script ("running scripts is disabled on this system"), allow local scripts for your user once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File .\Export-FabricPowerBI.ps1      # only needed if the file was downloaded as a ZIP
```

or start it with `powershell.exe -ExecutionPolicy Bypass -File .\Export-FabricPowerBI.ps1 ...`.

## Fabric CLI notes

Things worth knowing about the Fabric CLI itself:

| Topic | What to know |
|---|---|
| Python and `PATH` | The [Fabric CLI documentation](https://microsoft.github.io/fabric-cli/) lists Python 3.10, 3.11, 3.12 and 3.13. The `fab` 1.8.0 package on PyPI also accepts 3.14, but 3.13 is the safe choice. If `fab` is "not recognized" after `pip install`, Python's `Scripts` folder is not on `PATH`. Typical locations: `%LOCALAPPDATA%\Programs\Python\Python3xx\Scripts`, or `%APPDATA%\Python\Python3xx\Scripts` for `pip install --user`. Add it and reopen the terminal; `fab --version` must work. |
| Updating | `pip install --upgrade ms-fabric-cli`. `fab` shows an update notice only during `fab auth login`; it does not affect the script. |
| Sign-in | `fab auth login`, `fab auth status`, `fab auth logout`. The session is stored per OS user in `~/.config/fab/` (Windows: `%USERPROFILE%\.config\fab\`). Treat that folder as a secret, and remember that a scheduled task running under another account needs its own sign-in. |
| Folder listing | `fab config set folder_listing_enabled true` makes `fab ls` show workspace folders when you browse manually. The script does not need it: it lists items through the REST API with `recursive=false`. |
| Output format | Not relevant: the script always passes `--output_format text`, whatever `fab config get output_format` says. |
| Debug log | `fab config set debug_enabled true` makes `fab` log every HTTP request and response. Windows: `%LOCALAPPDATA%\fabric-cli\Logs\fabcli_debug.log`, macOS: `~/Library/Logs/fabric-cli/`, Linux: `~/.local/state/fabric-cli/log/`. The `Authorization` header is masked, but responses (including item definitions) are written, so switch it off again (`false`) and review the file before sharing it. |
| Token cache encryption | If sign-in fails with "An error occurred with the encrypted cache" (typically Linux or containers without a keyring), `fab config set encryption_fallback_enabled true` stores the token in plain text. Only do this on machines you trust. |
| Proxy | `fab` uses Python's `requests` library, which honors the `HTTPS_PROXY` / `NO_PROXY` environment variables. |

All settings: `fab config ls`. Documentation: <https://aka.ms/fabric-cli>.

## Usage

| Parameter | Description | Default |
|---|---|---|
| `-Workspace` | One or more workspace names, as shown by `fab ls`. The `.Workspace` / `.Personal` suffix is optional; `"My workspace"` exports your personal workspace. | *required* |
| `-Name` | Only items with these names. Wildcards allowed, e.g. `"Sales*"`. | all items |
| `-Exclude` | Skip items with these names. Wildcards allowed. | — |
| `-Type` | `Report`, `PaginatedReport`, `SemanticModel` | all three |
| `-IncludeFolder` | Also export these top-level folders: `"Workspace/Folder"` for one workspace, or `"Folder"` for every selected workspace that has it. | — |
| `-IncludeUsageMetrics` | Also export the system-generated usage metrics reports. | skipped |
| `-List` | Only list the matching items (type, name, id); nothing is downloaded. | — |
| `-ExportRoot` | Output folder. | `.\export` under the current directory |

```powershell
# Several workspaces into a separate folder (for example your backup repository)
.\Export-FabricPowerBI.ps1 -Workspace "Sales Analytics", "Finance" -ExportRoot "D:\powerbi-backup"

# One report (with its semantic model)
.\Export-FabricPowerBI.ps1 -Workspace "Sales Analytics" -Name "Monthly Revenue"

# Only paginated reports whose name starts with "Invoice"
.\Export-FabricPowerBI.ps1 -Workspace "Finance" -Type PaginatedReport -Name "Invoice*"

# Root plus the "Archive" folder, without drafts
.\Export-FabricPowerBI.ps1 -Workspace "Finance" -IncludeFolder "Finance/Archive" -Exclude "Draft*"

# Find an item when you don't know which workspace it is in
.\Export-FabricPowerBI.ps1 -Workspace "Sales Analytics", "Finance", "Operations" -Name "Monthly Revenue" -List
```

> **`-File` and lists:** With `powershell.exe -File` / `pwsh -File`, a comma-separated list (`-Name "A","B"`) is not passed as an array. Run such commands from inside a PowerShell session as shown above. The script rejects unexpected extra arguments instead of silently binding them to another parameter.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All selected items were exported |
| `1` | At least one item, folder or workspace failed (see the log), or `-Name` matched nothing. Also with `-List` |
| `2` | Could not start: `fab` was not found or you are not signed in |

## How it works

1. **Listing:** Lists the items directly in each location with the Fabric REST API (`GET workspaces/{id}/items?recursive=false`, through `fab api`). Without `rootFolderId` the location is the workspace root. Folders from `-IncludeFolder` are listed separately.
2. **Reports:** Downloads the report definition. The `semanticmodelid` in `definition.pbir` identifies the bound model.
   - **Model in an exported location:** The model definition is downloaded into the same project, and the report is re-pointed at it (`byPath`). The original connection is saved in `_ServiceReference`.
   - **Model in another workspace or a skipped folder:** The report keeps its service connection. It is logged as a `WARNING` and still opens in Desktop as a live connection.
   - **How the model is matched:** By ID whenever `definition.pbir` contains one (current Fabric exports do), so a report is not bound to a different model with the same name. Older definitions without an ID are matched by model name.
   - **Shared models:** A model used by several reports is downloaded once.
3. **Paginated reports:** The `.rdl` file is extracted from the item definition.
4. **Standalone models:** After all reports, the semantic models that none of them used are exported.
5. **Long-running requests:** Fabric often answers a definition request with HTTP 202. The script polls `operations/{id}` and then reads `operations/{id}/result`.
6. **Writing:** Every file of an item is first collected in memory; only then is the previous copy on disk replaced.

### What the semantic model folder contains

| Model type | Files |
|---|---|
| Import / DirectQuery | `definition\*.tmdl`: tables, columns, measures, relationships, Power Query (M) |
| Live connection to Analysis Services | `modelReference.json` with the connection string (there are no tables in Fabric to export) |

Reports are exported in the format stored in the service: PBIR (`definition\` folder) or legacy (`report.json`). Power BI Desktop opens both.

Fabric allows several items of the same type with the same name in one location. So that they don't overwrite each other, each of them gets the first 8 characters of its ID appended to the folder name, e.g. `Sales Overview (1a2b3c4d)` and `Sales Overview (5e6f7a8b)`. Unique names are written without a suffix.

## Opening the export

- **PBIP:** Double-click the `.pbip` file. The model contains **no data**, only definitions. Desktop therefore shows *"One or more calculated objects need to be manually refreshed"* and *"Some of the tables have incomplete or no data"*. That is expected and not an error: click *Refresh now*, and Desktop may ask for data source credentials. DirectQuery and live-connection reports show data right away.
- **Long paths:** Power BI Desktop cannot open a project whose file paths exceed 260 characters. Keep `-ExportRoot` short, e.g. `D:\pbi`.
- **RDL:** Open it in Power BI Report Builder.

### Local model or service model?

`datasetReference` in `<Report>.Report\definition.pbir` decides which semantic model a report uses. Power BI Desktop connects to that model **when the report is opened**. After an export:

| Binding | Which reports | `definition.pbir` | In Power BI Desktop |
|---|---|---|---|
| **Local model** | Reports whose model is in an exported location (most reports) | `"byPath": { "path": "../<Model>.SemanticModel" }` | Opens the model in the project folder. The model is editable; use *Refresh* to load data |
| **Service model** (app.powerbi.com) | Reports whose model is in another workspace or a skipped folder (logged as `WARNING`) | `"byConnection": { "connectionString": "Data Source=\"powerbi://api.powerbi.com/v1.0/myorg/<Workspace>\";initial catalog=\"<Model>\";...;semanticmodelid=<GUID>" }` | Opens a **live connection** to the model in the Power BI service. Requires sign-in; data comes from the service; the model is read-only |

To see which one a report uses, check whether its `definition.pbir` contains `byPath` or `byConnection`.

**Local model → service model:** Copy `_ServiceReference\definition.pbir` over `<Report>.Report\definition.pbir`. That file is the report's original connection in Fabric.

**Service model → local model** (otherwise the report keeps using the model in app.powerbi.com):
1. If the project folder has no `<Model>.SemanticModel` folder, copy it next to `<Report>.pbip`. For example, export the model's workspace (or folder) too and copy the folder from its `PBIP\_StandaloneSemanticModels`.
2. Back up `<Report>.Report\definition.pbir`, then change its `datasetReference` to:
   ```json
   "datasetReference": {
       "byPath": { "path": "../<Model>.SemanticModel" }
   }
   ```
3. If the report is open in Power BI Desktop, close and reopen it.

> **Note:** The next export run rewrites `definition.pbir` with its own rule, so manual changes are lost. Make lasting changes in the service, and keep local experiments on a separate Git branch.

## Logs and troubleshooting

Every run writes two files to `<ExportRoot>\_logs`:
- `.log`: one line per item, with the duration and the result. Failed items also show the item ID and the API call. A list of all failures is printed at the end.
- `.csv`: one row per item (`Location, ItemName, ItemType, ItemId, Status, Seconds, OutputPath, Message`). It opens directly in Excel.

| Message | Cause | Fix |
|---|---|---|
| `Fabric CLI (fab) was not found` | Fabric CLI not installed or not on `PATH` | `pip install ms-fabric-cli`, then reopen the terminal |
| `Not signed in` / `HTTP 401` | No session or expired session | `fab auth login` |
| `HTTP 403` | No write permission on the item | Ask for the Contributor role (or higher) on the workspace |
| `HTTP 404` | Item deleted or moved during the run | Run again |
| `Throttled (HTTP 429)` | Fabric API throttling | Retried automatically; if it persists, run later |
| `Network error: Fabric could not be reached` | Internet, VPN or proxy outage (e.g. `NameResolutionError`, `getaddrinfo failed`) | Retried automatically (3 attempts, 30 s apart); if the outage lasts longer, run the failed workspaces again |
| `fab did not respond within 300 s` | A single `fab` call hung (e.g. a stuck sign-in request) | Retried automatically up to 3 times |
| `Workspace not found or no access` | Name typo or no access | Compare with `fab ls` |
| `Folder not found at the workspace root` | Wrong `-IncludeFolder` name, or a nested folder | Use the exact name of a top-level folder |
| `Could not write to disk` | Project open in Power BI Desktop, or path longer than 260 characters | Close Desktop; use a shorter `-ExportRoot`; enable Windows long paths |
| `Could not get the definition ...` on a protected item | The item has an encrypted sensitivity label and you lack the usage rights to remove it | Ask your Purview administrator; otherwise the item cannot be exported |

Settings such as timeouts and retry counts are at the top of the script (`$FabTimeoutSeconds`, `$OperationTimeoutSeconds`, `$MaxRetries`).

## Unattended runs

The Fabric CLI supports service principals and managed identities:

```powershell
fab auth login -u <client-id> -p <client-secret> --tenant <tenant-id>   # service principal
fab auth login --identity                                               # managed identity
```

Instead of `fab auth login`, the Fabric CLI also reads these environment variables:
- `FAB_SPN_CLIENT_ID` + `FAB_SPN_CLIENT_SECRET` + `FAB_TENANT_ID`
- or `FAB_SPN_CERT_PATH` (+ `FAB_SPN_CERT_PASSWORD`) for a certificate
- or `FAB_SPN_FEDERATED_TOKEN`
- or `FAB_MANAGED_IDENTITY=true`

The identity needs access to the workspaces (Contributor or higher), and your tenant must allow service principals to use Fabric APIs. Keep secrets out of scripts and repositories; read them from a secret store.

Example for Windows Task Scheduler:

```text
Program:   powershell.exe
Arguments: -NoProfile -ExecutionPolicy Bypass -File "C:\tools\fabric-powerbi-export\Export-FabricPowerBI.ps1" -Workspace "Sales Analytics" -ExportRoot "D:\powerbi-backup"
```

A non-zero exit code marks the task run as failed.

## Keeping exports in Git

Keep the exports in a **separate** repository, not in this one:

```powershell
cd D:\powerbi-backup
git init
git config core.longpaths true                                  # PBIP paths can be long
git config core.quotepath false                                 # show non-ASCII file names readably
Copy-Item <path-to-this-repo>\templates\export-repo\.gitignore, <path-to-this-repo>\templates\export-repo\.gitattributes .
git add .
git status                                                      # _logs, cache.abf, localSettings.json must NOT be listed
git commit -m "Power BI export"
git branch -M main
git remote add origin <your-private-repository-url>
git push -u origin main
```

- **`.gitignore`:** Leaves out the Desktop cache (`.pbi/cache.abf`, which contains data), per-user settings, `.pbix` files and the logs.
- **`.gitattributes`:** Normalizes line endings. The Fabric service returns LF and Power BI Desktop saves CRLF; Git stores both the same way, so a diff shows only real changes, never whole files. After an export Git may print `LF will be replaced by CRLF`; that is only information.

The script writes `.pbip` and `definition.pbir` in the layout Power BI Desktop uses, so opening and saving a report in Desktop does not show these two files as changed, whether the export ran in PowerShell 5.1 or 7.

For later backups, run the export again, then `git add .`, `git commit` and `git push`; Git only sends the changed files.

Use a **private** repository: TMDL and RDL files contain server and database names and queries.

## Limitations

- Only **top-level** folders can be included; subfolders of an included folder are not exported.
- Items **deleted or renamed** in the service are not removed from an existing export. Delete the workspace folder before a run if you need an exact mirror.
- Only reports, paginated reports and semantic models are exported. Dashboards, dataflows, notebooks and other item types are skipped.
- Each `fab` call starts a new process. In our tests a report with its model took about 25–30 s and a paginated report about 5 s, so large workspaces take a while.
- The export contains definitions only, no data.

## Related projects

- [ssrs-reportserver-export](https://github.com/uzuntasgokberk/ssrs-reportserver-export): the same idea for SQL Server Reporting Services and Power BI Report Server. It exports reports, shared data sources, shared datasets, report parts and Power BI reports (`.pbix`) through the report server REST API.

## Contributing

Issues are welcome; pull requests are by invitation. [CONTRIBUTING.md](CONTRIBUTING.md) describes the process and the checks to run. When reporting a bug, include the relevant lines from the log file and remove workspace, item or server names you don't want to share. Report security problems privately, never in an issue: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © uzuntasgokberk

This project is not affiliated with or endorsed by Microsoft. Microsoft Fabric and Power BI are trademarks of the Microsoft group of companies.
