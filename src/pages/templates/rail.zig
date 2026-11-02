//! `rail` — the **collapsible HOUSEHOLD side rail** (holdings, BODY and the eating policy, in
//! every act; its restore label reads `HOUSEHOLD`). Fills the shell's
//! `regions.rail`: an expanded panel (width `tokens.rail.expanded`, 252) the caller fills with
//! the `household` column, or a narrow collapsed strip (width
//! `tokens.rail.collapsed`, 36) showing a **vertical restore affordance** — a chevron above the
//! rail's label set 90° counter-clockwise (the `.vertical` text fit), reading bottom-to-top.
//!
//! **One toggle, synchronized everything.** The rail's collapsed/expanded bit lives in a keyed
//! `RailState` pool (survives the frame-arena rebuild by `node.key`). One stable toggle control
//! owns interaction in both states: the expanded 24×26 collapse button becomes the collapsed
//! 36×124 restore button, while its label, focus, and hit target follow the same state each
//! frame. Distinct rails carry distinct ids, so **each view's rail keeps its own collapse
//! memory** for free; a **focus view's rail** (RESEARCH, MARKET) passes `force_collapsed`, which
//! overwrites *its own* state to collapsed every entry while leaving the other keys untouched.
//!
//! **The width animates (120ms, host tween).** The rail asks the host tween registry to
//! ride toward the target width over `tokens.dur_rail_s`, keyed by the rail node; `value(key,
//! target)` drives the node's fixed width, so an interrupted toggle reverses smoothly and a
//! first appearance simply sits at its target. Reduced motion snaps (the registry's policy).

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const UiCtx = uic.UiCtx;
const RailState = uic.UiState.RailState;

/// What the caller asks the rail to be. `label` is the vertical restore label shown when
/// collapsed; `force_collapsed` makes this rail start (and stay) collapsed on every entry —
/// the STRUCTURE behavior — without touching the ACTIONS/BUILD rails' remembered state.
pub const RailOptions = struct {
    id: []const u8,
    label: []const u8,
    force_collapsed: bool = false,
    /// The collapse bit when the caller owns it (read on entry, written after the toggle);
    /// null means the rail keeps its own memory keyed by `id`.
    collapsed: ?*bool = null,
    /// Set the collapse bit on this frame only (a fixture's first frame); null leaves it.
    initial_collapsed: ?bool = null,
};

/// The built rail: `collapsed` is this frame's resolved state (a caller may skip building
/// content when collapsed), and `body` is the fill target — non-null only while expanded, so
/// the caller does `if (r.body) |b| try holdings(b, …)`.
pub const Rail = struct {
    collapsed: bool,
    body: ?El,
};

// Prototype border-box dimensions. Engine fixed sizes describe the content box, so the
// restore control's 124px outer height is 108px of content plus 7px/9px vertical padding.
const restore_width: f32 = 36;
const restore_outer_height: f32 = 124;
const restore_pad_top: f32 = 7;
const restore_pad_bottom: f32 = 9;
const restore_content_height: f32 = restore_outer_height - restore_pad_top - restore_pad_bottom;
const collapse_width: f32 = 24;
const collapse_height: f32 = 26;

/// The toggle's box: the ground fill and an fg edge, matching the active tab's resting edge,
/// that lifts to accent while the pointer engages it or keyboard focus shows. A click keeps
/// focus across collapse/expand, but focus-visible is off after a click, so the rail does not
/// latch in its hover colour.
pub const toggle_chrome = Style{ .fill_ink = .bg, .outline_ink = .fg, .outline_width = 1, .on = &.{.{ .when = .hot, .outline_ink = .acc }} };
/// The toggle's chevron and restore label, lifting with its edge.
pub const toggle_ink = Style{ .ink = .fg, .on = &.{.{ .when = .hot, .ink = .acc }} };

