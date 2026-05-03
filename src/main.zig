const std = @import("std");
const ha = @import("ha");

const time = ha.time;
const ui = ha.ui;
const res = ha.res;
const widgets = ha.widgets;
const sdl = ha.sdl;
const sys = ha.systems;

const features = ui.features;
const screen_width: c_int = 800;
const screen_height: c_int = 600;
const fps = 60;
const font_path = "assets/fonts/Kenney Mini Square.ttf";

const UIWidgets = struct {
    counter:    widgets.Button,
    population: widgets.El,
    calendar:   widgets.El,
    money:      widgets.El,
    demand:     widgets.El,
    produce:    widgets.El,
    calories:   widgets.El,
    stockpile:  widgets.El,

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
    singletons: ha.singletons.Singletons,
    world: ha.world.World,
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
            .singletons = undefined,
            .world = undefined,
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
        self.singletons = ha.singletons.Singletons.init();
        self.world = ha.world.World.init();
        self.ui_widgets = .{
            .counter    = widgets.Button.init("counter", ui.OnClick.typed(time.Counter, &reset_counter, &self.singletons.counter), @ptrCast(&self.singletons.counter_display), .text),
            .population = widgets.El.init("population", @ptrCast(&self.singletons.population_display), .text),
            .calendar   = widgets.El.init("calendar",   @ptrCast(&self.singletons.calendar_display),   .text),
            .money      = widgets.El.init("money",      @ptrCast(&self.singletons.money_display),      .text),
            .demand     = widgets.El.init("demand",     @ptrCast(&self.world.demand_display),          .text),
            .produce    = widgets.El.init("produce",    @ptrCast(&self.world.produce_display),         .text),
            .calories   = widgets.El.init("calories",   @ptrCast(&self.singletons.calories_display),   .text),
            .stockpile  = widgets.El.init("stockpile",  @ptrCast(&self.singletons.stockpile_display),  .text),
        };
        self.frame_arena = std.heap.ArenaAllocator.init(allocator);
    }

    fn deinit(self: *App) void {
        self.frame_arena.deinit();
        self.singletons.deinit();
        self.world.deinit();
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
        sys.tick_singletons(&app.singletons, dt);
        sys.aggregate_produce(app.world.producers.constSlice(), &app.world.produce_display);
        sys.aggregate_demand(app.world.consumers.constSlice(), &app.world.demand_display);
        sys.format_singletons(&app.singletons);

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
