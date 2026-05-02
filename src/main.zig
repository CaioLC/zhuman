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
    counter_text: ha.font.TextData,
    timer: time.Timer,

    fn deinit(self: *Objects) void {
        self.counter_text.deinit();
    }
};

const UIWidgets = struct {
    counter: ui.Node,

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
            .counter_text = ha.font.TextData.init(),
            .timer = time.Timer.init(30.0, null),
        };
        self.ui_widgets = .{
            .counter = ui.Node.init("counter"),
        };
        _ = self.ui_widgets.counter
            .with_position(ui.Position.init(.relative, null, null, &widgets.calc_size_text))
            .with_onclick(ui.OnClick.typed(time.Counter, &reset_counter, &self.obj.counter))
            .with_data(@ptrCast(&self.obj.counter_text))
            .with_render(ui.OnRender.init(&widgets.sdl_render_text));
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
                .key_down => |key| if (key.key == .escape) { quit = true; },
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
        app.obj.counter_text.update(
            try std.fmt.bufPrint(
                &app.obj.counter_text.buf,
                "Counter: {d:.0}",
                .{app.obj.counter.get()},
            ),
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
    _ = root.with_position(ui.Position.init(.top_left, .centered_wrapped, null, &widgets.screen_size));

    try root.add_child(allocator, &w.counter);

    return root;
}

fn reset_counter(counter: *time.Counter, _: features.ClickEvent) void {
    counter.set(0.0);
}
