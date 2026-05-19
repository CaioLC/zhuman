const sdl = @import("sdl3");
const comp = @import("./components.zig");
const font = @import("./font.zig");

pub const Time = struct {
    dt: f32,
};

pub const Resources = struct {
    font:     *sdl.ttf.Font,
    renderer: *const sdl.render.Renderer,
    window:   sdl.video.Window,
    time:     Time,

    pub fn init(f: *sdl.ttf.Font, r: *const sdl.render.Renderer, w: sdl.video.Window) Resources {
        return .{
            .font     = f,
            .renderer = r,
            .window   = w,
            .time     = .{ .dt = 0 },
        };
    }
};
