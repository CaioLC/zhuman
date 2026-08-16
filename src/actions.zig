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
pub fn action_eat(
    w: *World,
    e: Entity,
) void {
    const food, const vigor = ecs.getMany(w, e, .{ comp.InventoryFood, comp.Vigor });
    if (food.v == 0.0) return;
    food.v -= 1.0;
    vigor.v += 2.0 * @as(f32, @floatFromInt(food.quality));
}

/// Shared body for the labor actions (Forage/Fish/ChopWood): spend energy/materials,
/// draw food/materials yield from `dist.sample` (the spread *is* the risk — no separate
/// success roll), and log what landed. `ActionT` is one of the typed per-action
/// components, each carrying its own `Requires`/`Yields` — so distinct actions stay
/// distinct component types (queryable independently) while sharing this one resolution
/// path.
fn gather(w: *World, e: Entity, res: *Resources, comptime ActionT: type) void {
    const act, const vigor, const stock, const food = ecs.getMany(w, e, .{ ActionT, comp.Vigor, comp.InventoryMaterial, comp.InventoryFood });
    // Energy is strict (spending vigor to exactly 0 is death); materials may be spent to
    // exactly 0 — `>=` here blocked every zero-materials action on a fresh spawn (0 >= 0).
    if (act.requires.energy >= vigor.v or act.requires.materials > stock.v) {
        return; // cannot do the action
    }

    // Pay the price. The strict energy gate above keeps vigor > 0, so labor alone can't
    // kill — running the body to death takes starving it of the refill, not one more click.
    vigor.v -= act.requires.energy;
    stock.v -= act.requires.materials;

    const got_food = dist.sample(act.yields.food, res.random());
    const got_mat = dist.sample(act.yields.materials, res.random());
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

    res.game.tutorial_done = true; // first resolved action ends the teaching presentation
}

pub fn action_forage(
    w: *World,
    e: Entity,
    res: *Resources,
) void {
    gather(w, e, res, comp.ActionForage);
}

pub fn action_fish(
    w: *World,
    e: Entity,
    res: *Resources,
) void {
    gather(w, e, res, comp.ActionFish);
}

pub fn action_chop_wood(
    w: *World,
    e: Entity,
    res: *Resources,
) void {
    gather(w, e, res, comp.ActionChopWood);
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

test "gather pays the cost, deposits the yield, and logs a receipt" {
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

    const vigor = w.get(e, comp.Vigor).?;
    try std.testing.expectEqual(@as(f32, 8), vigor.v); // 10 − 2 energy paid
    try std.testing.expect(w.get(e, comp.InventoryFood).?.v >= 0); // yield deposited (≥ 0 draw)
    try std.testing.expectEqual(@as(usize, 1), res.log.count); // the receipt line
    try std.testing.expect(res.game.tutorial_done); // first action condenses the tutorial
}

test "gather refuses when energy would hit zero, leaving no trace" {
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
    try std.testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryFood).?.v); // no deposit
    try std.testing.expectEqual(@as(usize, 0), res.log.count); // no receipt
    try std.testing.expect(!res.game.tutorial_done); // a refused action teaches nothing
}
