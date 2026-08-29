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
/// strings. Reports the (affordability-gated) click; the caller acts on it. A non-null
/// `progress` marks the tile as *running*: fg chrome, inert, and a bottom underbar
/// filling left-to-right (0..1) — a discrete task completing once, vs the ration dial's
/// repeating full-chip pulse.
pub fn tile(
    ctx: *UiCtx,
    parent: El,
    id: []const u8,
    name: []const u8,
    cost_txt: []const u8,
    kind: ha.dist.Kind,
    yield_txt: []const u8,
    can: bool,
    progress: ?f32,
) !Tile {
    const th = ctx.res.view.theme;
    const running = progress != null;

    const box = try el.div(ctx, parent, id);
    // Query unconditionally: an unqueried node has no slot, so stamp_rects skips it and
    // the prior-frame rect (which the underbar is sized from) would read null.
    const q = box.query();
    const chrome = if (running) th.fg else if (!can) th.dim else if (q.hovering) th.acc else th.fg;
    // The box carries only the outline and a 1px bottom inset; the content padding lives
    // on `inner` — so the underbar (anchored in the box's content box, which then spans
    // the full width) runs edge to edge, flush *above* the inward 1px border line.
    _ = box.with_flow(.{ .dir = .column })
        .with_style(.{ Style{ .outline_color = chrome }, style.pad_each(0, 0, 1, 0) });

    const inner = try el.div(ctx, box, "inner");
    _ = inner.with_flow(.{ .dir = .column, .cross = .center }).with_gap(2)
        .with_style(.{style.pad_sym(12, 6)});

    const lit = can or running; // dimmed tiles flatten everything onto the chrome

    _ = (try el.text(ctx, inner, "name", name)).with_style(.{ style.h3, Style{ .text = chrome } });

    // Info row: price · risk shape · payoff. Center-aligned across (the icon box has no
    // baseline). Disabled ⟹ everything takes the dim chrome, one flat scan-off signal.
    const row = try el.div(ctx, inner, "info");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);

    _ = (try el.text(ctx, row, "cost", cost_txt))
        .with_style(.{ style.body, Style{ .text = if (lit) th.dim else chrome } });

    const icon = try el.svg(ctx, row, "kind", info.kind_icon(kind), icon_px);
    // `Style` has no svg-tint slot (yet) — recolor the raster's tint directly.
    icon.get().render_data.svg = if (lit) th.dim else chrome;

    _ = (try el.text(ctx, row, "yield", yield_txt))
        .with_style(.{ style.body, Style{ .text = if (lit) th.fg else chrome } });

    // The underbar: full tile width × progress, sized from LAST frame's rect (this frame
    // isn't laid out yet — the prior-frame pattern). Anchored, so it never resizes the tile.
    if (progress) |p| {
        if (box.get().rect(ctx)) |r| {
            const bar = try el.div(ctx, box, "bar");
            _ = bar.with_layout(.bottom_left)
                .with_size(.{ .fixed = r.w * std.math.clamp(p, 0, 1) }, .{ .fixed = 3 })
                .with_style(.{Style{ .fill = th.acc }});
        }
    }

    return .{ .el = box, .clicked = !running and can and q.clicked };
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
    // One body, one act: any work in progress disables every tile; the one being
    // performed shows the underbar instead of dimming.
    const busy = world.get(e, comp.Busy);
    const running = busy != null and busy.?.doing == ha.actions.doing_of(ActionT);
    const progress: ?f32 = if (running) 1.0 - busy.?.remaining / busy.?.total else null;
    // Same strict energy gate as `begin_labor`: spending vigor to exactly 0 would be death.
    const can = busy == null and vigor.v > act.requires.energy;

    // Price row: energy (unitless — the universal price) then hours. Time is a price too:
    // under the metabolism, hours are food.
    var cbuf: [24]u8 = undefined;
    const cost_txt = if (act.requires.materials > 0)
        std.fmt.bufPrint(&cbuf, "-{d:.0} -{d:.0}m {d:.0}h", .{ act.requires.energy, act.requires.materials, act.requires.hours }) catch "?"
    else
        std.fmt.bufPrint(&cbuf, "-{d:.0} {d:.0}h", .{ act.requires.energy, act.requires.hours }) catch "?";

    // Band scaled by the same two-level factor `begin_labor` locks in (weak = ×0.7 below
    // the WEARY threshold) — the promise is exactly what a click right now would pay.
    const dom = info.dominant(act.yields);
    const quality = ha.actions.yield_factor(vigor, ctx.res.config);
    const lo = @round(dom.band.p10 * quality);
    const hi = @round(dom.band.p90 * quality);
    var ybuf: [16]u8 = undefined;
    const yield_txt = if (lo == hi)
        std.fmt.bufPrint(&ybuf, "+{d:.0}{c}", .{ hi, dom.letter }) catch "?"
    else
        std.fmt.bufPrint(&ybuf, "+{d:.0}-{d:.0}{c}", .{ lo, hi, dom.letter }) catch "?";

    const t = try tile(ctx, parent, id, name, cost_txt, dom.kind, yield_txt, can, progress);
    if (t.clicked) act_fn(world, e, ctx.res);
    return t.el;
}
