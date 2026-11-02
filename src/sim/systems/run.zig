//! The run's lifecycle: a `NewRun` intent requests Act I (`new_run`, in every state's `handle`
//! set), entering Act I begins the run (`begin_run`, its `on_enter`), and a run with no player
//! left requests the game-over state (`detect_death`, after `despawn_dead` in each act). The
//! player's spawn lives here, so the world is empty until a run begins.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const comp = @import("../components.zig");
const tag = @import("../tags.zig");
const res_mod = @import("../res.zig");
const States = @import("../state.zig").States;

const World = ecs.World;
const Entity = ecs.Entity;

/// The living player, if any.
const LivingPlayer = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) });

/// The opening line every run begins with; the log words `RunBegun` as it.
pub const opening_line = "You wake alone. Cold. Hungry.";

fn spawn_agent(world: *World) Entity {
    // Spawn from the components' authoritative default baselines (see `baselines.zig`)
    // rather than repeating literals — `Vigor{}` is rested at the ceiling, `InventoryFood{}` is
    // the thin perishable larder, `Metabolism{}` eats continuously at the normal rate — so the
    // starting state has exactly one source and Holdings can derive current-vs-base against it.
    return world.spawn(.{
        comp.Vigor{}, // rested at the ceiling (10/10)
        comp.InventoryFood{}, // a thin, perishable larder (4 units, quality 1, spoils 0.05)
        comp.InventoryBiomass{ .v = 0 }, // nothing stockpiled yet
        comp.Metabolism{}, // eats continuously from the first breath (normal rate)
        comp.Goods{}, // owns nothing yet; what it can do is derived from this and the roster
        comp.Generators{}, // collectable capital accumulates independently of the body's work
        comp.Granted{}, // and the goods contribute nothing to the body or larder yet
        comp.Condition{}, // rested; the `condition` system keeps the band
    });
}

/// Spawn an agent at the spawn baselines and tag it `Player`. `begin_run` calls it; a fixture
/// or a test that needs the player without a run calls it directly.
pub fn spawn_player(world: *World) Entity {
    const e = spawn_agent(world);
    world.add(e, tag.Player{});
    return e;
}

/// Read `NewRun` and request Act I. Several in one tick are one request; from Act I it is a
/// restart. Never refused.
pub fn new_run(intents: ecs.EventReader(events.NewRun, .run), states: *States) void {
    while (intents.next()) |_| states.set(.act_one);
}

/// Begin a fresh run, entering Act I: retire any living player (a settled actor is still alive
/// at a restart, so spawning over them would leave two), spawn the new one, reset `Sim` (the
/// clock, the log, the encounters; the prng carries over) and emit `RunBegun`.
pub fn begin_run(w: *World, sim: *res_mod.Sim, living: LivingPlayer, begun: ecs.EventWriter(events.RunBegun)) void {
    if (living.get()) |entry| w.despawn(entry[0]);
    _ = spawn_player(w);
    sim.reset();
    _ = begun.push(.{});
}

/// Request the game-over state once no player remains. A transition already requested this
/// tick (a new run) stands.
pub fn detect_death(states: *States, living: LivingPlayer) void {
    if (living.get() == null and states.next == null) states.set(.game_over);
}

// ============================ Tests ==========================================

const testing = std.testing;

test "new_run requests Act I once for several intents, and nothing without one" {
    var w = World.init();
    var res = res_mod.Resources{};
    res.events.update();
    ecs.run(&w, &res, new_run);
    try testing.expectEqual(@as(?@TypeOf(res.states.current), null), res.states.next);
    _ = res.events.writer(events.NewRun).push(.{});
    _ = res.events.writer(events.NewRun).push(.{});
    ecs.run(&w, &res, new_run);
    try testing.expectEqual(@as(?@TypeOf(res.states.current), .act_one), res.states.next);
    try testing.expect(res.states.in(.title));
}

test "begin_run retires the living player, spawns one, resets Sim and emits RunBegun" {
    var w = World.init();
    var res = res_mod.Resources{};
    res.events.update();
    const old = spawn_player(&w);
    res.sim.elapsed = 99;
    const prng_before = res.sim.prng;
    ecs.run(&w, &res, begin_run);

    try testing.expect(!w.has(old, comp.Vigor));
    const now = (LivingPlayer{ .world = &w }).get().?;
    try testing.expect(now[0] != old);
    try testing.expectEqual(@as(f32, 0), res.sim.elapsed);
    try testing.expectEqual(prng_before.s, res.sim.prng.s);
    try testing.expectEqual(@as(usize, 1), res.events.len(events.RunBegun));
}

test "detect_death requests game over only when no player remains" {
    var w = World.init();
    var res = res_mod.Resources{ .states = .{ .current = .act_one } };
    const e = spawn_player(&w);
    ecs.run(&w, &res, detect_death);
    try testing.expectEqual(@as(?@TypeOf(res.states.current), null), res.states.next);
    w.despawn(e);
    ecs.run(&w, &res, detect_death);
    try testing.expectEqual(@as(?@TypeOf(res.states.current), .game_over), res.states.next);
}
