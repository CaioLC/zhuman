const sdl = @import("sdl3");
const comp = @import("./components.zig");
const font = @import("./font.zig");

pub const Resources = struct {
    font:     *sdl.ttf.Font,
    renderer: *const sdl.render.Renderer,
    window:   sdl.video.Window,

    counter:    comp.Counter,
    timer:      comp.Timer,
    population: i32,
    calendar:   comp.Counter,
    money:      i32,
    calories:   i32,
    stockpile:  i32,

    pub fn init(f: *sdl.ttf.Font, r: *const sdl.render.Renderer, w: sdl.video.Window) Resources {
        return .{
            .font     = f,
            .renderer = r,
            .window   = w,

            .counter    = .{ .v = 0.0,  .multiplier = 1.0, ._buffer = 0.0 },
            .timer      = .{ .v = 30.0, .start = 30.0, .end = 0.0, .multiplier = 1.0, ._buffer = 0.0 },
            .population = 1,
            .calendar   = .{ .v = 0.0,  .multiplier = 1.0, ._buffer = 0.0 },
            .money      = 500,
            .calories   = 1000,
            .stockpile  = 4000,
        };
    }
};
