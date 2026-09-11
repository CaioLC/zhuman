//! `board_primitives` (KIT-23) — the small, **generic** building blocks the STRUCTURE board
//! (Act II) composes from: `tag`, `cost_list`, `legend`, `zoom_controls`, and `empty_state`.
//! They are deliberately domain-free — every string is the caller's, so the technology/sector
//! wording stays in the STRUCTURE screen and these templates never encode Act II vocabulary.
//! They reuse the KIT-02 fragments (`style.tag`, `style.legend_dot`) so their look tracks the
//! one theme.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

/// A **tag** — a small `line`-bordered `dim` label (the KIT-02 `style.tag` fragment). Caller
/// supplies the text; returns the tag `El`. Metadata chrome, not a control.
pub fn tag(ctx: *UiCtx, parent: El, id: []const u8, text: []const u8) !El {
    const box = try el.div(ctx, parent, id);
    _ = box.with_flow(.{ .dir = .row }).with_style(.{ style.tag, style.pad_sym(6, 1) });
    _ = (try el.text(ctx, box, "t", text)).with_style(.{ style.small, style.tag });
    return box;
}

/// One cost item: a label and its amount (the caller formats both — no domain math).
pub const Cost = struct { label: []const u8, amount: []const u8 };

/// A **cost list** — a compact column of `{label}  {amount}` rows, right-aligned amounts, from
/// a caller-supplied slice. Generic: the caller names the resources.
pub fn cost_list(ctx: *UiCtx, parent: El, id: []const u8, costs: []const Cost) !El {
    const th = ctx.res.view.theme;
    const col = try el.div(ctx, parent, id);
    _ = col.with_flow(.{ .dir = .column }).with_gap(ha.tokens.gap.tight).with_size(.fit_children, .fit_children);
    for (costs, 0..) |c, i| {
        const key = try std.fmt.allocPrint(ctx.arena, "c{d}", .{i});
        const row = try el.div(ctx, col, key);
        _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.group)
            .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
        _ = (try el.text(ctx, row, "l", c.label)).with_style(.{ style.small, Style{ .text = th.dim } });
        const tail = try el.div(ctx, row, "r");
        _ = tail.with_layout(.center_right);
        _ = (try el.text(ctx, tail, "a", c.amount)).with_style(.{ style.body, Style{ .text = th.fg } });
    }
    return col;
}

/// One legend entry: a resource hue (the KIT-01/02 `style.Resource`) and its caller label.
pub const LegendItem = struct { resource: style.Resource, label: []const u8 };

/// A **legend** — a row (or wrap) of `● {label}` entries, each dot filled with its resource
/// hue via the KIT-02 `style.legend_dot` fragment (so the legend cites the resource, not a
/// color). The labels are the caller's.
pub fn legend(ctx: *UiCtx, parent: El, id: []const u8, items: []const LegendItem) !El {
    const th = ctx.res.view.theme;
    const row = try el.div(ctx, parent, id);
    _ = row.with_flow(.{ .dir = .row, .wrap = true, .cross = .center }).with_gap(ha.tokens.gap.group)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    for (items, 0..) |item, i| {
        const key = try std.fmt.allocPrint(ctx.arena, "L{d}", .{i});
        const cell = try el.div(ctx, row, key);
        _ = cell.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_);
        const dot = try el.div(ctx, cell, "d");
        _ = dot.with_size(.{ .fixed = 8 }, .{ .fixed = 8 }).with_style(.{legendFrag(item.resource)});
        _ = (try el.text(ctx, cell, "t", item.label)).with_style(.{ style.small, Style{ .text = th.dim } });
    }
    return row;
}

/// Resolve a runtime `Resource` to its `legend_dot` fill fragment. `style.legend_dot` is
/// comptime-keyed (a distinct fragment per hue), so switch the runtime value to the right one.
fn legendFrag(r: style.Resource) fn (*UiCtx, *uic.Node) Style {
    return switch (r) {
        .food => style.legend_dot(.food),
        .water => style.legend_dot(.water),
        .fuel => style.legend_dot(.fuel),
        .metal => style.legend_dot(.metal),
        .minerals => style.legend_dot(.minerals),
        .biomass => style.legend_dot(.biomass),
    };
}

/// **Zoom controls** — `−` / `reset` / `+` buttons for a board camera. Reports which was
/// pressed this frame; the caller owns the zoom value (the control owns no camera math).
pub const Zoom = enum { none, out, reset, in };

fn zoom_button(ctx: *UiCtx, parent: El, id: []const u8, label: []const u8) !bool {
    const box = try el.div(ctx, parent, id);
    ctx.registerFocus(box.get().key, true);
    const q = box.query();
    if (q.clicked) _ = ctx.requestFocus(box.get().key);
    const focused = ctx.isFocused(box.get().key);
    if (q.hovering) ctx.res.cursor.request(.pointer);
    uic.publishControlState(ctx, box.get().key, .{ .focused = focused, .focus_visible = focused });
    const s = style.resolve(ctx, box.get(), .{style.btn_primary});
    if (s.outline_color) |c| box.get().render_data.outline = .{ .color = c };
    _ = box.with_flow(.{ .dir = .row }).with_style(.{style.pad_sym(8, 2)});
    _ = (try el.text(ctx, box, "l", label)).with_style(.{style.btn_primary});
    return q.clicked;
}

pub fn zoom_controls(ctx: *UiCtx, parent: El, id: []const u8) !Zoom {
    const row = try el.div(ctx, parent, id);
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_);
    var z: Zoom = .none;
    if (try zoom_button(ctx, row, "out", "\u{2212}")) z = .out; // −
    if (try zoom_button(ctx, row, "reset", "reset")) z = .reset;
    if (try zoom_button(ctx, row, "in", "+")) z = .in;
    return z;
}

/// An **empty state** — a centered `message` with an optional dim `hint` beneath it, for a
/// board/list with nothing to show. Generic copy from the caller.
pub fn empty_state(ctx: *UiCtx, parent: El, id: []const u8, message: []const u8, hint: []const u8) !El {
    const th = ctx.res.view.theme;
    const box = try el.div(ctx, parent, id);
    _ = box.with_layout(.center).with_flow(.{ .dir = .column, .cross = .center }).with_gap(ha.tokens.gap.tight);
    _ = (try el.text(ctx, box, "m", message)).with_style(.{ style.body, Style{ .text = th.dim } });
    if (hint.len > 0)
        _ = (try el.text(ctx, box, "h", hint)).with_style(.{ style.small, Style{ .text = th.line2 } });
    return box;
}
