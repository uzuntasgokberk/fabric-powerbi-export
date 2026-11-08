#requires -Version 5.1

<#
.SYNOPSIS
    Exports Power BI reports, paginated reports and semantic models from Microsoft Fabric
    workspaces to PBIP / TMDL / RDL files, using the Fabric CLI (fab).

.DESCRIPTION
    For every workspace in -Workspace, the items at the workspace root are exported.
    Workspace folders are skipped unless they are listed in -IncludeFolder.

      Report          -> <ExportRoot>\<Workspace>\PBIP\<Report>\   (.pbip + .Report + bound .SemanticModel)
      PaginatedReport -> <ExportRoot>\<Workspace>\RDL\<Report>.rdl
      SemanticModel   -> <ExportRoot>\<Workspace>\PBIP\_StandaloneSemanticModels\<Model>.SemanticModel
                         (only models that no exported report uses)

    Items of an included folder are written to <ExportRoot>\<Workspace>\<Folder>\PBIP and \RDL.

    The Fabric service is only read (list items, get item definition); nothing is changed there.
    Each item is downloaded completely into memory before its previous local copy is replaced,
    so a failed download never destroys the last good export.

.PARAMETER Workspace
    One or more workspace names, as shown by "fab ls" (the ".Workspace" / ".Personal" suffix is
    optional). "My workspace" exports the personal workspace.

.PARAMETER Name
    Only export items with these names. Wildcards are allowed, e.g. "Sales*".

.PARAMETER Exclude
    Skip items with these names. Wildcards are allowed.

.PARAMETER Type
    Only export these item types: Report, PaginatedReport, SemanticModel. Default: all three.

.PARAMETER IncludeFolder
    Workspace folders to export in addition to the root. Use "Workspace/Folder" for a single
    workspace, or just "Folder" for every selected workspace that has such a folder.
    Only top-level folders are supported; their subfolders are not exported.

.PARAMETER IncludeUsageMetrics
    Also export the system-generated usage metrics reports (skipped by default).

.PARAMETER List
    Only list the matching items (type, name, id). Nothing is downloaded.

.PARAMETER ExportRoot
    Output folder. Default: "export" under the current directory.

.EXAMPLE
    .\Export-FabricPowerBI.ps1 -Workspace "Sales Analytics" -List
    Lists the root items of a workspace without downloading anything.

.EXAMPLE
    .\Export-FabricPowerBI.ps1 -Workspace "Sales Analytics", "Finance" -ExportRoot "D:\powerbi-backup"
    Exports the root of two workspaces.

.EXAMPLE
    .\Export-FabricPowerBI.ps1 -Workspace "Sales Analytics" -Name "Monthly Revenue"
    Exports a single report together with its semantic model.

.EXAMPLE
    .\Export-FabricPowerBI.ps1 -Workspace "Finance" -Type PaginatedReport -Name "Invoice*"
    Exports every paginated report whose name starts with "Invoice".

.EXAMPLE
    .\Export-FabricPowerBI.ps1 -Workspace "Finance" -IncludeFolder "Finance/Archive" -Exclude "Draft*"
    Exports the root and the "Archive" folder, skipping items whose name starts with "Draft".

.LINK
    https://aka.ms/fabric-cli
#>

# PositionalBinding = $false: an unnamed or extra argument fails loudly instead of being
# silently bound to the next parameter (e.g. -Name "A","B" with powershell -File).
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)]
    [string[]]$Workspace,

    [string[]]$Name,

    [string[]]$Exclude,

    [ValidateSet("Report", "PaginatedReport", "SemanticModel")]
    [string[]]$Type = @("Report", "PaginatedReport", "SemanticModel"),

    [string[]]$IncludeFolder,

    [switch]$IncludeUsageMetrics,

    [switch]$List,

    [string]$ExportRoot = (Join-Path (Get-Location).Path "export")
)

# StrictMode 1.0 catches undefined variables but returns $null (instead of
# throwing) when a JSON property is missing from an API response.
Set-StrictMode -Version 1.0
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

$PollIntervalSeconds     = 3     # Status check interval for long-running (HTTP 202) calls.
$OperationTimeoutSeconds = 600   # Give up on a long-running call after this many seconds.
$FabTimeoutSeconds       = 300   # Kill a single fab call that hangs longer than this.
$MaxRetries              = 3     # Attempts per API call on HTTP 429 or a fab timeout.

# System-generated items that are skipped unless -IncludeUsageMetrics is given.
$UsageMetricsItems = @("Usage Metrics Report", "Report Usage Metrics Report", "Report Usage Metrics Model")

$ExportRoot = [System.IO.Path]::GetFullPath($ExportRoot)
$LogFolder  = Join-Path $ExportRoot "_logs"
$RunStart   = Get-Date
$LogFile    = Join-Path $LogFolder ("export_{0:yyyyMMdd_HHmmss}.log" -f $RunStart)
$CsvFile    = [System.IO.Path]::ChangeExtension($LogFile, ".csv")

