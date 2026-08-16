//! `action_tile` template — the compact, grid-scale presentation of one action: the
//! name on top, `-2  ⌒  +1-3f` beneath. This is the vocabulary the teaching card
//! (`action_card`) taught, at 10–20-tiles-on-screen density: *position* carries meaning
//! (the first slot is the price — unitless when it's energy, lettered otherwise: Eat's
//! `-1f`), the curve icon is the risk profile (see `action_info.kind_icon` — `fixed`'s
//! spike reads as "certain"), and the yield letter speaks the header resource bar's
//! V/F/M language. Chrome mirrors `button` — the whole tile dims when unaffordable,
//! accents on hover — so "which can I even afford" stays a one-glance scan across a
//! grid. The string-driven `tile` core draws the box; `action_tile` wraps it for the
//! typed action components (Requires/Yields), while one-off actions that don't fit that
//! shape (`eat_tile`) format their own strings and call `tile` directly.

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

pub const Tile = struct { el: El, clicked: bool };

/// The bare tile — box, name, `price · risk icon · payoff` row — from pre-formatted
/// strings. Reports the (affordability-gated) click; the caller acts on it.
pub fn tile(
    ctx: *UiCtx,
    parent: El,
    id: []const u8,
    name: []const u8,
    cost_txt: []const u8,
    kind: ha.dist.Kind,
    yield_txt: []const u8,
    can: bool,
) !Tile {
    const th = ctx.res.theme;

    const box = try el.div(ctx, parent, id);
    const chrome = if (!can) th.dim else if (box.query().hovering) th.acc else th.fg;
    _ = box.with_flow(.{ .dir = .column, .cross = .center }).with_gap(2)
        .with_style(.{ Style{ .outline_color = chrome }, style.pad_sym(12, 6) });

    _ = (try el.text(ctx, box, "name", name)).with_style(.{ style.h3, Style{ .text = chrome } });

    // Info row: price · risk shape · payoff. Center-aligned across (the icon box has no
    // baseline). Disabled ⟹ everything takes the dim chrome, one flat scan-off signal.
    const row = try el.div(ctx, box, "info");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);

    _ = (try el.text(ctx, row, "cost", cost_txt))
        .with_style(.{ style.body, Style{ .text = if (can) th.dim else chrome } });

    const icon = try el.svg(ctx, row, "kind", info.kind_icon(kind), icon_px);
    // `Style` has no svg-tint slot (yet) — recolor the raster's tint directly.
    icon.get().render_data.svg = if (can) th.dim else chrome;

    _ = (try el.text(ctx, row, "yield", yield_txt))
        .with_style(.{ style.body, Style{ .text = if (can) th.fg else chrome } });

    return .{ .el = box, .clicked = box.query().clicked and can };
}

/// A tile for one typed action component: formats price/band from the agent's own
/// `requires`/`yields` and funnels a click through `act_fn`. Returns the tile `El`
/// (null if the agent doesn't hold the action) — the caller places it.
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
    // Same strict energy gate as `gather`: spending vigor to exactly 0 would be death.
    const can = vigor.v > act.requires.energy;

    var cbuf: [16]u8 = undefined;
    const cost_txt = if (act.requires.materials > 0)
        std.fmt.bufPrint(&cbuf, "-{d:.0} -{d:.0}m", .{ act.requires.energy, act.requires.materials }) catch "?"
    else
        std.fmt.bufPrint(&cbuf, "-{d:.0}", .{act.requires.energy}) catch "?";

    const dom = info.dominant(act.yields);
    const lo = @round(dom.band.p10);
    const hi = @round(dom.band.p90);
    var ybuf: [16]u8 = undefined;
    const yield_txt = if (lo == hi)
        std.fmt.bufPrint(&ybuf, "+{d:.0}{c}", .{ hi, dom.letter }) catch "?"
    else
        std.fmt.bufPrint(&ybuf, "+{d:.0}-{d:.0}{c}", .{ lo, hi, dom.letter }) catch "?";

    const t = try tile(ctx, parent, id, name, cost_txt, dom.kind, yield_txt, can);
    if (t.clicked) act_fn(world, e, ctx.res);
    return t.el;
}
