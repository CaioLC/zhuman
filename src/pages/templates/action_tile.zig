//! `action_tile` template — the compact, grid-scale presentation of one action: the
//! name on top, `-2  ⌒  +1-3f` beneath. This is the vocabulary the teaching
//! presentation taught, at 10–20-tiles-on-screen density: *position* carries meaning
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

/// The tile's type scale. `regular` is Act I's grid (h3 name, body metrics, 82px); `compact`
/// is Act II's long catalog (body name, 10px metrics, 52px) — the prototype's `.act-two .action-tile`,
/// so twenty verbs fit without scrolling past the fold. Anatomy, chrome and states are shared.
pub const Density = enum { regular, compact };

/// The outer tile height (border included) per density; callers size the box to it.
pub fn height(density: Density) f32 {
    return switch (density) {
        .regular => 81,
        .compact => 51,
    };
}

/// What a tile is showing: an action you can take now, one you cannot afford, or the one the
/// body is performing. Running wins over affordability: a running tile paints the same whether
/// or not its price is still payable.
pub const TileState = enum { ready, unaffordable, running };

/// The tile's state from its two facts (pure).
pub fn tileState(can: bool, running: bool) TileState {
    if (running) return .running;
    return if (can) .ready else .unaffordable;
}

/// The inks of one tile state: the box outline, the name, the optional state line, the metrics
/// (`−2e · 4h`), the curve icon's tint and the payoff.
pub const TileLook = struct { outline: Style, name: Style, state: Style, metric: Style, icon: Style, yield: Style };

/// Every tile state's inks. An unaffordable tile flattens everything onto dim, one scan-off
/// signal; a running one keeps the ready chrome and lights its state line. Only a ready tile is
/// an enabled control, and its name lifts to accent while hot; the outline keeps its rest.
pub const tile_looks = std.EnumArray(TileState, TileLook).init(.{
    .ready = .{
        .outline = .{ .outline_ink = .fg },
        .name = .{ .ink = .fg, .on = &.{.{ .when = .hot, .ink = .acc }} },
        .state = .{ .ink = .dim },
        .metric = .{ .ink = .dim },
        .icon = .{ .tint_ink = .dim },
        .yield = .{ .ink = .fg },
    },
    .unaffordable = .{
        .outline = .{ .outline_ink = .dim },
        .name = .{ .ink = .dim },
        .state = .{ .ink = .dim },
        .metric = .{ .ink = .dim },
        .icon = .{ .tint_ink = .dim },
        .yield = .{ .ink = .dim },
    },
    .running = .{
        .outline = .{ .outline_ink = .fg },
        .name = .{ .ink = .fg },
        .state = .{ .ink = .acc },
        .metric = .{ .ink = .dim },
        .icon = .{ .tint_ink = .dim },
        .yield = .{ .ink = .fg },
    },
});

/// An enabled action is an ordinary focus target. Once activation turns it into a running
/// progress readout, retain it only while it already owns focus; moving away removes the inert
/// tile from traversal on the next frame.
fn focusRegistrationEnabled(enabled: bool, running: bool, focused: bool) bool {
    return enabled or (running and focused);
}

