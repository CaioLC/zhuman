//! A scripted Act I: the whole schedule ticked from a new run to the shelter, driven only by the
//! intents a page writes (`BeginLabor`, `BeginBuild`, `SetRation`, `Barter`), under three simple
//! policies, one for each way of making a living (`Path`):
//!
//! - the **generalist** buys the fishing rod and the hatchet, makes its own food and its own
//!   materials, and trades with the passerby for nothing but tools;
//! - the **fisher** buys the rod and then the net, fishes beyond what it eats and sells the
//!   surplus for the materials it builds with;
//! - the **woodcutter** buys the hatchet and then the hand axe, and with the axe splits wood
//!   beyond what it builds with and buys its food.
//!
//! All three build a camp bare-handed first (no passerby comes before it), save for their tools,
//! raise the same goods in the same order, eat the ration their food's price supports, and
//! leave the generators uncollected. Deterministic — the run's prng is seeded.
//!
//! The tests hold the act completable on every path, and specializing worth it: on every seed
//! tried each path raises the shelter before the limit and the body never dies, and over the
//! seeds each specialist stands the shelter sooner than the generalist.

const std = @import("std");
const ecs = @import("./ecs.zig");
const comp = @import("./components.zig");
const tag = @import("./tags.zig");
const events = @import("./events.zig");
const roster = @import("./data/roster.zig");
const schedule = @import("./schedule.zig");
const capital = @import("./rules/capital.zig");
const effects = @import("./rules/effects.zig");
const market = @import("./rules/market.zig");
const res_mod = @import("./res.zig");
const dist = @import("./kernel/dist.zig");

const World = ecs.World;
const Entity = ecs.Entity;
const Resources = res_mod.Resources;

/// A way of making a living in Act I.
const Path = enum { generalist, fisher, woodcutter };

/// A tool the passerby carries: its ware on the board and its good in the roster.
const Tool = struct { ware: market.Ware, good: []const u8 };

const rod = Tool{ .ware = .fish_hook, .good = "fish_rod" };
const net = Tool{ .ware = .fish_net, .good = "fish_net" };
const hatchet = Tool{ .ware = .whetstone, .good = "hatchet" };
const hand_axe = Tool{ .ware = .hand_axe, .good = "hand_axe" };
const gloves = Tool{ .ware = .work_gloves, .good = "work_gloves" };

/// The tools a path buys, in order.
fn toolsOf(path: Path) []const Tool {
    return switch (path) {
        .generalist => &.{ rod, hatchet },
        .fisher => &.{ rod, net },
        .woodcutter => &.{ hatchet, hand_axe },
    };
}

/// The builds every path raises, in order; the shelter follows once its unlock passes. The first
/// two are the cheapest camp, which brings the passerby.
const build_order = [_][]const u8{ "sandals", "leaf_bed", "rope_bag", "root_cellar", "medicinal_herb_bed" };

/// The larder a path keeps before it works for materials: thin enough that it gathers food.
const food_floor: f32 = 8;
/// The larder a woodcutter forages below between visits: it buys its food, and forages only
/// when a visit is too far off.
const bought_floor: f32 = 3;
/// The days of eating a woodcutter buys ahead: a gap between visits and a margin for rot.
const bought_days: f32 = 3;
/// The larder above which a fisher stops fishing for sale: more than a visit takes rots first.
const catch_cap: f32 = 40;
/// What a path keeps above the shelter's larder and what a rest to its vigor eats, against
/// spoilage while it rests.
const shelter_margin: f32 = 1.5;
/// The vigor a policy keeps after paying for a piece of work.
const vigor_reserve: f32 = 2.0;
/// The highest ration a policy eats at: beyond it the curve returns next to nothing.
const ration_cap: f32 = 2.0;

fn player(w: *const World) ?Entity {
    var e: Entity = 0;
    while (e < w.next_id) : (e += 1) {
        if (w.has(e, tag.Player) and w.has(e, comp.Vigor)) return e;
    }
    return null;
}

fn push(res: *Resources, fact: anytype) void {
    _ = res.events.writer(@TypeOf(fact)).push(fact);
}

/// What the agent holds that the policies read.
const Kit = struct {
    rod: bool,
    net: bool,
    hatchet: bool,
    axe: bool,
    gloves: bool,

    fn of(goods: *const comp.Goods, cat: *const roster.Catalog) Kit {
        return .{
            .rod = owns(goods, cat, rod.good),
            .net = owns(goods, cat, net.good),
            .hatchet = owns(goods, cat, hatchet.good),
            .axe = owns(goods, cat, hand_axe.good),
            .gloves = owns(goods, cat, gloves.good),
        };
    }

    fn fishes(self: Kit) bool {
        return self.rod or self.net;
    }

    fn chops(self: Kit) bool {
        return self.hatchet or self.axe;
    }
};

