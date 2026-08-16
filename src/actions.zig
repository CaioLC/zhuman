//! Actions definitions.
//!
//! Actions are direct manipulation of component states
const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const tag = ha.tag;
const dist = ha.dist;
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");
const world = @import("./world.zig");

const Resources = res_mod.Resources;
const World = world.World;
const Entity = world.Entity;
const Query = ecs.Query;
const With = ecs.With;

// --- actions archetypes (World.spawn bundles) ---
// The *innate* actions — what a bare-handed human can do from the first breath. Fish is
// deliberately absent: the verb arrives with the fish rod (an Unlocker capital good —
// `capital.build_fish_rod` grants `ActionFish` when the rod is built).
pub const actions_bundle = .{
    comp.ActionChopWood,
    comp.ActionForage,
};

// action queues
// (`action_eat` was removed 2026-08-15: eating moved onto the continuous metabolism loop
// — `systems.metabolize` — with a player-set ration rate. Eating is no longer an action.)

// --- labor quality: two levels, one constant step ---
// Below `weak_frac` of max vigor an agent is *weak* and its labor yields scale by
// `weak_factor`. Deliberately NOT a linear slide (that was built once and reverted): a
// constant step keeps the advertised band stable — it only changes at the threshold
// crossing — and the threshold reuses `actor_status`'s WEARY line, which the header's V
// chip already tints warn, so the state is announced before the band changes. Both the
// sim (`gather`) and the tiles' displayed bands call `yield_factor`, so the promise and
// the draw can never drift.

/// Vigor fraction below which labor weakens (== the WEARY threshold).
pub const weak_frac: f32 = 0.35;
/// Yield multiplier while weak.
pub const weak_factor: f32 = 0.7;

/// The current yield multiplier for an agent's vigor — 1.0, or `weak_factor` when weak.
pub fn yield_factor(vigor: *const comp.Vigor) f32 {
    return if (vigor.v / vigor.max < weak_frac) weak_factor else 1.0;
}

/// The runtime name of a labor action type — what a `Busy` can store so `resolve_busy`
/// can dispatch back to the comptime type at completion. Manual mapping, the same idiom
/// as `actions_bundle` (a fact about types, not entities).
pub fn doing_of(comptime ActionT: type) comp.Busy.Doing {
    return switch (ActionT) {
        comp.ActionForage => .forage,
        comp.ActionFish => .fish,
        comp.ActionChopWood => .chop_wood,
        else => @compileError("no Busy.Doing for " ++ @typeName(ActionT)),
    };
}

/// The **begin** half of a labor action: gate → pay → start the work. The yield resolves
/// only at completion (`finish_labor`, via `systems.resolve_busy`) — you don't get food
/// before the work is done, and dying mid-task loses it. Quality is locked here: the band
/// the tile advertised at the click is the band the draw will use, even if the metabolism
/// drains the body while working. Refuses while `Busy` (one body, one act at a time).
fn begin_labor(w: *World, e: Entity, res: *Resources, comptime ActionT: type) void {
    if (w.has(e, comp.Busy)) return; // one body, one act
    const act, const vigor, const stock = ecs.getMany(w, e, .{ ActionT, comp.Vigor, comp.InventoryMaterial });
    // Energy is strict (spending vigor to exactly 0 is death); materials may be spent to
    // exactly 0 — `>=` here blocked every zero-materials action on a fresh spawn (0 >= 0).
    if (act.requires.energy >= vigor.v or act.requires.materials > stock.v) {
        return; // cannot do the action
    }

    const quality = yield_factor(vigor);
    const frac_before = vigor.v / vigor.max;

    // Pay the price upfront. The strict energy gate above keeps vigor > 0, so labor alone
    // can't kill — running the body to death takes starving it of the refill.
    vigor.v -= act.requires.energy;
    stock.v -= act.requires.materials;
    if (frac_before >= weak_frac and vigor.v / vigor.max < weak_frac)
        res.log.push(.warn, "You feel weak. Work will yield less.");

    const total = res_mod.hours_to_secs(act.requires.hours);
    w.add(e, comp.Busy{ .doing = doing_of(ActionT), .total = total, .remaining = total, .quality = quality });

    res.game.tutorial_done = true; // the first begun action ends the teaching presentation
}

/// The **finish** half: draw the yield from `dist.sample` at the quality locked at begin
/// (the spread *is* the risk — no separate success roll), deposit, and log the receipt.
/// Called by `systems.resolve_busy` when the work's timer runs out.
pub fn finish_labor(w: *World, e: Entity, res: *Resources, comptime ActionT: type, quality: f32) void {
    const act, const stock, const food = ecs.getMany(w, e, .{ ActionT, comp.InventoryMaterial, comp.InventoryFood });
    const got_food = quality * dist.sample(act.yields.food, res.random());
    const got_mat = quality * dist.sample(act.yields.materials, res.random());
    food.v += got_food;
    stock.v += got_mat;

    // Feed the log — the HUD's footer is the action's visible receipt. Amounts are
    // rounded the way the HUD displays them; a rounded-to-zero draw reads as the miss it
    // felt like.
    const rf = @round(got_food);
    const rm = @round(got_mat);
    var buf: [64]u8 = undefined;
    const msg = if (rf > 0 and rm > 0)
        std.fmt.bufPrint(&buf, "You gathered {d:.0} food and {d:.0} materials.", .{ rf, rm }) catch return
    else if (rf > 0)
        std.fmt.bufPrint(&buf, "You gathered {d:.0} food.", .{rf}) catch return
    else if (rm > 0)
        std.fmt.bufPrint(&buf, "You gathered {d:.0} materials.", .{rm}) catch return
    else
        "You gathered nothing.";
    res.log.push(if (rf > 0 or rm > 0) .normal else .dim, msg);
}

