# Assertions on an installed Windows app. Writes the same TSV rows as lib.sh.
#
# usage: win-assert.ps1 -Prefix exe -Mode installed|uninstalled [-ExpectAo yes|no]
# env:   VERSION, RESULTS, JOB_LABEL, KNOWN_ISSUES
param(
  [string]$Prefix,
  [string]$Mode = "installed",
  [string]$ExpectAo = "no"
)
$ErrorActionPreference = "Continue"
$V = $env:VERSION
$Results = $env:RESULTS
$Job = $env:JOB_LABEL
$Known = " $($env:KNOWN_ISSUES) "

function Record($id, $status, $msg) {
  if ($status -eq "FAIL" -and $Known.Contains(" $id ")) { $status = "KNOWN" }
  $msg = ($msg -replace "[`t`r`n]", " ")
  Add-Content -Path $Results -Value "$Job`t$id`t$status`t$msg" -Encoding utf8
  if ($status -eq "FAIL") { Write-Host "::error title=$id::$msg" }
  if ($status -eq "KNOWN" -or $status -eq "WARN") { Write-Host "::warning title=$id::$msg" }
  Write-Host "[$status] ${id}: $msg"
}
function Eq($id, $want, $got, $what) {
  if ("$want" -eq "$got") { Record $id PASS "$what = $got" } else { Record $id FAIL "${what}: want '$want', got '$got'" }
}

$dirs = @("$env:LOCALAPPDATA\Programs\agent-orchestrator", "$env:ProgramFiles\agent-orchestrator")
$uninstKeys = @(
  "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$entry = Get-ItemProperty $uninstKeys -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match "Orchestrator" -or $_.PSChildName -match "d06535a3" } | Select-Object -First 1
$startMenu = @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs")
$lnks = Get-ChildItem $startMenu -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "Orchestrator" }
$desk = Get-ChildItem "$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop" -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "Orchestrator" }

if ($Mode -eq "uninstalled") {
  $left = @()
  foreach ($d in $dirs) { if (Test-Path $d) { $left += $d } }
  if ($entry) { $left += "uninstall registry entry '$($entry.DisplayName)'" }
  foreach ($l in $lnks + $desk) { $left += $l.FullName }
  if ($left.Count -eq 0) { Record "${Prefix}:uninstall-clean" PASS "no install dir, registry entry or shortcut left" }
  else { Record "${Prefix}:uninstall-clean" FAIL ("left behind: " + ($left -join "; ")) }
  $data = @("$env:APPDATA\agent-orchestrator", "$env:APPDATA\Agent Orchestrator", "$env:APPDATA\Orchestrator.inc", "$env:LOCALAPPDATA\agent-orchestrator-updater", "$env:USERPROFILE\.ao") | Where-Object { Test-Path $_ }
  Record "${Prefix}:user-data-left" INFO ("user data kept after uninstall: " + ($(if ($data) { $data -join "; " } else { "none" })))
  exit 0
}

$dir = $dirs | Where-Object { Test-Path "$_\agent-orchestrator.exe" } | Select-Object -First 1
if (-not $dir) { Record "${Prefix}:app-present" FAIL "agent-orchestrator.exe not found in $($dirs -join ', ')"; exit 0 }
Record "${Prefix}:app-present" PASS $dir
$exe = "$dir\agent-orchestrator.exe"
$fv = (Get-Item $exe).VersionInfo
Eq "${Prefix}:version" $V ($fv.ProductVersion -replace '\.0$', '' -replace '^(\d+\.\d+\.\d+).*', '$1') "exe ProductVersion"
Record "${Prefix}:product-name" INFO "exe ProductName='$($fv.ProductName)' FileDescription='$($fv.FileDescription)'"

$sig = Get-AuthenticodeSignature $exe
if ($sig.Status -eq "Valid") { Record "${Prefix}:signature" PASS "Authenticode valid: $($sig.SignerCertificate.Subject)" }
else { Record "${Prefix}:signature" FAIL "Authenticode $($sig.Status): $($sig.StatusMessage)" }

if ($entry) {
  Eq "${Prefix}:display-name" "Orchestrator" $entry.DisplayName "Apps & features DisplayName"
  Eq "${Prefix}:registry-version" $V $entry.DisplayVersion "Apps & features DisplayVersion"
  Record "${Prefix}:publisher" INFO "Publisher='$($entry.Publisher)' key=$($entry.PSChildName)"
} else {
  Record "${Prefix}:display-name" FAIL "no uninstall registry entry"
}
if ($lnks) { Eq "${Prefix}:start-menu" "Orchestrator.lnk" (($lnks | Select-Object -First 1).Name) "Start menu shortcut" }
else { Record "${Prefix}:start-menu" FAIL "no Start menu shortcut" }

$ao = Get-ChildItem $dir -Recurse -Filter ao.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "daemon" } | Select-Object -First 1
$th = Join-Path $env:RUNNER_TEMP ("aohome-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $th | Out-Null
$env:AO_DATA_DIR = "$th\data"; $env:AO_RUN_FILE = "$th\run\running.json"; $env:AO_PORT = "39117"
if ($ao) {
  $out = (& $ao.FullName version 2>&1 | Select-Object -First 1)
  if ("$out" -like "$V*") { Record "${Prefix}:bundled-ao" PASS "$($ao.FullName): $out" } else { Record "${Prefix}:bundled-ao" FAIL "bundled ao: $out" }
} else {
  Record "${Prefix}:bundled-ao" FAIL "no daemon\ao.exe under $dir"
}

# A fresh shell gets PATH from the registry, not from this process.
$fresh = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$found = $null
foreach ($p in $fresh.Split(";")) {
  if (-not $p) { continue }
  foreach ($n in "ao.exe", "ao.cmd", "ao.bat", "ao.ps1") {
    $c = Join-Path ([Environment]::ExpandEnvironmentVariables($p)) $n
    if (Test-Path $c) { $found = $c; break }
  }
  if ($found) { break }
}
if ($ExpectAo -eq "yes") {
  if ($found) { Record "${Prefix}:ao-on-path" PASS $found } else { Record "${Prefix}:ao-on-path" FAIL "ao not on PATH in a fresh shell" }
} else {
  if ($found) { Record "${Prefix}:ao-on-path" INFO "found $found" } else { Record "${Prefix}:ao-on-path" FAIL "this channel leaves no ao on PATH (fresh shell)" }
}
exit 0
