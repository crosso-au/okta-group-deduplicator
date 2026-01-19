<#
.SYNOPSIS
  Okta Group Duplicate Finder + Safe Deleter (two-phase) with near-duplicate detection

DESCRIPTION
  Phase 1 (CSV does not exist):
    - Lists groups with expand=stats (fast user count without per-group member calls)
    - Detects exact duplicates (NormalizedName) and near duplicates (CanonicalKey)
    - Writes CSV report for review
      Exact duplicates are marked KEEP or DELETE
      Near duplicates are marked REVIEW (safe default)

  Phase 2 (CSV exists):
    - Prompts for confirmation
    - Deletes groups marked SuggestedAction=DELETE
    - Respects rate limits, retries on 429
    - Writes deletion and failure report CSVs + logs to file + console

NOTES
  - Adds -UseBasicParsing automatically on Windows PowerShell 5.1
  - Forces array context to avoid StrictMode Count issues
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$OktaDomain,

  [Parameter(Mandatory=$false)]
  [string]$ApiToken,

  [Parameter(Mandatory=$false)]
  [string]$CsvPath = ".\okta-duplicate-groups.csv",

  [Parameter(Mandatory=$false)]
  [string]$LogPath = ".\okta-duplicate-groups.log",

  [Parameter(Mandatory=$false)]
  [switch]$IncludeAppGroups,

  [Parameter(Mandatory=$false)]
  [switch]$DryRun,

  [Parameter(Mandatory=$false)]
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [ValidateSet("INFO","WARN","ERROR","DEBUG")][string]$Level = "INFO"
  )
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
  $line = "$ts [$Level] $Message"
  Write-Host $line
  Add-Content -Path $LogPath -Value $line
}

function Normalize-OktaDomain {
  param([string]$Domain)
  $d = $Domain.Trim()
  if (-not ($d.StartsWith("https://") -or $d.StartsWith("http://"))) { $d = "https://$d" }
  if ($d.EndsWith("/")) { $d = $d.TrimEnd("/") }
  return $d
}

function Is-WindowsPowerShell51 {
  try { return ($PSVersionTable.PSEdition -eq "Desktop") } catch { return $true }
}

function Get-NextLink {
  param([string[]]$LinkHeaderValues)

  if (-not $LinkHeaderValues) { return $null }

  foreach ($lh in $LinkHeaderValues) {
    $parts = $lh -split ","
    foreach ($p in $parts) {
      $m = [regex]::Match($p, '<([^>]+)>\s*;\s*rel="next"')
      if ($m.Success) { return $m.Groups[1].Value }
    }
  }
  return $null
}

function Get-ResetSleepSeconds {
  param(
    [Parameter(Mandatory=$false)][hashtable]$Headers,
    [int]$FloorSeconds = 1
  )

  if (-not $Headers) { return $FloorSeconds }

  $reset = $null
  if ($Headers.ContainsKey("X-Rate-Limit-Reset")) { $reset = $Headers["X-Rate-Limit-Reset"] | Select-Object -First 1 }
  elseif ($Headers.ContainsKey("x-rate-limit-reset")) { $reset = $Headers["x-rate-limit-reset"] | Select-Object -First 1 }

  if ($reset) {
    $epoch = [double]$reset
    $nowEpoch = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $delta = [math]::Ceiling($epoch - $nowEpoch + 1)
    if ($delta -lt $FloorSeconds) { return $FloorSeconds }
    return [int]$delta
  }

  $ra = $null
  if ($Headers.ContainsKey("Retry-After")) { $ra = $Headers["Retry-After"] | Select-Object -First 1 }
  elseif ($Headers.ContainsKey("retry-after")) { $ra = $Headers["retry-after"] | Select-Object -First 1 }

  if ($ra) {
    $sec = [int]$ra
    if ($sec -lt $FloorSeconds) { return $FloorSeconds }
    return $sec
  }

  return $FloorSeconds
}

