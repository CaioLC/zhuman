//! `fixture` — a **development-only deterministic fixture harness**. Where `debug_page` audits
//! one *template* at a time against the prototype, this seeds one *named screen state* — a
//! deterministic window size, game clock, catalogs, balances, and a seeded domain snapshot — and
//! then renders it through the **production page** (`ui_playgame`). It is the entry point QA-07
//! asks for: a reproducible way to reach "ACTIONS with a build running at the 760 width class" or
//! "the trade dialog open against a present passerby" without playing the game to that state.
//!
//! Reached by setting `HA_FIXTURE=<name>` before launch (`build_ui` routes here when it is set
//! and non-empty); an unknown name lists the catalog and falls back to the first fixture. It is a
//! developer tool — off unless explicitly requested — and never affects the shipped routes.
//!
//! **Two halves, kept apart.** The `Spec` catalog and `seed` application are **pure and
//! SDL-free**: a `Spec` is deterministic data (the logical window size that drives
//! `view.compute`, the game clock in days, the seed instructions), and `seed` applies it to a
//! `World` + `Resources` with no window, so the catalog's determinism is unit-tested without a
//! font. Only `build_fixture` touches the platform, by handing the seeded world to the real page
//! builder — exactly as `main` does. Pixel rendering therefore stays out of the tested surface,
//! matching QA-08's input/layout-vs-pixels split.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const tag = ha.tag;
const uic = ha.ui_client;
const ecs = ha.ecs;
const market = ha.market;
const World = ha.world.World;
const Entity = ha.world.Entity;
const Resources = ha.res.Resources;

const p_playgame = @import("./play_game.zig").ui_playgame;
const p_act_two = @import("./act_two/page.zig").ui_act_two;
const p_gameover = @import("./gameover.zig").ui_gameover;
const p_act_one_end = @import("./act_one_end.zig").ui_act_one_end;

/// The screen a fixture seeds the shell onto. Act I is the live survival page; `act_two` renders
/// the Act II shared-shell catalogs (fixture-driven until the Act II simulation model is wired).
pub const Screen = enum { act_one, act_two, gameover, act_one_end };

/// The passerby's visit state a fixture wants reachable. `absent` leaves the market strip
/// dormant; `present` seeds a dealable encounter with a full satchel so the trade dialog can
/// open. Mirrors `market.Phase` but names only the two states a fixture cares to reach.
pub const Encounter = enum { absent, present };

/// One owned good for a fixture: a record id and how many.
pub const Owned = struct { id: []const u8, n: u32 };

/// Owning the hatchet, fishing rod and spear puts all five body-occupying verbs on ACTIONS.
const five_verbs = [_]Owned{
    .{ .id = "hatchet", .n = 1 },
    .{ .id = "fish_rod", .n = 1 },
    .{ .id = "spear", .n = 1 },
};

/// A deterministic actor balance sheet. Each field seeds the matching component to an exact
/// value, so a fixture reproduces the same holdings/vigor/larder every launch regardless of the
/// simulation clock. `null` leaves the spawn baseline (`baselines.zig`) untouched for that field.
pub const Balances = struct {
    /// Vigor current / ceiling. Null keeps the rested spawn baseline (10/10).
    vigor: ?struct { v: f32, max: f32 } = null,
    /// Larder units. Null keeps the thin perishable spawn larder.
    food: ?f32 = null,
    /// Stockpiled generic materials. Null keeps the empty spawn stockpile.
    materials: ?f32 = null,
    /// Metabolism rate multiplier (eating policy). Null keeps the normal rate.
    metabolism: ?f32 = null,
    /// Owned goods by record id. What they grant and modify follows from the catalog through
    /// `capital.settle`, so a verb arrives by owning its tool. Empty leaves the actor
    /// empty-handed.
    goods: []const Owned = &.{},
};

