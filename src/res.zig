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

    pub fn init(f: *sdl.ttf.Font, r: *const sdl.render.Renderer, w: sdl.video.Window) Resources {
        return .{
            .font     = f,
            .renderer = r,
            .window   = w,
            .time     = .{ .dt = 0 },
            .input    = .{},
        };
    }
};
