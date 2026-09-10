//! `view` — **frame-local view metrics** (VIEW-01). Once per frame, `build_ui`'s prologue
//! computes a `ViewMetrics` from the window's coordinate size, its drawable pixel size (DPI),
//! and the `900×820` design **reference**, and stores it on `Resources.View`. Everything
//! responsive reads it: the logical→device scale (feeding `type.toDevice` and the RENDER-06
//! hairline snap), the logical viewport the layout is laid out in, the centered terminal rect
//! (VIEW-03), and the width class that drives the `760/560/440` responsive branches (VIEW-04).
//!
//! **Two independent scales, kept apart:**
//!   - **DPI scale** (`dpi_scale`) = drawable pixels ÷ window coordinates. It is the
//!     crispness factor — device pixels per logical (window-coordinate) pixel — fed to
//!     `View.scale` so text opens the font at the right device size and hairlines snap to
//!     whole device pixels. It does **not** change layout: the layout is solved in logical
//!     (window-coordinate) space, which is what SDL's renderer maps to pixels.
//!   - **Responsive class** — derived from the *logical* width against the prototype's
//!     breakpoints, so the layout branches (VIEW-04) and the framed/centered terminal
//!     (VIEW-03) key off the design-space width, not the physical pixel count.
//!
//! The compute is **pure and SDL-free** (`compute(logical_w, logical_h, pixel_density)`), so
//! the reference-fit, centering, and breakpoint math are unit-tested without a window.

const std = @import("std");
const ui = @import("../ui/root.zig");

/// The design reference the prototype is authored at: the terminal caps here and centers
/// above it, and every authored dimension is a logical px against this space.
pub const ref_w: f32 = 900;
pub const ref_h: f32 = 820;

/// The prototype's responsive breakpoints, in **logical** px (window-coordinate width). Each
/// class is "at most this width"; `full` is anything wider than `w760`. They stack exactly as
/// the CSS media queries do (`≤760`, `≤560`, `≤440`).
pub const bp_760: f32 = 760;
pub const bp_560: f32 = 560;
pub const bp_440: f32 = 440;

/// The responsive width class, from the logical viewport width (VIEW-04). Ordered widest →
/// narrowest; a consumer typically asks `class.atMost(.w560)` rather than matching one value.
pub const WidthClass = enum {
    /// Wider than 760 logical px: the full framed/centered terminal layout.
    full,
    /// ≤760 (and >560): full-window, stacked page grid, page-level scroll.
    w760,
    /// ≤560 (and >440): + reduced padding, hidden optional copy, two action columns.
    w560,
    /// ≤440: + one action column, hidden BUILD cost column.
    w440,

    /// Classify a logical width into its stacked breakpoint class.
    pub fn of(logical_w: f32) WidthClass {
        if (logical_w <= bp_440) return .w440;
        if (logical_w <= bp_560) return .w560;
        if (logical_w <= bp_760) return .w760;
        return .full;
    }

    /// True when this class is at least as narrow as `other` — the natural test for a
    /// stacked breakpoint ("apply this at ≤560 and everything narrower"). Since the enum is
    /// ordered widest→narrowest, "at most `other`'s width" is "ordinal ≥ other's ordinal".
    pub fn atMost(self: WidthClass, other: WidthClass) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }

    /// True when the layout is the full framed/centered terminal (wider than 760).
    pub fn framed(self: WidthClass) bool {
        return self == .full;
    }
};

/// Frame-local view metrics (VIEW-01). All rects/sizes are in **logical** (window-coordinate)
/// px — the space the layout is solved in; `dpi_scale` converts those to device px for
/// crispness. Recomputed every frame, so a resize just produces new metrics.
pub const ViewMetrics = struct {
    /// The drawable size in **device** pixels (`window.getSizeInPixels`).
    px_w: f32 = ref_w,
    px_h: f32 = ref_h,
    /// The window's **logical** (coordinate) size — the layout viewport and the space
    /// breakpoints apply in.
    logical_w: f32 = ref_w,
    logical_h: f32 = ref_h,
    /// Device pixels per logical pixel (crispness factor). `View.scale` is set from this.
    dpi_scale: f32 = 1,
    /// The terminal rect in logical px: capped at the reference and centered when framed
    /// (VIEW-03), else the full window.
    terminal: ui.Rect = .{ .x = 0, .y = 0, .w = ref_w, .h = ref_h },
    /// The responsive width class from `logical_w`.
    width_class: WidthClass = .full,

    /// Whether the framed/centered terminal chrome (border, shadow, ground) is shown — true
    /// above the 760 breakpoint (VIEW-03).
    pub fn framed(self: ViewMetrics) bool {
        return self.width_class.framed();
    }
};

