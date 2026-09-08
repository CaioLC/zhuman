//! `build_list` — the BUILD tab: a sorted, filtered list of what you can act on now.
//!
//! The pane it replaces put all sixteen goods on screen the frame you opened it, ordered
//! by how `capital.zig` implements them, with four different reasons for unavailability
//! collapsed into one flat grey. This asks one question — *what can I act on now* — and
//! answers it in rows, sorted so the top of the list is always the next thing.
//!
//! **Sort and filter rather than authored groups.** Grouping the roster by hand would only
//! be a second fixed taxonomy, so the axis belongs to the player: sort by reach, materials
//! or time; show what is ready, what is in reach, or everything. That last control is
//! where the "within reach" cutoff lives — a state you can see and change, not a constant
//! buried in a predicate. The old shelf captions survive demoted to an optional chip, and
//! crude/manufactured gets its own, because that split *cuts across* the behavioral
//! variants rather than restating them.
//!
//! Two rows are never filtered away: a build in progress (you need the way out) and the
//! Shelter, which sits below the list as a goal card because it is the act's ending rather
//! than an item in it.

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
const BuildViewState = uic.UiState.BuildViewState;

const gt = @import("./good_text.zig");
const row_mod = @import("./capital_row.zig");
const capital_row = row_mod.capital_row;
const Kind = row_mod.Kind;

/// Everything but the Shelter, which the goal card owns.
const listed = capital.buildable_bundle.len - 1;

const Entry = struct { i: usize, kind: Kind, reach: f32, mats: f32, hours: f32 };

/// One clickable word in the control strip. Accented while it is the active choice.
fn chip(ctx: *UiCtx, parent: El, id: []const u8, label: []const u8, on: bool) !bool {
    const th = ctx.res.view.theme;
    const box = try el.div(ctx, parent, id);
    const q = box.query();
    const c = if (on) th.acc else if (q.hovering) th.fg else th.dim;
    _ = (try el.text(ctx, box, "t", label)).with_style(.{ style.body, Style{ .text = c } });
    return q.clicked;
}

fn group_label(ctx: *UiCtx, parent: El, id: []const u8, label: []const u8) !El {
    const th = ctx.res.view.theme;
    const g = try el.div(ctx, parent, id);
    _ = g.with_flow(.{ .dir = .row, .cross = .center }).with_gap(9);
    _ = (try el.text(ctx, g, "l", label)).with_style(.{ style.body, Style{ .text = th.line2 } });
    return g;
}

