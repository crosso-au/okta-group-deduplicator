# Okta Group Duplicate Cleanup Script
[![github](https://img.shields.io/badge/CrossboxLabs%20|%20crosso_au-8A2BE2)](https://github.com/crosso-au/) 

A safe, two-phase PowerShell script to identify and clean up duplicate and near-duplicate Okta groups at scale.

This tool is designed for real-world Okta tenants where accidental group sprawl has occurred, including:
- Exact duplicate group names
- Copy-style variants
- Numbered variants like group1, group2, group3
- Mixed separators and casing differences

The script is deliberately conservative and review-first to avoid accidental data loss.

## What This Script Does

The script operates in two explicit phases.

Phase 1 scans your Okta tenant, identifies duplicate and near-duplicate groups, and produces a CSV report for human review.

Phase 2 reads the CSV and deletes only the groups you have explicitly approved for deletion.

No deletion ever happens automatically on first run.

## How Duplicate Detection Works

The script uses two layers of logic.

### Exact Duplicates

Exact duplicates are detected by comparing a normalized version of the group name.

Normalization rules:
- Trim leading and trailing whitespace
- Convert to lowercase

Examples considered exact duplicates:
- Finance
- finance
- Finance  

If multiple groups share the same normalized name:
- The oldest-created group is marked KEEP
- All others are marked DELETE

### Near Duplicates

Near duplicates are detected using a canonical key derived from the group name.

Canonicalization rules include:
- Lowercasing and trimming
- Converting underscores and hyphens to spaces
- Collapsing repeated spaces
- Removing common duplicate suffixes
- Removing trailing numeric variants, including attached digits like group1

Examples grouped together as near duplicates:
- Finance
- Finance (1)
- Finance - Copy
- Finance_copy
- Finance2
- Finance 3
- group1
- group2
- group3

Near duplicates are intentionally marked REVIEW by default, not DELETE.

This ensures you explicitly confirm intent before any deletion occurs.

## Safety Model

This script is designed to be safe by default.

Key safety characteristics:
- No deletion on first run
- CSV-based human approval gate
- Explicit DELETE keyword confirmation
- Near duplicates never auto-deleted
- Rate-limit aware API calls with retry and backoff
- Full logging of all actions
- Dry-run support

## Prerequisites

- PowerShell 5.1 or later
- Okta API token with permission to list and delete groups
- Network access to the Okta API

The script automatically adapts behavior for:
- Windows PowerShell 5.1
- PowerShell 7+

## Installation

Clone or download the script into a working directory.

Ensure the script file name is:
OktaGroupDedupe.ps1

## Parameters

This script supports the following parameters.

### OktaDomain

Required.

Your Okta domain, including scheme.

Valid examples:
- https://yourorg.okta.com
- https://login.yourcompany.com

Example:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN"
```

### ApiToken

Optional, but strongly recommended to pass explicitly.

Okta API token used for authentication.

If omitted, the script reads the token from the environment variable OKTA_API_TOKEN.

Example passing token inline:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN"
```

Example using environment variable:
```
$env:OKTA_API_TOKEN="YOUR_API_TOKEN"
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com"
```

### CsvPath

Optional.

Path to the CSV report file.

Default:
- .\okta-duplicate-groups.csv

Example:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -CsvPath ".\reports\groups.csv"
```

### LogPath

Optional.

Path to the log file.

Default:
- .\okta-duplicate-groups.log

Example:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -LogPath ".\logs\run.log"
```

### IncludeAppGroups

Optional switch.

When set, the discovery phase includes app-managed groups in addition to OKTA_GROUP.

Default:
- False (only OKTA_GROUP)

Example:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -IncludeAppGroups
```

### DryRun

Optional switch.

Applies only during Phase 2 (delete phase).

When set:
- No groups are deleted
- The script logs what would be deleted
- Deletion reports are still produced

Example:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -DryRun
```

### Force

Optional switch.

Skips the typed DELETE confirmation prompt in Phase 2.

This does not bypass the CSV approval gate. Only rows marked DELETE are processed.

Example:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -Force
```

## Usage Overview

The script is always run the same way.

Its behavior changes based on whether the CSV file exists.

If the CSV file does not exist:
- Phase 1 runs
- A report is generated
- No groups are deleted

If the CSV file exists:
- Phase 2 runs
- Groups marked DELETE are deleted
- A deletion report is produced

## Phase 1: Discovery and Report Generation

Run the script when no CSV exists.

Minimal example:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN"
```

Discovery with custom output paths:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -CsvPath ".\reports\okta-groups.csv" -LogPath ".\logs\okta-groups.log"
```

Discovery including app-managed groups:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -IncludeAppGroups
```

What happens:
- All groups are retrieved from Okta
- Exact and near duplicates are detected
- A CSV report is generated
- No changes are made to Okta

Output files:
- okta-duplicate-groups.csv
- okta-duplicate-groups.log

## Reviewing the CSV

The CSV contains one row per group involved in a duplicate set.

Key columns:
- GroupName
- GroupId
- GroupType
- UsersCount
- Created
- NormalizedName
- CanonicalKey
- DuplicateMode
- SuggestedAction
- DuplicateSetKey
- DuplicateSetSize
- Notes

SuggestedAction values:
- KEEP means this group should be retained
- DELETE means safe to delete based on exact duplicate logic
- REVIEW means near duplicate requiring human judgement

Recommended workflow:
- Filter DuplicateMode = EXACT and verify the KEEP entry matches the group you expect to retain
- Review DuplicateMode = NEAR sets and decide which entries should be deleted
- Change SuggestedAction from REVIEW to DELETE only when you are confident

Important:
- Only rows with SuggestedAction = DELETE will be deleted in Phase 2

## Phase 2: Deletion

Once you are satisfied with the CSV, run the script again.

Minimal example:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN"
```

Delete using CSV and log in custom locations:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -CsvPath ".\reports\okta-groups.csv" -LogPath ".\logs\okta-groups.log"
```

Dry-run delete:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -DryRun
```

Delete without interactive prompt:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -Force
```

What happens:
- The CSV is read
- Only rows marked DELETE are processed
- You must type DELETE to confirm, unless Force is set
- Groups are deleted one by one with rate-limit handling

Output files:
- okta-duplicate-groups.deleted.csv
- okta-duplicate-groups.failed.csv
- okta-duplicate-groups.log

## Output Files

### okta-duplicate-groups.csv

Generated during Phase 1.

Contains:
- duplicate detection results
- suggested actions
- metadata required for deletion

### okta-duplicate-groups.deleted.csv

Generated during Phase 2.

Contains:
- each group successfully deleted
- group name and id
- HTTP status if captured

### okta-duplicate-groups.failed.csv

Generated during Phase 2.

Contains:
- each group that failed to delete
- group name and id
- error reason

### okta-duplicate-groups.log

Generated during both phases.

Contains:
- operational trace of execution
- API calls and retry behavior
- rate-limit waits
- results and errors

## Rate Limit Handling

The script respects Okta rate limits by:
- Inspecting X-Rate-Limit-Remaining
- Sleeping until X-Rate-Limit-Reset when required
- Retrying 429 responses with exponential backoff

This allows safe execution even when deleting hundreds of groups.

## Error Handling

Errors are handled per group.

If a deletion fails:
- The error is logged
- The group is added to the failed report
- The script continues processing remaining groups

No partial failure stops the run.

## Common Scenarios

### I expected hundreds of duplicates but the report shows none

Common reasons:
- The duplicates are APP_GROUP and you did not use IncludeAppGroups
- The names differ in ways not covered by canonical rules
- You are looking at a different Okta org or custom domain

First thing to try:
```
.\OktaGroupDedupe.ps1 -OktaDomain "https://yourorg.okta.com" -ApiToken "YOUR_API_TOKEN" -IncludeAppGroups
```

### I want to delete near duplicates automatically

Not recommended.

Near duplicates are REVIEW by default for a reason.

If you want to proceed anyway, update the CSV and explicitly mark the correct rows as DELETE.

## License and Disclaimer

This script is provided as-is.

Always test in a non-production Okta tenant first.

You are responsible for validating the CSV and approving deletions.