/// The bare tile — box, name, optional **state line**, `price · risk icon · payoff` row —
/// from pre-formatted strings. Reports the (affordability-gated) click; the caller
/// acts on it. A non-null `progress` marks the tile as *running*: fg chrome, inert, and a
/// bottom underbar filling left-to-right (0..1) — a discrete task completing once. `state` is
/// an optional short status word ("short", "working") rendered **only when nonempty**; `cost_txt` is the normalized price segment
/// (`−{energy}e {optional input costs}`) and `duration_txt` the trailing duration, joined by a
/// middot. `kind` selects the curve glyph and its shared accessible label.
pub fn tile(
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
    density: Density,
) !Tile {
    const ctx = parent.ctx;
    const running = progress != null;
    const compact = density == .compact;
    const name_role: Style = if (compact) style.body else style.h3;
    const metric_role: Style = if (compact) Style{ .font = 10 } else style.body;

    const box = try parent.div(id);
    // Affordability/running remains authoritative here; the lifecycle publishes it. The tile's
    // accessible name is the action's own; its spoken value is the determinate progress
    // readout while running (from the same fraction the underbar fills to, so the bridge can
    // speak "62%"), else the risk profile's shared label (the curve glyph is not a
    // string, so "Forage" reads with its "normal" distribution).
    const enabled = !running and can;
    const was_focused = ctx.isFocused(box.get().key);
    var pbuf: [8]u8 = undefined;
    const value: []const u8 = if (progress) |p|
        std.mem.print(&pbuf, "{d:.0}%", .{std.math.clamp(p, 0, 1) * 100}) catch "?"
    else
        ha.dist.kindLabel(kind);
    const q = box.control(.{
        .enabled = enabled,
        .name = name,
        .role = .tile,
        .focusable = focusRegistrationEnabled(enabled, running, was_focused),
        .value = value,
        .ring = false, // a large tile shows hover and focus on its name, not a second outline
    });
    // The look is the state's (`tile_looks`); the name's hover/focus lift is its rule, and the
    // control publishes `disabled` on every other state.
    const look = tile_looks.get(tileState(can, running));
    // The box carries only the outline and a 1px bottom inset; the content padding lives
    // on `inner` — so the underbar (anchored in the box's content box, which then spans
    // the full width) runs edge to edge, flush *above* the inward 1px border line.
    box.set(.{ .flow = .{ .dir = .column } }, .{ look.outline, style.pad_each(0, 0, 1, 0) });

    const inner = try box.box("inner", .{
        .flow = .{ .dir = .column, .cross = .start }, .gap = 2,
    }, .{if (compact) style.pad_sym(8, 5) else style.pad_sym(12, 6)});

    try inner.label("name", name, .{ name_role, look.name });

    // An optional state line, rendered **only when nonempty** (e.g. "short",
    // "working"). Dim, small — it qualifies the tile without competing with the name.
    if (state.len > 0) {
        try inner.label("state", state, .{ style.small, look.state });
    }

    // Info row: metrics `−{energy}e {input costs} · {duration}`, then the risk-shape glyph and
    // the expected payoff. Center-aligned across (the icon box has no baseline).
    const row = try inner.box("info", .{ .flow = .{ .dir = .row, .cross = .center }, .gap = 6 }, .{});

    try row.label("cost", cost_txt, .{ metric_role, look.metric });
    // The middot joins the price segment and the duration, so additional input costs
    // stay in the price segment *before* the middot.
    try row.label("mid", "\u{00B7}", .{ metric_role, look.metric });
    try row.label("dur", duration_txt, .{ metric_role, look.metric });

    // Recolor the icon raster's ink through the style fold's `tint` field rather
    // than poking `render_data.svg` — same last-fragment-wins path as every other look.
    (try row.svg("kind", info.kind_icon(kind), if (compact) icon_px - 2 else icon_px)).set(.{}, .{look.icon});

    try row.label("yield", yield_txt, .{ metric_role, look.yield });

    // The underbar: full tile width × progress, a percentage of the box it is anchored in
    // (an out-of-flow child resolves against its parent's final size, so it never resizes
    // the tile and needs no prior-frame rect).
    if (progress) |p| {
        try box.leaf("bar", .{
            .anchor = .bottom_left, .w = .{ .pct_of_parent = std.math.clamp(p, 0, 1) }, .h = .{ .fixed = 3 },
        }, .{Style{ .fill_ink = .acc }});
    }

    return .{ .el = box, .clicked = !running and can and q.clicked };
}

