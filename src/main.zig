const std = @import("std");

const ha = @import("ha");
const time = ha.time;
const ui = ha.ui;
const widgets = ha.widgets;
const sdl = ha.sdl;

const Renderer = ha.sdl.render.Renderer;
const screen_width: c_int = 800;
const screen_height: c_int = 600;
const fps = 60;
const font_path = "assets/fonts/Kenney Mini Square.ttf";

const UiRuntime = ui.runtime.Runtime(widgets.UiCtx);

const App = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    frame_capper: sdl.extras.FramerateCapper(f32),

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
        };
    }

    fn deinit(self: *App) void {
        self.renderer.deinit();
        self.window.deinit();
        sdl.ttf.quit();
        sdl.quit(.{ .video = true, .events = true });
        _ = self.gpa.deinit();
    }
};

const Resources = struct {
    quit_app: bool,
    font: sdl.ttf.Font,
    screen_height: c_int,
    screen_width: c_int,

    pub fn init() !Resources {
        return .{
            .quit_app = false,
            .font = try sdl.ttf.Font.init(font_path, 24),
            .screen_height = screen_height,
            .screen_width = screen_width,
        };
    }

    pub fn deinit(self: *Resources) void {
        self.font.deinit();
    }
};

const Objects = struct {
    counter: time.Counter,
    timer: time.Timer,
};

pub fn main() !void {
    // App Setup
    var app = try App.init();
    defer app.deinit();
    const allocator = app.gpa.allocator();

    // Resources
    var res = try Resources.init();
    defer res.deinit();

    // Objects
    var obj: Objects = .{
        .counter = time.Counter.init(0.0),
        .timer = time.Timer.init(30.0, null),
    };

    // UI
    var ui_ctx = widgets.UiCtx{
        .font = &res.font,
        .renderer = &app.renderer,
        .window = app.window,
    };
    var ui_runtime = try UiRuntime.init(
        allocator,
        &ui_ctx,
        ui.Position.init(.top_left, .centered_wrapped, null, &widgets.screen_size),
    );
    ui_runtime.setEventListener();
    defer ui_runtime.deinit(allocator);
    try setup_ui(allocator, &ui_runtime, &obj);

    while (!res.quit_app) {
        try events(&res, &ui_runtime);
        try update(app.frame_capper.delay(), &obj);
        try update_ui(&ui_runtime);
        try render(app.renderer, &ui_runtime);
    }
}

fn events(res: *Resources, ui_runtime: *UiRuntime) !void {
    while (sdl.events.poll()) |event| {
        switch (event) {
            .quit, .terminating => res.quit_app = true,
            .window_resized => |e| {
                res.screen_height = e.height;
                res.screen_width = e.width;
                const root = ui_runtime.root;
                root.position.?.data_height = @floatFromInt(e.height);
                root.position.?.data_width = @floatFromInt(e.width);
                root.position.?.height = @floatFromInt(e.height);
                root.position.?.width = @floatFromInt(e.width);
            },
            .key_down => |key| {
                if (key.key == .escape) {
                    res.quit_app = true;
                }
            },
            .mouse_button_down => |mbutton| {
                const button: ui.features.MouseButton = switch (mbutton.button) {
                    .left => .left,
                    .middle => .middle,
                    .right => .right,
                    else => .other,
                };
                ui_runtime.dispatch_click(mbutton.x, mbutton.y, button);
            },
            else => {},
        }
    }
}

fn setup_ui(allocator: std.mem.Allocator, ui_runtime: *UiRuntime, obj: *Objects) !void {

    // Counter
    const counter_data = try widgets.TextData.create(allocator);
    counter_data.fmt_text = try std.fmt.bufPrint(&counter_data.buf, "Counter: {}", .{obj.counter.get()});

    const counter_node = try ui.Node.create(allocator, "cntr");
    _ = counter_node
        .with_position(ui.Position.init(
            .relative,
            null,
            null,
            &widgets.calc_size_text,
        ))
        .with_onclick(ui.OnClick.typed(time.Counter, &reset_counter, &obj.counter))
        .with_data(@ptrCast(counter_data), &widgets.TextData.deinit)
        .with_render(ui.OnRender.init(&widgets.sdl_render_text));

    try ui_runtime.root.add_child(allocator, counter_node);
}

fn update(dt: f32, obj: *Objects) !void {
    obj.counter.update(dt);
    obj.timer.update(dt);
}

fn update_ui(ui_runtime: *UiRuntime) !void {
    try ui_runtime.update();
}

fn render(renderer: Renderer, ui_runtime: *UiRuntime) !void {
    try renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
    try renderer.clear();

    ui_runtime.render();

    try renderer.present();
}

fn format_counter(counter: *time.Counter, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "Counter: {}", .{@trunc(counter.get())}) catch null;
}

fn reset_counter(counter: *time.Counter, _: ui.features.ClickEvent) void {
    counter.set(0.0);
}
