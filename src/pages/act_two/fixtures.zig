//! `act_two/fixtures` — the authored stand-ins for what the Act II simulation does not model:
//! the population and coin readouts, the energy rate, the merchant's lots, the settlement's
//! per-day flows and its body projections. Everything the catalog and the world can say — the
//! verbs, the recipes, the stocks, the goods owned — comes from them instead
//! (`docs/roadmap.md`: ACT2-01 population, ACT2-08 the merchant, ACT2-09 coin).
const std = @import("std");
const ha = @import("ha");
const Resource = ha.roster.Resource;

// —— Header readouts with no model behind them ——————————————————————————————————————————

/// The settlement's population.
pub const population: f32 = 48;

/// The population the pages show: the stand-in, or the Exchange stub's override (a fixture
/// reaching the Exchange's 500-people condition).
pub fn populationOf(sim: *const @import("ha").res.Sim) f32 {
    return sim.exchange.population orelse population;
}

// —— Coin Merchant (ACT2-14) ————————————————————————————————————————————————————————————
// The merchant's finite lots, priced in the stub Coin. A term names a `Resource` or a good by
// catalog id; a lot is one unit of trade, scaled linearly by the slip's lot count. BUY lots
// carry the merchant's stock; SELL lots are bounded by what the settlement holds.

pub const MerchantTerm = struct { item: []const u8, n: f32 };

pub const MerchantLot = struct {
    id: u32,
    sell: bool = false,
    lot: []const u8,
    effect: []const u8,
    price: []const MerchantTerm,
    receive: []const MerchantTerm,
    stock: ?u32 = null,
    consequence: []const u8 = "",
};

