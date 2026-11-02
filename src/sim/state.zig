//! The run's states and the store that holds them. `GameState` is what the schedule
//! (`schedule.zig`) routes on: before a run, each act, and the run's end. `States` is the
//! engine's state resource over it, held on `sim.Resources.states`, so a system requests a
//! transition through `*States` and the UI reads `states.in(...)`.

const ecs = @import("ecs");

/// Where the run is. `title` is before a run has begun; it is the first tag, so a fresh
/// `sim.Resources{}` begins there. `game_over` is terminal: no player, one way out (`NewRun`).
pub const GameState = enum { title, act_one, act_two, act_three, game_over };

/// The current state and the transition requested for the next tick.
pub const States = ecs.States(GameState);
