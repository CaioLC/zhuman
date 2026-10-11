//! `capital_row` — one buildable good as a **row**, replacing the tile.
//!
//! A tile held two short strings, which is why its consequence column decayed into
//! notation. A row holds a sentence, a reach meter, a verb and a corner — and it is the
//! shape that lets a build in progress keep its place in the list instead of becoming a
//! 3px underbar on a dim box.
//!
//! Six fixed columns so every row's fields line up down the list. The last two carry the
//! row's *state*: an affordable good shows `Build →`, one out of reach shows how far
//! (`31/48m`), one in progress shows time left and a `×` in the corner that abandons it,
//! and one whose prerequisite is missing says which verb it wants.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const capital = ha.capital;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const World = ha.world.World;
const Entity = ha.world.Entity;
const Color = uic.Color;

const gt = @import("./good_text.zig");

/// The table's lanes, in order. The header and every row iterate this one array, so their
/// lanes cannot drift apart. `w` is the lane width in logical px; `hidden_at` is the widest
/// width class at which the lane is dropped — the lower-priority lanes go first as the
/// terminal narrows (KIT-18, the VIEW-04 pattern). The widths fit the canonical 594px
/// expanded Act-I content lane: 542px of cells, five 8px gaps, and 12px of row padding.
const Column = struct {
    id: []const u8,
    label: []const u8,
    w: f32,
    hidden_at: ?uic.view.WidthClass = null,

    fn visible(self: Column, ctx: *UiCtx) bool {
        const at = self.hidden_at orelse return true;
        return !ctx.res.view.metrics.width_class.atMost(at);
    }
};

const Lane = enum(usize) { recipe, cost, time, effect, state, corner };

const columns = [_]Column{
    .{ .id = "recipe", .label = "RECIPE", .w = 118 },
    .{ .id = "cost", .label = "COST", .w = 74 },
    .{ .id = "time", .label = "TIME", .w = 42, .hidden_at = .w560 },
    .{ .id = "effect", .label = "WHAT CHANGES", .w = 178, .hidden_at = .w440 },
    .{ .id = "state", .label = "STATE", .w = 76 },
    .{ .id = "corner", .label = "", .w = 54 },
};

fn col(lane: Lane) Column {
    return columns[@intFromEnum(lane)];
}

const row_gap: f32 = 8;
const row_pad_x: f32 = 6;

/// The visible lanes plus the gaps between them, logical px.
fn contentWidth(ctx: *UiCtx) f32 {
    var width: f32 = 0;
    var shown: f32 = 0;
    for (columns) |c| {
        if (c.visible(ctx)) {
            width += c.w;
            shown += 1;
        }
    }
    return width + (shown - 1) * row_gap;
}

pub fn tableWidth(ctx: *UiCtx) f32 {
    return contentWidth(ctx) + row_pad_x * 2;
}

fn header_cell(parent: El, id: []const u8, width: f32, label: []const u8) !void {
    const ctx = parent.ctx;
    const box = try parent.div(id);
    _ = box.with_size(.{ .fixed = width }, .fit_children);
    _ = (try box.text("t", label)).with_style(.{
        Style{ .font = 9, .tracking = 0.07, .text = ctx.res.view.theme.line2 },
    });
}

/// Column labels aligned to the exact same responsive lanes as every capital row.
pub fn capital_header(parent: El, id: []const u8) !El {
    const ctx = parent.ctx;
    const header = try parent.div(id);
    _ = header.with_size(.{ .fixed = contentWidth(ctx) }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(row_gap)
        .with_style(.{style.pad_sym(row_pad_x, 4)});
    for (columns) |c| {
        if (c.visible(ctx)) try header_cell(header, c.id, c.w, c.label);
    }
    return header;
}

/// What a row is showing, which is the one thing the flat grey never said.
pub const Kind = enum { ready, reach, building, blocked, locked, owned };

pub const Row = struct { kind: Kind, reach: f32, clicked_build: bool, clicked_cancel: bool };

fn cell(parent: El, id: []const u8, width: f32, text: []const u8, color: Color, right: bool) !void {
    const box = try parent.div(id);
    _ = box.with_size(.{ .fixed = width }, .fit_children);
    const inner = try box.div("i");
    _ = inner.with_layout(if (right) .center_right else .center_left);
    _ = (try inner.text_fit("t", text, .{ .cell = .{ .mode = .ellipsis, .width = width } }))
        .with_style(.{ style.body, Style{ .text = color } });
}

/// A catalog **name** cell (TEXT-03): the label is an ellipsis cell of exactly the column
/// width, so a long good name is elided (`Reinforced Timber Fra…`) instead of stretching the
/// row and knocking every downstream column out of its lane. The box and hit geometry stay
/// the allocated `width`; only the visible glyphs are bounded. A **secondary type** sub-label
/// (KIT-18) rides under the name in dim/small — the crude/manufactured tier word.
fn name_cell(parent: El, id: []const u8, width: f32, text: []const u8, secondary: []const u8, color: Color) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const box = try parent.div(id);
    _ = box.with_size(.{ .fixed = width }, .fit_children).with_flow(.{ .dir = .column, .cross = .start });
    _ = (try box.text_fit("t", text, .{ .cell = .{ .mode = .ellipsis, .width = width } }))
        .with_style(.{ style.body, Style{ .text = color } });
    if (secondary.len > 0) {
        _ = (try box.text_fit("ty", secondary, .{ .cell = .{ .mode = .ellipsis, .width = width } }))
            .with_style(.{ style.small, Style{ .text = th.dim } });
    }
}

