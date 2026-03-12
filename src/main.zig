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

const Resources = struct {
    quit_app: bool,
    font: sdl.ttf.Font,
    screen_height: c_int,
    screen_width: c_int,
    runtime: ui.runtime.Runtime,

    pub fn init() !Resources {
        return .{
            .quit_app = false,
            .font = try sdl.ttf.Font.init(font_path, 24),
            .screen_height = screen_height,
            .screen_width = screen_width,
            .runtime = ui.runtime.Runtime.init(),
        };
    }

    pub fn deinit(self: *Resources, allocator: std.mem.Allocator) void {
        self.runtime.deinit(allocator);
        self.font.deinit();
    }
};

fn get_counter(ptr: *anyopaque) f32 {
    const counter: *time.Counter = @ptrCast(@alignCast(ptr));
    return counter.get();
}

const Objects = struct {
    counter: time.Counter,
    timer: time.Timer,
};

fn reset_counter(data: ?*anyopaque, _: ui.features.ClickEvent) void {
    const counter: *time.Counter = @ptrCast(@alignCast(data orelse return));
    counter.set(0.0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit(.{ .video = true, .events = true });
    try sdl.ttf.init();
    defer sdl.ttf.quit();

    const window, const renderer = try sdl.render.Renderer.initWithWindow(
        "Human Action",
        screen_width,
        screen_height,
        .{ .resizable = true },
    );
    defer renderer.deinit();
    defer window.deinit();

    var frame_capper = sdl.extras.FramerateCapper(f32){ .mode = .{ .unlimited = {} } };
    renderer.setVSync(.{ .on_each_num_refresh = 1 }) catch {
        frame_capper.mode = .{ .limited = fps };
    };

    // Resources
    var res = try Resources.init();
    defer res.deinit(allocator);

    // Objects
    var obj: Objects = .{
        .counter = time.Counter.init(0.0),
        .timer = time.Timer.init(30.0, null),
    };

    // UI
    var ui_ctx = widgets.UiCtx{ .font = &res.font, .renderer = &renderer };
    res.runtime.bind(@ptrCast(&ui_ctx));
    res.runtime.root = try setup_ui(allocator, &res, &obj);

    while (!res.quit_app) {
        try events(&res, &obj);
        try update(frame_capper.delay(), &obj);
        try update_ui(&res);
        try render(renderer, &res);
    }
}

fn events(res: *Resources, _: *Objects) !void {
    while (sdl.events.poll()) |event| {
        switch (event) {
            .quit, .terminating => res.quit_app = true,
            .window_resized => |e| {
                res.screen_height = e.height;
                res.screen_width = e.width;
                if (res.runtime.root) |root| {
                    root.position.?.data_height = @floatFromInt(e.height);
                    root.position.?.data_width = @floatFromInt(e.width);
                    root.position.?.height = @floatFromInt(e.height);
                    root.position.?.width = @floatFromInt(e.width);
                }
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
                res.runtime.dispatch_click(mbutton.x, mbutton.y, button);
            },
            else => {},
        }
    }
}

fn setup_ui(allocator: std.mem.Allocator, res: *Resources, obj: *Objects) !*ui.Node {
    const padding = ui.Padding.initSymmetric(20.0, 10.0);

    const root = try allocator.create(ui.Node);
    root.* = ui.Node.init("root");
    _ = root.with_position(ui.Position.initStatic(.top_left, .centered_wrapped, screen_width, screen_height, null));

    // Counter
    const counter_tn = try allocator.create(widgets.TextNode);
    counter_tn.* = .{
        .value = &get_counter,
        .source = @ptrCast(&obj.counter),
        .label = "Counter:",
        .cached_surface = null,
        .last_value = -1.0,
    };

    const counter_node = try widgets.button(
        allocator,
        "cntr",
        ui.Position.init(
            &widgets.calc_text_node_pos,
            .relative,
            null,
            padding,
        ),
        ui.features.OnClick.init(reset_counter, @ptrCast(&obj.counter)),
    );
    _ = counter_node
        .with_data(@ptrCast(counter_tn))
        .with_render(ui.features.OnRender.init(&widgets.render_text_node));

    try res.runtime.register(allocator, counter_node);
    try root.add_child(allocator, counter_node);

    return root;
}

fn update(dt: f32, obj: *Objects) !void {
    obj.counter.update(dt);
    obj.timer.update(dt);
}

fn update_ui(res: *Resources) !void {
    try res.runtime.update();
}

fn render(renderer: Renderer, res: *Resources) !void {
    try renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
    try renderer.clear();

    res.runtime.render();

    try renderer.present();
}
