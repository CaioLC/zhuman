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

/// Column widths — 600px of content plus five 8px gaps is the 640 the tab already uses.
const w_name = 118;
const w_cost = 74;
const w_days = 42;
const w_says = 236;
const w_act = 110;
const w_corner = 20;

/// What a row is showing, which is the one thing the flat grey never said.
pub const Kind = enum { ready, reach, building, blocked, locked, owned };

pub const Row = struct { kind: Kind, reach: f32, clicked_build: bool, clicked_cancel: bool };

fn cell(ctx: *UiCtx, parent: El, id: []const u8, width: f32, text: []const u8, color: Color, right: bool) !void {
    const box = try el.div(ctx, parent, id);
    _ = box.with_size(.{ .fixed = width }, .fit_children);
    const inner = try el.div(ctx, box, "i");
    _ = inner.with_layout(if (right) .center_right else .center_left);
    _ = (try el.text(ctx, inner, "t", text)).with_style(.{ style.body, Style{ .text = color } });
}

/// One row. `state` decides the colors and what the last two columns say; the caller has
/// already decided the row belongs on screen at all (see `build_list`).
pub fn capital_row(
    ctx: *UiCtx,
    parent: El,
    world: *World,
    e: Entity,
    comptime GoodT: type,
    id: []const u8,
    kind: Kind,
    reach: f32,
) !Row {
    const th = ctx.res.view.theme;
    const cost = (GoodT{}).requires;

    const row = try el.div(ctx, parent, id);
    const hot = kind == .ready;
    uic.publishControlState(ctx, row.get().key, .{ .disabled = !hot });
    const q = row.query();
    const lit: Color = switch (kind) {
        .ready => if (q.held or q.hovering) th.acc else th.fg,
        .building => th.fg,
        .owned => th.dim,
        .reach, .blocked, .locked => th.dim,
    };
    const faint: Color = if (kind == .ready or kind == .building) th.dim else th.line2;

    _ = row.with_size(.{ .fixed = w_name + w_cost + w_days + w_says + w_act + w_corner + 5 * 8 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(8)
        .with_style(.{ style.pad_sym(6, 5), Style{ .fill = if (kind == .ready and (q.held or q.hovering)) th.panel else null } });

    try cell(ctx, row, "nm", w_name, gt.display_name(GoodT), lit, false);

    var cbuf: [24]u8 = undefined;
    const cost_txt = std.fmt.bufPrint(&cbuf, "{d:.0}m {d:.0}e", .{ cost.materials, cost.energy }) catch "?";
    try cell(ctx, row, "co", w_cost, cost_txt, faint, false);

    var dbuf: [16]u8 = undefined;
    const days_txt = std.fmt.bufPrint(&dbuf, "{d:.1}d", .{cost.hours / 24.0}) catch "?";
    try cell(ctx, row, "dy", w_days, days_txt, faint, false);

    try cell(ctx, row, "sa", w_says, gt.effect(GoodT), if (kind == .ready) th.fg else faint, false);

    // --- the state column ---------------------------------------------------------
    const act = try el.div(ctx, row, "ac");
    _ = act.with_size(.{ .fixed = w_act }, .fit_children);
    const act_in = try el.div(ctx, act, "i");
    _ = act_in.with_layout(.center_right).with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);

    switch (kind) {
        .ready => _ = (try el.text(ctx, act_in, "go", "Build \u{2192}"))
            .with_style(.{ style.body, Style{ .text = lit } }),
        .owned => _ = (try el.text(ctx, act_in, "ow", "built"))
            .with_style(.{ style.body, Style{ .text = th.line2 } }),
        .blocked => {
            var nbuf: [32]u8 = undefined;
            const txt = std.fmt.bufPrint(&nbuf, "needs {s}", .{gt.prereq_name(GoodT) orelse "a tool"}) catch "needs a tool";
            _ = (try el.text(ctx, act_in, "nd", txt)).with_style(.{ style.body, Style{ .text = th.danger } });
        },
        .locked => _ = (try el.text(ctx, act_in, "lk", "conditions"))
            .with_style(.{ style.body, Style{ .text = th.danger } }),
        .building => {
            const busy = world.get(e, comp.Busy).?;
            var bbuf: [20]u8 = undefined;
            const left = busy.remaining / ctx.res.config.secs_per_day;
            const txt = std.fmt.bufPrint(&bbuf, "{d:.1}d left", .{left}) catch "?";
            try meter(ctx, act_in, "bm", 1.0 - busy.remaining / busy.total, th.acc);
            _ = (try el.text(ctx, act_in, "bt", txt)).with_style(.{ style.body, Style{ .text = th.fg } });
        },
        .reach => {
            const stock = world.get(e, comp.InventoryMaterial).?;
            var rbuf: [24]u8 = undefined;
            const txt = std.fmt.bufPrint(&rbuf, "{d:.0}/{d:.0}m", .{ stock.v, cost.materials }) catch "?";
            try meter(ctx, act_in, "rm", reach, th.line2);
            _ = (try el.text(ctx, act_in, "rt", txt)).with_style(.{ style.body, Style{ .text = faint } });
        },
    }

    // --- the corner: the way out of a long build ----------------------------------
    const corner = try el.div(ctx, row, "cn");
    _ = corner.with_size(.{ .fixed = w_corner }, .fit_children);
    var cancelled = false;
    if (kind == .building) {
        const x = try el.div(ctx, corner, "x");
        _ = x.with_layout(.center_right);
        uic.publishControlState(ctx, x.get().key, .{});
        const xq = x.query();
        _ = (try el.text(ctx, x, "t", "\u{00d7}"))
            .with_style(.{ style.h3, Style{ .text = if (xq.held or xq.hovering) th.danger else th.line2 } });
        cancelled = x.consume(.clicked);
    }

    return .{
        .kind = kind,
        .reach = reach,
        // The corner sits inside the row, so hover still bubbles and keeps the row lit.
        // Its activation is consumed above; re-query after descendants for the action.
        .clicked_build = hot and row.query().clicked,
        .clicked_cancel = cancelled,
    };
}

/// A thin progress/reach bar. Fixed width so the numbers beside it stay in a column.
fn meter(ctx: *UiCtx, parent: El, id: []const u8, frac: f32, color: Color) !void {
    const th = ctx.res.view.theme;
    const track = try el.div(ctx, parent, id);
    _ = track.with_size(.{ .fixed = 34 }, .{ .fixed = 3 })
        .with_style(.{Style{ .fill = th.line }});
    const fill = try el.div(ctx, track, "f");
    _ = fill.with_layout(.top_left)
        .with_size(.{ .fixed = 34 * std.math.clamp(frac, 0, 1) }, .{ .fixed = 3 })
        .with_style(.{Style{ .fill = color }});
}
