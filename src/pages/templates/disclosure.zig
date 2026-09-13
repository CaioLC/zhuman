//! `disclosure` — the **disclosure control** (KIT-11): a summary row that toggles a details
//! section open/closed. One reusable control for the milestone "details ↓ / close ↑" reveal and
//! any sort/filter panel whose anatomy is a summary over a disclosed body.
//!
//! **Synchronized by one bit.** The expanded/collapsed state lives in a pooled
//! `DisclosureState { expanded }` keyed by the control node (survives the frame-arena rebuild).
//! The **whole summary row owns the toggle** (the KIT-03 button contract — outer box owns
//! interaction, a click flips the bit), and the affordance label (`details ↓` vs `close ↑`),
//! the details visibility, focus, and the compact summary are all rebuilt from that one bit
//! each frame, so they can never disagree. The **details subtree is built only while expanded**,
//! so a collapsed disclosure has no details nodes and nothing in them is focusable.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const UiCtx = uic.UiCtx;
const DisclosureState = uic.UiState.DisclosureState;

/// The built disclosure: `expanded` this frame, and `details` — the box the caller fills with
/// the disclosed content, non-null only while expanded (`if (d.details) |b| …`).
pub const Disclosure = struct {
    expanded: bool,
    details: ?El,
};

/// Build a disclosure into `parent`. `summary` is the always-visible compact label; the
/// affordance reads `details ↓` when collapsed, `close ↑` when expanded. `enabled` gates the
/// toggle (KIT-03). Returns the details box to fill when open.
pub fn disclosure(ctx: *UiCtx, parent: El, id: []const u8, summary: []const u8, enabled: bool) !Disclosure {
    const th = ctx.res.view.theme;

    const box = try el.div(ctx, parent, id);
    _ = box.with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    const st = box.get().state(ctx, DisclosureState);

    // The summary row is the toggle: the whole row owns the interaction (KIT-03).
    const row = try el.div(ctx, box, "summary");
    ctx.registerFocus(row.get().key, enabled);
    const q = row.query();
    if (q.clicked and !enabled) _ = ctx.consumeFlag(row.get().key, .clicked); // disabled can't toggle
    if (q.clicked and enabled) {
        _ = ctx.requestFocus(row.get().key);
        st.expanded = !st.expanded;
    }
    const focused = ctx.isFocused(row.get().key);
    if (q.hovering) ctx.res.cursor.request(if (enabled) .pointer else .not_allowed);
    uic.publishControlState(ctx, row.get().key, .{ .disabled = !enabled, .focused = focused, .focus_visible = focused });

    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    _ = (try el.text(ctx, row, "sum", summary))
        .with_style(.{ style.body, Style{ .text = if (enabled) th.fg else th.dim } });
    const tail = try el.div(ctx, row, "aff");
    _ = tail.with_layout(.center_right)
        .with_flow(.{ .dir = .row }).with_gap(ha.tokens.gap.inline_)
        .with_size(.fit_children, .fit_children);
    // Keep the prototype wording, but give the directional glyph its own measured box. This
    // avoids font-side-bearing ambiguity from a single `"details ↓"` leaf and makes the visual
    // arrow sit predictably inside the whole-row click target.
    const action = if (st.expanded) "close" else "details";
    const arrow = if (st.expanded) "\u{2191}" else "\u{2193}";
    const affordance_color = if (focused or q.hovering) th.acc else th.dim;
    _ = (try el.text(ctx, tail, "word", action))
        .with_style(.{ style.small, Style{ .text = affordance_color } });
    _ = (try el.text(ctx, tail, "arrow", arrow))
        .with_style(.{ style.small, Style{ .text = affordance_color } });

    // The details subtree exists only while expanded (nothing in it is focusable when closed).
    const details = if (st.expanded and enabled) blk: {
        const d = try el.div(ctx, box, "details");
        _ = d.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
            .with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight)
            .with_style(.{style.pad_each(4, 0, 0, 0)});
        break :blk d;
    } else null;

    return .{ .expanded = st.expanded, .details = details };
}