function Maybe-Throttle {
  param(
    [Parameter(Mandatory=$false)][hashtable]$Headers,
    [int]$LowRemainingThreshold = 5
  )

  if (-not $Headers) { return }

  $remaining = $null
  if ($Headers.ContainsKey("X-Rate-Limit-Remaining")) { $remaining = $Headers["X-Rate-Limit-Remaining"] | Select-Object -First 1 }
  elseif ($Headers.ContainsKey("x-rate-limit-remaining")) { $remaining = $Headers["x-rate-limit-remaining"] | Select-Object -First 1 }

  if ($remaining -ne $null) {
    $remInt = [int]$remaining
    if ($remInt -le $LowRemainingThreshold) {
      $sleep = Get-ResetSleepSeconds -Headers $Headers -FloorSeconds 1
      Write-Log "Rate limit remaining is low ($remInt). Sleeping $sleep seconds until reset." "WARN"
      Start-Sleep -Seconds $sleep
    }
  }
}

function Invoke-OktaRequest {
  param(
    [Parameter(Mandatory=$true)][ValidateSet("GET","POST","PUT","DELETE")][string]$Method,
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$false)][object]$Body,
    [int]$MaxRetries = 8
  )

  $headers = @{
    "Authorization" = "SSWS $ApiToken"
    "Accept"        = "application/json"
  }

  $attempt = 0
  $backoff = 1
  $useBasicParsing = Is-WindowsPowerShell51

  while ($true) {
    $attempt++
    try {
      Write-Log "$Method $Url (attempt $attempt)" "DEBUG"

      $iwrParams = @{
        Method      = $Method
        Uri         = $Url
        Headers     = $headers
        ErrorAction = "Stop"
      }

      if ($Body -ne $null) {
        $headers["Content-Type"] = "application/json"
        $iwrParams["Body"] = ($Body | ConvertTo-Json -Depth 20)
      }

      if ($useBasicParsing) { $resp = Invoke-WebRequest @iwrParams -UseBasicParsing }
      else { $resp = Invoke-WebRequest @iwrParams }

      Maybe-Throttle -Headers $resp.Headers

      $content = $null
      if ($resp.Content -and $resp.Content.Trim().Length -gt 0) {
        $content = $resp.Content | ConvertFrom-Json -ErrorAction Stop
      }

      return [pscustomobject]@{
        StatusCode = [int]$resp.StatusCode
        Headers    = $resp.Headers
        Content    = $content
      }
    }
    catch {
      $ex = $_.Exception
      $resp = $null
      if ($ex.Response) { $resp = $ex.Response }

      $statusCode = $null
      $respHeaders = $null
      try {
        if ($resp) {
          $statusCode = [int]$resp.StatusCode
          $respHeaders = @{}
          foreach ($k in $resp.Headers.Keys) { $respHeaders[$k] = $resp.Headers[$k] }
        }
      } catch { }

      if ($statusCode -eq 429) {
        if ($attempt -gt $MaxRetries) {
          Write-Log "429 Too Many Requests: max retries exceeded for $Method $Url" "ERROR"
          throw
        }
        $sleep = Get-ResetSleepSeconds -Headers $respHeaders -FloorSeconds $backoff
        Write-Log "429 Too Many Requests. Sleeping $sleep seconds, then retrying." "WARN"
        Start-Sleep -Seconds $sleep
        $backoff = [math]::Min($backoff * 2, 30)
        continue
      }

      if ($attempt -gt $MaxRetries) {
        Write-Log "Request failed after $MaxRetries retries: $Method $Url. Error: $($_.Exception.Message)" "ERROR"
        throw
      }

      if ($statusCode -ge 500 -or $statusCode -eq $null) {
        Write-Log "Transient error (status $statusCode). Sleeping $backoff seconds, then retrying. Error: $($_.Exception.Message)" "WARN"
        Start-Sleep -Seconds $backoff
        $backoff = [math]::Min($backoff * 2, 30)
        continue
      }

      Write-Log "Non-retryable error (status $statusCode) for $Method $Url. Error: $($_.Exception.Message)" "ERROR"
      throw
    }
  }
}

