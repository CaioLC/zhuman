//! `household` — the rail's whole column, the same in every act: HOLDINGS and BODY from the
//! act's `Content`, then the eating policy at their foot, aligned to the panels. The policy is
//! not a verb, so it lives with the body whose projections it moves rather than in the action
//! catalog; it collapses with the rail because the rail only builds this while expanded.

const ha = @import("ha");

const comp = ha.sim.comp;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;
const El = ha.ui_client.elements.El;

const holdings_mod = @import("./holdings.zig");
const eating_policy_mod = @import("./eating_policy.zig");
const eating_mod = @import("../eating.zig");

/// Build the column for agent `e`; when the slider's rate differs from its metabolism rate,
/// write `SetRation`, which the ration handler applies before the next build. Only a change is
/// written, so a still slider writes nothing. An agent with no metabolism shows the policy
/// disabled at normal.
pub fn household(parent: El, world: *const World, e: Entity, id: []const u8, content: holdings_mod.Content) !El {
    const ctx = parent.ctx;
    const column = try holdings_mod.holdings(parent, id, content);
    if (world.get(e, comp.Metabolism)) |met| {
        const band = eating_mod.Band.of(ctx.res.game.config);
        const value = try eating_policy_mod.eating_policy(column, "eating_policy", eating_mod.valueFromRate(met.rate, band), true);
        const rate = eating_mod.rate(value, band);
        if (rate != met.rate) _ = ctx.res.game.events.writer(ha.sim.events.SetRation).push(.{ .agent = e, .rate = rate });
    } else {
        _ = try eating_policy_mod.eating_policy(column, "eating_policy", 50, false);
    }
    return column;
}