$Separator    = [System.IO.Path]::DirectorySeparatorChar
$Utf8NoBom    = New-Object System.Text.UTF8Encoding $false
$Results      = New-Object System.Collections.Generic.List[object]
$UsedModelIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
$ModelCache   = @{}              # Model ID -> definition, so shared models are downloaded once.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-ExportLog([string]$Message, [string]$Level = "INFO") {
    $Line   = "[{0:yyyy-MM-dd HH:mm:ss}][{1}] {2}" -f (Get-Date), $Level, $Message
    $Colors = @{ INFO = "Cyan"; SUCCESS = "Green"; WARNING = "Yellow"; ERROR = "Red" }
    Write-Host $Line -ForegroundColor $Colors[$Level]

    # Logging must never stop the export (e.g. antivirus briefly locking the log file).
    try   { [System.IO.File]::AppendAllText($LogFile, $Line + [Environment]::NewLine, $Utf8NoBom) }
    catch { Write-Host "  (could not write to the log file: $($_.Exception.Message))" -ForegroundColor DarkGray }
}

function Add-Result([string]$Location, $Item, [string]$Status, [string]$OutputPath, [string]$Message, [double]$Seconds) {
    $Results.Add([PSCustomObject]@{
        DateTime   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Location   = $Location
        ItemName   = $Item.displayName
        ItemType   = $Item.type
        ItemId     = $Item.id
        Status     = $Status
        Seconds    = [Math]::Round($Seconds)
        OutputPath = $OutputPath
        Message    = $Message
    })
}

# ---------------------------------------------------------------------------
# File helpers (.NET APIs, because cmdlets treat [ ] in names as wildcards)
# ---------------------------------------------------------------------------

# Windows rules on every platform, so an export can be copied or cloned anywhere.
$InvalidNameChars = [char[]]'\/:*?"<>|' + [char[]](0..31)

function Get-SafeFileName([string]$Name) {
    foreach ($Char in $InvalidNameChars) { $Name = $Name.Replace([string]$Char, "_") }

    $Name = $Name.Trim().TrimEnd(".")
    if (-not $Name) { return "_Unnamed" }
    if ($Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { return "_$Name" }
    return $Name
}

function Join-ChildPath([string[]]$Parts) {
    # Join-Path with any number of parts (Windows PowerShell 5.1 accepts only two).
    $Path = $Parts[0]
    foreach ($Part in ($Parts | Select-Object -Skip 1)) { $Path = Join-Path $Path $Part }
    return $Path
}

function New-ParentFolder([string]$Path) {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
}

function Remove-ExistingPath([string]$Path) {
    # Retries because antivirus/indexer can briefly lock freshly written files.
    for ($Attempt = 1; ; $Attempt++) {
        try {
            if ([System.IO.Directory]::Exists($Path)) { [System.IO.Directory]::Delete($Path, $true) }
            elseif ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
            return
        }
        catch {
            if ($Attempt -ge 5) { throw }
            Start-Sleep -Seconds 1
        }
    }
}

function Save-ItemOutput($Files, [string]$Target) {
    # Called only after every download for the item succeeded.
    try {
        Remove-ExistingPath $Target

        foreach ($Path in $Files.Keys) {
            New-ParentFolder $Path
            [System.IO.File]::WriteAllBytes($Path, $Files[$Path])
        }
    }
    catch {
        throw ("Could not write to disk: $($_.Exception.Message) " +
               "Hint: the folder may be open in Power BI Desktop / Explorer, or the path may exceed 260 characters (use a shorter -ExportRoot).")
    }
}

# ---------------------------------------------------------------------------
# JSON writer for the files the script writes itself (.pbip, rewritten definition.pbir)
# ---------------------------------------------------------------------------

function ConvertTo-PbipJson($Value) {
    # Writes JSON exactly as Power BI Desktop and the service do: 2-space indent, one space
    # after the colon, CRLF, no final newline, '&' and non-ASCII letters as they are.
    # ConvertTo-Json is not used: it indents differently in 5.1 and 7 and writes '&' as a
    # Unicode escape, so Git would show these files as changed after every Desktop save.
    $Builder = New-Object System.Text.StringBuilder
    Add-JsonValue $Builder $Value 0
    return $Builder.ToString()
}

function Add-JsonValue([System.Text.StringBuilder]$Builder, $Value, [int]$Depth) {
    $NewLine     = "`r`n"
    $Indent      = "  " * ($Depth + 1)
    $CloseIndent = "  " * $Depth

    if ($null -eq $Value)    { [void]$Builder.Append("null"); return }
    if ($Value -is [string]) { Add-JsonString $Builder $Value; return }
    if ($Value -is [bool])   { [void]$Builder.Append($(if ($Value) { "true" } else { "false" })); return }

    # Objects: hashtables built here, or PSCustomObjects from ConvertFrom-Json.
    $Names  = New-Object System.Collections.Generic.List[string]
    $Values = New-Object System.Collections.Generic.List[object]
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($Key in $Value.Keys) { $Names.Add([string]$Key); $Values.Add($Value[$Key]) }
    }
    elseif ($Value -is [System.Collections.IList]) {
        if ($Value.Count -eq 0) { [void]$Builder.Append("[]"); return }
        [void]$Builder.Append("[")
        for ($i = 0; $i -lt $Value.Count; $i++) {
            if ($i -gt 0) { [void]$Builder.Append(",") }
            [void]$Builder.Append($NewLine).Append($Indent)
            Add-JsonValue $Builder $Value[$i] ($Depth + 1)
        }
        [void]$Builder.Append($NewLine).Append($CloseIndent).Append("]")
        return
    }
    elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($Property in $Value.PSObject.Properties) { $Names.Add($Property.Name); $Values.Add($Property.Value) }
    }
    elseif ($Value -is [ValueType]) {
        [void]$Builder.Append([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
        return
    }
    else {
        Add-JsonString $Builder ([string]$Value)
        return
    }

    if ($Names.Count -eq 0) { [void]$Builder.Append("{}"); return }
    [void]$Builder.Append("{")
    for ($i = 0; $i -lt $Names.Count; $i++) {
        if ($i -gt 0) { [void]$Builder.Append(",") }
        [void]$Builder.Append($NewLine).Append($Indent)
        Add-JsonString $Builder $Names[$i]
        [void]$Builder.Append(": ")
        Add-JsonValue $Builder $Values[$i] ($Depth + 1)
    }
    [void]$Builder.Append($NewLine).Append($CloseIndent).Append("}")
}

function Add-JsonString([System.Text.StringBuilder]$Builder, [string]$Text) {
    # Escapes only what JSON requires: the quote, the backslash and control characters.
    [void]$Builder.Append('"')
    foreach ($Char in $Text.ToCharArray()) {
        $Code = [int]$Char
        if     ($Code -eq 34) { [void]$Builder.Append('\"') }
        elseif ($Code -eq 92) { [void]$Builder.Append('\\') }
        elseif ($Code -eq 10) { [void]$Builder.Append('\n') }
        elseif ($Code -eq 13) { [void]$Builder.Append('\r') }
        elseif ($Code -eq 9)  { [void]$Builder.Append('\t') }
        elseif ($Code -eq 8)  { [void]$Builder.Append('\b') }
        elseif ($Code -eq 12) { [void]$Builder.Append('\f') }
        elseif ($Code -lt 32) { [void]$Builder.Append(('\u{0:x4}' -f $Code)) }
        else                  { [void]$Builder.Append($Char) }
    }
    [void]$Builder.Append('"')
}

# ---------------------------------------------------------------------------
# Fabric CLI / REST API
# ---------------------------------------------------------------------------

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    # fab is a launcher that starts Python, so the child process must be stopped as well.
    if ($PSVersionTable.PSVersion.Major -ge 7) { $Process.Kill($true); return }

    Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $Process.Kill()
}

