const std = @import("std");
const sdl = @import("sdl3");
const comp = @import("./components.zig");
const font = @import("./font.zig");

pub const Time = struct {
    dt: f32,
};

/// Host input state for this frame, fed by the event loop. Shared by both the
/// UI (hit-testing via `comm`) and ECS systems — one source of truth.
pub const Input = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// A press occurred during this frame's event poll (one-frame edge).
    mouse_down: bool = false,
};

pub const Resources = struct {
    font:     *sdl.ttf.Font,
    renderer: *const sdl.render.Renderer,
    window:   sdl.video.Window,
    time:     Time,
    input:    Input,
    /// The simulation's one source of chance — every uncertain outcome (an action
    /// that may or may not deliver) is rolled against this. Held here so the player
    /// today and the AI deciders later draw uncertainty from the same stream.
    prng:     std.Random.DefaultPrng,

    pub fn init(f: *sdl.ttf.Font, r: *const sdl.render.Renderer, w: sdl.video.Window) Resources {
        return .{
            .font     = f,
            .renderer = r,
            .window   = w,
            .time     = .{ .dt = 0 },
            .input    = .{},
            .prng     = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
        };
    }

    /// A `std.Random` over `prng` — call `.float(f32)`, `.boolean()`, etc. on it.
    pub fn random(self: *Resources) std.Random {
        return self.prng.random();
    }
};