function Get-AllOktaGroups {
  param(
    [string]$BaseUrl,
    [int]$Limit = 200
  )

  $groups = New-Object System.Collections.Generic.List[object]

  $filter = $null
  if (-not $IncludeAppGroups) {
    $filter = [uri]::EscapeDataString('type eq "OKTA_GROUP"')
  }

  $url = "$BaseUrl/api/v1/groups?limit=$Limit&expand=stats"
  if ($filter) { $url = "$url&filter=$filter" }

  while ($true) {
    $r = Invoke-OktaRequest -Method "GET" -Url $url

    $page = @($r.Content)
    if ($page.Count -eq 0) { break }

    foreach ($g in $page) { $groups.Add($g) }

    $next = Get-NextLink -LinkHeaderValues $r.Headers["Link"]
    if (-not $next) { break }

    $url = $next
  }

  return $groups
}

function Get-NormalizedName {
  param([Parameter(Mandatory=$true)][string]$Name)
  return ($Name.Trim()).ToLowerInvariant()
}

function Get-CanonicalKey {
  param([Parameter(Mandatory=$true)][string]$Name)

  $s = $Name.ToLowerInvariant().Trim()

  # unify common separators
  $s = $s -replace '[_\-]+', ' '
  $s = $s -replace '\s+', ' '

  # remove common duplicate/copy suffix patterns (iteratively)
  # Examples:
  # group1, group2
  # finance 1
  # finance (1)
  # finance [1]
  # finance - 1
  # finance copy
  # finance copy 1
  # finance (copy 1)
  # finance duplicate
  # finance dup
  # finance clone
  # finance backup
  # finance test
  $patterns = @(
    '(?<=\p{L})\d{1,3}\s*$',                 # group1, finance2 (letters + 1-3 trailing digits)
    '\s*\(\s*\d+\s*\)\s*$',                  # (1)
    '\s*\[\s*\d+\s*\]\s*$',                  # [1]
    '\s+\d+\s*$',                            # 1
    '\s*[-]\s*\d+\s*$',                      # - 1
    '\s*(?:\(|\[)?\s*(copy|duplicate|dup|clone|backup|test)\s*(?:\d+)?\s*(?:\)|\])?\s*$',
    '\s*(copy|duplicate|dup|clone|backup|test)\s*$',
    '\s*(copy|duplicate|dup|clone|backup|test)\s+\d+\s*$'
  )

  $changed = $true
  while ($changed) {
    $before = $s
    foreach ($p in $patterns) {
      $s = [regex]::Replace($s, $p, '', 'IgnoreCase')
      $s = $s.Trim()
      $s = $s -replace '\s+', ' '
    }
    $changed = ($s -ne $before)
  }

  return $s
}


function Build-DuplicateReport {
  param([object[]]$Groups)

  $rows = foreach ($g in $Groups) {
    $name = $g.profile.name
    if ($null -eq $name) { continue }

    $nameStr = [string]$name
    $normalized = Get-NormalizedName -Name $nameStr
    $canonical  = Get-CanonicalKey -Name $nameStr

    $usersCount = $null
    try { $usersCount = [int]$g._embedded.stats.usersCount } catch { $usersCount = $null }

    [pscustomobject]@{
      GroupName       = $nameStr
      GroupId         = $g.id
      GroupType       = $g.type
      UsersCount      = $usersCount
      Created         = $g.created
      LastUpdated     = $g.lastUpdated

      NormalizedName  = $normalized
      CanonicalKey    = $canonical

      DuplicateMode   = ""   # EXACT or NEAR
      SuggestedAction = ""   # KEEP, DELETE, REVIEW
      DuplicateSetKey = ""   # key used for grouping (NormalizedName or CanonicalKey)
      DuplicateSetSize= 0
      Notes           = ""
    }
  }

  $out = New-Object System.Collections.Generic.List[object]

  # 1) EXACT duplicates (NormalizedName)
  $exactSets = @(
    $rows | Group-Object -Property NormalizedName | Where-Object { $_.Count -gt 1 }
  )

  foreach ($set in $exactSets) {
    $items = @($set.Group) | Sort-Object { [DateTime]$_.Created }, GroupId
    $keep = $items[0]

    foreach ($it in $items) {
      $it.DuplicateMode = "EXACT"
      $it.DuplicateSetKey = $set.Name
      $it.DuplicateSetSize = $set.Count

      if ($it.GroupId -eq $keep.GroupId) {
        $it.SuggestedAction = "KEEP"
        $it.Notes = "Exact duplicate by name (normalized). Oldest created in set."
      } else {
        $it.SuggestedAction = "DELETE"
        $it.Notes = "Exact duplicate by name (normalized)."
      }
      $out.Add($it) | Out-Null
    }
  }

  # Track which IDs already handled by exact logic
  $exactIds = @{}
  foreach ($r in @($out.ToArray())) { $exactIds[$r.GroupId] = $true }

  # 2) NEAR duplicates (CanonicalKey), excluding anything already in exact sets
  $nearCandidates = @(
    $rows | Where-Object { -not $exactIds.ContainsKey($_.GroupId) }
  )

  $nearSets = @(
    $nearCandidates | Group-Object -Property CanonicalKey | Where-Object { $_.Count -gt 1 -and $_.Name -ne "" }
  )

  foreach ($set in $nearSets) {
    $items = @($set.Group) | Sort-Object { [DateTime]$_.Created }, GroupId
    $keep = $items[0]

    foreach ($it in $items) {
      $it.DuplicateMode = "NEAR"
      $it.DuplicateSetKey = $set.Name
      $it.DuplicateSetSize = $set.Count

      if ($it.GroupId -eq $keep.GroupId) {
        $it.SuggestedAction = "KEEP"
        $it.Notes = "Near-duplicate candidate by canonical rules. Oldest created in set."
      } else {
        $it.SuggestedAction = "REVIEW"
        $it.Notes = "Near-duplicate candidate by canonical rules. Review before setting DELETE."
      }
      $out.Add($it) | Out-Null
    }
  }

  return @($out.ToArray())
}