fn owns(goods: *const comp.Goods, cat: *const roster.Catalog, id: []const u8) bool {
    return goods.count[cat.goodIndex(id).?] > 0;
}

/// The mean units of `resource` a verb yields the holder of `goods` for a unit of energy, on the
/// terms those goods make of it (`effects.terms`).
fn perEnergy(cat: *const roster.Catalog, goods: *const comp.Goods, verb: []const u8, comptime resource: []const u8) f32 {
    const terms = effects.terms(cat, goods, cat.actionIndex(verb).?);
    const draw = @field(terms.output, resource) orelse return 0;
    return dist.stats(draw.asDist()).mean / terms.requires.energy;
}

/// The food a unit of energy brings the agent on `path` with `kit`: what it catches or gathers,
/// or for a woodcutter what its wood buys at the passerby's asking rate.
fn foodPerEnergy(cat: *const roster.Catalog, goods: *const comp.Goods, path: Path, kit: Kit) f32 {
    const gathered = perEnergy(cat, goods, if (kit.fishes()) "fish" else "forage", "food");
    if (path != .woodcutter or !kit.axe) return gathered;
    return @max(gathered, perEnergy(cat, goods, "chop_wood", "biomass") / market.food_ask);
}

/// The ration at which one more unit of food stops paying for the energy it takes to get, for
/// food that costs `1 / food_per_energy`: where the recovery curve's slope (`Config.regen`)
/// meets that price.
fn rationFor(cfg: *const res_mod.Config, base_rate: f32, food_per_energy: f32) f32 {
    const k = -@log(1.0 - cfg.regen_at_normal);
    const slope_at_zero = cfg.regen_full_per_day * k; // vigor a day per unit of ration
    const price = base_rate / food_per_energy; // energy a day per unit of ration
    if (slope_at_zero <= price) return cfg.metabolism_rate_min;
    return std.math.clamp(@log(slope_at_zero / price) / k, cfg.metabolism_rate_min, ration_cap);
}

/// The ration the passerby's satchel can feed between two visits, a fifth of it left to rot.
fn suppliedRation(cfg: *const res_mod.Config, base_rate: f32) f32 {
    const sched = market.Schedule{};
    const cycle = sched.gap_days + sched.approach_days + sched.linger_days + sched.depart_days;
    const food_a_day = sched.satchel[@backingInt(market.Ware.food)] * 0.8 / cycle;
    return @max(cfg.metabolism_rate_min, food_a_day / base_rate);
}

