# claude_run.ps1 - build, test and (optionally) deploy SmartBizz, logging everything.
#
#   Right-click > "Run with PowerShell", or in PowerShell:
#     powershell -ExecutionPolicy Bypass -File .\claude_run.ps1            # check + build + deploy
#     powershell -ExecutionPolicy Bypass -File .\claude_run.ps1 -NoDeploy  # check + build only
#
# Output goes to claude_run_log.txt in this folder, which Claude reads.

param([switch]$NoDeploy)

$ErrorActionPreference = 'Continue'
Set-Location -Path $PSScriptRoot
$log = Join-Path $PSScriptRoot 'claude_run_log.txt'
if (Test-Path $log) { Remove-Item $log -Force }
Start-Transcript -Path $log | Out-Null

$flutter = 'C:\Users\santhosh\flutter\bin\flutter.bat'
if (-not (Test-Path $flutter)) { $flutter = 'flutter' }
function Step($name) { Write-Host ''; Write-Host "===== $name =====" }
$ok = @{}

Step 'git'
git -c core.autocrlf=true checkout fix/category-alignment 2>&1 | Out-Host
git log --oneline -1 2>&1 | Out-Host

Step 'flutter --version'
& $flutter --version 2>&1 | Out-Host

Step 'pub get'
& $flutter pub get 2>&1 | Out-Host
$ok.pub = ($LASTEXITCODE -eq 0)

Step 'analyze'
& $flutter analyze --no-fatal-infos 2>&1 | Out-Host
$ok.analyze = ($LASTEXITCODE -eq 0)

Step 'test'
& $flutter test 2>&1 | Out-Host
$ok.test = ($LASTEXITCODE -eq 0)

Step 'build web'
& $flutter build web --release --base-href /pos/ 2>&1 | Out-Host
$ok.build = ($LASTEXITCODE -eq 0)

if ($ok.build) {
  Step 'copy build to hosting_public\pos'
  robocopy build\web hosting_public\pos /E /NFL /NDL /NJH /NP | Out-Host
}

if ($NoDeploy) {
  Step 'deploy skipped (-NoDeploy)'
} elseif (-not $ok.build) {
  Step 'deploy skipped: build failed'
} else {
  Step 'firebase deploy (hosting only)'
  if (-not (Get-Command firebase -ErrorAction SilentlyContinue)) { npm install -g firebase-tools }
  firebase projects:list 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { firebase login }
  firebase deploy --only hosting 2>&1 | Out-Host
  $ok.deploy = ($LASTEXITCODE -eq 0)
}

Step 'SUMMARY'
$ok.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host ("{0,-8} {1}" -f $_.Name, $(if ($_.Value) { 'OK' } else { 'FAILED' })) }
Stop-Transcript | Out-Null
Write-Host "`nDone. Log saved to $log - tell Claude it has finished."
Read-Host 'Press Enter to close'