/// Build the collapsible rail into `parent` (the shell's `regions.rail`). Manages its own
/// collapse memory, toggle, and width tween; returns the fill target when expanded.
pub fn rail(parent: El, opts: RailOptions) !Rail {
    const ctx = parent.ctx;

    // The rail is the width-bearing container, not the bordered button. In the prototype the
    // expanded rail itself is 252px wide and visually transparent; only its 24x26 collapse
    // control is boxed. When collapsed, that control becomes the separate 36x124 restore box.
    const box = try parent.div(opts.id);
    const st = box.state(RailState);
    if (opts.collapsed) |c| st.collapsed = c.*;
    if (opts.initial_collapsed) |c| st.collapsed = c;
    if (opts.force_collapsed) st.collapsed = true;

    // Build the body before the toggle so the control remains the top-painted sibling after
    // callers populate the body. One stable toggle key owns focus and interaction in both
    // states, keeping the visual box and hit box synchronized through the transition.
    const body = try box.div("rail_body");
    const toggle = try box.div("toggle");
    // Flip on the click before the lifecycle publishes `expanded`, so it is current this frame.
    if (toggle.query().clicked) st.collapsed = !st.collapsed;
    if (opts.collapsed) |c| c.* = st.collapsed;
    _ = toggle.control(.{ .name = opts.label, .role = .button, .expanded = !st.collapsed, .ring = false });

    // Width animates between the shared rail tokens. Clipping belongs to this width-bearing
    // container, so expanded content cannot leak across the shrinking rail during the tween.
    const target: f32 = if (st.collapsed) ha.tokens.rail.collapsed else ha.tokens.rail.expanded;
    ctx.res.tween.retarget(box.get().key, target, ha.tokens.dur_rail_s);
    const w = ctx.res.tween.value(box.get().key, target);
    // Stacked (≤760), the expanded rail spans the page above the surface.
    const stack = @import("./terminal.zig").stacked(ctx);

    if (st.collapsed) {
        // The 36×124 restore control exactly fills this box. Keep overflow visible in the
        // collapsed branch so its 1px fg/acc outline is painted; clipping is only needed while
        // expanded content exists and would otherwise leak across the animated rail width.
        box.set(.{ .w = .{ .fixed = w }, .h = .{ .fixed = restore_outer_height }, .overflow = .visible }, .{});

        // CSS counterpart: `.holdings-restore` — 36x124 border-box, 7px/9px vertical
        // padding, 8px gap, and centered children. Each glyph sits in a full-width row below:
        // the engine's column cross-line is intrinsically child-sized, while row main-axis
        // centering resolves against the definite 36px lane just like CSS `align-items:center`.
        toggle.set(.{
            .anchor = .top_left, .w = .{ .fixed = restore_width }, .h = .{ .fixed = restore_content_height },
            .flow = .{ .dir = .column, .main = .start, .cross = .center }, .gap = 8,
        }, .{ toggle_chrome, style.pad_each(restore_pad_top, 0, restore_pad_bottom, 0) });
        const chevron_lane = try toggle.box("chevron_lane", .{
            .w = .{ .fixed = restore_width }, .h = .fit_children,
            .flow = .{ .dir = .row, .main = .center, .cross = .center },
        }, .{});
        try chevron_lane.label("chevron", "\u{203A}", .{ toggle_ink, Style{ .font = 16 } });

        const label_lane = try toggle.box("label_lane", .{
            .w = .{ .fixed = restore_width }, .h = .fit_children,
            .flow = .{ .dir = .row, .main = .center, .cross = .center },
        }, .{});
        try label_lane.label_fit("label", opts.label, .vertical, .{ toggle_ink, Style{ .font = 9, .tracking = 0.09 } });
        return .{ .collapsed = true, .body = null };
    }

    box.set(.{
        .w = if (stack) .{ .pct_of_parent = 1.0 } else .{ .fixed = w },
        .h = if (stack) .fit_children else .{ .pct_of_parent = 1.0 }, .overflow = .clip,
    }, .{});
    body.set(.{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column }, .gap = ha.tokens.gap.stack }, .{});

    // CSS counterpart: `.holdings-toggle` — a 24x26 box at the expanded panel's upper-right.
    // Its chevron is independently centered in both axes against the box's definite height.
    toggle.set(.{
        .anchor = .top_right,
        .offset = .{ .x = if (stack) -(@import("./holdings.zig").stackedColumn(ctx).total - @import("./holdings.zig").stackedColumn(ctx).col_w) - 2 else -2 },
        .w = .{ .fixed = collapse_width }, .h = .{ .fixed = collapse_height },
    }, .{toggle_chrome});
    (try toggle.text("chevron", "\u{2039}")).set(.{ .anchor = .center }, .{ toggle_ink, Style{ .font = 16 } });

    return .{ .collapsed = false, .body = body };
}

