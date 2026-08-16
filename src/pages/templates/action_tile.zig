//! `action_tile` template — the compact, grid-scale presentation of one action: the
//! name on top, `-2  ⌒  +1-3f` beneath. This is the vocabulary the teaching card
//! (`action_card`) taught, at 10–20-tiles-on-screen density: *position* carries meaning
//! (the first slot is always the energy price, unitless on purpose), the curve icon is
//! the risk profile (see `action_info.kind_icon`), and the yield letter speaks the
//! header resource bar's V/F/M language. Chrome mirrors `button` — the whole tile dims
//! when unaffordable, accents on hover — so "which can I even afford" stays a one-glance
//! scan across a grid. Click funnels through `act_fn`; returns the tile `El` (null if
//! the agent doesn't hold the action) — the caller places it.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const uic = ha.ui_client;
const World = ha.world.World;
const Entity = ha.world.Entity;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

const info = @import("./action_info.zig");

/// Curve icon edge, in px — sized to ride beside body text.
const icon_px: f32 = 14;

pub fn action_tile(
    ctx: *UiCtx,
    parent: El,
    world: *World,
    e: Entity,
    comptime ActionT: type,
    id: []const u8,
    name: []const u8,
    comptime act_fn: anytype,
) !?El {
    if (!world.has(e, ActionT)) return null;
    const act = world.get(e, ActionT).?;
    const vigor = world.get(e, comp.Vigor).?;
    const th = ctx.res.theme;
    // Same strict energy gate as `gather`: spending vigor to exactly 0 would be death.
    const can = vigor.v > act.requires.energy;

    const tile = try el.div(ctx, parent, id);
    const chrome = if (!can) th.dim else if (tile.query().hovering) th.acc else th.fg;
    _ = tile.with_flow(.{ .dir = .column, .cross = .center }).with_gap(2)
        .with_style(.{ Style{ .outline_color = chrome }, style.pad_sym(12, 6) });
    if (tile.query().clicked and can) act_fn(world, e, ctx.res);

    _ = (try el.text(ctx, tile, "name", name)).with_style(.{ style.h3, Style{ .text = chrome } });

    // Info row: price · risk shape · payoff. Center-aligned across (the icon box has no
    // baseline). Disabled ⟹ everything takes the dim chrome, one flat scan-off signal.
    const row = try el.div(ctx, tile, "info");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);

    var buf: [16]u8 = undefined; // one leaf at a time — el.text copies at build
    const cost_txt = std.fmt.bufPrint(&buf, "-{d:.0}", .{act.requires.energy}) catch "?";
    _ = (try el.text(ctx, row, "cost", cost_txt))
        .with_style(.{ style.body, Style{ .text = if (can) th.dim else chrome } });
    if (act.requires.materials > 0) {
        const mat_txt = std.fmt.bufPrint(&buf, "-{d:.0}m", .{act.requires.materials}) catch "?";
        _ = (try el.text(ctx, row, "mcost", mat_txt))
            .with_style(.{ style.body, Style{ .text = if (can) th.dim else chrome } });
    }

    const dom = info.dominant(act.yields);
    const icon = try el.svg(ctx, row, "kind", info.kind_icon(dom.kind), icon_px);
    // `Style` has no svg-tint slot (yet) — recolor the raster's tint directly.
    icon.get().render_data.svg = if (can) th.dim else chrome;

    const lo = @round(dom.band.p10);
    const hi = @round(dom.band.p90);
    const yield_txt = if (lo == hi)
        std.fmt.bufPrint(&buf, "+{d:.0}{c}", .{ hi, dom.letter }) catch "?"
    else
        std.fmt.bufPrint(&buf, "+{d:.0}-{d:.0}{c}", .{ lo, hi, dom.letter }) catch "?";
    _ = (try el.text(ctx, row, "yield", yield_txt))
        .with_style(.{ style.body, Style{ .text = if (can) th.fg else chrome } });

    return tile;
}
