const std = @import("std");
const sdl = @import("sdl3");
const comp = @import("./components.zig");
const logmod = @import("./log.zig");
const thememod = @import("./ui_client/theme.zig");
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
    /// **Renderer generation** (TEXT-05). A monotonic counter bumped every time the SDL
    /// renderer's device/targets are (re)set — the host loop advances it on an
    /// `SDL_EVENT_RENDER_TARGETS_RESET` / `RENDER_DEVICE_RESET` / `RENDER_DEVICE_LOST`
    /// event (`bumpGeneration`). It is folded into the text-texture cache key so a texture
    /// uploaded under an older generation is never blitted after a reset invalidates it;
    /// and it lets a cached slot distinguish an ordinary invalidation (renderer alive —
    /// free the old texture) from a post-reset one (underlying GPU texture already dead —
    /// abandon the handle, do **not** double-free). Starts at `0`; the first upload keys on
    /// it. Read-only outside the host loop's reset handler and `Resources.init`.
    generation: u32 = 0,

    /// Advance the renderer generation (TEXT-05). Called by the host loop when SDL reports
    /// a render targets/device reset or loss: every GPU texture uploaded under the prior
    /// generation is now invalid, so bumping this makes the text cache miss (and abandon,
    /// not free, the dead handles) and re-rasterize under the new generation. Saturates
    /// rather than wraps so an absurdly long-lived process can never alias an old value.
    pub fn bumpGeneration(self: *Platform) void {
        self.generation +|= 1;
    }
};

/// This frame's timestep, written by the host loop before the systems run.
pub const Time = struct {
    dt: f32 = 0,
};