/// A tile for one verb of the roster: formats price/band from the agent's quote and reports
/// the affordability-gated click. Returns the tile and its activation (null if the agent
/// doesn't hold the verb); the caller places it and calls the simulation — a template never
/// takes a domain operation as a parameter.
pub fn action_tile(
    parent: El,
    world: *World,
    e: Entity,
    ai: u16,
    id: []const u8,
    density: Density,
) !?Tile {
    const ctx = parent.ctx;
    const cat = &ctx.res.game.catalog;
    const act = ha.migration.actOf(world, e);
    const q = ha.actions.quote(world, e, cat, ctx.res.game.config, ai) orelse return null;
    const rec = cat.actions[ai];
    // One body, one act: any work in progress disables every tile; the one being
    // performed shows the underbar instead of dimming.
    const busy = world.get(e, comp.Busy);
    const running = busy != null and busy.?.isLabor(ai);
    const progress: ?f32 = if (running) 1.0 - busy.?.remaining / busy.?.total else null;
    // The same gates `begin` applies: strict energy, payable inputs, a free body.
    const can = q.ready();

    // Price segment: `−{energy}e` then every input line (e.g. Check traps' `−1m`), all
    // *before* the middot; the duration is the trailing segment after it. Amounts use
    // `fmt_amount` (one decimal only when fractional), so Forage reads `−1.7e` while
    // Scavenge reads `−2e` (metric style).
    const fmt = @import("../fmt.zig");
    var cbuf: [40]u8 = undefined;
    var cw = std.Io.Writer.fixed(&cbuf);
    {
        var ebuf: [8]u8 = undefined;
        cw.print("\u{2212}{s}e", .{fmt.fmt_amount(&ebuf, q.verb.requires.energy)}) catch {};
    }
    for (q.verb.input.slice()) |l| {
        var nbuf: [8]u8 = undefined;
        cw.print(" \u{2212}{s}{s}", .{ fmt.fmt_amount(&nbuf, l.n), info.letterOf(act, l.item) }) catch {};
    }
    const cost_txt = cw.buffered();
    var dbuf: [12]u8 = undefined;
    const duration_txt = std.mem.print(&dbuf, "{d:.0}h", .{q.verb.requires.hours}) catch "?";

    // The prototype action tile always keeps the same two-line anatomy: name, then metrics.
    // Running state is already communicated by the ActivityStrip and the tile's progress
    // underbar; affordability is communicated by disabled chrome. Do not insert a transient
    // status row here, because it changes the tile height when an action starts.
    const state_txt: []const u8 = "";

    // Band scaled by the same two-level factor `begin` locks in (weak = ×0.7 below the
    // WEARY threshold) — the promise is exactly what a click right now would pay.
    var ybuf: [16]u8 = undefined;
    var kind: ha.dist.Kind = .fixed;
    var yield_txt: []const u8 = "+0";
    if (info.dominant(act, cat, q.verb.output.slice())) |dom| {
        kind = dom.kind;
        const lo = @round(dom.band.p10 * q.quality);
        const hi = @round(dom.band.p90 * q.quality);
        yield_txt = if (lo == hi)
            std.mem.print(&ybuf, "+{d:.0}{s}", .{ hi, dom.letter }) catch "?"
        else
            std.mem.print(&ybuf, "+{d:.0}\u{2013}{d:.0}{s}", .{ lo, hi, dom.letter }) catch "?";
    }

    return try tile(parent, id, rec.name, state_txt, cost_txt, duration_txt, kind, yield_txt, can, progress, density);
}

test "running action retains existing focus without becoming a new tab stop" {
    try std.testing.expect(focusRegistrationEnabled(true, false, false));
    try std.testing.expect(focusRegistrationEnabled(false, true, true));
    try std.testing.expect(!focusRegistrationEnabled(false, true, false));
    try std.testing.expect(!focusRegistrationEnabled(false, false, true));
}

test "tileState: running wins over affordability" {
    try std.testing.expectEqual(TileState.ready, tileState(true, false));
    try std.testing.expectEqual(TileState.unaffordable, tileState(false, false));
    try std.testing.expectEqual(TileState.running, tileState(true, true));
    try std.testing.expectEqual(TileState.running, tileState(false, true));
}

test "tile_looks pins every state's inks" {
    const R = style.ThemeRole;
    const Row = struct { TileState, R, R, R, R, R, R };
    // outline, name, state line, metrics, icon, yield
    const want = [_]Row{
        .{ .ready, .fg, .fg, .dim, .dim, .dim, .fg },
        .{ .unaffordable, .dim, .dim, .dim, .dim, .dim, .dim },
        .{ .running, .fg, .fg, .acc, .dim, .dim, .fg },
    };
    for (want) |w| {
        const l = tile_looks.get(w[0]);
        try std.testing.expectEqual(w[1], l.outline.outline_ink.?);
        try std.testing.expectEqual(w[2], l.name.ink.?);
        try std.testing.expectEqual(w[3], l.state.ink.?);
        try std.testing.expectEqual(w[4], l.metric.ink.?);
        try std.testing.expectEqual(w[5], l.icon.tint_ink.?);
        try std.testing.expectEqual(w[6], l.yield.ink.?);
        // Only the ready name carries a rule: hot lifts it to accent.
        const rules = l.name.on;
        if (w[0] == .ready) {
            try std.testing.expectEqual(@as(usize, 1), rules.len);
            try std.testing.expectEqual(style.When.hot, rules[0].when);
            try std.testing.expectEqual(R.acc, rules[0].ink.?);
        } else try std.testing.expectEqual(@as(usize, 0), rules.len);
        inline for (.{ "outline", "state", "metric", "icon", "yield" }) |f| {
            try std.testing.expectEqual(@as(usize, 0), @field(l, f).on.len);
        }
    }
}