function Invoke-Fab([string[]]$Arguments) {
    # Runs fab as a child process and returns stdout. A timeout is required because a
    # single hung call (e.g. a stuck sign-in request) would otherwise block the whole run.
    # stdout/stderr are read separately, so stderr can never corrupt the JSON output.
    $Info = New-Object System.Diagnostics.ProcessStartInfo
    $Info.FileName               = $FabPath
    $Info.Arguments              = ($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join " "
    $Info.UseShellExecute        = $false
    $Info.CreateNoWindow         = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError  = $true
    $Info.StandardOutputEncoding = $Utf8NoBom
    $Info.StandardErrorEncoding  = $Utf8NoBom
    $Info.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"   # Keeps non-ASCII names intact.

    $Process = [System.Diagnostics.Process]::Start($Info)
    $StdOut  = $Process.StandardOutput.ReadToEndAsync()   # Async reads: a full pipe can never stall fab.
    $StdErr  = $Process.StandardError.ReadToEndAsync()

    if (-not $Process.WaitForExit($FabTimeoutSeconds * 1000)) {
        Stop-ProcessTree $Process
        throw (New-Object System.TimeoutException "fab did not respond within $FabTimeoutSeconds s: fab $($Arguments -join ' ')")
    }
    $Process.WaitForExit()   # Lets the async readers finish.

    if ($Process.ExitCode -ne 0) {
        # fab HTML-escapes its error text (e.g. &#x27;), so decode it for readability.
        $Detail  = [System.Net.WebUtility]::HtmlDecode("$($StdOut.Result) $($StdErr.Result)".Trim())
        $Message = "fab failed (exit $($Process.ExitCode)): fab $($Arguments -join ' ') | $Detail"

        # Network failures (no DNS, no connection) get their own exception type so they are retried.
        if ($Detail -match 'NameResolutionError|getaddrinfo|ConnectionError|Max retries exceeded|ConnectTimeout|Connection aborted|RemoteDisconnected') {
            throw (New-Object System.Net.WebException "Network error: Fabric could not be reached (check internet / VPN / proxy). $Message")
        }
        throw $Message
    }

    return $StdOut.Result
}

function Invoke-FabRetry([string[]]$Arguments) {
    # Retries a fab call that hung (timeout) or failed on the network (e.g. a short internet outage).
    for ($Attempt = 1; ; $Attempt++) {
        try {
            return Invoke-Fab $Arguments
        }
        catch [System.TimeoutException], [System.Net.WebException] {
            if ($Attempt -ge $MaxRetries) { throw }
            $Wait = if ($_.Exception -is [System.Net.WebException]) { 30 } else { 0 }
            Write-ExportLog "$($_.Exception.Message) | Retrying in $Wait s ($Attempt/$MaxRetries)." "WARNING"
            Start-Sleep -Seconds $Wait
        }
    }
}

function Get-HttpHint([int]$StatusCode) {
    switch ($StatusCode) {
        401 { return "Hint: the session is not valid; run 'fab auth login'." }
        403 { return "Hint: no permission; getting an item definition requires write access to the item (workspace Contributor or higher)." }
        404 { return "Hint: not found; the item may have been deleted or moved." }
        429 { return "Hint: Fabric API throttling; wait a while and run again." }
    }
    if ($StatusCode -ge 500) { return "Hint: Fabric service error; try again later." }
    return ""
}

function Invoke-FabApi([string]$Method, [string]$Endpoint, [string]$Params) {
    # Returns { status_code, headers, text }. "--output_format text" keeps this shape
    # even if the user's fab config has output_format = json.
    $Arguments = @("api", "-A", "fabric", "-X", $Method, $Endpoint, "--show_headers", "--output_format", "text")
    if ($Params) { $Arguments += @("-P", $Params) }

    for ($Attempt = 1; ; $Attempt++) {
        $Output = Invoke-FabRetry $Arguments

        try   { $Response = $Output | ConvertFrom-Json }
        catch { throw "fab output is not JSON ($Method $Endpoint): $($Output.Substring(0, [Math]::Min(300, $Output.Length)))" }

        # "fab api" returns raw responses and does not retry throttling itself.
        if ($Response.status_code -ne 429 -or $Attempt -ge $MaxRetries) { return $Response }

        $Wait = 0
        if (-not [int]::TryParse([string]$Response.headers.'Retry-After', [ref]$Wait) -or $Wait -le 0) { $Wait = 30 }
        Write-ExportLog "Throttled (HTTP 429), waiting $Wait s ($Attempt/$MaxRetries): $Endpoint" "WARNING"
        Start-Sleep -Seconds $Wait
    }
}

function Invoke-FabJson([string]$Method, [string]$Endpoint, [string]$Params) {
    # Calls the API, waits for long-running operations (HTTP 202) and returns the body.
    $Response = Invoke-FabApi $Method $Endpoint $Params

    if ($Response.status_code -eq 202) {
        # The Location header points to a non-Fabric host, so poll the Fabric
        # operations API with x-ms-operation-id instead.
        $OperationId = $Response.headers.'x-ms-operation-id'
        if (-not $OperationId) { throw "HTTP 202 response without x-ms-operation-id [$Method $Endpoint]" }

        $Deadline = (Get-Date).AddSeconds($OperationTimeoutSeconds)
        do {
            if ((Get-Date) -gt $Deadline) {
                throw "Long-running operation did not finish within $OperationTimeoutSeconds s (operation $OperationId) [$Method $Endpoint]"
            }
            Start-Sleep -Seconds $PollIntervalSeconds

            $Response = Invoke-FabApi "get" "operations/$OperationId"
            if ($Response.status_code -ne 200) {
                throw "Could not read the operation state: HTTP $($Response.status_code) (operation $OperationId) [$Method $Endpoint]"
            }

            $Status = $Response.text.status
            if ($Status -in "Failed", "Cancelled") {
                $Err = $Response.text.error
                throw "Long-running operation ended as '$Status': $($Err.errorCode) $($Err.message) (operation $OperationId) [$Method $Endpoint]"
            }
        } while ($Status -ne "Succeeded")

        $Response = Invoke-FabApi "get" "operations/$OperationId/result"
    }

    $Code = [int]$Response.status_code
    if ($Code -lt 200 -or $Code -ge 300) {
        throw "HTTP $Code $($Response.text.errorCode): $($Response.text.message) $(Get-HttpHint $Code) [$Method $Endpoint]"
    }

    return $Response.text
}

function Get-PagedList([string]$Endpoint, [string]$Params) {
    # Collects "value" from every page of a list API (follows continuationToken).
    $Values = @()
    $Token  = $null

    do {
        $Query = $Params
        if ($Token) { $Query = (@($Params, "continuationToken=$Token") | Where-Object { $_ }) -join "," }   # fab URL-encodes -P values itself.

        $Page  = Invoke-FabJson "get" $Endpoint $Query
        if ($Page.value) { $Values += $Page.value }
        $Token = $Page.continuationToken
    } while ($Token)

    return $Values
}

function Get-FolderContent([string]$WorkspaceId, [string]$FolderId) {
    # recursive=false returns only the items directly in this location; nested folders
    # are skipped. Without rootFolderId the location is the workspace root.
    $Params = "recursive=false"
    if ($FolderId) { $Params += ",rootFolderId=$FolderId" }
    return Get-PagedList "workspaces/$WorkspaceId/items" $Params
}

function Get-Definition([string]$WorkspaceId, $Item) {
    $Collection = @{ Report = "reports"; SemanticModel = "semanticModels"; PaginatedReport = "paginatedReports" }[$Item.type]

    # Semantic models default to TMDL format.
    try {
        $Body = Invoke-FabJson "post" "workspaces/$WorkspaceId/$Collection/$($Item.id)/getDefinition"
        if (-not $Body.definition.parts) { throw "The response has no definition.parts." }
    }
    catch {
        throw "Could not get the definition of $($Item.type) '$($Item.displayName)': $($_.Exception.Message)"
    }

    return $Body.definition
}

function Get-ModelDefinition([string]$WorkspaceId, $Model) {
    if (-not $ModelCache.ContainsKey($Model.id)) {
        $ModelCache[$Model.id] = Get-Definition $WorkspaceId $Model
    }
    return $ModelCache[$Model.id]
}

function Add-DefinitionPart($Files, $Definition, [string]$Folder) {
    # Each part is a Base64 file; refuse paths that would escape the target folder.
    $Root = [System.IO.Path]::GetFullPath($Folder).TrimEnd($Separator) + $Separator

    foreach ($Part in $Definition.parts) {
        $Path = [System.IO.Path]::GetFullPath((Join-Path $Folder $Part.path))
        if (-not $Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe path in item definition: $($Part.path)"
        }
        $Files[$Path] = [Convert]::FromBase64String([string]$Part.payload)
    }
}

# ---------------------------------------------------------------------------
# Selection and report -> semantic model matching
# ---------------------------------------------------------------------------

function Get-TargetName($Entry, $Siblings) {
    # Fabric allows several items of the same type with the same name in one location. They would
    # overwrite each other on disk, so each of them gets a short ID suffix, e.g. "Sales (1a2b3c4d)".
    # All items of the location are compared (not only the selected ones), so names stay stable.
    $Name = Get-SafeFileName $Entry.displayName
    $Same = @($Siblings | Where-Object { $_.type -eq $Entry.type -and (Get-SafeFileName $_.displayName).ToLowerInvariant() -eq $Name.ToLowerInvariant() })
    if ($Same.Count -gt 1) { $Name = "$Name ($($Entry.id.Substring(0, 8)))" }
    return $Name
}

function Test-NameMatch([string]$DisplayName, [string[]]$Patterns) {
    # Exact match (ignoring surrounding spaces) or wildcard match.
    foreach ($Pattern in $Patterns) {
        if ($DisplayName.Trim() -eq $Pattern.Trim() -or $DisplayName.Trim() -like $Pattern.Trim()) { return $true }
    }
    return $false
}

function Test-Selected($Entry, [string[]]$Types, [string[]]$Names, [string[]]$Excludes) {
    # Applies -Type, -Exclude and -Name.
    if ($Types -notcontains $Entry.type) { return $false }
    if ($Excludes -and (Test-NameMatch $Entry.displayName $Excludes)) { return $false }
    if (-not $Names) { return $true }
    return (Test-NameMatch $Entry.displayName $Names)
}

function Get-RegexGroup([string]$Text, [string]$Pattern) {
    # CultureInvariant: under some locales (e.g. Turkish) IgnoreCase does not match "I" with "i".
    $Match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]"IgnoreCase, CultureInvariant")
    if ($Match.Success) { return $Match.Groups[1].Value.Trim() }
    return $null
}

