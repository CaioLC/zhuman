//! `act_two/fixtures` — the authored stand-ins for what the Act II simulation does not model:
//! the coin readout, the energy rate, the merchant's days left, the settlement's per-day flows
//! and its body projections; the population stand-in is `Sim.population`. Everything the
//! catalog and the world can say (the verbs, the recipes, the stocks, the goods owned) comes
//! from them, not from here. The stand-ins are listed in `docs/roadmap.md`.
const std = @import("std");
const ha = @import("ha");
const Resource = ha.sim.data.roster.Resource;

// —— Coin Merchant ————————————————————————————————————————————————————————————
// The merchant's lots and its visits are the simulation's (`sim.systems.merchant`); what the
// dialog's kicker says about them is here.

/// The merchant's days left in its stay: the visit's clock, or the full stay before its first
/// tick. The dialog's kicker reads `MERCHANT · MARKET OPEN 2.4 DAYS`.
pub fn merchantDaysLeft(res: *const ha.res.Resources) f32 {
    const v = res.game.sim.merchant;
    const left = if (v.remaining < 0) (ha.sim.rules.market.MerchantSchedule{}).stay_days * res.game.config.secs_per_day else v.remaining;
    return left / res.game.config.secs_per_day;
}
/// The kicker's tail once the Exchange stands: the floor no longer leaves.
pub const exchange_meta = "STANDING FLOOR";

// —— Holdings / BODY ——————————————————————————————————————————————————————————————————
// The per-day flow margins and the population-relevant Body projection; the holdings
// themselves are the agent's goods.

/// Act-specific per-day flow margins (generated vs consumed), authored stand-ins for a
/// production model. A positive flow reads `good`, a deficit `danger`.
pub const FlowRecord = struct { resource: Resource, per_day: f32 };
pub const flows = [_]FlowRecord{
    .{ .resource = .food, .per_day = 6 },
    .{ .resource = .water, .per_day = -3 },
    .{ .resource = .fuel, .per_day = 2 },
    .{ .resource = .coin, .per_day = 4 },
};

/// The authored flow of `r`, or 0 when none is authored.
pub fn flowOf(r: Resource) f32 {
    for (flows) |f| if (f.resource == r) return f.per_day;
    return 0;
}

/// The settlement's housing, a stand-in for the population model: twelve places for a hamlet,
/// and room for 640 once it has outgrown that.
pub fn capacityOf(people: f32) f32 {
    return if (people > 12) @max(640, people) else 12;
}

/// Food one person eats a day at the normal ration (`23` food feeding `7` people `10.3d`), a
/// stand-in for a per-person metabolism.
pub const ration_per_person: f32 = 0.32;

/// The runline energy flow the Act II HUD shows (generated / consumed per unit).
pub const energy_gen: f32 = 7.2;
pub const energy_consumed: f32 = 5.4;
