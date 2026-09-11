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

/// The bare tile — box, name, optional **state line**, `price · risk icon · payoff` row —
/// from pre-formatted strings (KIT-17). Reports the (affordability-gated) click; the caller
/// acts on it. A non-null `progress` marks the tile as *running*: fg chrome, inert, and a
/// bottom underbar filling left-to-right (0..1) — a discrete task completing once, vs the
/// ration dial's repeating full-chip pulse. `state` is an optional short status word ("short",
/// "working") rendered **only when nonempty**; `cost_txt` is the normalized price segment
/// (`−{energy}e {optional input costs}`) and `duration_txt` the trailing duration, joined by a
/// middot. `kind` selects the curve glyph and its shared accessible label.
pub fn tile(
    ctx: *UiCtx,
    parent: El,
    id: []const u8,
    name: []const u8,
    state: []const u8,
    cost_txt: []const u8,
    duration_txt: []const u8,
    kind: ha.dist.Kind,
    yield_txt: []const u8,
    can: bool,
    progress: ?f32,
) !Tile {
    const th = ctx.res.view.theme;
    const running = progress != null;

    const box = try el.div(ctx, parent, id);
    // Affordability/running remains authoritative here; publication is a visual/semantic
    // projection and explicitly clears stale disabled state when the facts change.
    const box_key = box.get().key;
    const enabled = !running and can;
    ctx.registerFocus(box_key, enabled);
    const q = box.query();
    if (q.clicked and enabled) _ = ctx.requestFocus(box_key);
    const focused = ctx.isFocused(box_key);
    uic.publishControlState(ctx, box_key, .{
        .disabled = !enabled,
        .focused = focused,
        .focus_visible = focused,
    });
    // INPUT-08: an action tile is a composite actionable node. Its accessible name is the
    // action's own name (authoritative); `enabled` is the same affordability/running gate.
    // When running it carries a determinate progress readout as its value, from the same
    // `progress` fraction the underbar fills to — so the bridge can speak "62%".
    var tile_node = uic.semantic.describeTile(box_key, name, enabled, focused, &[_]u64{});
    if (progress) |p| {
        var pbuf: [8]u8 = undefined;
        const readout = std.fmt.bufPrint(&pbuf, "{d:.0}%", .{std.math.clamp(p, 0, 1) * 100}) catch "?";
        _ = tile_node.setValue(readout);
    } else {
        // KIT-17: the risk profile's shared accessible label rides as the tile's spoken value
        // (the curve glyph is not a string), so "Forage" reads with its "normal" distribution.
        _ = tile_node.setValue(ha.dist.kindLabel(kind));
    }
    ctx.res.semantics.publish(tile_node);
    if (q.hovering) ctx.res.cursor.request(if (enabled) .pointer else .not_allowed);
    const chrome = if (running) th.fg else if (!enabled) th.dim else if (q.held or q.hovering or focused) th.acc else th.fg;
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

    // KIT-17: an optional state line, rendered **only when nonempty** (e.g. "short",
    // "working"). Dim, small — it qualifies the tile without competing with the name.
    if (state.len > 0) {
        _ = (try el.text(ctx, inner, "state", state))
            .with_style(.{ style.small, Style{ .text = if (running) th.acc else if (!enabled) th.dim else th.dim } });
    }

    // Info row: metrics `−{energy}e {input costs} · {duration}`, then the risk-shape glyph and
    // the expected payoff. Center-aligned across (the icon box has no baseline). Disabled ⟹
    // everything takes the dim chrome, one flat scan-off signal.
    const row = try el.div(ctx, inner, "info");
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(6);

    _ = (try el.text(ctx, row, "cost", cost_txt))
        .with_style(.{ style.body, Style{ .text = if (lit) th.dim else chrome } });
    // The middot joins the price segment and the duration (KIT-17), so additional input costs
    // stay in the price segment *before* the middot.
    _ = (try el.text(ctx, row, "mid", "\u{00B7}"))
        .with_style(.{ style.body, Style{ .text = if (lit) th.dim else chrome } });
    _ = (try el.text(ctx, row, "dur", duration_txt))
        .with_style(.{ style.body, Style{ .text = if (lit) th.dim else chrome } });

    // RENDER-02: recolor the icon raster's ink through the style fold's `tint` field rather
    // than poking `render_data.svg` — same last-fragment-wins path as every other look.
    _ = (try el.svg(ctx, row, "kind", info.kind_icon(kind), icon_px))
        .with_style(.{Style{ .tint = if (lit) th.dim else chrome }});

    _ = (try el.text(ctx, row, "yield", yield_txt))
        .with_style(.{ style.body, Style{ .text = if (lit) th.fg else chrome } });

    // The underbar: full tile width × progress, sized from LAST frame's rect (this frame
    // isn't laid out yet — the prior-frame pattern). Anchored, so it never resizes the tile.
    if (progress) |p| {
        if (box.get().rect(ctx)) |r| {
            const bar = try el.div(ctx, box, "bar");
            // `r.w` is the stamped (device-px) box width; the underbar width tracks it, so use
            // `with_size_px` (VIEW-02) — the 3px logical height is scaled through `view.dp`.
            _ = bar.with_layout(.bottom_left)
                .with_size_px(.{ .fixed = r.w * std.math.clamp(p, 0, 1) }, .{ .fixed = uic.view.dp(3, ctx.res.view.scale) })
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

    // Price segment (KIT-17): `−{energy}e` then any additional input costs (e.g. Check traps'
    // `−1m`), all *before* the middot; the duration is the trailing segment after it.
    var cbuf: [24]u8 = undefined;
    const cost_txt = if (act.requires.materials > 0)
        std.fmt.bufPrint(&cbuf, "-{d:.0}e -{d:.0}m", .{ act.requires.energy, act.requires.materials }) catch "?"
    else
        std.fmt.bufPrint(&cbuf, "-{d:.0}e", .{act.requires.energy}) catch "?";
    var dbuf: [12]u8 = undefined;
    const duration_txt = std.fmt.bufPrint(&dbuf, "{d:.0}h", .{act.requires.hours}) catch "?";

    // Optional state line (KIT-17), rendered only when nonempty: "working" while this action
    // runs, "short" when it is unaffordable (not enough vigor), else empty (ready).
    const state_txt: []const u8 = if (running) "working" else if (!can) "short" else "";

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

    const t = try tile(ctx, parent, id, name, state_txt, cost_txt, duration_txt, dom.kind, yield_txt, can, progress);
    if (t.clicked) act_fn(world, e, ctx.res);
    return t.el;
}