function Get-ModelReference([string]$PbirText) {
    # PBIR 2.x connectionString example:
    #   Data Source="powerbi://.../myorg/<Workspace>";initial catalog="<Model>";...;semanticmodelid=<GUID>
    $Connection = ($PbirText | ConvertFrom-Json).datasetReference.byConnection
    $Text       = [string]$Connection.connectionString

    $Reference = @{
        Id        = Get-RegexGroup $Text 'semanticmodelid\s*=\s*"?([0-9a-f-]{36})'
        Name      = Get-RegexGroup $Text 'initial catalog\s*=\s*"?([^";]+)'
        Workspace = Get-RegexGroup $Text '/myorg/([^";]+)'
    }

    # PBIR 1.x keeps the model ID in a separate property.
    if (-not $Reference.Id -and $Connection.pbiModelDatabaseName) { $Reference.Id = [string]$Connection.pbiModelDatabaseName }

    return $Reference
}

function Find-ReportModel($Reference, $Report, $CandidateModels) {
    # When the ID is known, match by ID only: if it is not in an exported location, the model
    # lives in another workspace or a skipped folder, and a name match could bind the wrong model.
    if ($Reference.Id)   { return $CandidateModels | Where-Object id -eq $Reference.Id | Select-Object -First 1 }
    if ($Reference.Name) { return $CandidateModels | Where-Object displayName -eq $Reference.Name | Select-Object -First 1 }
    return $CandidateModels | Where-Object displayName -eq $Report.displayName | Select-Object -First 1
}