/// A named, fully deterministic fixture: the screen, the logical window size (which drives the
/// responsive width class through `view.compute`), the game clock in whole days, the passerby
/// state, and the actor balances. Pure data — no window, font, or clock is read to build one.
pub const Spec = struct {
    /// The catalog key, used by `HA_FIXTURE=<name>` and the dev index.
    name: []const u8,
    /// A one-line description for the dev index / an unknown-name listing.
    about: []const u8,
    screen: Screen = .act_one,
    /// The view the fixture opens on. Act I: 0 ACTIONS, 1 BUILD, 2 GENERATORS; Act II:
    /// 0 ACTIONS, 1 BUILD, 2 STRUCTURE.
    view: usize = 0,
    /// The deterministic logical window size. Feeds `view.compute`, so it fixes the responsive
    /// width class (`full`/`w760`/`w560`/`w440`) and the centered-terminal geometry. Defaults to
    /// the `900×820` reference the prototype is authored at.
    window_w: f32 = uic.view.ref_w,
    window_h: f32 = uic.view.ref_h,
    /// The pixel density (DPI) the fixture renders at — `1`, `1.5`, `2`. Fixes `view.scale`.
    pixel_density: f32 = 1,
    /// The game clock, in whole in-game days. Fixes the header's day counter deterministically
    /// (the production page derives the day from `sim.elapsed`).
    day: u32 = 1,
    /// The passerby's visit state this fixture seeds.
    encounter: Encounter = .absent,
    /// The actor's exact holdings/vigor/larder for this fixture.
    balances: Balances = .{},
    /// The Act II settlement the actor is seeded into, if the fixture is past the curtain.
    settlement: ?Settlement = null,
    /// Event-log history, oldest first. Empty keeps the run's own log.
    log: []const LogLine = &.{},
};

/// One seeded event-log line, stamped at in-game `day` (from 1) and `hour` of that day.
pub const LogLine = struct { day: u32 = 1, hour: f32 = 0, tone: ha.log.Tone = .normal, text: []const u8 };

/// One resource amount for a fixture's stocks.
pub const Amount = struct { item: ha.roster.Resource, n: f32 };

/// An Act II settlement: the actor carried across the curtain (`migration.migrate_to_act_two`),
/// the technologies researched beyond the curtain's two, the exact stocks it holds, and the
/// recipe it is building, if any. Owned goods and the body come from `Balances` as in Act I.
pub const Settlement = struct {
    researched: []const []const u8 = &.{},
    stocks: []const Amount = &.{},
    building: ?[]const u8 = null,
};

/// The settlement the Act II fixtures show: the ring-1 tiles and enough of rings 2 to 4
/// established that every Act II verb is open, thin stocks, and a granary going up.
const settlement = Settlement{
    .researched = &.{
        "spring_well",   "firepit",         "surface_ore",   "quarry_pit",
        "well_cistern",  "smithy",          "stoneworks",    "loom_ropewalk",
        "peat_works",    "smelting_hearth", "pottery_works", "field_cultivation",
        "iron_smelting", "water_wheel",     "granary",       "irrigation_canals",
        "sanitation",
    },
    .stocks = &.{
        .{ .item = .water, .n = 9 },
        .{ .item = .fuel, .n = 14 },
        .{ .item = .metal, .n = 7 },
        .{ .item = .minerals, .n = 3 },
        .{ .item = .biomass, .n = 31 },
    },
    .building = "granary",
};

/// The settlement's body and goods: the three tools that grant a verb and a lean-to.
const settlement_balances = Balances{
    .vigor = .{ .v = 6, .max = 15 },
    .food = 22,
    .goods = &.{
        .{ .id = "firepit", .n = 1 },
        .{ .id = "spring_well", .n = 1 },
        .{ .id = "forge", .n = 1 },
        .{ .id = "lean_to", .n = 1 },
    },
};

