//! A scripted Act I: the whole schedule ticked from a new run to the shelter, driven only by the
//! intents a page writes (`BeginLabor`, `BeginBuild`, `CollectGenerator`, `SetRation`,
//! `Barter`), under a simple greedy policy: eat lavishly, buy the hatchet from the first
//! passerby who can be paid, split wood for materials and forage when the larder is thin,
//! collect the generators, build the wire snares, leaf bed, rope bag, garden bed and root
//! cellar in that order, then gather the shelter's larder and rest to its vigor. It holds the
//! act completable: on every seed tried the shelter stands before day 40 and the body never
//! dies. Deterministic — the run's prng is seeded.

const std = @import("std");
const ecs = @import("./ecs.zig");
const comp = @import("./components.zig");
const tag = @import("./tags.zig");
const events = @import("./events.zig");
const roster = @import("./data/roster.zig");
const schedule = @import("./schedule.zig");
const capital = @import("./rules/capital.zig");
const market = @import("./rules/market.zig");
const res_mod = @import("./res.zig");

const World = ecs.World;
const Entity = ecs.Entity;
const Resources = res_mod.Resources;

/// The builds the policy raises, in order; the shelter follows once its unlock passes.
const build_order = [_][]const u8{ "wire_snares", "leaf_bed", "rope_bag", "garden_bed", "root_cellar" };

/// The larder the policy keeps before it works for materials: thin enough that it forages.
const food_floor: f32 = 8;
/// What the policy keeps above the shelter's larder and what a rest to its vigor eats, against
/// spoilage while it rests.
const shelter_margin: f32 = 1.5;

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

/// One decision, between two ticks, as the page would make it from what it reads.
fn decide(w: *const World, res: *Resources, e: Entity) void {
    const cat = &res.catalog;
    const quotes = w.get(e, comp.Quotes).?;
    const vigor = w.get(e, comp.Vigor).?;
    const food = w.get(e, comp.InventoryFood).?.v;
    const biomass = w.get(e, comp.InventoryBiomass).?.v;
    const goods = w.get(e, comp.Goods).?;
    const band = w.get(e, comp.Condition).?.band;

    // Eat lavishly while there is anything to eat: the eating rate caps the body's income.
    const rate: f32 = if (food >= 1) 2.0 else 1.0;
    if (w.get(e, comp.Metabolism).?.rate != rate) push(res, events.SetRation{ .agent = e, .rate = rate });

    // Collect every ready generator the body can pay for with a margin.
    for (cat.actions, 0..) |a, ai| {
        const g = quotes.generators[ai] orelse continue;
        if (g.ready() and vigor.v > a.requires.energy + 1) push(res, events.CollectGenerator{ .agent = e, .ai = @intCast(ai) });
    }

    // The hatchet, from the passerby, as soon as it can be paid for.
    const enc = &res.sim.encounter;
    if (enc.dealable() and goods.count[cat.goodIndex("hatchet").?] == 0) {
        const q = market.buy_quote(enc, .whetstone);
        if (q.takeable(enc, food, biomass)) push(res, events.Barter{ .agent = e, .quote = q, .lots = 1 });
    }

    if (w.has(e, comp.Busy)) return;
    const has_hatchet = goods.count[cat.goodIndex("hatchet").?] > 0;

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
    // While the passerby is here without the hatchet sold, every material saves for it.
    const saving = enc.dealable() and !has_hatchet;
    if (!saving) if (quotes.builds[t]) |b| switch (b.standing) {
        .ready => return push(res, events.BeginBuild{ .agent = e, .gi = t }),
        // The order is on hand and only the body is short: rest until it is not.
        .energy => if (food >= food_floor) return,
        else => {},
    };

    const forage = cat.actionIndex("forage").?;
    const work = cat.actionIndex(if (has_hatchet) "chop_wood" else "scavenge").?;
    const for_shelter = t == shelter and biomass >= cat.goods[shelter].requires.biomass;

    // Rested work only: a weary body yields less, so it waits for the larder to restore it.
    if (band != .alive and food >= 0.5) return;
    if (for_shelter) {
        // Materials in hand: gather the larder, then rest to the vigor the roof asks.
        const unlock = cat.goods[shelter].unlock.?;
        const rest_eats = (unlock.vigor_abs - vigor.v) / 2; // two vigor a food, while resting
        if (food < unlock.food + rest_eats + shelter_margin) return begin(w, res, e, quotes, forage);
        return; // resting
    }
    if (food < food_floor) return begin(w, res, e, quotes, forage);
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

/// Play Act I from a new run under the policy, the run's prng seeded with `seed`, until the
/// shelter stands, the body dies, or `limit_days` pass.
fn play(seed: u64, limit_days: f32) !Outcome {
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
    while (res.sim.elapsed < limit_days * spd) {
        decide(&w, &res, e);
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

test "a greedy policy raises the shelter before day 40 without dying, on every seed tried" {
    for ([_]u64{ 0x5eed, 1, 2, 3 }) |seed| {
        const out = try play(seed, 40);
        if (out.stood == null) std.debug.print("\nseed {d} stalled: day {d:.1} died {} vigor {d:.1} food {d:.1} materials {d:.1} kinds {d}\n", .{ seed, out.day, out.died, out.vigor, out.food, out.materials, out.kinds });
        try std.testing.expect(!out.died);
        try std.testing.expect(out.stood != null);
    }
}