# ---------------------------------------------------------------------------
# Item builders: download into $Files (full path -> bytes), return a status message
# ---------------------------------------------------------------------------

function Build-PbipProject([string]$WorkspaceId, $Report, $CandidateModels, [string]$Folder, $Files) {
    $Name         = Get-SafeFileName $Report.displayName
    $ReportFolder = Join-Path $Folder "$Name.Report"
    $PbirPath     = [System.IO.Path]::GetFullPath((Join-Path $ReportFolder "definition.pbir"))

    Add-DefinitionPart $Files (Get-Definition $WorkspaceId $Report) $ReportFolder
    if (-not $Files.Contains($PbirPath)) { throw "The report definition has no definition.pbir." }

    $Pbip = [ordered]@{
        '$schema' = "https://developer.microsoft.com/json-schemas/fabric/pbip/pbipProperties/1.0.0/schema.json"
        version   = "1.0"
        artifacts = @(@{ report = @{ path = "$Name.Report" } })
        settings  = @{ enableAutoRecovery = $true }
    }
    $Files[(Join-Path $Folder "$Name.pbip")] = $Utf8NoBom.GetBytes((ConvertTo-PbipJson $Pbip))

    $PbirText  = $Utf8NoBom.GetString($Files[$PbirPath]).TrimStart([char]0xFEFF)
    $Reference = Get-ModelReference $PbirText
    $Model     = Find-ReportModel $Reference $Report $CandidateModels

    if (-not $Model) {
        return "WARNING: the bound model is not in an exported location; it is in another workspace or a skipped folder (reference: '$($Reference.Workspace)' / '$($Reference.Name)'). The report keeps its service connection; the model was not exported."
    }

    $ModelFolderName = "$(Get-SafeFileName $Model.displayName).SemanticModel"
    Add-DefinitionPart $Files (Get-ModelDefinition $WorkspaceId $Model) (Join-Path $Folder $ModelFolderName)

    # Keep the original service connection, then point the report at the local model.
    $Files[(Join-ChildPath @($Folder, "_ServiceReference", "definition.pbir"))] = $Files[$PbirPath]

    $Pbir = $PbirText | ConvertFrom-Json
    $Pbir.datasetReference = @{ byPath = @{ path = "../$ModelFolderName" } }
    $Files[$PbirPath] = $Utf8NoBom.GetBytes((ConvertTo-PbipJson $Pbir))

    [void]$UsedModelIds.Add($Model.id)
    return "Bound to model '$($Model.displayName)'; definition.pbir now points to the local model."
}