/// Compute the frame's metrics from the window's **logical** size and its **pixel density**
/// (device px ÷ logical px, e.g. `1.0` at 96dpi, `1.5`/`2.0` on high-DPI). Pure and SDL-free.
///
/// - `dpi_scale` is the pixel density, floored positive (a degenerate `≤0` density → 1).
/// - `width_class` classifies the logical width against the `760/560/440` breakpoints.
/// - `terminal`: when **framed** (wider than 760), cap the terminal to the `900×820` reference
///   (never larger, but shrinking with the window between 760 and 900) and center it in the
///   logical viewport, snapped to whole logical px so its border stays crisp. When not framed
///   (≤760), the terminal is the full window at the origin — the prototype's full-width mode.
pub fn compute(logical_w: f32, logical_h: f32, pixel_density: f32) ViewMetrics {
    const lw = @max(1, logical_w);
    const lh = @max(1, logical_h);
    const density = if (pixel_density > 0) pixel_density else 1;
    const class = WidthClass.of(lw);

    const terminal: ui.Rect = if (class.framed()) blk: {
        const tw = @min(lw, ref_w);
        const th = @min(lh, ref_h);
        // Center in the logical viewport, snapped to whole logical px (crisp border edges).
        const tx = @round((lw - tw) / 2);
        const ty = @round((lh - th) / 2);
        break :blk .{ .x = tx, .y = ty, .w = tw, .h = th };
    } else .{ .x = 0, .y = 0, .w = lw, .h = lh };

    return .{
        .px_w = lw * density,
        .px_h = lh * density,
        .logical_w = lw,
        .logical_h = lh,
        .dpi_scale = density,
        .terminal = terminal,
        .width_class = class,
    };
}

// ============================ Tests (deterministic, SDL-free) =========================

const testing = std.testing;

test "WidthClass: stacked breakpoints classify logical width" {
    try testing.expectEqual(WidthClass.full, WidthClass.of(900));
    try testing.expectEqual(WidthClass.full, WidthClass.of(761));
    try testing.expectEqual(WidthClass.w760, WidthClass.of(760));
    try testing.expectEqual(WidthClass.w760, WidthClass.of(561));
    try testing.expectEqual(WidthClass.w560, WidthClass.of(560));
    try testing.expectEqual(WidthClass.w560, WidthClass.of(441));
    try testing.expectEqual(WidthClass.w440, WidthClass.of(440));
    try testing.expectEqual(WidthClass.w440, WidthClass.of(320));
}

test "WidthClass: atMost is a stacked 'this width and narrower' test" {
    try testing.expect(WidthClass.w440.atMost(.w560)); // 440 is narrower than 560 → applies
    try testing.expect(WidthClass.w560.atMost(.w560)); // equal → applies
    try testing.expect(!WidthClass.full.atMost(.w560)); // full is wider → does not apply
    try testing.expect(WidthClass.w440.atMost(.w760));
    try testing.expect(!WidthClass.w760.atMost(.w560));
}

test "compute: at the reference size the terminal is the full 900x820 at origin, framed" {
    const m = compute(ref_w, ref_h, 1);
    try testing.expectEqual(WidthClass.full, m.width_class);
    try testing.expect(m.framed());
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 900, .h = 820 }, m.terminal);
    try testing.expectEqual(@as(f32, 1), m.dpi_scale);
}

test "compute: above the reference the terminal caps at 900x820 and centers" {
    const m = compute(1200, 1000, 1);
    try testing.expect(m.framed());
    try testing.expectEqual(@as(f32, 900), m.terminal.w);
    try testing.expectEqual(@as(f32, 820), m.terminal.h);
    try testing.expectEqual(@as(f32, 150), m.terminal.x); // (1200-900)/2
    try testing.expectEqual(@as(f32, 90), m.terminal.y); // (1000-820)/2
}

test "compute: between 760 and 900 stays framed, terminal shrinks with the window and centers" {
    const m = compute(820, 700, 1);
    try testing.expect(m.framed());
    try testing.expectEqual(@as(f32, 820), m.terminal.w); // min(820,900)
    try testing.expectEqual(@as(f32, 700), m.terminal.h);
    try testing.expectEqual(@as(f32, 0), m.terminal.x); // centered but == full width here
    try testing.expectEqual(@as(f32, 0), m.terminal.y);
}

test "compute: at or below 760 the terminal is the full window (unframed)" {
    const m = compute(760, 900, 1);
    try testing.expect(!m.framed());
    try testing.expectEqual(WidthClass.w760, m.width_class);
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 760, .h = 900 }, m.terminal);
}

test "compute: dpi_scale is the pixel density; drawable px = logical * density" {
    const m = compute(900, 820, 2);
    try testing.expectEqual(@as(f32, 2), m.dpi_scale);
    try testing.expectEqual(@as(f32, 1800), m.px_w);
    try testing.expectEqual(@as(f32, 1640), m.px_h);
    // A degenerate density is floored to 1.
    const d = compute(900, 820, 0);
    try testing.expectEqual(@as(f32, 1), d.dpi_scale);
}

test "compute: a fractional high-DPI density is preserved for the crispness scale" {
    const m = compute(900, 820, 1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.5), m.dpi_scale, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1350), m.px_w, 1e-4);
}