# ----------------- Main -----------------
$OktaDomain = Normalize-OktaDomain -Domain $OktaDomain
if (-not $ApiToken) { $ApiToken = $env:OKTA_API_TOKEN }
if (-not $ApiToken) { throw "ApiToken not provided. Pass -ApiToken or set env var OKTA_API_TOKEN." }

"==== $(Get-Date -Format o) START ====" | Out-File -FilePath $LogPath -Encoding utf8
Write-Log "OktaDomain: $OktaDomain" "INFO"
Write-Log "CSV Path : $CsvPath" "INFO"
Write-Log "Log Path : $LogPath" "INFO"
Write-Log "IncludeAppGroups: $IncludeAppGroups" "INFO"
Write-Log "DryRun: $DryRun" "INFO"
Write-Log ("PowerShell Edition: {0}, Version: {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion) "INFO"

if (-not (Test-Path -Path $CsvPath)) {
  Write-Log "CSV not found. Running discovery scan to find duplicate and near-duplicate groups by name." "INFO"

  $allGroups = Get-AllOktaGroups -BaseUrl $OktaDomain -Limit 200
  Write-Log ("Fetched {0} groups total." -f $allGroups.Count) "INFO"

  $report = @(
    Build-DuplicateReport -Groups $allGroups
  )

  Write-Log ("Found {0} groups in duplicate sets (exact and near)." -f $report.Count) "INFO"

  if ($report.Count -eq 0) {
    Write-Log "No duplicates found by exact or near-duplicate rules. Exiting." "INFO"
    Write-Host ""
    Write-Host "No duplicate or near-duplicate group names found. Nothing written."
    exit 0
  }

  $report |
    Sort-Object DuplicateMode, DuplicateSetKey, SuggestedAction, Created |
    Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

  $exactSummary = @(
    $report | Where-Object { $_.DuplicateMode -eq "EXACT" } | Group-Object DuplicateSetKey | Sort-Object Count -Descending
  )
  $nearSummary = @(
    $report | Where-Object { $_.DuplicateMode -eq "NEAR" } | Group-Object DuplicateSetKey | Sort-Object Count -Descending
  )

  Write-Log "Top EXACT duplicate sets (by count):" "INFO"
  foreach ($s in ($exactSummary | Select-Object -First 10)) {
    Write-Log ("  {0} -> {1} groups" -f $s.Name, $s.Count) "INFO"
  }

  Write-Log "Top NEAR duplicate sets (by count):" "INFO"
  foreach ($s in ($nearSummary | Select-Object -First 10)) {
    Write-Log ("  {0} -> {1} groups" -f $s.Name, $s.Count) "INFO"
  }

  Write-Host ""
  Write-Host "Wrote report to: $CsvPath"
  Write-Host "Exact duplicates are pre-marked DELETE (except oldest KEEP)."
  Write-Host "Near duplicates are marked REVIEW by default. Change to DELETE if you confirm they are duplicates."
  Write-Host "When ready, run the same script again to perform deletions."
  exit 0
}

Write-Log "CSV exists. Entering delete phase." "INFO"

$csv = @(Import-Csv -Path $CsvPath)
if ($csv.Count -eq 0) { throw "CSV exists but is empty: $CsvPath" }

$toDelete = @(
  $csv | Where-Object { $_.SuggestedAction -eq "DELETE" }
)

Write-Log ("CSV rows: {0}. Rows marked DELETE: {1}." -f $csv.Count, $toDelete.Count) "INFO"

if ($toDelete.Count -eq 0) {
  Write-Log "No rows marked DELETE. Nothing to do." "WARN"
  Write-Host ""
  Write-Host "No groups marked DELETE in the CSV. Exiting."
  exit 0
}

Write-Host ""
Write-Host "About to delete $($toDelete.Count) Okta groups listed in: $CsvPath"
Write-Host "DryRun is $DryRun"
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host 'Type DELETE to proceed (anything else will cancel)'
  if ($confirm -ne "DELETE") {
    Write-Log "User cancelled deletion step." "WARN"
    Write-Host "Cancelled. No changes made."
    exit 0
  }
} else {
  Write-Log "Force enabled. Skipping typed confirmation." "WARN"
}

