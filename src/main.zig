const std = @import("std");
const ha = @import("ha");

const time = ha.time;
const ui = ha.ui;
const res = ha.res;
const widgets = ha.widgets;
const sdl = ha.sdl;

const features = ui.features;
const screen_width: c_int = 800;
const screen_height: c_int = 600;
const fps = 60;
const font_path = "assets/fonts/Kenney Mini Square.ttf";

const Objects = struct {
    counter: time.Counter,
    timer: time.Timer,
    population: time.Accumulator(i32),
    calendar: time.Counter,
    money: time.Accumulator(i32),
    demand: time.Accumulator(i32),
    produce: time.Accumulator(i32),
    calories: time.Accumulator(i32),
    stockpile: time.Accumulator(i32),
    //
    counter_text: ha.font.TextData,
    population_text: ha.font.TextData,
    demand_text: ha.font.TextData,
    produce_text: ha.font.TextData,
    calories_text: ha.font.TextData,
    stockpile_text: ha.font.TextData,
    calendar_text: ha.font.TextData,
    money_text: ha.font.TextData,

    fn deinit(self: *Objects) void {
        self.counter_text.deinit();
        self.population_text.deinit();
        self.demand_text.deinit();
        self.produce_text.deinit();
        self.calories_text.deinit();
        self.stockpile_text.deinit();
        self.calendar_text.deinit();
        self.money_text.deinit();
    }
};

const UIWidgets = struct {
    counter: widgets.Button,
    population: widgets.Button,
    calendar: widgets.Button,
    money: widgets.Button,
    demand: widgets.Button,
    produce: widgets.Button,
    calories: widgets.Button,
    stockpile: widgets.Button,

    fn deinit(_: *UIWidgets) void {}
};

const PendingClick = struct {
    x: f32,
    y: f32,
    button: features.MouseButton,
};

const App = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    frame_capper: sdl.extras.FramerateCapper(f32),
    font: sdl.ttf.Font,
    resources: res.Resources,
    obj: Objects,
    ui_widgets: UIWidgets,
    frame_arena: std.heap.ArenaAllocator,

    fn init() !App {
        const gpa = std.heap.GeneralPurposeAllocator(.{}){};
        try sdl.init(.{ .video = true, .events = true });
        try sdl.ttf.init();
        const window, const renderer = try sdl.render.Renderer.initWithWindow(
            "Human Action",
            screen_width,
            screen_height,
            .{ .resizable = true },
        );
        var frame_capper = sdl.extras.FramerateCapper(f32){ .mode = .{ .unlimited = {} } };
        renderer.setVSync(.{ .on_each_num_refresh = 1 }) catch {
            frame_capper.mode = .{ .limited = fps };
        };
        return .{
            .gpa = gpa,
            .window = window,
            .renderer = renderer,
            .frame_capper = frame_capper,
            .font = undefined,
            .resources = undefined,
            .obj = undefined,
            .ui_widgets = undefined,
            .frame_arena = undefined,
        };
    }

    fn setup(self: *App, allocator: std.mem.Allocator) !void {
        self.font = try sdl.ttf.Font.init(font_path, 24);
        self.resources = .{
            .font = &self.font,
            .renderer = &self.renderer,
            .window = self.window,
        };
        self.obj = .{
            .counter = time.Counter.init(0.0),
            .timer = time.Timer.init(30.0, null),
            .population = time.Accumulator(i32).init(1),
            .calendar = time.Counter.init(0.0),
            .money = time.Accumulator(i32).init(500),
            .demand = time.Accumulator(i32).init(100), // 100Wh
            .produce = time.Accumulator(i32).init(0),
            .calories = time.Accumulator(i32).init(1000), // 1000kcal/day
            .stockpile = time.Accumulator(i32).init(4000), // calories stockpile

            .counter_text = ha.font.TextData.init(),
            .population_text = ha.font.TextData.init(),
            .demand_text = ha.font.TextData.init(),
            .produce_text = ha.font.TextData.init(),
            .calories_text = ha.font.TextData.init(),
            .stockpile_text = ha.font.TextData.init(),
            .calendar_text = ha.font.TextData.init(),
            .money_text = ha.font.TextData.init(),
        };
        self.ui_widgets = .{
            .counter  = widgets.Button.init("counter",    ui.OnClick.typed(time.Counter, &reset_counter, &self.obj.counter), @ptrCast(&self.obj.counter_text),    .text),
            .population = widgets.Button.init("population", null, @ptrCast(&self.obj.population_text), .text),
            .demand     = widgets.Button.init("demand",     null, @ptrCast(&self.obj.demand_text),      .text),
            .produce    = widgets.Button.init("produce",    null, @ptrCast(&self.obj.produce_text),     .text),
            .calories   = widgets.Button.init("calories",  null, @ptrCast(&self.obj.calories_text),    .text),
            .stockpile  = widgets.Button.init("stockpile", null, @ptrCast(&self.obj.stockpile_text),   .text),
            .calendar   = widgets.Button.init("calendar",  null, @ptrCast(&self.obj.calendar_text),    .text),
            .money      = widgets.Button.init("money",     null, @ptrCast(&self.obj.money_text),        .text),
        };
        self.frame_arena = std.heap.ArenaAllocator.init(allocator);
    }

    fn deinit(self: *App) void {
        self.frame_arena.deinit();
        self.obj.deinit();
        self.ui_widgets.deinit();
        self.font.deinit();
        self.renderer.deinit();
        self.window.deinit();
        sdl.ttf.quit();
        sdl.quit(.{ .video = true, .events = true });
        _ = self.gpa.deinit();
    }
};