/// One row. `state` decides the colors and what the last two columns say; the caller has
/// already decided the row belongs on screen at all (see `build_list`).
pub fn capital_row(
    parent: El,
    world: *World,
    e: Entity,
    comptime GoodT: type,
    index: usize,
    kind: Kind,
    reach: f32,
) !Row {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const cost = (GoodT{}).requires;

    // `index` is the recipe's catalog index: the row's identity across re-sorts and filters.
    const row = try parent.item("r", index);
    const hot = kind == .ready;
    const row_key = row.get().key;
    // The row is a composite tile: the good's display name is its accessible name and `hot`
    // is the same enabled fact the build click gates on.
    const q = row.control(.{ .enabled = hot, .name = gt.display_name(GoodT), .role = .tile });
    const lit: Color = switch (kind) {
        .ready => if (q.held or q.hovering or q.focused) th.acc else th.fg,
        .building => th.fg,
        .owned => th.dim,
        .reach, .blocked, .locked => th.dim,
    };
    const faint: Color = if (kind == .ready or kind == .building) th.dim else th.line2;

    // The row's lanes are the header's: the same columns, widths and visibility.
    _ = row.with_size(.{ .fixed = contentWidth(ctx) }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(row_gap)
        .with_style(.{ style.pad_sym(row_pad_x, 5), Style{ .fill = if (kind == .ready and (q.held or q.hovering or q.focused)) th.panel else null } });

    // Name + secondary type (crude vs manufactured — the row's KIT-18 type sub-label).
    const type_word = if (capital.is_crude(GoodT)) "crude" else "made";
    try name_cell(row, "nm", col(.recipe).w, gt.display_name(GoodT), type_word, lit);

    var cbuf: [24]u8 = undefined;
    const cost_txt = std.fmt.bufPrint(&cbuf, "{d:.0}m {d:.0}e", .{ cost.materials, cost.energy }) catch "?";
    try cell(row, "co", col(.cost).w, cost_txt, faint, false);

    if (col(.time).visible(ctx)) {
        var dbuf: [16]u8 = undefined;
        const days_txt = std.fmt.bufPrint(&dbuf, "{d:.1}d", .{cost.hours / 24.0}) catch "?";
        try cell(row, "dy", col(.time).w, days_txt, faint, false);
    }

    if (col(.effect).visible(ctx)) {
        try cell(row, "sa", col(.effect).w, gt.effect(GoodT), if (kind == .ready) th.fg else faint, false);
    }

    // --- state column: readiness, reach/materials, ownership, or live progress ------------
    const state = try row.div("st");
    _ = state.with_size(.{ .fixed = col(.state).w }, .fit_children);
    const state_in = try state.div("i");
    _ = state_in.with_layout(.center_left).with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);

    switch (kind) {
        .ready => _ = (try state_in.text("ready", "ready"))
            .with_style(.{ style.body, Style{ .text = th.acc } }),
        .owned => _ = (try state_in.text("owned", "owned"))
            .with_style(.{ style.body, Style{ .text = th.line2 } }),
        .blocked => {
            var nbuf: [32]u8 = undefined;
            const txt = std.fmt.bufPrint(&nbuf, "needs {s}", .{gt.prereq_name(GoodT) orelse "a tool"}) catch "needs a tool";
            _ = (try state_in.text("blocked", txt)).with_style(.{ style.body, Style{ .text = th.danger } });
        },
        .locked => _ = (try state_in.text("locked", "conditions"))
            .with_style(.{ style.body, Style{ .text = th.danger } }),
        .building => {
            const busy = world.get(e, comp.Busy).?;
            var bbuf: [20]u8 = undefined;
            const left = busy.remaining / ctx.res.config.secs_per_day;
            const txt = std.fmt.bufPrint(&bbuf, "{d:.1}d left", .{left}) catch "?";
            try meter(state_in, "meter", 1.0 - busy.remaining / busy.total, th.acc);
            _ = (try state_in.text("time", txt)).with_style(.{ style.body, Style{ .text = th.fg } });
        },
        .reach => {
            const stock = world.get(e, comp.InventoryMaterial).?;
            var rbuf: [24]u8 = undefined;
            const txt = std.fmt.bufPrint(&rbuf, "{d:.0}/{d:.0}m", .{ stock.v, cost.materials }) catch "?";
            try reach_meter(state_in, "meter", reach, th.line2);
            _ = (try state_in.text("materials", txt)).with_style(.{ style.body, Style{ .text = faint } });
        },
    }

    // --- right-side action column: Build → / Build +1 / cancel -----------------------------
    const action = try row.div("ac");
    _ = action.with_size(.{ .fixed = col(.corner).w }, .fit_children);
    const action_in = try action.div("i");
    _ = action_in.with_layout(.center_right);

    var build_more = false;
    var cancelled = false;
    var cancel_key: ?u64 = null;
    switch (kind) {
        .ready => _ = (try action_in.text("build", "Build \u{2192}"))
            .with_style(.{ style.body, Style{ .text = lit } }),
        .owned => {
            const stock = world.get(e, comp.InventoryMaterial).?;
            const busy = world.get(e, comp.Busy);
            const affordable = busy == null and stock.v >= cost.materials;
            if (affordable) {
                const more = try action_in.div("more");
                const mq = more.control(.{ .name = "Build +1", .role = .button });
                _ = (try more.text("t", "Build +1"))
                    .with_style(.{ style.body, Style{ .text = if (mq.held or mq.hovering or mq.focused) th.acc else th.dim } });
                build_more = more.consume(.clicked);
            }
        },
        .building => {
            const x = try action_in.div("cancel");
            const xq = x.control(.{ .name = "Cancel build", .role = .icon_button });
            _ = (try x.text("t", "\u{00d7}"))
                .with_style(.{ style.h3, Style{ .text = if (xq.held or xq.hovering or xq.focused) th.danger else th.line2 } });
            cancelled = x.consume(.clicked);
            cancel_key = x.get().key;
        },
        .reach, .blocked, .locked => {},
    }

    // INPUT-08: the row controls its cancel sub-action when one exists. The sub-action's key is
    // known only once it is built, so the row's published node is updated in place with the
    // relation (same key, first-seen paint order preserved).
    if (cancel_key) |ck| {
        ctx.res.semantics.publish(uic.semantic.describeTile(row_key, gt.display_name(GoodT), hot, q.focused, &[_]u64{ck}));
    }

    return .{
        .kind = kind,
        .reach = reach,
        // The corner sits inside the row, so hover still bubbles and keeps the row lit.
        // Its activation is consumed above; re-query after descendants for the action.
        // `clicked_build` fires for a ready row's whole-box click OR an owned row's `Build +1`.
        .clicked_build = (hot and row.query().clicked) or build_more,
        .clicked_cancel = cancelled,
    };
}