function Build-Rdl([string]$WorkspaceId, $Item, [string]$File, $Files) {
    $Part = (Get-Definition $WorkspaceId $Item).parts | Where-Object path -like "*.rdl" | Select-Object -First 1
    if (-not $Part) { throw "The paginated report definition has no .rdl file." }

    $Files[$File] = [Convert]::FromBase64String([string]$Part.payload)
    return "RDL exported ($($Files[$File].Length) bytes)."
}

function Export-Item([string]$Location, [string]$WorkspaceId, $Item, [string]$Target, $CandidateModels) {
    $Timer = [System.Diagnostics.Stopwatch]::StartNew()
    $Files = [ordered]@{}

    try {
        switch ($Item.type) {
            "Report"          { $Message = Build-PbipProject $WorkspaceId $Item $CandidateModels $Target $Files }
            "PaginatedReport" { $Message = Build-Rdl $WorkspaceId $Item $Target $Files }
            "SemanticModel"   {
                Add-DefinitionPart $Files (Get-ModelDefinition $WorkspaceId $Item) $Target
                $Message = "Exported as a standalone model (no exported report uses it)."
            }
        }

        Save-ItemOutput $Files $Target

        $Level = if ($Message -like "WARNING:*") { "WARNING" } else { "SUCCESS" }
        Write-ExportLog ("{0} | {1} / {2} | {3:N0} s | {4}" -f $Item.type, $Location, $Item.displayName, $Timer.Elapsed.TotalSeconds, $Message) $Level
        Add-Result $Location $Item "Success" $Target $Message $Timer.Elapsed.TotalSeconds
    }
    catch {
        $ErrorText = $_.Exception.Message
        Write-ExportLog ("{0} | {1} / {2} | FAILED | id={3} | {4}" -f $Item.type, $Location, $Item.displayName, $Item.id, $ErrorText) "ERROR"
        Add-Result $Location $Item "Failed" $Target $ErrorText $Timer.Elapsed.TotalSeconds
    }
}

function Get-WorkspaceId([string]$WorkspaceName, [string[]]$Suffixes) {
    # "fab ls" shows shared workspaces as "<Name>.Workspace" and the personal one as "My workspace.Personal".
    # Without a suffix, a shared workspace is tried first, then the personal workspace.
    $Errors = @()
    foreach ($Suffix in $Suffixes) {
        try   { return (Invoke-FabRetry @("get", "$WorkspaceName$Suffix", "-q", "id", "--output_format", "text")).Trim() }
        catch [System.Net.WebException] { throw }
        catch { $Errors += $_.Exception.Message }
    }
    throw "Workspace not found or no access. Compare the name with the output of 'fab ls'. Details: $($Errors -join ' | ')"
}

