//! `fish_rod_tile` — the fish rod as a real, buildable **Unlocker**: reads the agent's
//! state (owned? affordable?), formats the build price from `comp.FishRod`'s catalog
//! default, and funnels a click through `capital.build_fish_rod` — which pays, grants
//! the rod, and grants the Fish verb, so the Fish tile appears in ACTIONS the next
//! frame. Dashed while a plan, solid once owned (see `capital_tile`). Returns the tile
//! `El` (null if the agent has no vigor/stockpile to price against).

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

pub fn fish_rod_tile(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8) !?El {
    const vigor = world.get(e, comp.Vigor) orelse return null;
    const stock = world.get(e, comp.InventoryMaterial) orelse return null;
    const owned = world.has(e, comp.FishRod);
    const busy = world.get(e, comp.Busy);
    const building = busy != null and busy.?.doing == .build_fish_rod;
    const progress: ?f32 = if (building) 1.0 - busy.?.remaining / busy.?.total else null;
    const cost = (comp.FishRod{}).requires; // catalog default — the build price
    // Same gates as build_fish_rod itself (energy strict; materials spendable to 0;
    // one body, one act).
    const can = !owned and busy == null and vigor.v > cost.energy and stock.v >= cost.materials;

    var buf: [24]u8 = undefined;
    const cost_txt = std.fmt.bufPrint(&buf, "-{d:.0}m -{d:.0}e {d:.0}h", .{ cost.materials, cost.energy, cost.hours }) catch "?";
    const tl = try capital_tile(ctx, parent, id, "Fish rod", cost_txt, "Fish", can, owned, progress);
    if (tl.clicked) capital.build_fish_rod(world, e, ctx.res);
    return tl.el;
}
