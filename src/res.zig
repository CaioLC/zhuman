const sdl = @import("sdl3");
const time = @import("./time.zig");
const font = @import("./font.zig");

pub const Resources = struct {
    font:     *sdl.ttf.Font,
    renderer: *const sdl.render.Renderer,
    window:   sdl.video.Window,

    counter:    time.Counter,
    timer:      time.Timer,
    population: time.Accumulator(i32),
    calendar:   time.Counter,
    money:      time.Accumulator(i32),
    calories:   time.Accumulator(i32),
    stockpile:  time.Accumulator(i32),

    pub fn init(f: *sdl.ttf.Font, r: *const sdl.render.Renderer, w: sdl.video.Window) Resources {
        return .{
            .font     = f,
            .renderer = r,
            .window   = w,

            .counter    = .{ .v = 0.0 },
            .timer      = .{ .v = 30.0, .start = 30.0, .end = 0.0 },
            .population = .{ .v = 1 },
            .calendar   = .{ .v = 0.0 },
            .money      = .{ .v = 500 },
            .calories   = .{ .v = 1000 },
            .stockpile  = .{ .v = 4000 },
        };
    }
};
