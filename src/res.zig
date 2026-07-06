const std = @import("std");
const sdl = @import("sdl3");
const comp = @import("./components.zig");
const font = @import("./font.zig");
const logmod = @import("./log.zig");

pub const Time = struct {
    dt: f32,
    /// Seconds of game time elapsed this run — advanced while the actor lives (see
    /// `advance_clock`), reset on start over. Drives the day counter.
    elapsed: f32 = 0,
};

/// Host input state for this frame, fed by the event loop. Shared by both the
/// UI (hit-testing via `comm`) and ECS systems — one source of truth.
pub const Input = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// A press occurred during this frame's event poll (one-frame edge).
    mouse_down: bool = false,
    /// Vertical wheel delta this frame (one-frame edge; 0 when idle). Positive = away
    /// from the user (SDL convention) — `scroll_view` treats that as "scroll up".
    wheel_y: f32 = 0,
};

pub const Resources = struct {
    font: *sdl.ttf.Font,
    renderer: *const sdl.render.Renderer,
    window: sdl.video.Window,
    time: Time,
    input: Input,
    /// Newest-first event feed shown in the HUD log panel; global (one feed for the run).
    log: logmod.Log = .{},
    /// The simulation's one source of chance — every uncertain outcome (an action
    /// that may or may not deliver) is rolled against this. Held here so the player
    /// today and the AI deciders later draw uncertainty from the same stream.
    prng: std.Random.DefaultPrng,
    tex: sdl.render.Texture,
    /// Sprite sheet of capital-good icons (`assets/icons.png`, a 2×2 grid). Cached once
    /// here; the UI samples cells from it by source rect (see `widgets.data_sprite`).
    icons: sdl.render.Texture,

    pub fn init(f: *sdl.ttf.Font, r: *const sdl.render.Renderer, w: sdl.video.Window) !Resources {
        const tex = try sdl.image.loadTexture(r.*, "assets/hello.png");
        const icons = try sdl.image.loadTexture(r.*, "assets/icons.png");
        return .{
            .font = f,
            .renderer = r,
            .window = w,
            .time = .{ .dt = 0 },
            .input = .{},
            .prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
            .tex = tex,
            .icons = icons,
        };
    }

    pub fn deinit(self: *Resources) void {
        self.tex.deinit();
        self.icons.deinit();
    }

    /// A `std.Random` over `prng` — call `.float(f32)`, `.boolean()`, etc. on it.
    pub fn random(self: *Resources) std.Random {
        return self.prng.random();
    }
};
