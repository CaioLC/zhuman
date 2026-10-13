//! `act_two/fixtures` — the authored stand-ins for what the Act II simulation does not model:
//! the population and coin readouts, the energy rate, the merchant's lots, the settlement's
//! per-day flows and its body projections. Everything the catalog and the world can say — the
//! verbs, the recipes, the stocks, the goods owned — comes from them instead
//! (`docs/roadmap.md`: ACT2-01 population, ACT2-08 the merchant, ACT2-09 coin).

// —— Header readouts with no model behind them ——————————————————————————————————————————

/// The settlement's population.
pub const population = "48";
/// The coin balance.
pub const coin = "126";

// —— Coin Merchant (ACT2-14) ————————————————————————————————————————————————————————————
// The merchant's finite lots. Buys cost Coin ("YOU PAY"); sells give goods/resources for Coin
// ("YOU GIVE"). Each lot has a stock count and an optional refusal reason. A refused or
// zero-stock lot is unselectable (the row-facing `valid()` the dialog already enforces).

pub const MerchantOffer = struct {
    id: usize,
    name: []const u8,
    detail: []const u8 = "",
    /// What the player hands over for this lot (Coin on BUY, a good/resource on SELL).
    give: []const u8,
    /// What the player receives (the good/resource on BUY, Coin on SELL).
    receive: []const u8,
    effect: []const u8 = "",
    stock: u32 = 1,
    refusal: []const u8 = "",
};

/// BUY lots — the player PAYS Coin. Nine lots: water, fuel, metal, minerals, biomass, goods.
pub const merchant_buys = [_]MerchantOffer{
    .{ .id = 1, .name = "Water", .detail = "spring-fresh", .give = "6 Coin", .receive = "Water +10", .stock = 4 },
    .{ .id = 2, .name = "Fuel", .detail = "seasoned charcoal", .give = "9 Coin", .receive = "Fuel +8", .stock = 3 },
    .{ .id = 3, .name = "Metal", .detail = "bar stock", .give = "14 Coin", .receive = "Metal +4", .stock = 2 },
    .{ .id = 4, .name = "Minerals", .detail = "crushed ore", .give = "7 Coin", .receive = "Minerals +12", .stock = 5 },
    .{ .id = 5, .name = "Biomass", .detail = "baled fibre", .give = "5 Coin", .receive = "Biomass +15", .stock = 6 },
    .{ .id = 6, .name = "Preserved food", .detail = "keeps well", .give = "8 Coin", .receive = "Food +10", .stock = 3 },
    .{ .id = 7, .name = "Hand tools", .detail = "a maker's kit", .give = "22 Coin", .receive = "Tools \u{00d7}1", .stock = 1, .effect = "A ready-made toolset: Forge tools no longer needs Metal on hand." },
    .{ .id = 8, .name = "Draft animal", .detail = "sold out", .give = "40 Coin", .receive = "Ox \u{00d7}1", .stock = 0 },
    .{ .id = 9, .name = "Seed grain", .detail = "needs a granary", .give = "11 Coin", .receive = "Seed +6", .stock = 2, .refusal = "needs a granary" },
};

/// SELL lots — the player GIVES a good/resource for Coin. Diminishing marginal prices are
/// taught in the effect line, mirroring the Act I passerby.
pub const merchant_sells = [_]MerchantOffer{
    .{ .id = 101, .name = "Biomass", .detail = "your surplus", .give = "Biomass \u{00d7}10", .receive = "4 Coin", .effect = "The first bale earns the most; the next falls to 3 Coin.", .stock = 3 },
    .{ .id = 102, .name = "Minerals", .detail = "your surplus", .give = "Minerals \u{00d7}10", .receive = "5 Coin", .effect = "Diminishing: the next lot falls to 4 Coin.", .stock = 1 },
    .{ .id = 103, .name = "Food", .detail = "your surplus", .give = "Food \u{00d7}10", .receive = "7 Coin", .effect = "Selling the larder down raises the price you later pay back.", .stock = 2 },
    .{ .id = 104, .name = "Spare tools", .detail = "your spare stock", .give = "Tools \u{00d7}1", .receive = "16 Coin", .effect = "A spare is sold first; the set you use keeps its effect.", .stock = 2 },
    .{ .id = 105, .name = "Fuel", .detail = "your surplus", .give = "Fuel \u{00d7}8", .receive = "6 Coin", .stock = 1 },
};

/// The merchant venue meta line (time left) the dialog shows above the lots.
pub const merchant_meta = "MERCHANT \u{00b7} 2 DAYS AT MARKET";

// —— Holdings / BODY (ACT2-15) ——————————————————————————————————————————————————————————
// The per-day flow margins and the population-relevant Body projection; the holdings
// themselves are the agent's goods. No decorative durability/maintenance meters (those systems
// do not exist).

/// Act-specific per-day flow margins (generated vs consumed). A positive flow is `good`, a
/// deficit `danger` — the semantics the caller colors.
pub const FlowRecord = struct { 
    label: []const u8, 
    value: []const u8, 
    positive: bool,
    resource: []const u8, // Resource tag name for keying
};
pub const flows = [_]FlowRecord{
    .{ .label = "Food", .value = "+6/day", .positive = true, .resource = "food" },
    .{ .label = "Water", .value = "-3/day", .positive = false, .resource = "water" },
    .{ .label = "Fuel", .value = "+2/day", .positive = true, .resource = "fuel" },
    .{ .label = "Coin", .value = "+4/day", .positive = true, .resource = "coin" },
};

/// The population-relevant Body projections — sentences the caller renders dim-prefix + value.
/// What a Body sentence projects; its row is keyed by this, not by its wording.
pub const Body = enum { population, larder, water, vigor };

pub const BodyRecord = struct { key: Body, prefix: []const u8, value: []const u8, suffix: []const u8, positive: bool };
pub const body_projection = [_]BodyRecord{
    .{ .key = .population, .prefix = "Population ", .value = "48", .suffix = " under one roof.", .positive = true },
    .{ .key = .larder, .prefix = "Larder feeds all for ", .value = "7.4d", .suffix = ".", .positive = true },
    .{ .key = .water, .prefix = "Water runs short in ", .value = "3.0d", .suffix = ".", .positive = false },
    .{ .key = .vigor, .prefix = "Vigor across the hall: ", .value = "weary", .suffix = ".", .positive = false },
};

/// The runline energy flow the Act II HUD shows (generated / consumed per unit).
pub const energy_gen: f32 = 7.2;
pub const energy_consumed: f32 = 5.4;
