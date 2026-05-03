const time = @import("./time.zig");
const font = @import("./font.zig");

pub const Singletons = struct {
    counter:    time.Counter,
    timer:      time.Timer,
    population: time.Accumulator(i32),
    calendar:   time.Counter,
    money:      time.Accumulator(i32),
    calories:   time.Accumulator(i32),
    stockpile:  time.Accumulator(i32),

    counter_display:    font.TextData,
    population_display: font.TextData,
    calendar_display:   font.TextData,
    money_display:      font.TextData,
    calories_display:   font.TextData,
    stockpile_display:  font.TextData,

    pub fn init() Singletons {
        return .{
            .counter    = time.Counter.init(0.0),
            .timer      = time.Timer.init(30.0, null),
            .population = time.Accumulator(i32).init(1),
            .calendar   = time.Counter.init(0.0),
            .money      = time.Accumulator(i32).init(500),
            .calories   = time.Accumulator(i32).init(1000),
            .stockpile  = time.Accumulator(i32).init(4000),

            .counter_display    = font.TextData.init(),
            .population_display = font.TextData.init(),
            .calendar_display   = font.TextData.init(),
            .money_display      = font.TextData.init(),
            .calories_display   = font.TextData.init(),
            .stockpile_display  = font.TextData.init(),
        };
    }

    pub fn deinit(self: *Singletons) void {
        self.counter_display.deinit();
        self.population_display.deinit();
        self.calendar_display.deinit();
        self.money_display.deinit();
        self.calories_display.deinit();
        self.stockpile_display.deinit();
    }
};
