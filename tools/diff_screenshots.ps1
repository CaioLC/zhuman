# diff_screenshots.ps1 - the pixel diff between two screenshot sets (capture_screenshots.ps1 output).
#
# Pairs the PNGs in -Base and -Head by file name and compares each pair pixel by pixel (both read
# as 32bppArgb, every channel including alpha). For each fixture it prints one line:
#   identical  the two images match within -Tolerance;
#   differs    the count of differing pixels and the bounding box that holds them;
#   size       the two images have different dimensions (no pixel comparison);
#   missing    the PNG exists on one side only;
#   error      a PNG could not be read (or the diff image not written).
# With -Out it writes <name>.png per differing fixture: the head image dimmed, the differing pixels
# in magenta. Prints a summary line and exits 1 when any fixture differs, is missing or errors,
# else 0.
#
# Two runs of the same binary differ in two ways the fixtures do not pin: a mouse cursor resting
# over the window hovers whatever is under it (keep it off the window while capturing), and the
# sim clock runs during the settle, so a log line the sim writes on its first ticks carries a
# minute stamp that varies by a few minutes (act_one_oversized, act_one_scale110,
# act_one_shelter_locked, act_one_trade, act_one_trade_sell; a 5x25 px box in the log).
#
# Usage (from the repo root; capture each side with capture_screenshots.ps1 -OutDir <dir>):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/diff_screenshots.ps1 -Base $env:TEMP\ha_base -Head $env:TEMP\ha_head
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/diff_screenshots.ps1 -Base $env:TEMP\ha_base -Head $env:TEMP\ha_head -Only act_one_default,title
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/diff_screenshots.ps1 -Base $env:TEMP\ha_base -Head $env:TEMP\ha_head -Out $env:TEMP\ha_diff -Tolerance 2
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/diff_screenshots.ps1 -Base $env:TEMP\ha_base -Head $env:TEMP\ha_head -Ignore act_one_trade,act_one_trade_sell

param(
    [Parameter(Mandatory = $true)] [string] $Base,
    [Parameter(Mandatory = $true)] [string] $Head,
    [string[]] $Only = @(),
    # Fixtures left out of the comparison (a capture that is not reproducible run to run).
    [string[]] $Ignore = @(),
    [string] $Out = "",
    # Largest per-channel difference (0..255) still counted as the same pixel.
    [int] $Tolerance = 0
)

foreach ($d in @($Base, $Head)) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { Write-Error "Not a directory: $d"; exit 2 }
}
if ($Tolerance -lt 0 -or $Tolerance -gt 255) { Write-Error "-Tolerance must be 0..255"; exit 2 }
$Base = (Resolve-Path -LiteralPath $Base).ProviderPath
$Head = (Resolve-Path -LiteralPath $Head).ProviderPath
if ($Out) {
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    $Out = (Resolve-Path -LiteralPath $Out).ProviderPath
    if ($Out -eq $Base -or $Out -eq $Head) { Write-Error "-Out must not be -Base or -Head"; exit 2 }
}

