const std = @import("std");
const ha = @import("ha");
const time = ha.time;
const ui = ha.ui;
const widgets = ha.widgets;
const sdl = ha.sdl;

const features = ui.features;
const screen_width: c_int = 800;
const screen_height: c_int = 600;
const fps = 60;
const font_path = "assets/fonts/Kenney Mini Square.ttf";

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

const Objects = struct {
    counter: time.Counter,
    timer: time.Timer,
    counter_text: widgets.TextData,

    fn deinit(self: *Objects) void {
        self.counter_text.deinit();
    }
};

const PendingClick = struct {
    x: f32,
    y: f32,
    button: features.MouseButton,
};

pub fn main() !void {
    var app = try App.init();
    defer app.deinit();
    const allocator = app.gpa.allocator();

    var font = try sdl.ttf.Font.init(font_path, 24);
    defer font.deinit();

    var ui_ctx = widgets.UiCtx{
        .font = &font,
        .renderer = &app.renderer,
        .window = app.window,
    };
    const raw_ctx: *anyopaque = @ptrCast(&ui_ctx);

    var obj = Objects{
        .counter = time.Counter.init(0.0),
        .timer = time.Timer.init(30.0, null),
        .counter_text = widgets.TextData.init(),
    };
    defer obj.deinit();

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

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
        obj.counter.update(dt);
        obj.timer.update(dt);

        _ = frame_arena.reset(.retain_capacity);
        const fa = frame_arena.allocator();

        const root = try build_ui(fa, &obj);
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

fn build_ui(allocator: std.mem.Allocator, obj: *Objects) !*ui.Node {
    const root = try ui.Node.create(allocator, "root");
    _ = root.with_position(ui.Position.init(.top_left, .centered_wrapped, null, &widgets.screen_size));

    obj.counter_text.update(try std.fmt.bufPrint(&obj.counter_text.buf, "Counter: {d:.0}", .{obj.counter.get()}));
    const counter = try ui.Node.create(allocator, "cntr");
    _ = counter
        .with_position(ui.Position.init(.relative, null, null, &widgets.calc_size_text))
        .with_onclick(ui.OnClick.typed(time.Counter, &reset_counter, &obj.counter))
        .with_data(@ptrCast(&obj.counter_text))
        .with_render(ui.OnRender.init(&widgets.sdl_render_text));
    try root.add_child(allocator, counter);

    return root;
}

fn reset_counter(counter: *time.Counter, _: features.ClickEvent) void {
    counter.set(0.0);
}
