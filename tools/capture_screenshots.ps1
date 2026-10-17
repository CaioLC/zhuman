# capture_screenshots.ps1 — the screenshot-matrix capture driver (QA-10..13).
#
# Launches the built `human_action` binary once per named fixture (`HA_FIXTURE=<name>`), waits for
# the window to settle, captures it with PrintWindow (the capture path `docs/CLAUDE.md`'s
# `project_dev_workflow` names — there is no synthetic-input render path into SDL), and writes one
# PNG per fixture under `docs/screenshots/`. The result is the reference matrix the parity review
# compares against the prototype HTML/screenshots in `prototypes/`.
#
# The fixtures are deterministic (fixed window size, clock, catalogs, balances — see
# `src/pages/fixture.zig`), so each capture is reproducible: the same name yields the same screen
# every run, which is what makes a screenshot diff meaningful rather than noisy.
#
# Usage (from the repo root, after `zig build`):
#   pwsh -File tools/capture_screenshots.ps1                 # capture every fixture
#   pwsh -File tools/capture_screenshots.ps1 -Only act_one_working,act_one_passerby
#   pwsh -File tools/capture_screenshots.ps1 -SettleMs 4000  # longer settle for slow machines
#
# Requires: a built `zig-out/bin/human_action.exe`, Windows (PrintWindow is a Win32 call).

param(
    [string[]] $Only = @(),
    [int] $SettleMs = 2500,
    [string] $OutDir = "docs/screenshots",
    [string] $Exe = "zig-out/bin/human_action.exe"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# The screenshot matrix: each fixture name maps to the QA item it evidences. Keep this list in
# step with the catalog in `src/pages/fixture.zig` (the single source of fixture names).
$matrix = [ordered]@{
    "act_one_default"   = "QA-10 Act I ACTIONS, reference 900x820"
    "act_one_working"   = "QA-10 Act I BUILD/holdings mid-run"
    "act_one_build"     = "QA-10 Act I BUILD recipe table, scroll on overflow"
    "gameover"          = "Game-over curtain"
    "act_one_end"       = "Act I curtain, first beat"
    "act_one_low_stock" = "QA-10 Act I low-stock / disabled states"
    "act_one_passerby"  = "QA-10 Act I Passerby trade (dialog openable)"
    "act_one_w760"      = "QA-10 Act I narrow layout, 760 width class"
    "act_one_w560"      = "QA-10 Act I narrow layout, 560 width class"
    "act_one_w440"      = "QA-10 Act I narrow layout, 440 width class"
    "act_one_hidpi"     = "QA-13 Act I high-DPI (2x) terminal"
    "act_two_actions"   = "QA-11 Act II shell ACTIONS / catalog"
    "act_two_build"     = "QA-11 Act II shell BUILD / 50-recipe catalog"
    "act_two_w560"      = "QA-11 Act II narrow layout, 560 width class"
}

if (-not (Test-Path $Exe)) {
    Write-Error "Binary not found at $Exe. Run 'zig build' first."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --- PrintWindow P/Invoke: capture a window's client area to a bitmap, DPI-aware. ---
Add-Type @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class WinCap {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    // PW_RENDERFULLCONTENT (2) captures layered/accelerated content SDL draws.
    public static void Capture(IntPtr hwnd, string path) {
        RECT r; GetWindowRect(hwnd, out r);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) throw new Exception("window has no area");
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            try { PrintWindow(hwnd, hdc, 2); } finally { g.ReleaseHdc(hdc); }
            bmp.Save(path, ImageFormat.Png);
        }
    }
}
"@ -ReferencedAssemblies System.Drawing

[WinCap]::SetProcessDPIAware() | Out-Null

function Capture-Fixture([string] $name, [string] $about) {
    Write-Host "capturing $name  ($about)"
    $env:HA_FIXTURE = $name
    $proc = Start-Process -FilePath $Exe -PassThru
    try {
        Start-Sleep -Milliseconds $SettleMs
        $proc.Refresh()
        $hwnd = $proc.MainWindowHandle
        if ($hwnd -eq [IntPtr]::Zero) {
            Write-Warning "  no main window handle for $name (skipped)"
            return
        }
        $out = Join-Path (Resolve-Path -LiteralPath $OutDir) "$name.png"
        [WinCap]::Capture($hwnd, $out)
        Write-Host "  -> $out"
    } finally {
        if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 200 }
        if (-not $proc.HasExited) { $proc.Kill() }
        Remove-Item Env:\HA_FIXTURE -ErrorAction SilentlyContinue
    }
}

$names = if ($Only.Count -gt 0) { $Only } else { $matrix.Keys }
foreach ($name in $names) {
    $about = if ($matrix.Contains($name)) { $matrix[$name] } else { "(not in matrix)" }
    Capture-Fixture $name $about
}

Write-Host "`nDone. Screenshots in $OutDir. Compare against prototypes/ for the parity review."
