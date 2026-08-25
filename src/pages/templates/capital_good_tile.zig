//! `capital_good_tile` — one buildable capital good, wired to the real build path. Reads
//! the agent's state (owned? building? affordable? prerequisite met?), formats the price
//! from the good's catalog default (`comp.<Good>{}.requires`, hours included), and funnels
//! a click through `capital.begin_build` — which pays, starts the work, and grants the
//! good's effect `hours` later via `systems.resolve_busy`. Dashed while a plan, solid once
//! owned; the underbar fills while building (see `capital_tile`).
//!
//! Comptime-parameterized over the good, the way `action_tile` is over the action — one
//! wrapper for all fifteen instead of a hand-written tile each. The `consequence` string
//! stays a caller argument: it's the good's *pitch* (what changes for you), which is
//! presentation, not data the component carries.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const capital = ha.capital;
const uic = ha.ui_client;
const World = ha.world.World;
const Entity = ha.world.Entity;
const El = uic.elements.El;
const UiCtx = uic.UiCtx;

const capital_tile = @import("./capital_tile.zig").capital_tile;

pub fn capital_good_tile(
    ctx: *UiCtx,
    parent: El,
    world: *World,
    e: Entity,
    comptime GoodT: type,
    id: []const u8,
    name: []const u8,
    consequence: []const u8,
) !?El {
    const vigor = world.get(e, comp.Vigor) orelse return null;
    const stock = world.get(e, comp.InventoryMaterial) orelse return null;
    const owned = world.has(e, GoodT);
    const busy = world.get(e, comp.Busy);
    const building = busy != null and busy.?.doing == capital.doing_of_good(GoodT);
    const progress: ?f32 = if (building) 1.0 - busy.?.remaining / busy.?.total else null;
    const cost = (GoodT{}).requires; // catalog default — the build price
    // Same gates as `begin_build` itself: not owned, not busy (one body, one act), the
    // good's prerequisite verb present, energy strict, materials spendable to 0.
    const can = !owned and busy == null and
        capital.prereq_met(world, e, GoodT) and
        vigor.v > cost.energy and stock.v >= cost.materials;

    var buf: [24]u8 = undefined;
    const cost_txt = std.fmt.bufPrint(&buf, "-{d:.0}m -{d:.0}e {d:.0}h", .{ cost.materials, cost.energy, cost.hours }) catch "?";
    const tl = try capital_tile(ctx, parent, id, name, cost_txt, consequence, can, owned, progress);
    if (tl.clicked) capital.begin_build(world, e, ctx.res, GoodT);
    return tl.el;
}