pub fn main() !void {
    var app = try App.init();
    defer app.deinit();
    try app.setup(app.gpa.allocator());

    const raw_ctx: *anyopaque = @ptrCast(&app.resources);
    var quit = false;
    var pending_click: ?PendingClick = null;

    while (!quit) {
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => quit = true,
                .key_down => |key| if (key.key == .escape) {
                    quit = true;
                },
                .mouse_button_down => |mb| {
                    pending_click = .{
                        .x = mb.x,
                        .y = mb.y,
                        .button = switch (mb.button) {
                            .left => .left,
                            .middle => .middle,
                            .right => .right,
                            else => .other,
                        },
                    };
                },
                else => {},
            }
        }

        const dt = app.frame_capper.delay();
        app.obj.counter.update(dt);
        app.obj.timer.update(dt);
        app.obj.calendar.update(dt);

        // app.obj.money.update(dt);
        // app.obj.demand.update(dt);
        // app.obj.produce.update(dt);
        // app.obj.calories.update(dt);
        // app.obj.stockpile.update(dt);

        app.obj.counter_text.update(
            try std.fmt.bufPrint(&app.obj.counter_text.buf, "Counter: {d:.0}", .{app.obj.counter.get()}),
        );
        app.obj.population_text.update(
            try std.fmt.bufPrint(&app.obj.population_text.buf, "Population: {d:.0}", .{app.obj.population.get()}),
        );
        app.obj.demand_text.update(
            try std.fmt.bufPrint(&app.obj.demand_text.buf, "Demand: {d:.0}", .{app.obj.demand.get()}),
        );
        app.obj.produce_text.update(
            try std.fmt.bufPrint(&app.obj.produce_text.buf, "Produce: {d:.0}", .{app.obj.produce.get()}),
        );
        app.obj.calories_text.update(
            try std.fmt.bufPrint(&app.obj.calories_text.buf, "Calories: {d:.0}", .{app.obj.calories.get()}),
        );
        app.obj.stockpile_text.update(
            try std.fmt.bufPrint(&app.obj.stockpile_text.buf, "Stockpile: {d:.0}", .{app.obj.stockpile.get()}),
        );
        app.obj.calendar_text.update(
            try std.fmt.bufPrint(&app.obj.calendar_text.buf, "Calendar: {d:.0}", .{app.obj.calendar.get()}),
        );
        app.obj.money_text.update(
            try std.fmt.bufPrint(&app.obj.money_text.buf, "Money: {d:.0}", .{app.obj.money.get()}),
        );

        _ = app.frame_arena.reset(.retain_capacity);
        const fa = app.frame_arena.allocator();

        const root = try build_ui(fa, &app.ui_widgets);
        try root.set_global_pos(null, raw_ctx);

        if (pending_click) |click| {
            ui.dispatch_click(root, click.x, click.y, click.button);
            pending_click = null;
        }

        try app.renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
        try app.renderer.clear();
        ui.render(root, raw_ctx);
        try app.renderer.present();
    }
}

fn build_ui(allocator: std.mem.Allocator, w: *UIWidgets) !*ui.Node {
    const root = try ui.Node.create(allocator, "root");
    _ = root.with_size(ui.Size.init(&widgets.screen_size, null));
    _ = root.with_layout(ui.Layout.init(.top_left, .centered_wrapped));

    _ = w.counter.node.with_layout(ui.Layout.init(.relative, null));
    try root.add_child(allocator, &w.counter.node);

    const left_panel = try ui.Node.create(allocator, "left_panel");
    _ = left_panel.with_size(ui.Size.initFixed(300, 600, null));
    _ = left_panel.with_layout(ui.Layout.init(.top_left, .vertical));

    _ = w.population.node.with_layout(ui.Layout.init(.relative, null));
    try left_panel.add_child(allocator, &w.population.node);
    _ = w.demand.node.with_layout(ui.Layout.init(.relative, null));
    try left_panel.add_child(allocator, &w.demand.node);
    _ = w.produce.node.with_layout(ui.Layout.init(.relative, null));
    try left_panel.add_child(allocator, &w.produce.node);
    _ = w.calories.node.with_layout(ui.Layout.init(.relative, null));
    try left_panel.add_child(allocator, &w.calories.node);
    _ = w.stockpile.node.with_layout(ui.Layout.init(.relative, null));
    try left_panel.add_child(allocator, &w.stockpile.node);

    try root.add_child(allocator, left_panel);

    const right_panel = try ui.Node.create(allocator, "right_panel");
    _ = right_panel.with_size(ui.Size.initFixed(300, 600, null));
    _ = right_panel.with_layout(ui.Layout.init(.top_right, .vertical_right));

    _ = w.calendar.node.with_layout(ui.Layout.init(.relative, null));
    try right_panel.add_child(allocator, &w.calendar.node);
    _ = w.money.node.with_layout(ui.Layout.init(.relative, null));
    try right_panel.add_child(allocator, &w.money.node);

    try root.add_child(allocator, right_panel);

    return root;
}

fn reset_counter(counter: *time.Counter, _: features.ClickEvent) void {
    counter.set(0.0);
}
