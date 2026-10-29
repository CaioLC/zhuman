# layout_audit.ps1 - the overflow and reachability audit over the fixture matrix (PARITY-03, QA-09).
#
# Launches the built binary once per fixture in `capture_screenshots.ps1`'s matrix with
# `HA_LAYOUT_DUMP` set, then reads each dump for two faults:
#   - overflow: a painted or focusable node whose box runs past the right edge of the clip it
#     paints under, so its edge or its text is cut (a row wider than its scroll viewport, a field
#     whose padding pushes it past the catalog);
#   - hidden tab: a node in Tab order whose clip shows none of it, outside any scroll view that
#     would bring it into view when focused.
# Prints each fault with its fixture and the dump line, and exits 1 when there are any.
#
# Usage (from the repo root, after `zig build`):
#   powershell -ExecutionPolicy Bypass -File tools/layout_audit.ps1
#   powershell -ExecutionPolicy Bypass -File tools/layout_audit.ps1 -Only act_two_build_w560
#   powershell -ExecutionPolicy Bypass -File tools/layout_audit.ps1 -Allow research_zoom_250

param(
    [string[]] $Only = @(),
    # Fixtures whose overflow is intended (a zoomed board camera crops its tiles).
    [string[]] $Allow = @("research_zoom_250"),
    [string] $OutDir = "$env:TEMP\ha_layout_audit",
    [string] $Exe = "zig-out/bin/human_action.exe",
    [int] $Frame = 20
)

if (-not (Test-Path $Exe)) { Write-Error "Binary not found at $Exe. Run 'zig build' first."; exit 2 }

$names = Select-String -Path "$PSScriptRoot/capture_screenshots.ps1" -Pattern '^\s*"([a-z0-9_]+)"\s*=' |
    ForEach-Object { $_.Matches[0].Groups[1].Value }
if ($Only.Count -gt 0) {
    $Only = $Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ }
    $names = $names | Where-Object { $Only -contains $_ }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
foreach ($n in $names) {
    $path = Join-Path $OutDir "$n.txt"
    Remove-Item $path -ErrorAction SilentlyContinue
    $env:HA_FIXTURE = $n
    $env:HA_LAYOUT_DUMP = $path
    $env:HA_LAYOUT_DUMP_FRAME = "$Frame"
    $p = Start-Process -FilePath $Exe -PassThru -WindowStyle Minimized
    for ($i = 0; $i -lt 60 -and -not (Test-Path $path); $i++) { Start-Sleep -Milliseconds 150 }
    Start-Sleep -Milliseconds 200
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $path)) { Write-Warning "$n wrote no dump" }
}
Remove-Item env:HA_FIXTURE, env:HA_LAYOUT_DUMP, env:HA_LAYOUT_DUMP_FRAME -ErrorAction SilentlyContinue

$rx = '^( *)(\S+) #[0-9a-f]+ (-?\d+),(-?\d+) (\d+)x(\d+) clip (-?\d+),(-?\d+) (\d+)x(\d+)'
$faults = 0
foreach ($n in $names) {
    $path = Join-Path $OutDir "$n.txt"
    if (-not (Test-Path $path)) { continue }
    $scrolls = @()  # indents of the open scroll viewports above the current line
    foreach ($l in Get-Content $path) {
        $m = [regex]::Match($l, $rx)
        if (-not $m.Success) { continue }
        $indent = $m.Groups[1].Value.Length
        $scrolls = @($scrolls | Where-Object { $_ -lt $indent })
        $x = [int]$m.Groups[3].Value; $w = [int]$m.Groups[5].Value
        $cx = [int]$m.Groups[7].Value; $cw = [int]$m.Groups[9].Value; $ch = [int]$m.Groups[10].Value
        $shows = $l -match ' (text|fill|outline|tab)( |$)'
        if ($Allow -notcontains $n -and $ch -gt 0 -and $shows -and ($x + $w) -gt ($cx + $cw + 1) -and $x -lt ($cx + $cw)) {
            Write-Output ("overflow   {0}: {1}px past its clip: {2}" -f $n, (($x + $w) - ($cx + $cw)), $l.Trim())
            $faults++
        }
        if ($l -match ' hidden' -and $l -match ' tab( |$)' -and $scrolls.Count -eq 0) {
            Write-Output ("hidden tab {0}: {1}" -f $n, $l.Trim())
            $faults++
        }
        if ($l -match ' clips' -and $l -match ' tab ' -and $l -match ' group ') { $scrolls += $indent }
    }
}
Write-Output "$faults faults over $($names.Count) fixtures"
if ($faults -gt 0) { exit 1 }