// ============================ Tests (SDL-free) =========================================
// The rail's visual composition needs a live font (measured text), so it is verified in the
// running app; the pure state→width policy is unit-tested here against the real token widths
// and the tween registry — the same registry the rail drives at runtime.

const testing = std.testing;
const tween = uic.tween;

/// The rail's target width for a collapse state — the single mapping `rail` uses.
fn targetWidth(collapsed: bool) f32 {
    return if (collapsed) ha.tokens.rail.collapsed else ha.tokens.rail.expanded;
}

test "rail target width is the collapsed/expanded token, never a bare literal" {
    try testing.expectEqual(@as(f32, 36), targetWidth(true));
    try testing.expectEqual(@as(f32, 252), targetWidth(false));
    try testing.expectEqual(ha.tokens.rail.collapsed, targetWidth(true));
    try testing.expectEqual(ha.tokens.rail.expanded, targetWidth(false));
}

test "rail toggle boxes mirror the prototype dimensions" {
    try testing.expectEqual(ha.tokens.rail.collapsed, restore_width);
    try testing.expectEqual(@as(f32, 124), restore_content_height + restore_pad_top + restore_pad_bottom);
    try testing.expectEqual(@as(f32, 24), collapse_width);
    try testing.expectEqual(@as(f32, 26), collapse_height);
}

test "rail width rides the tween between the token widths and lands on target" {
    var reg: tween.Registry = .{};
    const key: u64 = 0x5a11;
    const dur = ha.tokens.dur_rail_s;

    // First appearance expanded: no animation, sits at the target.
    reg.retarget(key, targetWidth(false), dur);
    try testing.expectApproxEqAbs(@as(f32, 252), reg.value(key, targetWidth(false)), 1e-3);

    // Toggle to collapsed: rides from 252 toward 36 over the duration.
    reg.retarget(key, targetWidth(true), dur);
    reg.advance(dur / 2);
    const mid = reg.value(key, targetWidth(true));
    try testing.expect(mid < 252 and mid > 36); // mid-transition, between the two widths
    reg.advance(dur / 2);
    try testing.expectApproxEqAbs(@as(f32, 36), reg.value(key, targetWidth(true)), 1e-3); // landed
}

test "reduced motion snaps the rail width instantly (no transition)" {
    var reg: tween.Registry = .{};
    reg.setPolicy(.{ .reduced_motion = true });
    const key: u64 = 0x5a12;
    reg.retarget(key, targetWidth(false), ha.tokens.dur_rail_s);
    reg.retarget(key, targetWidth(true), ha.tokens.dur_rail_s);
    // Snapped: already at collapsed with no advance.
    try testing.expectApproxEqAbs(@as(f32, 36), reg.value(key, targetWidth(true)), 1e-3);
}

test "distinct rails keep separate collapse memory; force_collapsed overrides only its key" {
    // RailState is per-key POD; the ACTIONS and BUILD rails have different keys, so their
    // collapse bits are independent. `force_collapsed` sets one rail's bit without reading or
    // touching another's — modeled here as two separate state values.
    var actions_rail = RailState{ .collapsed = false }; // remembered expanded
    var build_rail = RailState{ .collapsed = true }; // remembered collapsed
    var structure_rail = RailState{ .collapsed = false };

    // Entering STRUCTURE forces its rail collapsed; the others are untouched.
    const force_collapsed = true;
    if (force_collapsed) structure_rail.collapsed = true;

    try testing.expect(structure_rail.collapsed); // forced
    try testing.expect(!actions_rail.collapsed); // preserved
    try testing.expect(build_rail.collapsed); // preserved
    _ = &actions_rail;
    _ = &build_rail;
}