/// The BUILD tab. `state_key` must be a node built on *every* frame — its pool slot is
/// pruned the moment it stops being built, and the list itself only exists while its tab
/// is active, so keying the view state on the list would reset sort and filter on every
/// visit to ACTIONS.
pub fn build_list(ctx: *UiCtx, parent: El, world: *World, e: Entity, state_key: El, id: []const u8) !El {
    const th = ctx.res.view.theme;
    const st = state_key.get().state(ctx, BuildViewState);

    const outer = try el.div(ctx, parent, id);
    _ = outer.with_flow(.{ .dir = .column }).with_gap(6);

    // --- the control strip ---------------------------------------------------------
    const strip = try el.div(ctx, outer, "strip");
    _ = strip.with_flow(.{ .dir = .row, .wrap = true, .cross = .center }).with_gap(22)
        .with_style(.{style.pad_each(0, 0, 6, 0)});

    const g_sort = try group_label(ctx, strip, "gs", "SORT");
    if (try chip(ctx, g_sort, "s0", "reach", st.sort == .reach)) st.sort = .reach;
    if (try chip(ctx, g_sort, "s1", "materials", st.sort == .materials)) st.sort = .materials;
    if (try chip(ctx, g_sort, "s2", "time", st.sort == .time)) st.sort = .time;

    const g_show = try group_label(ctx, strip, "gh", "SHOW");
    if (try chip(ctx, g_show, "h0", "ready", st.show == .ready)) st.show = .ready;
    if (try chip(ctx, g_show, "h1", "in reach", st.show == .in_reach)) st.show = .in_reach;
    if (try chip(ctx, g_show, "h2", "all", st.show == .all)) st.show = .all;

    const g_tier = try group_label(ctx, strip, "gt", "TIER");
    if (try chip(ctx, g_tier, "t0", "any", st.tier == .any)) st.tier = .any;
    if (try chip(ctx, g_tier, "t1", "crude", st.tier == .crude)) st.tier = .crude;
    if (try chip(ctx, g_tier, "t2", "made", st.tier == .manufactured)) st.tier = .manufactured;

    const g_own = try el.div(ctx, strip, "go");
    if (try chip(ctx, g_own, "b", if (st.built) "\u{25a0} built" else "\u{25a1} built", st.built)) st.built = !st.built;

    // --- the body: one line for a busy body, then the rows --------------------------
    const busy = world.get(e, comp.Busy);
    const building_good = busy != null and busy.?.doing != .forage and busy.?.doing != .scavenge and
        busy.?.doing != .fish and busy.?.doing != .chop_wood and busy.?.doing != .check_traps and
        busy.?.doing != .hunt;
    if (busy != null and !building_good) {
        // Labor, not a build: say so, so the rows below read as *waiting* rather than
        // unaffordable — the distinction the flat grey never made.
        var lbuf: [64]u8 = undefined;
        const left = busy.?.remaining / ctx.res.config.secs_per_day;
        const msg = std.fmt.bufPrint(&lbuf, "Your hands are busy \u{2014} {d:.1}d left.", .{left}) catch "Your hands are busy.";
        _ = (try el.text(ctx, outer, "busy", msg))
            .with_style(.{ style.body, Style{ .text = th.warn } });
    }

    // --- classify, filter, sort ------------------------------------------------------
    var buf: [listed]Entry = undefined;
    var n: usize = 0;
    const stock = world.get(e, comp.InventoryMaterial).?;
    const vigor = world.get(e, comp.Vigor).?;

    inline for (capital.buildable_bundle, 0..) |G, i| {
        if (G != comp.Shelter) {
            const cost = (G{}).requires;
            const owned = world.has(e, G);
            const doing_this = busy != null and busy.?.doing == capital.doing_of_good(G);
            const affordable = cost.energy < vigor.v and cost.materials <= stock.v;
            const reach = if (cost.materials <= 0) 1.0 else @min(1.0, stock.v / cost.materials);

            const kind: Kind = if (doing_this) .building else if (owned)
                .owned
            else if (!capital.prereq_met(world, e, G))
                .blocked
            else if (!capital.unlock_met(world, e, G))
                .locked
            else if (affordable and busy == null) .ready else .reach;

            const tier_ok = switch (st.tier) {
                .any => true,
                .crude => capital.is_crude(G),
                .manufactured => !capital.is_crude(G),
            };
            const show_ok = switch (st.show) {
                .all => true,
                // Blocked stays visible under every filter but `ready`: hiding it is
                // strictly worse than the grey tile it replaces, which at least told you
                // the thing existed.
                .in_reach => kind == .ready or kind == .blocked or reach >= 0.5,
                .ready => kind == .ready,
            };
            const owned_ok = st.built or !owned;
            // A build in progress is never filtered away — the corner is the way out.
            if (kind == .building or (tier_ok and show_ok and owned_ok)) {
                buf[n] = .{ .i = i, .kind = kind, .reach = reach, .mats = cost.materials, .hours = cost.hours };
                n += 1;
            }
        }
    }

    const entries = buf[0..n];
    const Cmp = struct {
        fn less(s: BuildViewState.Sort, a: Entry, b: Entry) bool {
            // A build in progress pins to the top under every sort: it is the one row
            // whose state is changing while you look at it.
            if ((a.kind == .building) != (b.kind == .building)) return a.kind == .building;
            return switch (s) {
                .reach => a.reach > b.reach,
                .materials => a.mats < b.mats,
                .time => a.hours < b.hours,
            };
        }
    };
    std.sort.insertion(Entry, entries, st.sort, Cmp.less);

    const rows = try el.div(ctx, outer, "rows");
    _ = rows.with_flow(.{ .dir = .column });

    if (n == 0) {
        _ = (try el.text(ctx, rows, "empty", "Nothing matches. Widen the filter."))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
    }

    for (entries, 0..) |ent, slot| {
        var idbuf: [8]u8 = undefined;
        const rid = std.fmt.bufPrint(&idbuf, "r{d}", .{slot}) catch "r";
        inline for (capital.buildable_bundle, 0..) |G, i| {
            if (G != comp.Shelter and i == ent.i) {
                const r = try capital_row(ctx, rows, world, e, G, rid, ent.kind, ent.reach);
                if (r.clicked_build) capital.begin_build(world, e, ctx.res, G);
                if (r.clicked_cancel) _ = capital.cancel_build(world, e, ctx.res);
            }
        }
    }

    // --- what the list does not hold: everything priced past one pair of hands -------
    var hidden: u32 = 0;
    inline for (capital.buildable_bundle) |G| {
        if (G != comp.Shelter and !capital.is_crude(G) and !world.has(e, G)) {
            const cost = (G{}).requires;
            if (cost.materials > stock.v) hidden += 1;
        }
    }
    if (hidden > 0 and st.show != .all) {
        // Two nodes, not one sentence: a text node holds 64 bytes and `TextState.update`
        // truncates past that *silently*, so a long line loses its tail rather than
        // wrapping or erroring.
        var hbuf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&hbuf, "{d} more are priced past one pair of hands.", .{hidden}) catch "";
        const foot = try el.div(ctx, outer, "hint");
        _ = foot.with_flow(.{ .dir = .column });
        _ = (try el.text(ctx, foot, "a", msg))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
        _ = (try el.text(ctx, foot, "b", "A trader might carry them."))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
    }

    try goal_card(ctx, outer, world, e, "goal", stock, vigor);
    return outer;
}