/// Host frame input state, fed by the event loop and shared by UI/ECS consumers.
pub const Input = @import("./ui_client/input.zig").Input;

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
    /// The bounded metabolism-rate range and default (ACT1-02). `Metabolism.rate` is a scalar
    /// multiplier the player sets continuously; the *range* and *default* are config (not UI
    /// words), and `clampMetabolism` is the one place a rate is made legal. Normal is the
    /// default (`1.0`); ration/feast are just points inside `[min, max]`.
    metabolism_rate_min: f32 = 0.5,
    metabolism_rate_max: f32 = 2.0,
    metabolism_rate_default: f32 = 1.0,

    // —— capital ——
    /// Share of a cancelled build's materials that comes back. Flat, not prorated by
    /// how far the work got: materials are spent in full at `begin_build` and nothing
    /// draws them down over time, so a time-proportional refund would imply a
    /// consumption schedule the sim doesn't run. What it means is salvage — you take
    /// back the stock you hadn't worked in yet. The energy and the hours are gone.
    cancel_refund: f32 = 0.5,

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

    /// Clamp a metabolism rate into the authoritative `[min, max]` band (ACT1-02) — the one
    /// place a rate is made legal, used on migration/reset and by any UI that sets the rate.
    pub fn clampMetabolism(self: Config, rate: f32) f32 {
        return std.math.clamp(rate, self.metabolism_rate_min, self.metabolism_rate_max);
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
/// `Ctx` pool; state the sim writes belongs in `Sim`. The responsive-scale factor is the
/// next resident (docs/roadmap.md, "Act I").
pub const View = struct {
    /// This frame's palette — `build_ui` installs one over the foundation's neutral
    /// defaults.
    theme: thememod.Theme = .{},
    /// This frame's terminal **ground** — the near-black the framed terminal floats on
    /// (art direction, not a foundation `Theme` role; installed from `palette.ground` by
    /// `build_ui`). Defaults to the terminal `bg` so a view built before the prologue runs
    /// still has a sane, non-clashing value.
    ground: thememod.Color = .{ .r = 14, .g = 12, .b = 9, .a = 255 },
    /// This frame's six resource/sector colors (Food/Water/Fuel/Metal/Minerals/Biomass) —
    /// game content, not `Theme` roles (KIT-01). Installed from `palette.resources` by
    /// `build_ui`; the HUD/legend samples a hue by name.
    resources: @import("./palette.zig").ResourceColors = .{},
    /// This frame's reduced-motion policy (INPUT-10), projected from `Resources.motion`
    /// in `build_ui`'s prologue. When `true`, *optional/decorative* transitions must snap
    /// to their end state (via `ui_client.MotionPolicy.snap`/`.phase`); functional progress
    /// indicators, state changes, pointer/focus cues, and the simulation stay visible and
    /// are never gated by it.
    reduced_motion: bool = false,
    /// This frame's **logical→device scale factor** (TEXT-04 seam for VIEW-01). Every font
    /// size the host resolves is multiplied by this exactly once, in
    /// `ui_client.type.toDevice`, before it reaches the font backend — so a heading at 21
    /// *logical* px opens the font at `21 * scale` device px and tracking is computed at the
    /// device size. Defaults to `1` (device px == logical px, today's behavior byte-for-byte)
    /// until VIEW-01 computes the real DPI/reference-fit factor here each frame. Kept as a
    /// single field so there is exactly one multiply point for the whole UI.
    scale: f32 = 1,
    /// This frame's **view metrics** (VIEW-01): the logical viewport, drawable/DPI scale, the
    /// centered terminal rect, and the responsive width class — computed once per frame in
    /// `build_ui`'s prologue from the window's coordinate size and pixel density against the
    /// `900×820` reference. `scale` above is set from `metrics.dpi_scale`; the responsive
    /// templates (VIEW-03/04) read `metrics.terminal`/`metrics.width_class`. Defaults to the
    /// reference metrics so a view built before the prologue runs is still sane.
    metrics: @import("./ui_client/view.zig").ViewMetrics = .{},
};

/// The host bundle, held by `Ctx` as `*Res` and passed to systems. One field per
/// writer: `platform` is set at init, `input`/`time` by the event loop, `sim` by the
/// systems, `config` by nobody, `view` by `build_ui`.
pub const Resources = struct {
    platform: Platform,
    input: Input = .{},
    cursor: @import("./ui_client/cursor.zig").State = .{},
    commands: @import("./ui_client/command.zig").Registry = .{},
    /// Host-side accessibility model (INPUT-08): the double-buffered semantic snapshot the
    /// platform bridge (INPUT-09) will read, plus the polite live-announcement channel.
    /// Presentation plumbing only — no simulation system reads or writes it. Built in paint
    /// order during `build_ui` and published after end-frame, exactly like `commands`.
    semantics: @import("./ui_client/semantics.zig").SemanticRegistry = .{},
    announcements: @import("./ui_client/semantics.zig").AnnouncementChannel = .{},
    /// Host-side accessibility bridge (INPUT-09): consumes the published `semantics` snapshot
    /// and drains `announcements` to the active platform provider each frame. Default provider
    /// is the inert `NoopProvider` — this build ships no Windows UIA screen-reader tree
    /// (`zig-sdl3` 0.1.6 exposes no `WM_GETOBJECT` hook), and the bridge's capability report
    /// says so honestly. All platform policy stays host-side; no simulation system touches it.
    a11y: @import("./ui_client/a11y.zig").Bridge =
        @import("./ui_client/a11y.zig").Bridge.init(@import("./ui_client/a11y.zig").NoopProvider.instance()),
    /// Host-side reduced-motion policy (INPUT-10): a one-bit preference resolved **once** at
    /// init — an explicit `HA_REDUCED_MOTION` override, else the Windows
    /// `SPI_GETCLIENTAREAANIMATION` probe, else a deterministic `false` fallback — and then
    /// projected onto `view.reduced_motion` every frame in `build_ui`. Avoids per-frame OS
    /// calls. Presentation policy only; no simulation system reads or writes it. Defaults to
    /// motion-allowed until `init` resolves the real preference.
    motion: @import("./ui_client/motion.zig").Policy = .{},
    /// Host-side transition/tween registry (RENDER-08): scalar transitions keyed by stable
    /// node/domain id for the prototype's functional animations (Holdings collapse, stock-token
    /// font swap, board state changes). `main` advances it by the frame `dt` and projects the
    /// reduced-motion policy onto it each frame; a consumer reads `value(id, fallback)` to
    /// drive a size/gap/opacity. Presentation only; no simulation system reads it. Bounded and
    /// non-allocating (POD), so it lives inline on `Resources`.
    tween: @import("./ui_client/tween.zig").Registry = .{},
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

test "Config.clampMetabolism bounds the rate into [min, max]" {
    const cfg = Config{}; // min 0.5, max 2.0, default 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.clampMetabolism(1.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cfg.clampMetabolism(0.1), 1e-6); // clamps low
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), cfg.clampMetabolism(9.0), 1e-6); // clamps high
    try std.testing.expectApproxEqAbs(@as(f32, 1.3), cfg.clampMetabolism(1.3), 1e-6); // in-band untouched
    try std.testing.expectEqual(cfg.metabolism_rate_default, (comp.Metabolism{}).rate); // default matches component
}