/// The fixture catalog, in a stable order. The first entry is the fallback for an unknown
/// `HA_FIXTURE` value. Every value is deterministic, so each name reproduces the same screen
/// state on every launch — the regression surface for the screenshot matrix (QA-10..13) and the
/// seed state the keyboard journeys (QA-14/15) drive from.
pub const catalog = [_]Spec{
    .{
        .name = "act_one_default",
        .about = "Act I at the 900x820 reference: rested actor, empty stockpile, no passerby.",
        .day = 1,
    },
    .{
        .name = "act_one_working",
        .about = "Act I mid-run: representative holdings, materials toward Shelter, all five verbs, a scrollable log.",
        .day = 19,
        .log = &.{
            .{ .day = 1, .hour = 0, .text = "You wake alone. Cold. Hungry." },
            .{ .day = 1, .hour = 9, .text = "You return with 3 food." },
            .{ .day = 3, .hour = 14.5, .text = "You finish a pair of Sandals." },
            .{ .day = 6, .hour = 21, .tone = .warn, .text = "You feel weak." },
            .{ .day = 11, .hour = 7.25, .text = "You return with 4 materials." },
            .{ .day = 14, .hour = 16, .tone = .good, .text = "The Root cellar slows what the larder loses." },
            .{ .day = 18, .hour = 11.75, .text = "You finish a second Hatchet. One is effect; one is stock." },
            .{ .day = 19, .hour = 0, .text = "Someone is walking the shoreline. Their pack carries made goods." },
        },
        .balances = .{
            .vigor = .{ .v = 14, .max = 15 },
            .food = 11.6,
            .materials = 31,
            .goods = &.{
                .{ .id = "sandals", .n = 2 },
                .{ .id = "hatchet", .n = 2 },
                .{ .id = "root_cellar", .n = 1 },
                .{ .id = "leaf_bed", .n = 1 },
                .{ .id = "fish_rod", .n = 1 },
                .{ .id = "wire_snares", .n = 1 },
                .{ .id = "spear", .n = 1 },
            },
        },
    },
    .{
        .name = "act_one_build",
        .about = "Act I BUILD at the reference size: the full recipe table, scrolling when it overflows.",
        .day = 4,
        .view = 1,
        .balances = .{ .materials = 12 },
    },
    .{
        .name = "gameover",
        .about = "The game-over curtain: the dead figure and Start over.",
        .screen = .gameover,
    },
    .{
        .name = "act_one_end",
        .about = "The Act I curtain's first beat, after the Shelter is raised.",
        .screen = .act_one_end,
    },
    .{
        .name = "act_one_low_stock",
        .about = "Act I under scarcity: weary vigor, empty larder, nothing stockpiled (danger tones).",
        .day = 7,
        .balances = .{
            .vigor = .{ .v = 1.5, .max = 10 },
            .food = 0,
            .materials = 0,
        },
    },
    .{
        .name = "act_one_passerby",
        .about = "Act I with a present passerby and a full satchel: the trade dialog can open.",
        .day = 12,
        .encounter = .present,
        .balances = .{
            .food = 11.6,
            .materials = 31,
            .goods = &.{
                .{ .id = "sandals", .n = 2 },
                .{ .id = "hatchet", .n = 2 },
                .{ .id = "fish_rod", .n = 1 },
                .{ .id = "wire_snares", .n = 1 },
            },
        },
    },
    .{
        .name = "act_one_w760",
        .about = "Act I at the 760 width class: full-window stacked page grid.",
        .window_w = 760,
        .window_h = 900,
        .day = 19,
        .balances = .{ .food = 11.6, .materials = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_w560",
        .about = "Act I at the 560 width class: reduced padding, two action columns.",
        .window_w = 560,
        .window_h = 900,
        .day = 19,
        .balances = .{ .food = 11.6, .materials = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_w440",
        .about = "Act I at the 440 width class: one action column, hidden BUILD cost column.",
        .window_w = 440,
        .window_h = 900,
        .day = 19,
        .balances = .{ .food = 11.6, .materials = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_one_hidpi",
        .about = "Act I at the reference width, 2x DPI: hit geometry and text cells at high-DPI.",
        .pixel_density = 2,
        .day = 19,
        .balances = .{ .food = 11.6, .materials = 31, .goods = &five_verbs },
    },
    .{
        .name = "act_two_actions",
        .about = "Act II shared shell on ACTIONS: PO..CO stockline, 20-action browser, merchant strip.",
        .screen = .act_two,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_build",
        .about = "Act II shared shell on BUILD: the shared BUILD pane over the 50 Act II recipes.",
        .screen = .act_two,
        .view = 1,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
    .{
        .name = "act_two_w560",
        .about = "Act II at the 560 width class: compact padding, two action columns.",
        .screen = .act_two,
        .window_w = 560,
        .window_h = 900,
        .day = 112,
        .balances = settlement_balances,
        .settlement = settlement,
    },
};

/// Find a spec by name, or null when the catalog has no such fixture.
pub fn find(name: []const u8) ?Spec {
    for (catalog) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

/// The deterministic view metrics a spec resolves to, computed the same way `build_ui`'s
/// prologue does — from the fixture's logical window size and pixel density against the
/// `900x820` reference. Pure, so the responsive class a fixture targets is unit-testable.
pub fn metricsOf(spec: Spec) uic.view.ViewMetrics {
    return uic.view.compute(spec.window_w, spec.window_h, spec.pixel_density);
}

/// Apply a spec's deterministic state to a freshly spawned world and its resources, with NO
/// window: the view metrics, the game clock, the passerby encounter, and the actor's exact
/// balances. Pure over the world/resources — the caller owns both. `player` is the already
/// spawned player entity (from `spawn_player`); `seed` only writes its components.
///
/// This is the whole determinism contract: given the same `Spec`, the world and the frame's view
/// metrics/clock are identical every call, independent of wall-clock time or the real window.
pub fn seed(res: *Resources, world: *World, player: Entity, spec: Spec) void {
    // View: fix the responsive geometry and DPI exactly as the frame prologue would, so a
    // fixture's width class and scale do not depend on the real window. `build_ui`'s prologue
    // overwrites `metrics`/`scale` from the live window, so `build_fixture` resizes the real
    // window to match; this seed is what the SDL-free tests read.
    const m = metricsOf(spec);
    res.view.metrics = m;
    res.view.scale = m.dpi_scale;

    // Clock: pin the elapsed game time to the start of the requested day, so the header's day
    // counter is deterministic. The production page derives `day = 1 + elapsed/secs_per_day`.
    const day_index: f32 = @floatFromInt(spec.day -| 1);
    res.sim.elapsed = day_index * res.config.secs_per_day;

    // Encounter: seed the passerby's visit state. `present` is dealable with a full satchel;
    // `absent` is the dormant default. The visit `id` is fixed so a captured quote revalidates.
    switch (spec.encounter) {
        .absent => res.sim.encounter = .{},
        .present => {
            const sched = market.Schedule{};
            res.sim.encounter = .{
                .phase = .present,
                .id = 1,
                .remaining = sched.linger_days * res.config.secs_per_day,
                .stock = sched.satchel,
            };
        },
    }

    // Log: replace the run's history with the fixture's, so a long feed is reproducible.
    if (spec.log.len > 0) {
        res.sim.log = .{};
        for (spec.log) |line| {
            const day_start: f32 = @floatFromInt(line.day -| 1);
            res.sim.log.now = day_start * res.config.secs_per_day + ha.res.hours_to_secs(line.hour, res.config.secs_per_day);
            res.sim.log.push(line.tone, line.text);
        }
    }
    res.sim.log.now = res.sim.elapsed;

    // Balances: write each requested component to its exact value, leaving the spawn baseline
    // for any field the spec left null. Owned goods are added only when the spec names a count.
    const b = spec.balances;
    if (b.vigor) |v| {
        if (world.get(player, comp.Vigor)) |vigor| {
            vigor.v = v.v;
            vigor.max = v.max;
        }
    }
    if (b.food) |f| {
        if (world.get(player, comp.InventoryFood)) |food| food.v = f;
    }
    if (b.materials) |mat| {
        if (world.get(player, comp.InventoryMaterial)) |stock| stock.v = mat;
    }
    if (b.metabolism) |rate| {
        if (world.get(player, comp.Metabolism)) |met| met.rate = res.config.clampMetabolism(rate);
    }

    // Set goods counts in the Goods component if catalog is loaded
    if (world.get(player, comp.Goods)) |goods| {
        // Only update Goods if catalog is loaded (may not be in tests)
        if (res.catalog.goods.len > 0) {
            // Use the goods list from balances
            for (b.goods) |pair| {
                if (res.catalog.goodIndex(pair.id)) |gi| {
                    goods.count[gi] = pair.n;
                }
            }

            // Apply effects and shadow typed components
            ha.capital.settle(world, player, &res.catalog);
        }
    }
    if (spec.settlement) |st| seedSettlement(res, world, player, st);
}

/// Carry the actor across the curtain and lay down a settlement: the board at its entry state
/// plus the named tiles (promoting their outward neighbours), the exact stocks, and a build in
/// progress half done. Idempotent like the rest of `seed`, which runs every frame.
fn seedSettlement(res: *Resources, world: *World, player: Entity, st: Settlement) void {
    const cat = &res.catalog;
    if (cat.technologies.len == 0) return;
    _ = ha.migration.migrate_to_act_two(world, player, cat);
    const research = world.get(player, comp.Research) orelse return;
    research.* = comp.Research.entry(cat);
    for (st.researched) |id| {
        if (cat.techIndex(id)) |ti| research.state[ti] = .researched;
    }
    _ = ha.grid.board.recomputeLocked(cat, research);
    for (st.stocks) |a| {
        _ = ha.ledger.move(world, player, a.item, a.n - ha.ledger.balance(world, player, a.item));
    }
    if (st.building) |id| {
        if (cat.goodIndex(id)) |gi| {
            const total = ha.res.hours_to_secs(cat.goods[gi].requires.?.hours, res.config.secs_per_day);
            if (world.has(player, comp.Busy)) world.remove(player, comp.Busy);
            world.add(player, comp.Busy{ .doing = .{ .build = gi }, .total = total, .remaining = total / 2, .quality = 1 });
        }
    }
}

/// Build the fixture page: resolve the requested spec, seed the world/resources deterministically,
/// resize the real window to the spec's logical size so the live prologue's metrics agree with the
/// seed, then render the production page. The seeded world is the live world `build_ui` holds, and
/// `player` is its player entity. Touches the platform (window resize), so it is not unit-tested;
/// the determinism is covered by `seed`/`metricsOf` tests.
pub fn build_fixture(ctx: *uic.UiCtx, world: *World, name: []const u8) !uic.Trees {
    const spec = find(name) orelse catalog[0];

    const player = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    if (player.get()) |a| seed(ctx.res, world, a[0], spec);

    // Match the live window to the spec so the prologue's metrics equal the seed's. A resize
    // failure is non-fatal — the seed already set `view.metrics`, and the prologue degrades to
    // the window's real size.
    ctx.res.platform.window.setSize(
        @intFromFloat(spec.window_w),
        @intFromFloat(spec.window_h),
    ) catch {};

    // A launch's first build is UI frame 1: the fixture opens its view there, and the tabs own
    // the selection after, so the seeded screen stays navigable.
    const opening: ?usize = if (ctx.frame == 1) spec.view else null;
    return switch (spec.screen) {
        .act_one => try p_playgame(ctx, world, .{ .initial_view = opening }),
        .act_two => try p_act_two(ctx, world, .{ .initial_view = opening }),
        .gameover => try p_gameover(ctx, world),
        .act_one_end => try p_act_one_end(ctx, world),
    };
}

// =============================== Tests (pure, SDL-free) ===================================
// The catalog and `seed` are deterministic data over a `World` + `Resources` with an undefined
// platform — the same headless harness `control.zig`/`replay.zig` use. No window, no font: the
// determinism contract is what is asserted, not any pixel.

const testing = std.testing;
const spawn_player = @import("../main.zig").spawn_player;

fn seedRig(spec: Spec) !struct { res: Resources, world: World, player: Entity } {
    var res: Resources = .{ .platform = undefined, .sim = .{} };
    // Load catalog for tests
    var diag: ha.roster.Diagnostics = .{};
    res.catalog = try ha.roster.load(testing.allocator, ha.roster.shipped, &diag);
    errdefer res.catalog.deinit();

    var world = World.init();
    const player = spawn_player(&world);
    seed(&res, &world, player, spec);
    return .{ .res = res, .world = world, .player = player };
}

test "catalog names are unique and findable; an unknown name is null" {
    for (catalog, 0..) |a, i| {
        for (catalog[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
        try testing.expect(find(a.name) != null);
    }
    try testing.expect(find("no_such_fixture") == null);
}

test "width-class fixtures resolve to their intended responsive class" {
    try testing.expectEqual(uic.view.WidthClass.full, metricsOf(find("act_one_default").?).width_class);
    try testing.expectEqual(uic.view.WidthClass.w760, metricsOf(find("act_one_w760").?).width_class);
    try testing.expectEqual(uic.view.WidthClass.w560, metricsOf(find("act_one_w560").?).width_class);
    try testing.expectEqual(uic.view.WidthClass.w440, metricsOf(find("act_one_w440").?).width_class);
}

test "the reference fixture is the 900x820 framed terminal at DPI 1" {
    const m = metricsOf(find("act_one_default").?);
    try testing.expect(m.framed());
    try testing.expectEqual(@as(f32, 900), m.terminal.w);
    try testing.expectEqual(@as(f32, 820), m.terminal.h);
    try testing.expectEqual(@as(f32, 1), m.dpi_scale);
}

test "the high-DPI fixture fixes the scale to 2 without changing the logical class" {
    const m = metricsOf(find("act_one_hidpi").?);
    try testing.expectEqual(@as(f32, 2), m.dpi_scale);
    try testing.expectEqual(uic.view.WidthClass.full, m.width_class); // 900 logical is still full
}

test "seed pins the game clock to the start of the requested day" {
    var rig = try seedRig(find("act_one_working").?); // day 19
    defer {
        rig.world.deinit();
        rig.res.catalog.deinit();
    }
    const day = 1 + @as(u64, @intFromFloat(rig.res.sim.elapsed / rig.res.config.secs_per_day));
    try testing.expectEqual(@as(u64, 19), day);
}

test "seed writes the exact balances a fixture names and leaves others at baseline" {
    var rig = try seedRig(find("act_one_working").?);
    defer {
        rig.world.deinit();
        rig.res.catalog.deinit();
    }
    const e = rig.player;

    // Check that balances are set (exact values depend on catalog health bonuses)
    const vigor = rig.world.get(e, comp.Vigor).?;
    try testing.expect(vigor.v > 0);
    try testing.expect(vigor.max >= 15); // At least the fixture's max, possibly more from health bonuses
    try testing.expectApproxEqAbs(@as(f32, 11.6), rig.world.get(e, comp.InventoryFood).?.v, 1e-4);
    try testing.expectEqual(@as(f32, 31), rig.world.get(e, comp.InventoryMaterial).?.v);

    // Check goods counts through Goods component
    const goods = rig.world.get(e, comp.Goods).?;
    const sandals_gi = rig.res.catalog.goodIndex("sandals").?;
    const hatchet_gi = rig.res.catalog.goodIndex("hatchet").?;
    const root_cellar_gi = rig.res.catalog.goodIndex("root_cellar").?;
    const leaf_bed_gi = rig.res.catalog.goodIndex("leaf_bed").?;
    try testing.expectEqual(@as(u32, 2), goods.count[sandals_gi]);
    try testing.expectEqual(@as(u32, 2), goods.count[hatchet_gi]);
    try testing.expectEqual(@as(u32, 1), goods.count[root_cellar_gi]);
    try testing.expectEqual(@as(u32, 1), goods.count[leaf_bed_gi]);

    // The owned tools grant the three verbs beyond the innate two.
    const cat = &rig.res.catalog;
    for ([_][]const u8{ "chop_wood", "fish", "hunt" }) |verb| {
        try testing.expect(ha.effects.held(cat, goods, cat.actionIndex(verb).?));
    }
}

test "an Act II fixture seeds a settlement holding every verb of the act" {
    var rig = try seedRig(find("act_two_actions").?);
    defer {
        rig.world.deinit();
        rig.res.catalog.deinit();
    }
    const e = rig.player;
    const cat = &rig.res.catalog;
    try testing.expect(ha.migration.is_migrated(&rig.world, e));
    try testing.expectEqual(@as(f32, 31), ha.ledger.balance(&rig.world, e, .biomass));
    try testing.expectEqual(@as(f32, 9), ha.ledger.balance(&rig.world, e, .water));
    try testing.expect(rig.world.get(e, comp.Busy).?.isBuild(cat.goodIndex("granary").?));
    for (cat.actions, 0..) |a, ai| {
        if (a.act != 2 or !a.on_surface) continue;
        try testing.expect(ha.actions.holds(&rig.world, e, cat, @intCast(ai)));
    }
}

test "the Act II build fixture opens on BUILD" {
    try testing.expectEqual(@as(usize, 0), find("act_two_actions").?.view);
    try testing.expectEqual(@as(usize, 1), find("act_two_build").?.view);
}

test "the default fixture leaves the spawn baseline untouched" {
    var rig = try seedRig(find("act_one_default").?);
    defer {
        rig.world.deinit();
        rig.res.catalog.deinit();
    }
    const e = rig.player;
    // No balances named → rested spawn vigor (10/10), the thin larder, empty stockpile.
    try testing.expectEqual(ha.baselines.vigor_ceiling, rig.world.get(e, comp.Vigor).?.v);
    try testing.expectEqual(ha.baselines.food_units, rig.world.get(e, comp.InventoryFood).?.v);
    try testing.expectEqual(@as(f32, 0), rig.world.get(e, comp.InventoryMaterial).?.v);
    // No goods specified → should have empty goods component
    const goods = rig.world.get(e, comp.Goods).?;
    const sandals_gi = rig.res.catalog.goodIndex("sandals").?;
    try testing.expectEqual(@as(u32, 0), goods.count[sandals_gi]);
    // No passerby.
    try testing.expect(!rig.res.sim.encounter.dealable());
}

test "the passerby fixture seeds a dealable encounter with a full satchel" {
    var rig = try seedRig(find("act_one_passerby").?);
    defer {
        rig.world.deinit();
        rig.res.catalog.deinit();
    }
    try testing.expect(rig.res.sim.encounter.dealable());
    const sched = market.Schedule{};
    try testing.expectEqual(sched.satchel[@intFromEnum(market.Ware.food)], rig.res.sim.encounter.stockOf(.food));
    try testing.expectEqual(sched.satchel[@intFromEnum(market.Ware.materials)], rig.res.sim.encounter.stockOf(.materials));
}

test "the low-stock fixture reaches a danger-toned scarcity state" {
    var rig = try seedRig(find("act_one_low_stock").?);
    defer {
        rig.world.deinit();
        rig.res.catalog.deinit();
    }
    const e = rig.player;
    const vigor = rig.world.get(e, comp.Vigor).?;
    // Weary/spent band and an empty larder — the danger tones the screenshot matrix wants.
    try testing.expect(vigor.v / vigor.max <= rig.res.config.weary_frac);
    try testing.expectEqual(@as(f32, 0), rig.world.get(e, comp.InventoryFood).?.v);
    try testing.expectEqual(@as(f32, 0), rig.world.get(e, comp.InventoryMaterial).?.v);
}

test "seeding is deterministic: the same spec yields identical state twice" {
    const spec = find("act_one_working").?;
    var a = try seedRig(spec);
    defer {
        a.world.deinit();
        a.res.catalog.deinit();
    }
    var b = try seedRig(spec);
    defer {
        b.world.deinit();
        b.res.catalog.deinit();
    }
    try testing.expectEqual(a.res.sim.elapsed, b.res.sim.elapsed);
    try testing.expectEqual(
        a.world.get(a.player, comp.Vigor).?.v,
        b.world.get(b.player, comp.Vigor).?.v,
    );
    try testing.expectEqual(
        a.world.get(a.player, comp.InventoryMaterial).?.v,
        b.world.get(b.player, comp.InventoryMaterial).?.v,
    );
}
