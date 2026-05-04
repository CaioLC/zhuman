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

            .counter    = time.Counter.init(0.0),
            .timer      = time.Timer.init(30.0, null),
            .population = time.Accumulator(i32).init(1),
            .calendar   = time.Counter.init(0.0),
            .money      = time.Accumulator(i32).init(500),
            .calories   = time.Accumulator(i32).init(1000),
            .stockpile  = time.Accumulator(i32).init(4000),
        };
    }
};