pub const merchant_lots = [_]MerchantLot{
    .{ .id = 1, .lot = "Water \u{00d7}6", .effect = "typed resource", .price = &.{.{ .item = "coin", .n = 5 }}, .receive = &.{.{ .item = "water", .n = 6 }}, .stock = 3 },
    .{ .id = 2, .lot = "Minerals \u{00d7}5", .effect = "typed resource", .price = &.{.{ .item = "coin", .n = 7 }}, .receive = &.{.{ .item = "minerals", .n = 5 }}, .stock = 2 },
    .{ .id = 3, .lot = "Fuel \u{00d7}4", .effect = "typed resource", .price = &.{.{ .item = "coin", .n = 8 }}, .receive = &.{.{ .item = "fuel", .n = 4 }}, .stock = 2 },
    .{ .id = 4, .lot = "Metal \u{00d7}3", .effect = "typed resource", .price = &.{.{ .item = "coin", .n = 12 }}, .receive = &.{.{ .item = "metal", .n = 3 }}, .stock = 2 },
    .{ .id = 5, .lot = "Food \u{00d7}10", .effect = "preserved, keeps well", .price = &.{.{ .item = "coin", .n = 8 }}, .receive = &.{.{ .item = "food", .n = 10 }}, .stock = 3 },
    .{ .id = 6, .lot = "Biomass \u{00d7}15", .effect = "baled fibre", .price = &.{.{ .item = "coin", .n = 5 }}, .receive = &.{.{ .item = "biomass", .n = 15 }}, .stock = 4 },
    .{ .id = 7, .lot = "Cut stone \u{00d7}4", .effect = "dressed downriver", .price = &.{.{ .item = "coin", .n = 9 }}, .receive = &.{.{ .item = "worked_stone", .n = 4 }}, .stock = 2 },
    .{ .id = 8, .lot = "Glass pane \u{00d7}1", .effect = "no kiln here can make it", .price = &.{.{ .item = "coin", .n = 22 }}, .receive = &.{.{ .item = "glass_pane", .n = 1 }}, .stock = 1 },
    .{ .id = 9, .lot = "Hand tools \u{00d7}1", .effect = "forged beyond the valley", .price = &.{.{ .item = "coin", .n = 26 }}, .receive = &.{.{ .item = "hand_tools", .n = 1 }}, .stock = 2 },
    .{ .id = 10, .lot = "Fishing net \u{00d7}1", .effect = "better Fish tool", .price = &.{.{ .item = "coin", .n = 18 }}, .receive = &.{.{ .item = "fishing_net", .n = 1 }}, .stock = 1, .consequence = "Replaces Fishing rod: Fish yield rises. The unlock does not stack." },
    .{ .id = 11, .lot = "Carpenter bench \u{00d7}1", .effect = "finished capital", .price = &.{.{ .item = "coin", .n = 60 }}, .receive = &.{.{ .item = "carpenter_bench", .n = 1 }}, .stock = 1 },
    .{ .id = 101, .sell = true, .lot = "Biomass \u{00d7}6", .effect = "leaves your stock", .price = &.{.{ .item = "biomass", .n = 6 }}, .receive = &.{.{ .item = "coin", .n = 5 }} },
    .{ .id = 102, .sell = true, .lot = "Food \u{00d7}8", .effect = "leaves your larder", .price = &.{.{ .item = "food", .n = 8 }}, .receive = &.{.{ .item = "coin", .n = 4 }} },
    .{ .id = 103, .sell = true, .lot = "Fuel \u{00d7}4", .effect = "burned down the ridge", .price = &.{.{ .item = "fuel", .n = 4 }}, .receive = &.{.{ .item = "coin", .n = 6 }} },
    .{ .id = 104, .sell = true, .lot = "Minerals \u{00d7}3", .effect = "they would take it", .price = &.{.{ .item = "minerals", .n = 3 }}, .receive = &.{.{ .item = "coin", .n = 4 }} },
    .{ .id = 105, .sell = true, .lot = "Metal \u{00d7}3", .effect = "they would take it", .price = &.{.{ .item = "metal", .n = 3 }}, .receive = &.{.{ .item = "coin", .n = 9 }} },
    .{ .id = 106, .sell = true, .lot = "Water \u{00d7}5", .effect = "drawn this morning", .price = &.{.{ .item = "water", .n = 5 }}, .receive = &.{.{ .item = "coin", .n = 3 }} },
    .{ .id = 107, .sell = true, .lot = "Forge \u{00d7}1", .effect = "your spare stock", .price = &.{.{ .item = "forge", .n = 1 }}, .receive = &.{.{ .item = "coin", .n = 30 }}, .consequence = "A spare goes first; the forge you use keeps its verb." },
    .{ .id = 108, .sell = true, .lot = "Lean-to \u{00d7}1", .effect = "your spare stock", .price = &.{.{ .item = "lean_to", .n = 1 }}, .receive = &.{.{ .item = "coin", .n = 7 }} },
};
/// The merchant's days left in its stay: the visit's clock, or the full stay before its first
/// tick. The dialog's kicker reads `MERCHANT · MARKET OPEN 2.4 DAYS`.
pub fn merchantDaysLeft(res: *const ha.res.Resources) f32 {
    const v = res.sim.merchant;
    const left = if (v.remaining < 0) (ha.market.MerchantSchedule{}).stay_days * res.config.secs_per_day else v.remaining;
    return left / res.config.secs_per_day;
}
/// The kicker's tail once the Exchange stands: the floor no longer leaves.
pub const exchange_meta = "STANDING FLOOR";

// —— Holdings / BODY (ACT2-15) ——————————————————————————————————————————————————————————
// The per-day flow margins and the population-relevant Body projection; the holdings
// themselves are the agent's goods. No decorative durability/maintenance meters (those systems
// do not exist).

/// Act-specific per-day flow margins (generated vs consumed), authored until a production model
/// computes them. A positive flow reads `good`, a deficit `danger`.
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

/// The settlement's housing, the prototype's stand-in until the population model (ACT2-01):
/// twelve places for a hamlet, and room for 640 once it has outgrown that.
pub fn capacityOf(people: f32) f32 {
    return if (people > 12) @max(640, people) else 12;
}

/// Food one person eats a day at the normal ration, the prototype's (`23` food feeding `7`
/// people `10.3d`), until the population model gives each person a metabolism.
pub const ration_per_person: f32 = 0.32;

/// The runline energy flow the Act II HUD shows (generated / consumed per unit).
pub const energy_gen: f32 = 7.2;
pub const energy_consumed: f32 = 5.4;