$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Ignore = @($Ignore | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not ('ScreenshotDiff' -as [type])) {
Add-Type @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class ScreenshotDiffResult {
    public bool SizeMismatch;
    public int BaseWidth, BaseHeight, HeadWidth, HeadHeight;
    public long Count;
    public int MinX, MinY, MaxX, MaxY;
}

public static class ScreenshotDiff {
    // Reads a PNG as packed 0xAARRGGBB ints, one row after another, whatever its stored format.
    static int[] Load(string path, out int w, out int h) {
        using (var bmp = new Bitmap(path)) {
            w = bmp.Width; h = bmp.Height;
            BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try {
                int[] px = new int[w * h];
                for (int y = 0; y < h; y++) Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), px, y * w, w);
                return px;
            } finally { bmp.UnlockBits(data); }
        }
    }

    static void Save(int[] px, int w, int h, string path) {
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
            BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try {
                for (int y = 0; y < h; y++) Marshal.Copy(px, y * w, IntPtr.Add(data.Scan0, y * data.Stride), w);
            } finally { bmp.UnlockBits(data); }
            bmp.Save(path, ImageFormat.Png);
        }
    }

    static bool Differs(int a, int b, int tolerance) {
        if (a == b) return false;
        if (tolerance == 0) return true;
        for (int s = 0; s < 32; s += 8) {
            int ca = (a >> s) & 0xFF, cb = (b >> s) & 0xFF;
            if (Math.Abs(ca - cb) > tolerance) return true;
        }
        return false;
    }

    // Compares two PNGs; when diffPath is set and any pixel differs, writes the diff image there.
    public static ScreenshotDiffResult Compare(string basePath, string headPath, int tolerance, string diffPath) {
        var r = new ScreenshotDiffResult();
        int wa, ha, wb, hb;
        int[] pa = Load(basePath, out wa, out ha);
        int[] pb = Load(headPath, out wb, out hb);
        r.BaseWidth = wa; r.BaseHeight = ha; r.HeadWidth = wb; r.HeadHeight = hb;
        if (wa != wb || ha != hb) { r.SizeMismatch = true; return r; }

        bool[] mask = new bool[pa.Length];
        r.MinX = int.MaxValue; r.MinY = int.MaxValue; r.MaxX = -1; r.MaxY = -1;
        for (int y = 0; y < ha; y++) {
            int row = y * wa;
            for (int x = 0; x < wa; x++) {
                int i = row + x;
                if (!Differs(pa[i], pb[i], tolerance)) continue;
                mask[i] = true;
                r.Count++;
                if (x < r.MinX) r.MinX = x;
                if (x > r.MaxX) r.MaxX = x;
                if (y < r.MinY) r.MinY = y;
                if (y > r.MaxY) r.MaxY = y;
            }
        }

        if (!String.IsNullOrEmpty(diffPath) && r.Count > 0) {
            int[] o = new int[pb.Length];
            for (int i = 0; i < pb.Length; i++) {
                if (mask[i]) { o[i] = unchecked((int)0xFFFF00FF); continue; }
                int p = pb[i];
                int red = ((p >> 16) & 0xFF) * 3 / 10, green = ((p >> 8) & 0xFF) * 3 / 10, blue = (p & 0xFF) * 3 / 10;
                o[i] = unchecked((int)0xFF000000) | (red << 16) | (green << 8) | blue;
            }
            Save(o, wb, hb, diffPath);
        }
        return r;
    }
}
"@ -ReferencedAssemblies System.Drawing
}

$baseNames = @(Get-ChildItem -LiteralPath $Base -Filter *.png -File | ForEach-Object { $_.BaseName })
$headNames = @(Get-ChildItem -LiteralPath $Head -Filter *.png -File | ForEach-Object { $_.BaseName })
$names = if ($Only.Count -gt 0) { $Only } else { @($baseNames + $headNames | Sort-Object -Unique) }

$identical = 0; $differ = 0; $size = 0; $missing = 0; $errors = 0; $ignored = 0
foreach ($n in $names) {
    if ($Ignore -contains $n) { $ignored++; continue }
    $a = Join-Path $Base "$n.png"
    $b = Join-Path $Head "$n.png"
    $inA = Test-Path -LiteralPath $a
    $inB = Test-Path -LiteralPath $b
    if (-not ($inA -and $inB)) {
        $where = if ($inA) { "head" } elseif ($inB) { "base" } else { "base and head" }
        Write-Output ("missing    {0}: not in {1}" -f $n, $where)
        $missing++
        continue
    }
    $diffPath = if ($Out) { Join-Path $Out "$n.png" } else { "" }
    try {
        $r = [ScreenshotDiff]::Compare($a, $b, $Tolerance, $diffPath)
    } catch {
        $e = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
        Write-Output ("error      {0}: {1}" -f $n, $e.Message)
        $errors++
        continue
    }
    if ($r.SizeMismatch) {
        Write-Output ("size       {0}: base {1}x{2}, head {3}x{4}" -f $n, $r.BaseWidth, $r.BaseHeight, $r.HeadWidth, $r.HeadHeight)
        $size++
    } elseif ($r.Count -gt 0) {
        Write-Output ("differs    {0}: {1} px in x {2}..{3}, y {4}..{5} ({6}x{7})" -f $n, $r.Count,
            $r.MinX, $r.MaxX, $r.MinY, $r.MaxY, ($r.MaxX - $r.MinX + 1), ($r.MaxY - $r.MinY + 1))
        $differ++
    } else {
        Write-Output ("identical  {0}" -f $n)
        $identical++
    }
}

$compared = $identical + $differ + $size + $missing + $errors
$summary = "{0} fixtures: {1} identical, {2} differ, {3} size mismatch, {4} missing, {5} ignored" -f
    $compared, $identical, $differ, $size, $missing, $ignored
if ($errors -gt 0) { $summary += ", $errors unreadable" }
Write-Output $summary
if ($differ + $size + $missing + $errors -gt 0) { exit 1 }
exit 0
