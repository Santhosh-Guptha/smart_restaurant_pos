<#
.SYNOPSIS
    SmartBizz POS - Apps Script Production Deployer & Validator (PowerShell Wrapper)

.DESCRIPTION
    Automates versioning, AST syntax validation, simulator test suite,
    release bundle generation (with SHA256 checksums), clasp push, clipboard sync,
    and live web app HTTP health probing for google_apps_script/Code.gs.

.PARAMETER Version
    Explicit semantic version to assign (e.g. "2.4.0").

.PARAMETER Bump
    Automated semver bump: "patch", "minor", or "major".

.PARAMETER Tag
    Release tag identifier (e.g. "prod-2026-10-26").

.PARAMETER Notes
    Release notes or changelog entry for this deployment.

.PARAMETER DryRun
    Simulates validation and bundling without modifying live files or pushing.

.PARAMETER ClaspPush
    Attempts automated push via clasp if authenticated (~/.clasprc.json exists).

.PARAMETER CopyToClipboard
    Copies the stamped Code.gs content directly to the Windows clipboard for zero-mistake paste.

.PARAMETER SkipTests
    Skips the local environment simulator test suite (tools/test_code_gs.js).

.PARAMETER SkipProbe
    Skips the live web app HTTP health check probe.

.PARAMETER Endpoint
    Override the production Google Apps Script /exec URL.

.EXAMPLE
    .\tools\deploy_code_gs.ps1 -Bump patch -CopyToClipboard
    .\tools\deploy_code_gs.ps1 -Version 2.4.0 -Tag prod-2026-10-26
    .\tools\deploy_code_gs.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('patch', 'minor', 'major')][string]$Bump,
    [string]$Tag,
    [string]$Notes,
    [switch]$DryRun,
    [switch]$ClaspPush,
    [switch]$CopyToClipboard,
    [switch]$SkipTests,
    [switch]$SkipProbe,
    [string]$Endpoint
)

$ErrorActionPreference = "Stop"

# Ensure Node.js is available
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "[FATAL] Node.js is required but was not found in PATH."
    exit 1
}

# Resolve script paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DeployJs = Join-Path $ScriptDir "deploy_code_gs.js"

if (-not (Test-Path $DeployJs)) {
    Write-Error "[FATAL] deploy_code_gs.js not found at $DeployJs"
    exit 1
}

# Build arguments array
$nodeArgs = @($DeployJs)

if ($Version) {
    $nodeArgs += "--version"
    $nodeArgs += $Version
}
if ($Bump) {
    $nodeArgs += "--bump"
    $nodeArgs += $Bump
}
if ($Tag) {
    $nodeArgs += "--tag"
    $nodeArgs += $Tag
}
if ($Notes) {
    $nodeArgs += "--notes"
    $nodeArgs += $Notes
}
if ($DryRun) {
    $nodeArgs += "--dry-run"
}
if ($ClaspPush) {
    $nodeArgs += "--clasp-push"
}
if ($CopyToClipboard) {
    $nodeArgs += "--copy"
}
if ($SkipTests) {
    $nodeArgs += "--skip-tests"
}
if ($SkipProbe) {
    $nodeArgs += "--skip-probe"
}
if ($Endpoint) {
    $nodeArgs += "--endpoint"
    $nodeArgs += $Endpoint
}

# Execute deployment runner
& node $nodeArgs
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Host "[DEPLOY FAILED] Exit code: $exitCode" -ForegroundColor Red
}

exit $exitCode
