//! `eat_tile` template — the Eat action in tile grammar. Eat doesn't fit the typed
//! action shape (`Requires` prices energy/materials; Eat's price is *food*), so this
//! formats its own strings and calls the bare `tile`: cost `-1f`, a `fixed` spike icon
//! (eating is certain — a quiet lesson next to Gather's bell), yield `+Nv` scaled by the
//! larder's quality, exactly what `actions.action_eat` will do. Gated on having a whole
//! unit of food. Returns the tile `El` (null if the agent has no larder).

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const actions = ha.actions;
const uic = ha.ui_client;
const World = ha.world.World;
const Entity = ha.world.Entity;
const El = uic.elements.El;
const UiCtx = uic.UiCtx;

const tile = @import("./action_tile.zig").tile;

pub fn eat_tile(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8) !?El {
    if (!world.has(e, comp.InventoryFood)) return null;
    const food = world.get(e, comp.InventoryFood).?;
    const can = food.v >= 1.0;

    var buf: [12]u8 = undefined;
    const yield_txt = std.fmt.bufPrint(&buf, "+{d}v", .{2 * @as(u32, food.quality)}) catch "?";
    const t = try tile(ctx, parent, id, "Eat", "-1f", .fixed, yield_txt, can);
    if (t.clicked) actions.action_eat(world, e);
    return t.el;
}