/// One decision, between two ticks, as the page would make it from what it reads.
fn decide(w: *const World, res: *Resources, e: Entity, path: Path) void {
    const cat = &res.catalog;
    const quotes = w.get(e, comp.Quotes).?;
    const vigor = w.get(e, comp.Vigor).?;
    const larder = w.get(e, comp.InventoryFood).?;
    const food = larder.v;
    const biomass = w.get(e, comp.InventoryBiomass).?.v;
    const goods = w.get(e, comp.Goods).?;
    const band = w.get(e, comp.Condition).?.band;
    const met = w.get(e, comp.Metabolism).?;
    const kit = Kit.of(goods, cat);

    // Eat what the food's price supports; with next to nothing in the larder, the meagerest
    // ration starves slowest.
    // The woodcutter's larder is bought once the hand axe makes wood cheap enough to live on;
    // it eats no more than the passerby carries.
    const buying = path == .woodcutter and kit.axe;
    const priced_ration = rationFor(&res.config, met.base_rate, foodPerEnergy(cat, goods, path, kit));
    const ration = if (buying) @min(priced_ration, suppliedRation(&res.config, met.base_rate)) else priced_ration;
    const rate: f32 = if (food < 0.5) res.config.metabolism_rate_min else ration;
    if (met.rate != rate) push(res, events.SetRation{ .agent = e, .rate = rate });
    const eats_a_day = met.base_rate * rate;

    // The next build: the first of the order not yet owned, then the shelter.
    var target: ?u16 = null;
    for (build_order) |id| {
        const gi = cat.goodIndex(id).?;
        if (goods.count[gi] == 0) {
            target = gi;
            break;
        }
    }
    const shelter = cat.goodIndex("shelter").?;
    const t = target orelse shelter;
    const unlock = cat.goods[shelter].unlock.?;
    // What the roof asks of the larder: its floor, what a rest to its vigor eats at this
    // ration's recovery, and a margin.
    const rest_days = @max(0, unlock.vigor_abs - vigor.v) / res.config.regen(rate, larder.quality);
    const roof_larder = unlock.food + rest_days * eats_a_day + shelter_margin;

    // The next tool of the path not yet owned.
    var next_tool: ?Tool = null;
    for (toolsOf(path)) |tool| if (!owns(goods, cat, tool.good)) {
        next_tool = tool;
        break;
    };

    const enc = &res.sim.encounter;
    if (enc.dealable()) {
        // The tool, as soon as it can be paid for.
        if (next_tool) |tool| {
            const q = market.buy_quote(enc, tool.ware);
            if (q.takeable(enc, food, biomass)) push(res, events.Barter{ .agent = e, .quote = q, .lots = 1 });
        }
        switch (path) {
            .generalist => {},
            // The fisher sells what it holds above its own larder.
            .fisher => if (kit.fishes()) {
                const tool_keep: f32 = if (next_tool) |tool| market.tool_price(tool.ware).food * market.modifier(market.passerby_swing) + 1 else 0;
                const keep = @max(tool_keep, if (t == shelter) roof_larder + food_floor else food_floor);
                const q = market.sell_quote(enc, .food);
                const spare = @floor(@max(0, food - keep));
                const lots: u16 = @intFromFloat(@min(spare, @as(f32, @floatFromInt(q.stock))));
                if (lots > 0) push(res, events.Barter{ .agent = e, .quote = q, .lots = lots });
            },
            // The woodcutter buys the days of eating ahead, or the roof's larder out of what
            // the roof itself leaves.
            .woodcutter => if (buying) {
                const want = if (t == shelter) roof_larder else eats_a_day * bought_days;
                const q = market.buy_quote(enc, .food);
                const price = q.give.qtyOf(.biomass);
                const short = @ceil(@max(0, want - food));
                const purse = if (t == shelter) @max(0, biomass - cat.goods[shelter].requires.biomass) else biomass;
                const lots: u16 = @intFromFloat(@min(short, @min(@floor(purse / price), @as(f32, @floatFromInt(q.stock)))));
                if (lots > 0 and food < want - 1) push(res, events.Barter{ .agent = e, .quote = q, .lots = lots });
            },
        }
    }

    if (w.has(e, comp.Busy)) return;

    // Once the camp stands, every material saves for the path's tools before anything else is
    // built: a tool pays for itself sooner than a bed does.
    const camp = capital.goodsOwned(w, e, cat) >= (market.Schedule{}).camp_kinds;
    const saving = camp and next_tool != null;
    if (!saving) if (quotes.builds[t]) |b| switch (b.standing) {
        .ready => return push(res, events.BeginBuild{ .agent = e, .gi = t }),
        // The order is on hand and only the body is short: rest until it is not.
        .energy => if (food >= food_floor) return,
        else => {},
    };

    const gather = cat.actionIndex(if (kit.fishes()) "fish" else "forage").?;
    const labor = cat.actionIndex(if (kit.chops()) "chop_wood" else "scavenge").?;
    // What the path does for materials: the fisher fishes for sale while the catch will sell.
    const selling = path == .fisher and kit.fishes();
    const work = if (selling and food < catch_cap) gather else labor;
    // Saving for a tool, the larder holds the food the tool costs once its materials are in
    // hand: held any sooner it only rots.
    const dearest = market.modifier(market.passerby_swing);
    const tool_food: f32 = if (saving and biomass >= market.tool_price(next_tool.?.ware).biomass * dearest) market.tool_price(next_tool.?.ware).food * dearest + 1 else 0;
    // A bought larder is gathered for only when a visit is too far off.
    const floor: f32 = @max(tool_food, if (buying) bought_floor else food_floor);
    const roof = cat.goods[shelter].requires.biomass;
    const for_shelter = t == shelter and biomass >= roof;

    // Rested work only: a weary body yields less, so it waits for the larder to restore it.
    if (band != .alive and food >= 0.5) return;
    if (for_shelter) {
        // Materials in hand: fill the larder, then rest to the vigor the roof asks. A
        // woodcutter splits the wood the shortfall will cost, and with that in hand forages.
        if (food >= roof_larder) return; // resting
        const paid_for = biomass >= roof + (roof_larder - food) * market.food_ask * dearest;
        return begin(w, res, e, quotes, if (buying and !paid_for and food >= bought_floor) labor else gather);
    }
    if (food < floor) return begin(w, res, e, quotes, gather);
    // A woodcutter with its next build and its next larder paid for has wood enough: it forages.
    if (buying and biomass >= cat.goods[t].requires.biomass + eats_a_day * bought_days * market.food_ask * dearest) return begin(w, res, e, quotes, gather);
    begin(w, res, e, quotes, work);
}

