//! `action_button` template — one labor-action button wired to an agent's own action
//! component. Reads the agent's copy of `ActionT` for its price/yield, gates affordability
//! on vigor, shows the dominant yield's p10–p90 band, and funnels a click through `act_fn`
//! (`actions.action_*`). Skips silently if the agent doesn't hold this action. Migrated onto
//! the new foundation — it composes the `button` template rather than the old widget.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const uic = ha.ui_client;
const World = ha.world.World;
const Entity = ha.world.Entity;
const UiCtx = uic.UiCtx;
const El = uic.elements.El;

const button = @import("./button.zig").button;

pub fn action_button(
    ctx: *UiCtx,
    parent: El,
    world: *World,
    e: Entity,
    comptime ActionT: type,
    id: []const u8,
    name: []const u8,
    comptime act_fn: anytype,
) !void {
    if (!world.has(e, ActionT)) return;
    const act = world.get(e, ActionT).?;
    const vigor = world.get(e, comp.Vigor).?;
    // `gather` treats `requires.energy >= vigor.v` as "can't do it", so affordable is strict.
    const can = vigor.v > act.requires.energy;

    // Show the dominant yield's p10–p90 band (food for forage/fish, materials for chop).
    const food_band = ha.dist.stats(act.yields.food);
    const mat_band = ha.dist.stats(act.yields.materials);
    const food_dom = food_band.mean >= mat_band.mean;
    const band = if (food_dom) food_band else mat_band;
    const unit: u8 = if (food_dom) 'f' else 'm';

    var rbuf: [24]u8 = undefined;
    const lo = @round(band.p10);
    const hi = @round(band.p90);
    const range = if (lo == hi)
        std.fmt.bufPrint(&rbuf, "{d:.0}", .{lo}) catch "?"
    else
        std.fmt.bufPrint(&rbuf, "{d:.0}-{d:.0}", .{ lo, hi }) catch "?";

    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{s}  (-{d:.0} e, +{s}{c})", .{ name, act.requires.energy, range, unit }) catch name;
    const btn = try button(ctx, parent, id, txt, can);
    if (btn.query().clicked and can) act_fn(world, e, ctx.res);
}