function Get-IncludedFolder([string]$WorkspaceName) {
    # "Workspace/Folder" entries for this workspace (explicit) and plain "Folder" entries (any workspace).
    $Folders = @()
    foreach ($Entry in $IncludeFolder) {
        $Parts = $Entry -split '/', 2
        if ($Parts.Count -eq 2) {
            if (($Parts[0].Trim() -replace '\.(Workspace|Personal)$', '') -eq $WorkspaceName) { $Folders += @{ Name = $Parts[1].Trim(); Explicit = $true } }
        }
        elseif ($Entry.Trim()) {
            $Folders += @{ Name = $Entry.Trim(); Explicit = $false }
        }
    }
    return $Folders
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[void][System.IO.Directory]::CreateDirectory($LogFolder)
Write-ExportLog "Export started."
Write-ExportLog "Export root : $ExportRoot"
Write-ExportLog "PowerShell  : $($PSVersionTable.PSVersion)"
Write-ExportLog "Workspaces  : $($Workspace -join ', ')"
Write-ExportLog "Filter      : type = $($Type -join ', ') | name = $(if ($Name) { $Name -join ', ' } else { '(all)' })$(if ($Exclude) { ' | exclude = ' + ($Exclude -join ', ') })$(if ($IncludeFolder) { ' | folders = ' + ($IncludeFolder -join ', ') })$(if ($List) { ' | list only' })"

$FabPath = (Get-Command fab -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $FabPath) {
    Write-ExportLog "Fabric CLI (fab) was not found. Install it with: pip install ms-fabric-cli (then reopen the terminal)." "ERROR"
    exit 2
}

try {
    Write-ExportLog "Fabric CLI  : $((Invoke-Fab @('--version')).Split([Environment]::NewLine)[0].Trim())"
    $AuthStatus = Invoke-Fab @("auth", "status")
}
catch {
    Write-ExportLog "Fabric CLI could not be started: $($_.Exception.Message)" "ERROR"
    exit 2
}

if ($AuthStatus -match "Logged In:\s*False") {
    Write-ExportLog "Not signed in to Fabric CLI. Run 'fab auth login' first." "ERROR"
    exit 2
}
if ($AuthStatus -match "Account:\s*(\S+)") { Write-ExportLog "Signed in as: $($Matches[1])" }

$SelectedTotal = 0
$Excludes      = @($Exclude | Where-Object { $_ })
if (-not $IncludeUsageMetrics) { $Excludes += $UsageMetricsItems }

foreach ($WorkspaceName in $Workspace) {
    $Suffixes = @(".Workspace", ".Personal")
    if ($WorkspaceName -match '\.(Workspace|Personal)$') { $Suffixes = @(".$($Matches[1])") }
    $WorkspaceName   = $WorkspaceName -replace '\.(Workspace|Personal)$', ''
    $WorkspaceFolder = Join-Path $ExportRoot (Get-SafeFileName $WorkspaceName)
    $WorkspaceId     = $null
    Write-ExportLog "------------------------------------------------------------"
    Write-ExportLog "Workspace: $WorkspaceName"

    try {
        $WorkspaceId = Get-WorkspaceId $WorkspaceName $Suffixes
        if ($WorkspaceId -notmatch '^[0-9a-fA-F-]{36}$') { throw "Unexpected workspace ID: '$WorkspaceId'" }
        Write-ExportLog "Workspace ID: $WorkspaceId"

        # Locations to export: the workspace root, plus the folders requested with -IncludeFolder.
        $Scopes = @(@{ Label = $WorkspaceName; FolderId = $null; Output = $WorkspaceFolder })

        $Requested = @(Get-IncludedFolder $WorkspaceName)
        if ($Requested) {
            $Folders = @(Get-PagedList "workspaces/$WorkspaceId/folders" "")

            foreach ($Request in $Requested) {
                $Folder = $Folders | Where-Object { $_.displayName -eq $Request.Name -and -not $_.parentFolderId } | Select-Object -First 1
                if ($Folder) {
                    $Scopes += @{ Label = "$WorkspaceName/$($Request.Name)"; FolderId = $Folder.id; Output = Join-Path $WorkspaceFolder (Get-SafeFileName $Request.Name) }
                }
                elseif ($Request.Explicit) {
                    Write-ExportLog "Folder not found at the workspace root: $WorkspaceName/$($Request.Name)" "ERROR"
                    Add-Result $WorkspaceName @{ displayName = $Request.Name; type = "Folder"; id = $null } "Failed" "" "Folder not found at the workspace root." 0
                }
            }
        }

        foreach ($Scope in $Scopes) {
            $Scope.Items    = @(Get-FolderContent $WorkspaceId $Scope.FolderId)
            $Scope.Selected = @($Scope.Items | Where-Object { Test-Selected $_ $Type $Name $Excludes } | Sort-Object type, displayName)
            $SelectedTotal += $Scope.Selected.Count

            Write-ExportLog ("Location: {0} | selected: {1} Report, {2} SemanticModel, {3} PaginatedReport ({4} items in this location)" -f $Scope.Label,
                @($Scope.Selected | Where-Object type -eq "Report").Count, @($Scope.Selected | Where-Object type -eq "SemanticModel").Count,
                @($Scope.Selected | Where-Object type -eq "PaginatedReport").Count, $Scope.Items.Count)

            if ($List) {
                Write-Host ($Scope.Selected | Format-Table @{ n = "Type"; e = { $_.type } }, @{ n = "Name"; e = { $_.displayName } }, @{ n = "Id"; e = { $_.id } } -AutoSize | Out-String -Width 250)
            }
        }

        if ($List) { continue }

        # All models of the exported locations are candidates for report -> model matching.
        $CandidateModels = @($Scopes | ForEach-Object { $_.Items } | Where-Object type -eq "SemanticModel")

        if (@($Scopes | ForEach-Object { $_.Selected }).Count -eq 0) {
            Write-ExportLog "Nothing in this workspace matches the filter. To see the item names: -Workspace `"$WorkspaceName`" -List" "WARNING"
            continue
        }

        foreach ($Scope in $Scopes) {
            foreach ($Entry in @($Scope.Selected | Where-Object type -eq "Report")) {
                $Target = Join-ChildPath @($Scope.Output, "PBIP", (Get-TargetName $Entry $Scope.Items))
                Export-Item $Scope.Label $WorkspaceId $Entry $Target $CandidateModels
            }

            foreach ($Entry in @($Scope.Selected | Where-Object type -eq "PaginatedReport")) {
                $Target = Join-ChildPath @($Scope.Output, "RDL", "$(Get-TargetName $Entry $Scope.Items).rdl")
                Export-Item $Scope.Label $WorkspaceId $Entry $Target $CandidateModels
            }
        }

        # Runs after the reports of every location; models already saved inside a report project are skipped.
        foreach ($Scope in $Scopes) {
            foreach ($Entry in @($Scope.Selected | Where-Object { $_.type -eq "SemanticModel" -and -not $UsedModelIds.Contains($_.id) })) {
                $Target = Join-ChildPath @($Scope.Output, "PBIP", "_StandaloneSemanticModels", "$(Get-TargetName $Entry $Scope.Items).SemanticModel")
                Export-Item $Scope.Label $WorkspaceId $Entry $Target $CandidateModels
            }
        }

        $Done = @($Results | Where-Object { $_.Location -eq $WorkspaceName -or $_.Location -like "$WorkspaceName/*" })
        Write-ExportLog ("Workspace done: {0} | succeeded: {1}, failed: {2}" -f $WorkspaceName,
            @($Done | Where-Object Status -eq "Success").Count, @($Done | Where-Object Status -eq "Failed").Count)
    }
    catch {
        Write-ExportLog "Workspace failed: $WorkspaceName | $($_.Exception.Message)" "ERROR"
        Add-Result $WorkspaceName @{ displayName = ""; type = "Workspace"; id = $WorkspaceId } "Failed" $WorkspaceFolder $_.Exception.Message 0
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if ($Name -and $SelectedTotal -eq 0) {
    Write-ExportLog "No item named '$($Name -join ', ')' was found in the selected workspaces. Check the names with -List." "ERROR"
    exit 1
}

$Failed = @($Results | Where-Object Status -eq "Failed")

# A workspace or folder that could not be listed is a failure in a dry run too.
if ($List) {
    if ($Failed.Count -gt 0) { exit 1 }
    exit 0
}

if ($Results.Count -gt 0) {
    # UTF-8 with BOM so Excel shows non-ASCII characters correctly ("UTF8" has no BOM in PowerShell 7).
    $CsvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    $Results | Export-Csv -LiteralPath $CsvFile -NoTypeInformation -Encoding $CsvEncoding
}

$Warnings = @($Results | Where-Object { $_.Status -eq "Success" -and $_.Message -like "WARNING:*" })

Write-ExportLog "============================================================"
Write-ExportLog ("Done. Succeeded: {0} (with warning: {1}), failed: {2}, duration: {3:hh\:mm\:ss}" -f
    ($Results.Count - $Failed.Count), $Warnings.Count, $Failed.Count, ((Get-Date) - $RunStart))

foreach ($Row in $Failed) {
    Write-ExportLog "  FAILED | $($Row.Location) / $($Row.ItemName) [$($Row.ItemType)] | $($Row.Message)" "ERROR"
}

Write-ExportLog "Log: $LogFile"
if ($Results.Count -gt 0) { Write-ExportLog "CSV: $CsvFile" }

# Non-zero exit code so scheduled tasks can detect failures.
if ($Failed.Count -gt 0) { exit 1 }