/// Begin verb `ai` when it is ready and the body is rested enough to lock a full yield (or the
/// larder is empty, when foraging cannot wait).
fn begin(w: *const World, res: *Resources, e: Entity, quotes: *const comp.Quotes, ai: u16) void {
    const v = quotes.verbs[ai] orelse return;
    if (!v.ready()) return;
    const vigor = w.get(e, comp.Vigor).?;
    const starving = w.get(e, comp.InventoryFood).?.v < 0.5;
    if (!starving and vigor.v < res.config.weary_frac * vigor.max) return;
    // And with vigor to spare after the work is paid: a body worked to its last breath dies of
    // the first missed meal.
    const energy = effects.terms(&res.catalog, w.get(e, comp.Goods).?, ai).requires.energy;
    if (!starving and vigor.v - energy < vigor_reserve) return;
    push(res, events.BeginLabor{ .agent = e, .ai = ai });
}

/// How a scripted run ended: the day the shelter stood, or where it stopped.
const Outcome = struct {
    /// The in-game day the shelter stood; null when it did not by the limit, or the body died.
    stood: ?f32,
    died: bool,
    day: f32,
    vigor: f32,
    food: f32,
    materials: f32,
    kinds: u32,
};

/// Play Act I from a new run on `path`, the run's prng seeded with `seed`, until the shelter
/// stands, the body dies, or `days` pass.
fn play(path: Path, seed: u64, days: f32) !Outcome {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = Resources{ .catalog = try roster.load(std.testing.allocator, roster.shipped, null) };
    defer res.catalog.deinit();
    res.sim.prng = std.Random.DefaultPrng.init(seed);

    // A new run, as the title's button writes it: the next tick enters Act I and spawns the
    // player at the spawn baselines (`run.spawn_player`: the thin larder, 10 vigor, forage and
    // scavenge).
    push(&res, events.NewRun{});
    schedule.tick(&w, &res);
    schedule.tick(&w, &res);
    try std.testing.expect(res.states.in(.act_one));
    const e = player(&w).?;

    const spd = res.config.secs_per_day;
    res.time.dt = spd / 400; // 3.6 in-game minutes a tick
    var out = Outcome{ .stood = null, .died = false, .day = 0, .vigor = 0, .food = 0, .materials = 0, .kinds = 0 };
    while (res.sim.elapsed < days * spd) {
        decide(&w, &res, e, path);
        schedule.tick(&w, &res);
        if (!w.has(e, comp.Vigor)) {
            out.died = true;
            break;
        }
        if (capital.ownsMilestone(&w, e, &res.catalog, .act_one)) {
            out.stood = res.sim.elapsed / spd;
            break;
        }
    }
    out.day = res.sim.elapsed / spd;
    if (!out.died) {
        out.vigor = w.get(e, comp.Vigor).?.v;
        out.food = w.get(e, comp.InventoryFood).?.v;
        out.materials = w.get(e, comp.InventoryBiomass).?.v;
        out.kinds = capital.goodsOwned(&w, e, &res.catalog);
    }
    return out;
}

/// The seeds every path is played on.
const seeds = [_]u64{ 0x5eed, 1, 2, 3, 4, 5, 6, 7 };
/// The day by which every path raises the shelter.
const limit_days: f32 = 70;

/// Play `path` on every seed; the mean day the shelter stood. Fails when a run dies or stalls.
fn meanDays(path: Path) !f32 {
    var sum: f32 = 0;
    for (seeds) |seed| {
        const out = try play(path, seed, limit_days);
        if (out.stood == null) std.debug.print("\n{s} seed {d}: stood {?d:.1} day {d:.1} died {} vigor {d:.1} food {d:.1} materials {d:.1} kinds {d}\n", .{ @tagName(path), seed, out.stood, out.day, out.died, out.vigor, out.food, out.materials, out.kinds });
        try std.testing.expect(!out.died);
        sum += out.stood orelse return error.TestUnexpectedResult;
    }
    return sum / seeds.len;
}

test "every path raises the shelter before the limit without dying, and a specialist sooner than the generalist" {
    const generalist = try meanDays(.generalist);
    const fisher = try meanDays(.fisher);
    const woodcutter = try meanDays(.woodcutter);
    try std.testing.expect(fisher < generalist);
    try std.testing.expect(woodcutter < generalist);
}

test "the ration a policy eats rises with how cheaply its food comes" {
    const cfg = res_mod.Config{};
    const base = (comp.Metabolism{}).base_rate;
    const dear = rationFor(&cfg, base, 1.0);
    const cheap = rationFor(&cfg, base, 2.5);
    const cheaper = rationFor(&cfg, base, 5.0);
    try std.testing.expect(dear < cheap and cheap < cheaper);
    try std.testing.expect(dear >= cfg.metabolism_rate_min and cheaper <= ration_cap);
    // Food that costs more energy than it can ever restore is worth the least a body eats.
    try std.testing.expectEqual(cfg.metabolism_rate_min, rationFor(&cfg, base, 0.01));
}
