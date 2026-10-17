# capture_templates.ps1 — one PNG per template on the debug page.
#
# Launches the built binary once per debug-page entry (`HA_DEBUG_PAGE=<entry>` opens on it),
# waits for it to settle, captures the window with PrintWindow, crops away the title bar, the
# frame and the right-hand template index, then trims the empty background around the template
# (keeping a small margin), and writes `<OutDir>/<entry>.png`. Overlay entries (trade dialog,
# merchant, menu, tooltip) keep the full stage, since they float over it.
#
# Usage (from the repo root, after `zig build`):
#   pwsh -File tools/capture_templates.ps1                    # every entry
#   pwsh -File tools/capture_templates.ps1 -Only tabs,header  # some entries
#
# Requires: a built `zig-out/bin/human_action.exe`, Windows (PrintWindow is a Win32 call).

param(
    [string[]] $Only = @(),
    [int] $SettleMs = 2000,
    [string] $OutDir = "prototypes/templates",
    [string] $Exe = "zig-out/bin/human_action.exe",
    [int] $Margin = 12,
    [int] $WindowW = 1180,
    [int] $WindowH = 940
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Test-Path $Exe)) { Write-Error "Binary not found at $Exe. Run 'zig build' first." }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# The entry names, read from the debug page's `entries` list (the one source of names).
$entries = Select-String -Path "src/pages/debug_page.zig" -Pattern '^    "(\w+)",' | ForEach-Object { $_.Matches[0].Groups[1].Value }
$names = if ($Only.Count -gt 0) { $Only } else { $entries }
$overlays = @("trade_dialog", "coin_merchant", "menu_dialog")

Add-Type @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class TemplateCap {
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hwnd, int x, int y, int w, int h, bool repaint);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    // Capture the window, keep its client area minus rightCut px of index, then (unless
    // full) trim to the bounding box of pixels that differ from the background.
    public static void Capture(IntPtr hwnd, string path, int rightCut, bool full, int margin) {
        RECT w; GetWindowRect(hwnd, out w);
        RECT c; GetClientRect(hwnd, out c);
        POINT o; o.X = 0; o.Y = 0; ClientToScreen(hwnd, ref o);
        int ww = w.Right - w.Left, wh = w.Bottom - w.Top;
        using (var win = new Bitmap(ww, wh, PixelFormat.Format32bppArgb)) {
            using (var g = Graphics.FromImage(win)) {
                IntPtr hdc = g.GetHdc();
                try { PrintWindow(hwnd, hdc, 2); } finally { g.ReleaseHdc(hdc); }
            }
            int cx = o.X - w.Left, cy = o.Y - w.Top;
            int cw = Math.Max(1, (c.Right - c.Left) - rightCut), ch = c.Bottom - c.Top;
            Rectangle crop = new Rectangle(cx, cy, cw, ch);
            if (!full) {
                Color bg = win.GetPixel(cx + 2, cy + ch - 3);
                int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
                for (int y = cy; y < cy + ch; y++)
                    for (int x = cx; x < cx + cw; x++) {
                        Color p = win.GetPixel(x, y);
                        if (Math.Abs(p.R - bg.R) + Math.Abs(p.G - bg.G) + Math.Abs(p.B - bg.B) > 24) {
                            if (x < minX) minX = x; if (x > maxX) maxX = x;
                            if (y < minY) minY = y; if (y > maxY) maxY = y;
                        }
                    }
                if (maxX >= 0) {
                    int x0 = Math.Max(cx, minX - margin), y0 = Math.Max(cy, minY - margin);
                    int x1 = Math.Min(cx + cw, maxX + margin + 1), y1 = Math.Min(cy + ch, maxY + margin + 1);
                    crop = new Rectangle(x0, y0, x1 - x0, y1 - y0);
                }
            }
            using (var outBmp = win.Clone(crop, PixelFormat.Format32bppArgb)) outBmp.Save(path, ImageFormat.Png);
        }
    }
}
"@ -ReferencedAssemblies System.Drawing

[TemplateCap]::SetProcessDPIAware() | Out-Null

# The index column's width in device px at the reference DPI: 150 logical + 2×10 padding.
$indexWidth = 170

foreach ($name in $names) {
    if ($entries -notcontains $name) { Write-Warning "unknown entry '$name' (skipped)"; continue }
    $env:HA_DEBUG_PAGE = $name
    $proc = Start-Process -FilePath $Exe -PassThru
    try {
        Start-Sleep -Milliseconds 700
        $proc.Refresh()
        # Wide enough that the largest demo (the 900px page) clears the index column.
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [TemplateCap]::MoveWindow($proc.MainWindowHandle, 20, 20, $WindowW, $WindowH, $true) | Out-Null }
        Start-Sleep -Milliseconds $SettleMs
        $proc.Refresh()
        if ($proc.HasExited) { Write-Warning "  $name exited early (code $($proc.ExitCode))"; continue }
        $hwnd = $proc.MainWindowHandle
        if ($hwnd -eq [IntPtr]::Zero) { Write-Warning "  no window for $name (skipped)"; continue }
        $out = Join-Path (Resolve-Path -LiteralPath $OutDir) "$name.png"
        $isOverlay = $overlays -contains $name
        # An overlay floats over the whole window (index included), so it keeps the full client area.
        [TemplateCap]::Capture($hwnd, $out, $(if ($isOverlay) { 0 } else { $indexWidth }), $isOverlay, $Margin)
        Write-Host "  $name -> $out"
    } finally {
        if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 200 }
        if (-not $proc.HasExited) { $proc.Kill() }
        Remove-Item Env:\HA_DEBUG_PAGE -ErrorAction SilentlyContinue
    }
}
Write-Host "`nDone. Template PNGs in $OutDir."