/// A thin progress bar (a build in progress) — continuous fill. Fixed width so the numbers
/// beside it stay in a column.
fn meter(parent: El, id: []const u8, frac: f32, color: Color) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const track = try parent.div(id);
    _ = track.with_size(.{ .fixed = 34 }, .{ .fixed = 3 })
        .with_style(.{Style{ .fill = th.line }});
    const fill = try track.div("f");
    _ = fill.with_layout(.top_left)
        .with_size(.{ .fixed = 34 * std.math.clamp(frac, 0, 1) }, .{ .fixed = 3 })
        .with_style(.{Style{ .fill = color }});
}

/// The **3-segment reach meter** (KIT-18): three fixed cells that light in sequence as `frac`
/// crosses 1/3, 2/3, 3/3 — a coarse "how close to affordable" read that quantizes the reach
/// into thirds rather than a smooth bar, matching the prototype's segmented treatment. A lit
/// segment takes `color`; an unlit one the inactive `line`.
fn reach_meter(parent: El, id: []const u8, frac: f32, color: Color) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const track = try parent.div(id);
    _ = track.with_size(.{ .fixed = 34 }, .{ .fixed = 4 }).with_flow(.{ .dir = .row }).with_gap(2);
    const lit_segments = reachSegments(frac);
    var s: usize = 0;
    while (s < 3) : (s += 1) {
        const seg = try track.item("s", s);
        _ = seg.with_size(.{ .fixed = 10 }, .{ .fixed = 4 })
            .with_style(.{Style{ .fill = if (s < lit_segments) color else th.line }});
    }
}

/// How many of the 3 reach segments are lit for a fraction — pure, tested. `>= 1/3` lights one,
/// `>= 2/3` two, `>= 1` all three; below `1/3` none.
pub fn reachSegments(frac: f32) usize {
    if (frac >= 1.0) return 3;
    if (frac >= 2.0 / 3.0) return 2;
    if (frac >= 1.0 / 3.0) return 1;
    return 0;
}

test "reachSegments quantizes reach into thirds" {
    try std.testing.expectEqual(@as(usize, 0), reachSegments(0.0));
    try std.testing.expectEqual(@as(usize, 0), reachSegments(0.32));
    try std.testing.expectEqual(@as(usize, 1), reachSegments(0.34));
    try std.testing.expectEqual(@as(usize, 1), reachSegments(0.5));
    try std.testing.expectEqual(@as(usize, 2), reachSegments(0.67));
    try std.testing.expectEqual(@as(usize, 3), reachSegments(1.0));
    try std.testing.expectEqual(@as(usize, 3), reachSegments(1.5));
}

test "wide BUILD table fits the expanded Act I content lane" {
    var cells: f32 = 0;
    for (columns) |c| cells += c.w;
    const content = cells + (columns.len - 1) * row_gap;
    try std.testing.expectEqual(@as(f32, 582), content);
    try std.testing.expectEqual(@as(f32, 594), content + 2 * row_pad_x);
}