$deleted = New-Object System.Collections.Generic.List[object]
$failed  = New-Object System.Collections.Generic.List[object]

foreach ($row in $toDelete) {
  $gid = $row.GroupId
  $gname = $row.GroupName

  if (-not $gid) {
    Write-Log "Skipping row with missing GroupId (GroupName=$gname)." "ERROR"
    $failed.Add([pscustomobject]@{ GroupName=$gname; GroupId=$gid; Reason="Missing GroupId" }) | Out-Null
    continue
  }

  if ($DryRun) {
    Write-Log "DRYRUN: Would delete group '$gname' ($gid)" "INFO"
    $deleted.Add([pscustomobject]@{ GroupName=$gname; GroupId=$gid; DryRun=$true }) | Out-Null
    continue
  }

  try {
    $url = "$OktaDomain/api/v1/groups/$gid"
    $r = Invoke-OktaRequest -Method "DELETE" -Url $url
    Write-Log "Deleted group '$gname' ($gid). Status=$($r.StatusCode)" "INFO"
    $deleted.Add([pscustomobject]@{ GroupName=$gname; GroupId=$gid; Status=$r.StatusCode; DryRun=$false }) | Out-Null
  }
  catch {
    $msg = $_.Exception.Message
    Write-Log "FAILED deleting group '$gname' ($gid). Error: $msg" "ERROR"
    $failed.Add([pscustomobject]@{ GroupName=$gname; GroupId=$gid; Reason=$msg }) | Out-Null
  }
}

$deletedReportPath = [System.IO.Path]::ChangeExtension($CsvPath, ".deleted.csv")
$failedReportPath  = [System.IO.Path]::ChangeExtension($CsvPath, ".failed.csv")

$deleted | Export-Csv -Path $deletedReportPath -NoTypeInformation -Encoding UTF8
$failed  | Export-Csv -Path $failedReportPath  -NoTypeInformation -Encoding UTF8

Write-Log "Deletion report written to: $deletedReportPath" "INFO"
Write-Log "Failure report written to : $failedReportPath" "INFO"

Write-Host ""
Write-Host "Completed."
Write-Host "Deleted: $($deleted.Count)"
Write-Host "Failed : $($failed.Count)"
Write-Host ""
Write-Host "Deleted report: $deletedReportPath"
Write-Host "Failed report : $failedReportPath"
Write-Host "Log file      : $LogPath"

Write-Log "==== $(Get-Date -Format o) END ====" "INFO"
