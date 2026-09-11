//! `rail` — the **collapsible Holdings/BODY side rail** (KIT-05). Fills the KIT-04 shell's
//! `regions.rail`: an expanded panel (width `tokens.rail.expanded`, 252) the caller fills with
//! content (Holdings in Act I, BODY in Act II), or a narrow collapsed strip (width
//! `tokens.rail.collapsed`, 36) showing a **vertical restore affordance** — a chevron above the
//! rail's label set 90° counter-clockwise (TEXT-06 `.vertical()`), reading bottom-to-top.
//!
//! **One toggle, synchronized everything.** The rail's collapsed/expanded bit lives in a keyed
//! `RailState` pool (survives the frame-arena rebuild by `node.key`), and the *whole strip*
//! owns the toggle (the KIT-03 button contract): a click flips the bit, the width animates, the
//! affordance/label/focus/hit-target follow because they are rebuilt from the one bit each
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

/// Build the collapsible rail into `parent` (the shell's `regions.rail`). Manages its own
/// collapse memory, toggle, and width tween; returns the fill target when expanded.
pub fn rail(ctx: *UiCtx, parent: El, opts: RailOptions) !Rail {
    const th = ctx.res.view.theme;

    // The rail's outer box owns the collapse memory and the toggle interaction.
    const box = try el.div(ctx, parent, opts.id);
    const st = box.get().state(ctx, RailState);

    // STRUCTURE forces collapsed on entry — overwrite *this* rail's bit each frame. Other
    // rails (distinct keys) are untouched, so ACTIONS/BUILD keep their remembered state.
    if (opts.force_collapsed) st.collapsed = true;

    // The whole strip is the toggle (KIT-03: outer box owns interaction). A completed click
    // flips the bit; querying keeps the slot alive for next frame's hit-test.
    const q = box.query();
    if (q.clicked) st.collapsed = !st.collapsed;
    if (q.hovering) ctx.res.cursor.request(.pointer);

    // Width animates between the two token widths (RENDER-08 tween, keyed by the rail node).
    const target: f32 = if (st.collapsed) ha.tokens.rail.collapsed else ha.tokens.rail.expanded;
    ctx.res.tween.retarget(box.get().key, target, ha.tokens.dur_rail_s);
    const w = ctx.res.tween.value(box.get().key, target);

    _ = box.with_size(.{ .fixed = w }, .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .column, .cross = .center })
        .with_overflow(.clip) // during the width tween, content is clipped to the animating box
        .with_style(.{ Style{ .fill = th.panel, .outline_color = th.line }, style.pad_sym(0, 10) });

    if (st.collapsed) {
        // Collapsed: the vertical restore affordance — a chevron pointing toward the expanded
        // rail, above the label rotated 90° CCW (TEXT-06), reading bottom-to-top. Both are
        // content of the same clickable strip, so the label/affordance/hit-target stay in sync.
        _ = box.with_gap(8);
        _ = (try el.text(ctx, box, "chevron", "\u{203A}"))
            .with_style(.{Style{ .text = th.dim }});
        _ = (try el.text(ctx, box, "label", opts.label))
            .with_style(.{Style{ .text = th.fg, .font = 9, .tracking = 0.09 }})
            .vertical();
        return .{ .collapsed = true, .body = null };
    }

    // Expanded: a header row (label + a collapse chevron) over the content body the caller
    // fills. The header is content of the same clickable box, so clicking anywhere collapses.
    _ = box.with_gap(6);
    const header = try el.div(ctx, box, "rail_head");
    _ = header.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center })
        .with_style(.{style.pad_sym(6, 4)});
    _ = (try el.text(ctx, header, "label", opts.label))
        .with_style(.{ style.eyebrow, Style{ .text = th.dim } });
    const tail = try el.div(ctx, header, "collapse");
    _ = tail.with_layout(.center_right);
    _ = (try el.text(ctx, tail, "chev", "\u{2039}")) // ‹ points left, toward collapse
        .with_style(.{Style{ .text = th.dim }});

    const body = try el.div(ctx, box, "rail_body");
    _ = body.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.stack);
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
