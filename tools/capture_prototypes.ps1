# capture_prototypes.ps1 — the prototype side of the parity review.
#
# Screenshots the HTML prototypes in headless Microsoft Edge, one PNG per named state, so each
# can be set beside the matching fixture capture from `capture_screenshots.ps1` (same names
# where a fixture exists). The states use the prototypes' review controls: the hash picks a
# view, query parameters seed the rest (`?holdings=collapsed`, `?modal=merchant`, `?screen=`).
#
# Usage (from the repo root):
#   powershell -ExecutionPolicy Bypass -File tools/capture_prototypes.ps1
#   powershell -ExecutionPolicy Bypass -File tools/capture_prototypes.ps1 -Only act_one_trade,act_one_menu
#
# Requires: Windows with Microsoft Edge installed.

param(
    [string[]] $Only = @(),
    [string] $OutDir = "docs/screenshots/prototypes",
    [int] $Width = 900,
    [int] $Height = 820,
    [int] $BudgetMs = 4000,
    [string] $Edge = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not $Edge) {
    $Edge = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Edge) { Write-Error "Microsoft Edge not found; pass -Edge <path to msedge.exe>." }

# Named prototype states, keyed like the fixtures they are compared against.
$matrix = [ordered]@{
    "act_one_default"    = "act-i.html#actions"
    "act_one_build"      = "act-i.html#build"
    "act_one_actions_generators" = "act-i.html?kind=generator#actions"
    "act_one_collapsed"  = "act-i.html?holdings=collapsed#actions"
    "act_one_trade"      = "act-i.html?modal=merchant#actions"
    "act_two_actions"    = "act-ii.html#actions"
    "act_two_build"      = "act-ii.html#build"
    "act_two_actions_hidden" = "act-ii.html?hidden=Draw%20water,Garden%20bed&showhidden=1#actions"
    "act_two_research"   = "act-ii.html#research"
    "act_one_shelter_busy" = "act-i.html?shelter=busy&shelteropen=1#build"
    "act_one_shelter_building" = "act-i.html?shelter=building&shelteropen=1#build"
    "act_one_shelter_building_closed" = "act-i.html?shelter=building#build"
    "act_two_exchange"   = "act-ii.html?exchangeopen=1#build"
    "act_two_market"     = "act-ii.html#market"
    "act_two_trade"      = "act-ii.html?modal=merchant#actions"
    "act_one_menu"       = "menu.html"
    "menu_save"          = "menu.html?screen=save"
    "menu_settings"      = "menu.html?screen=settings"
    "menu_quit"          = "menu.html?screen=quit"
    "title"              = "title.html"
    "title_settings"     = "title.html?screen=settings"
    "title_credits"      = "title.html?screen=credits"
    "market_stall"       = "market.html?stall=1"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = Resolve-Path -LiteralPath $OutDir
$base = "file:///" + ((Resolve-Path "prototypes").Path -replace '\\', '/')

$names = if ($Only.Count -gt 0) { $Only } else { $matrix.Keys }
foreach ($name in $names) {
    if (-not $matrix.Contains($name)) { Write-Warning "unknown state '$name' (skipped)"; continue }
    $png = Join-Path $out "$name.png"
    $url = "$base/$($matrix[$name])"
    # Edge reports "bytes written" on stderr; under Windows PowerShell that is an error record,
    # so the call runs with errors continuing and success is judged by the file.
    $ErrorActionPreference = "Continue"
    & $Edge --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files `
        "--window-size=$Width,$Height" "--virtual-time-budget=$BudgetMs" "--screenshot=$png" $url 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    if (Test-Path $png) { Write-Host "  $name -> $png" } else { Write-Warning "  $name produced no image" }
}
Write-Host "`nDone. Prototype PNGs in $OutDir."