/// The Shelter, pinned below the list and outside the sort: it is how the act ends, not an
/// item in it. Its three standing conditions are shown live, because a good whose gate is
/// invisible is exactly the grey tile this pane was built to stop being.
fn goal_card(
    ctx: *UiCtx,
    parent: El,
    world: *World,
    e: Entity,
    id: []const u8,
    stock: *const comp.InventoryMaterial,
    vigor: *const comp.Vigor,
) !void {
    const th = ctx.res.view.theme;
    const G = comp.Shelter;
    if (world.has(e, G)) return; // owning it ends the act; the curtain is already up

    const cost = (G{}).requires;
    const u = (G{}).unlock;
    const food = world.get(e, comp.InventoryFood).?;
    const kinds = capital.goods_owned(world, e);

    const card = try el.div(ctx, parent, id);
    _ = card.with_flow(.{ .dir = .column }).with_gap(5)
        .with_style(.{ Style{ .outline_color = th.acc }, style.solid, style.pad_sym(10, 8) });

    const head = try el.div(ctx, card, "h");
    _ = head.with_flow(.{ .dir = .row, .cross = .center }).with_gap(10);
    _ = (try el.text(ctx, head, "n", gt.display_name(G)))
        .with_style(.{ style.h3, Style{ .text = th.acc } });
    var cbuf: [40]u8 = undefined;
    const ct = std.fmt.bufPrint(&cbuf, "{d:.0}m {d:.0}e  {d:.1}d", .{ cost.materials, cost.energy, cost.hours / 24.0 }) catch "?";
    _ = (try el.text(ctx, head, "c", ct)).with_style(.{ style.body, Style{ .text = th.dim } });
    _ = (try el.text(ctx, head, "s", "\u{2014} a roof with room for four, and how Act I ends"))
        .with_style(.{ style.body, Style{ .text = th.fg } });

    const checks = try el.div(ctx, card, "k");
    _ = checks.with_flow(.{ .dir = .row, .wrap = true, .cross = .center }).with_gap(20);

    var b1: [40]u8 = undefined;
    var b2: [40]u8 = undefined;
    var b3: [40]u8 = undefined;
    const frac = vigor.v / vigor.max;
    try check(ctx, checks, "c1", frac >= u.vigor_frac, std.fmt.bufPrint(&b1, "rested {d:.0}%/{d:.0}%", .{ frac * 100, u.vigor_frac * 100 }) catch "?");
    try check(ctx, checks, "c2", food.v >= u.food, std.fmt.bufPrint(&b2, "food {d:.0}/{d:.0}", .{ food.v, u.food }) catch "?");
    try check(ctx, checks, "c3", kinds >= u.goods, std.fmt.bufPrint(&b3, "goods {d}/{d}", .{ kinds, u.goods }) catch "?");

    const ready = capital.unlock_met(world, e, G) and cost.materials <= stock.v and
        cost.energy < vigor.v and !world.has(e, comp.Busy);
    const go = try el.div(ctx, card, "go");
    const q = go.query();
    const c = if (!ready) th.line2 else if (q.hovering) th.acc else th.fg;
    var mbuf: [48]u8 = undefined;
    const label = if (ready)
        "Raise the shelter \u{2192}"
    else
        std.fmt.bufPrint(&mbuf, "{d:.0}/{d:.0} materials", .{ stock.v, cost.materials }) catch "";
    _ = (try el.text(ctx, go, "t", label)).with_style(.{ style.body, Style{ .text = c } });
    if (ready and q.clicked) capital.begin_build(world, e, ctx.res, G);
}

fn check(ctx: *UiCtx, parent: El, id: []const u8, ok: bool, label: []const u8) !void {
    const th = ctx.res.view.theme;
    const box = try el.div(ctx, parent, id);
    _ = box.with_flow(.{ .dir = .row, .cross = .center }).with_gap(5);
    _ = (try el.text(ctx, box, "m", if (ok) "\u{2713}" else "\u{00b7}"))
        .with_style(.{ style.body, Style{ .text = if (ok) th.acc else th.danger } });
    _ = (try el.text(ctx, box, "t", label))
        .with_style(.{ style.body, Style{ .text = if (ok) th.dim else th.danger } });
}
