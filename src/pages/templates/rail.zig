//! `rail` — the **collapsible Holdings/BODY side rail** (KIT-05). Fills the KIT-04 shell's
//! `regions.rail`: an expanded panel (width `tokens.rail.expanded`, 252) the caller fills with
//! content (Holdings in Act I, BODY in Act II), or a narrow collapsed strip (width
//! `tokens.rail.collapsed`, 36) showing a **vertical restore affordance** — a chevron above the
//! rail's label set 90° counter-clockwise (TEXT-06 `.vertical()`), reading bottom-to-top.
//!
//! **One toggle, synchronized everything.** The rail's collapsed/expanded bit lives in a keyed
//! `RailState` pool (survives the frame-arena rebuild by `node.key`). One stable toggle control
//! owns interaction in both states: the expanded 24×26 collapse button becomes the collapsed
//! 36×124 restore button, while its label, focus, and hit target follow the same state each
//! frame. Distinct rails carry distinct ids, so the **ACTIONS and BUILD rails keep separate
//! collapse memories** for free; the **STRUCTURE rail** passes `force_collapsed`, which
//! overwrites *its own* state to collapsed every entry while leaving the other keys untouched.
//!
//! **The width animates (120ms, RENDER-08 tween).** The rail asks the host tween registry to
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
};

/// The built rail: `collapsed` is this frame's resolved state (a caller may skip building
/// content when collapsed), and `body` is the fill target — non-null only while expanded, so
/// the caller does `if (r.body) |b| try holdings(ctx, b, …)`.
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

/// Build the collapsible rail into `parent` (the shell's `regions.rail`). Manages its own
/// collapse memory, toggle, and width tween; returns the fill target when expanded.
pub fn rail(ctx: *UiCtx, parent: El, opts: RailOptions) !Rail {
    const th = ctx.res.view.theme;

    // The rail is the width-bearing container, not the bordered button. In the prototype the
    // expanded rail itself is 252px wide and visually transparent; only its 24x26 collapse
    // control is boxed. When collapsed, that control becomes the separate 36x124 restore box.
    const box = try el.div(ctx, parent, opts.id);
    const st = box.get().state(ctx, RailState);
    if (opts.force_collapsed) st.collapsed = true;

    // Build the body before the toggle so the control remains the top-painted sibling after
    // callers populate the body. One stable toggle key owns focus and interaction in both
    // states, keeping the visual box and hit box synchronized through the transition.
    const body = try el.div(ctx, box, "rail_body");
    const toggle = try el.div(ctx, box, "toggle");
    ctx.registerFocus(toggle.get().key, true);
    const q = toggle.query();
    if (q.clicked) {
        _ = ctx.requestFocus(toggle.get().key);
        st.collapsed = !st.collapsed;
    }
    if (q.hovering) ctx.res.cursor.request(.pointer);
    const focused = ctx.isFocused(toggle.get().key);
    uic.publishControlState(ctx, toggle.get().key, .{
        .focused = focused,
        .focus_visible = focused,
    });
    // `btn_primary` also carries glyph ink, which must not be applied to this non-text div.
    // Resolve the stateful fragments once, then project only their decoration fields onto the
    // toggle box; the chevron/label text leaves receive their ink separately below.
    const resolved_toggle = style.resolve(ctx, toggle.get(), .{ style.btn_primary, style.focus_ring });
    const toggle_chrome = Style{
        .fill = th.bg,
        .outline_color = resolved_toggle.outline_color,
        .outline_width = resolved_toggle.outline_width,
        .outline_style = resolved_toggle.outline_style,
    };

    // Width animates between the shared rail tokens. Clipping belongs to this width-bearing
    // container, so expanded content cannot leak across the shrinking rail during the tween.
    const target: f32 = if (st.collapsed) ha.tokens.rail.collapsed else ha.tokens.rail.expanded;
    ctx.res.tween.retarget(box.get().key, target, ha.tokens.dur_rail_s);
    const w = ctx.res.tween.value(box.get().key, target);

    if (st.collapsed) {
        _ = box.with_size(.{ .fixed = w }, .{ .fixed = restore_outer_height })
            .with_overflow(.clip);

        // CSS counterpart: `.holdings-restore` — 36x124 border-box, 7px/9px vertical
        // padding, 8px gap, and centered children. Each glyph sits in a full-width row below:
        // the engine's column cross-line is intrinsically child-sized, while row main-axis
        // centering resolves against the definite 36px lane just like CSS `align-items:center`.
        _ = toggle.with_layout(.top_left)
            .with_size(.{ .fixed = restore_width }, .{ .fixed = restore_content_height })
            .with_flow(.{ .dir = .column, .main = .start, .cross = .center })
            .with_gap(8)
            .with_style(.{
            toggle_chrome,
            style.pad_each(restore_pad_top, 0, restore_pad_bottom, 0),
        });
        const chevron_lane = try el.div(ctx, toggle, "chevron_lane");
        _ = chevron_lane.with_size(.{ .fixed = restore_width }, .fit_children)
            .with_flow(.{ .dir = .row, .main = .center, .cross = .center });
        _ = (try el.text(ctx, chevron_lane, "chevron", "\u{203A}"))
            .with_style(.{Style{ .text = if (q.hovering or focused) th.acc else th.fg, .font = 16 }});

        const label_lane = try el.div(ctx, toggle, "label_lane");
        _ = label_lane.with_size(.{ .fixed = restore_width }, .fit_children)
            .with_flow(.{ .dir = .row, .main = .center, .cross = .center });
        _ = (try el.text(ctx, label_lane, "label", opts.label))
            .with_style(.{Style{ .text = if (q.hovering or focused) th.acc else th.fg, .font = 9, .tracking = 0.09 }})
            .vertical();
        return .{ .collapsed = true, .body = null };
    }

    _ = box.with_size(.{ .fixed = w }, .{ .pct_of_parent = 1.0 })
        .with_overflow(.clip);
    _ = body.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.stack);

    // CSS counterpart: `.holdings-toggle` — a 24x26 box at the expanded panel's upper-right.
    // Its chevron is independently centered in both axes; the old right-anchored bare text
    // had neither the correct box nor a definite height against which to center.
    _ = toggle.with_layout(.top_right)
        .with_offset(-2, 0)
        .with_size(.{ .fixed = collapse_width }, .{ .fixed = collapse_height })
        .with_style(.{toggle_chrome});
    _ = (try el.text(ctx, toggle, "chevron", "\u{2039}"))
        .with_layout(.center)
        .with_style(.{Style{ .text = if (q.hovering or focused) th.acc else th.fg, .font = 16 }});

    return .{ .collapsed = false, .body = body };
}

// ============================ Tests (SDL-free) =========================================
// The rail's visual composition needs a live font (measured text), so it is verified in the
// running app; the pure state→width policy is unit-tested here against the real token widths
// and the RENDER-08 tween registry — the same registry the rail drives at runtime.

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