pub fn action_forage(
    w: *World,
    e: Entity,
    res: *Resources,
) void {
    begin_labor(w, e, res, comp.ActionForage);
}

pub fn action_fish(
    w: *World,
    e: Entity,
    res: *Resources,
) void {
    begin_labor(w, e, res, comp.ActionFish);
}

pub fn action_chop_wood(
    w: *World,
    e: Entity,
    res: *Resources,
) void {
    begin_labor(w, e, res, comp.ActionChopWood);
}

// ============================ Tests ==========================================

/// A Resources with only the fields `gather` touches (`prng`, `log`, `game`)
/// initialized — the SDL-backed fields stay undefined and untouched.
fn test_res() Resources {
    var res: Resources = undefined;
    res.prng = std.Random.DefaultPrng.init(42);
    res.log = .{};
    res.game = .{};
    return res;
}

test "begin pays upfront and starts the work; finish deposits and logs the receipt" {
    var w = World.init();
    var res = test_res();
    // 0 materials on purpose: a zero-materials action must act at stock 0 (the old `>=`
    // gate refused 0 >= 0).
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryMaterial{ .v = 0 },
        comp.ActionForage{},
    });

    action_forage(&w, e, &res);

    // Paid and busy — but nothing delivered yet.
    try std.testing.expectEqual(@as(f32, 8), w.get(e, comp.Vigor).?.v); // 10 − 2 energy
    const b = w.get(e, comp.Busy).?;
    try std.testing.expectEqual(comp.Busy.Doing.forage, b.doing);
    try std.testing.expectEqual(res_mod.hours_to_secs(4), b.total); // Forage's 4h
    try std.testing.expectEqual(@as(f32, 1.0), b.quality); // locked at full strength
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryFood).?.v); // no deposit
    try std.testing.expectEqual(@as(usize, 0), res.log.count); // no receipt yet
    try std.testing.expect(res.game.tutorial_done); // the first begun action condenses

    // A second begin while busy must refuse, leaving no trace.
    action_forage(&w, e, &res);
    try std.testing.expectEqual(@as(f32, 8), w.get(e, comp.Vigor).?.v); // unpaid

    finish_labor(&w, e, &res, comp.ActionForage, b.quality);
    try std.testing.expect(w.get(e, comp.InventoryFood).?.v >= 0); // yield deposited (≥ 0 draw)
    try std.testing.expectEqual(@as(usize, 1), res.log.count); // the receipt line
}

test "yield_factor: two stable levels split at the WEARY threshold" {
    var v = comp.Vigor{ .v = 10, .max = 10 };
    try std.testing.expectEqual(@as(f32, 1.0), yield_factor(&v));
    v.v = 3.5; // exactly the threshold — not yet weak (strictly below crosses)
    try std.testing.expectEqual(@as(f32, 1.0), yield_factor(&v));
    v.v = 3.4;
    try std.testing.expectEqual(weak_factor, yield_factor(&v));
}

test "begin warns once when its own toll crosses into weakness, and locks pre-pay quality" {
    var w = World.init();
    var res = test_res();
    const e = w.spawn(.{
        comp.Vigor{ .v = 4, .max = 10 }, // 40% — paying 2 lands at 20%, across the line
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryMaterial{ .v = 0 },
        comp.ActionForage{},
    });

    action_forage(&w, e, &res);
    try std.testing.expectEqual(@as(f32, 2), w.get(e, comp.Vigor).?.v);
    try std.testing.expectEqual(@as(usize, 1), res.log.count); // the weakness warning
    // Quality was judged before paying: 40% was not weak, so the locked factor is 1.0.
    try std.testing.expectEqual(@as(f32, 1.0), w.get(e, comp.Busy).?.quality);
}

test "begin refuses when energy would hit zero, leaving no trace" {
    var w = World.init();
    var res = test_res();
    const e = w.spawn(.{
        comp.Vigor{ .v = 2, .max = 10 }, // exactly the price — strict gate must refuse
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryMaterial{ .v = 0 },
        comp.ActionForage{},
    });

    action_forage(&w, e, &res);

    try std.testing.expectEqual(@as(f32, 2), w.get(e, comp.Vigor).?.v); // unpaid
    try std.testing.expect(!w.has(e, comp.Busy)); // no work started
    try std.testing.expectEqual(@as(usize, 0), res.log.count); // no lines
    try std.testing.expect(!res.game.tutorial_done); // a refused action teaches nothing
}
