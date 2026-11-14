//! `act_two/fixtures` — the authored stand-ins for what the Act II simulation does not model:
//! the coin readout, the merchant's days left, the settlement's housing and what it produces
//! and demands a day; the population stand-in is `Sim.population`. Everything the
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

// —— SETTLEMENT ——————————————————————————————————————————————————————————————————
// What the rail's SETTLEMENT panel reads beside the live stocks.

/// What the settlement produces and demands of one thing a day, authored stand-ins for a
/// production model: energy first, then every stock in the header's order.
pub const FlowRecord = struct {
    /// The line's stable key and its label.
    key: []const u8,
    label: []const u8,
    produced: f32,
    demanded: f32,

    /// Production less demand: positive fills the stock, negative drains it.
    pub fn net(f: FlowRecord) f32 {
        return f.produced - f.demanded;
    }
};

fn stock(r: Resource, produced: f32, demanded: f32) FlowRecord {
    return .{ .key = @tagName(r), .label = r.labelIn(2), .produced = produced, .demanded = demanded };
}

pub const flows = [_]FlowRecord{
    .{ .key = "energy", .label = "Energy", .produced = 7, .demanded = 5 },
    stock(.food, 14, 8),
    stock(.biomass, 12, 10),
    stock(.water, 9, 12),
    stock(.fuel, 6, 4),
    stock(.metal, 2, 2),
    stock(.minerals, 3, 4),
    stock(.coin, 10, 6),
};

/// The settlement's housing, a stand-in for the population model: twelve places for a hamlet,
/// and room for 640 once it has outgrown that.
pub fn capacityOf(people: f32) f32 {
    return if (people > 12) @max(640, people) else 12;
}
