//! `button` template — a clickable, outlined box hugging a text label, in the game's
//! chrome. The exemplar for the shelf: a *template* is a game-specific (theme-aware)
//! composition built entirely from the `ui_client` foundation — a content leaf
//! (`elements.text`) plus style (`style.apply`) and placement (`style.apply_placement`)
//! composed onto it. It owns none of that machinery; it just arranges it and picks the
//! colors from `res.theme` + interaction.
//!
//! The interaction-driven chrome (dim if disabled, accent on hover, else fg) is computed
//! inline off the outer box's own interaction slot — the template builds the node, so it
//! reads `outer.query(ctx)` directly rather than deferring to a `fn` style fragment (that
//! form is for call sites composing a node they didn't build). Returns the outer node; the
//! caller reads `.query(ctx).clicked` and still guards the click (`enabled` is only the look).

const ha = @import("ha");

const ui = ha.ui;
const uic = ha.ui_client;
const style = uic.style;
const elements = uic.elements;
const UiCtx = uic.UiCtx;
const Node = uic.Node;

pub fn button(ctx: *UiCtx, parent: *Node, id: []const u8, label: []const u8, enabled: bool) !*Node {
    const th = ctx.res.theme;

    // Outer clickable box: a relative child that flows, lays its label out horizontally,
    // and hugs it (fit_children). No content of its own — just the outline chrome.
    const outer = try Node.pcreate(ctx.arena, id, parent);
    style.apply_placement(outer, .{ style.flow, style.row, style.fit });

    // Label content leaf; padding lives on it so the glyphs clear the box border.
    const lbl = try elements.text(ctx, outer, "lbl", label);
    style.apply_placement(lbl, .{style.flow});

    // Chrome: dim disabled, accent on hover (read off the box's slot), else soft fg.
    // Querying also keeps the slot alive for next frame's hit-test (same as the caller's
    // `.clicked` read). Box draws the outline, label its text — both in `c`.
    const c = if (!enabled) th.dim else if (outer.query(ctx).hovering) th.acc else th.fg;
    style.apply(ctx, lbl, .{style.Style{ .text = c, .padding = ui.Padding.initSymmetric(8, 4) }});
    style.apply(ctx, outer, .{style.Style{ .outline = c }});

    return outer;
}
