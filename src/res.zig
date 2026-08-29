const std = @import("std");
const sdl = @import("sdl3");
const comp = @import("./components.zig");
const logmod = @import("./log.zig");
const thememod = @import("./theme.zig");
const fontmod = @import("./font.zig");

/// In-game hours → game-seconds (a day is 24h mapped onto `Config.secs_per_day`).
/// Action durations are authored in hours (`Requires.hours`) — human-readable on the
/// tiles — and ticked in game-seconds (`Busy.remaining`).
pub fn hours_to_secs(h: f32, secs_per_day: f32) f32 {
    return h * secs_per_day / 24.0;
}

/// Host handles, set once in `Resources.init` and never written again. Read only by
/// the UI — no sim system touches one.
pub const Platform = struct {
    /// The multi-size monospace text backend (see `font.zig`) — measure/render at any
    /// point size, one cached `ttf.Font` per size. Held by pointer, owned by `App`.
    font: *fontmod.Fonts,
    renderer: *const sdl.render.Renderer,
    window: sdl.video.Window,
    tex: sdl.render.Texture,
    /// Sprite sheet of capital-good icons (`assets/icons.png`, a 2×2 grid). Cached once
    /// here; the UI samples cells from it by source rect (see the `img` feature's
    /// `attach_sprite`, re-exported as `ui_client.data_sprite`).
    icons: sdl.render.Texture,
};

/// This frame's timestep, written by the host loop before the systems run.
pub const Time = struct {
    dt: f32 = 0,
};

/// Host input state for this frame, fed by the event loop. Shared by both the
/// UI (hit-testing via `mark`) and ECS systems — one source of truth.
pub const Input = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// A press occurred during this frame's event poll (one-frame edge).
    mouse_down: bool = false,
    /// Vertical wheel delta this frame (one-frame edge; 0 when idle). Positive = away
    /// from the user (SDL convention) — `scroll_view` treats that as "scroll up".
    wheel_y: f32 = 0,
};

/// How tired an agent is, in bands. One vocabulary for the condition word, the vigor
/// chip's color, the "you feel weak" log lines and labor's yield penalty — they all key
/// off the same two thresholds, so they read them through `Config.condition` rather than
/// each carrying its own copy of the numbers.
pub const Condition = enum { alive, weary, spent };

/// Tuning knobs. Never written at runtime, and deliberately **not** part of `Sim`, so
/// starting a fresh run doesn't discard a setting the player chose. Every value here is
/// a first guess awaiting playtesting — which is why they're runtime fields rather than
/// consts scattered across `actions.zig`, `systems.zig` and the templates.
pub const Config = struct {
    /// Game-seconds per in-game day — the tempo every per-day rate (metabolism,
    /// starvation, spoilage-as-displayed) is expressed against, and the day counter's
    /// divisor. Lives here (not `main.zig`) so library systems can convert per-day
    /// rates to per-`dt` amounts.
    secs_per_day: f32 = 20,

    // —— condition bands ——
    /// Vigor fraction at or below which an agent is SPENT.
    spent_frac: f32 = 0.12,
    /// Vigor fraction below which an agent is WEARY.
    weary_frac: f32 = 0.35,
    /// Yield multiplier once an agent is no longer `.alive`. A constant step, not a
    /// linear slide — the slide was built once and reverted (band churn, felt bad).
    weary_yield: f32 = 0.7,

    // —— metabolism ——
    /// Vigor drained per day once the larder is empty. ~2.5 days from a full tank to
    /// death — the countdown that makes rationing a real decision.
    starve_per_day: f32 = 4.0,
    /// Vigor gained per unit of food eaten, before the larder's `quality` scales it.
    vigor_per_food: f32 = 2.0,
    /// Per-day consumption multipliers for the two off-normal ration settings. `normal`
    /// has none by definition — `Metabolism.base_rate` already is the normal rate.
    ration_scale: f32 = 0.5,
    feast_scale: f32 = 2.0,

    /// Which band a vigor fraction falls in. The single definition of the two
    /// thresholds; edge-crossing is a change in this value.
    pub fn condition(self: Config, frac: f32) Condition {
        if (frac <= self.spent_frac) return .spent;
        if (frac < self.weary_frac) return .weary;
        return .alive;
    }

    /// Labor's yield multiplier for an agent in this condition.
    pub fn yield_of(self: Config, c: Condition) f32 {
        return if (c == .alive) 1.0 else self.weary_yield;
    }
};

/// The run: everything the simulation writes that isn't a component. `reset` starts a
/// fresh one — a new field added here is cleared by that call for free, which is the
/// point of the grouping.
pub const Sim = struct {
    /// Seconds of game time elapsed this run — advanced while the actor lives (see
    /// `advance_clock`). Drives the day counter.
    elapsed: f32 = 0,
    /// Newest-first event feed shown in the HUD log panel; one feed for the run.
    log: logmod.Log = .{},
    /// The player has resolved at least one action this run — flips in
    /// `actions.begin_labor` and condenses the teaching card (`action_card`) into the
    /// compact tile (`action_tile`). A future settings menu lets an experienced player
    /// pre-set it.
    tutorial_done: bool = false,
    /// The simulation's one source of chance — every uncertain outcome is rolled
    /// against this. Held here so the player today and the AI deciders later draw
    /// uncertainty from the same stream. Reached through `Resources.random()`.
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

    /// Begin a fresh run. The prng is **carried over on purpose**: rewinding it would
    /// make every run replay the first one's luck.
    pub fn reset(self: *Sim) void {
        self.* = .{ .prng = self.prng };
    }
};

/// This frame's resolved presentation values. Everything here is recomputed in
/// `build_ui`'s prologue from sim state and the window; nothing persists across frames,
/// and nothing outside the UI reads it. State that must survive a frame belongs in a
/// `Ctx` pool; state the sim writes belongs in `Sim`. The responsive-scale factor
/// (see `ui_client/style.zig`'s `TODO(responsive-scale)`) is the next resident.
pub const View = struct {
    /// TODO: let's drop the cold/warm for now.
    theme: thememod.Theme = thememod.cold,
};

/// The host bundle, held by `Ctx` as `*Res` and passed to systems. One field per
/// writer: `platform` is set at init, `input`/`time` by the event loop, `sim` by the
/// systems, `config` by nobody, `view` by `build_ui`.
pub const Resources = struct {
    platform: Platform,
    input: Input = .{},
    time: Time = .{},
    sim: Sim,
    config: Config = .{},
    view: View = .{},

    pub fn init(f: *fontmod.Fonts, r: *const sdl.render.Renderer, w: sdl.video.Window) !Resources {
        const tex = try sdl.image.loadTexture(r.*, "assets/hello.png");
        const icons = try sdl.image.loadTexture(r.*, "assets/icons.png");
        return .{
            .platform = .{ .font = f, .renderer = r, .window = w, .tex = tex, .icons = icons },
            .sim = .{ .prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())) },
        };
    }

    pub fn deinit(self: *Resources) void {
        self.platform.tex.deinit();
        self.platform.icons.deinit();
    }

    /// A `std.Random` over `sim.prng` — call `.float(f32)`, `.boolean()`, etc. on it.
    pub fn random(self: *Resources) std.Random {
        return self.sim.prng.random();
    }
};
