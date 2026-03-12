const std = @import("std");

const ha = @import("ha");
const time = ha.time;
const ui = ha.ui;
const sdl = ha.sdl;
const zfont = ha.font;

const Renderer = ha.sdl.render.Renderer;
const screen_width: c_int = 800;
const screen_height: c_int = 600;
const fps = 60;
const font_path = "assets/fonts/Kenney Mini Square.ttf";

// logger
const log_app = sdl.log.Category.application;

// colors
const white = zfont.white;

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

const CounterObj = struct {
    counter: time.Counter,
    text: []const u8,
};

const TimerObj = struct {
    timer: time.Timer,
    text: []const u8,
};

const Objects = struct {
    counter: CounterObj,
    timer: TimerObj,
};

fn reset_click(data: ?*anyopaque, _: ui.features.ClickEvent) void {
    const obj: *Objects = @ptrCast(@alignCast(data.?));
    obj.counter.counter.set(0.0);
    obj.timer.timer.reset();
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
    const counter: CounterObj = .{
        .counter = time.Counter.init(0.0),
        .text = "Counter:",
    };
    const timer: TimerObj = .{
        .timer = time.Timer.init(30.0, null),
        .text = "Timer:",
    };

    var obj: Objects = .{
        .counter = counter,
        .timer = timer,
    };

    // UI
    var ui_ctx = UiCtx{ .font = &res.font, .renderer = &renderer };
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

const UiCtx = struct {
    font: *sdl.ttf.Font,
    renderer: *const Renderer,
};

fn render_counter(node: *ui.Node, ctx: ?*anyopaque) void {
    const ui_ctx: *UiCtx = @ptrCast(@alignCast(ctx orelse return));
    const obj: *Objects = @ptrCast(@alignCast(node.data orelse return));
    const pos = node.position orelse return;
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "{s} {}", .{
        obj.counter.text,
        @trunc(obj.counter.counter.get()),
    }) catch return;
    const surface = ui_ctx.font.renderTextSolid(text, white) catch return;
    defer surface.deinit();
    const texture = ui_ctx.renderer.createTextureFromSurface(surface) catch return;
    defer texture.deinit();
    const dst = sdl.rect.FRect{
        .x = (pos._global_x orelse return) + pos.padding.left,
        .y = (pos._global_y orelse return) + pos.padding.up,
        .w = pos.data_width,
        .h = pos.data_height,
    };
    ui_ctx.renderer.renderTexture(texture, null, dst) catch return;
}

fn calc_counter_pos(node: *ui.Node, ctx: ?*anyopaque) struct { f32, f32 } {
    const ui_ctx: *UiCtx = @ptrCast(@alignCast(ctx orelse return .{ 0, 0 }));
    const obj: *Objects = @ptrCast(@alignCast(node.data orelse return .{ 0, 0 }));
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "{s} {}", .{
        obj.counter.text,
        @trunc(obj.counter.counter.get()),
    }) catch return .{ 0, 0 };
    const surface = ui_ctx.font.renderTextSolid(text, white) catch return .{ 0, 0 };
    defer surface.deinit();
    const width: f32 = @floatFromInt(surface.getWidth());
    const height: f32 = @floatFromInt(surface.getHeight());
    return .{ width, height };
}

fn setup_ui(allocator: std.mem.Allocator, res: *Resources, obj: *Objects) !*ui.Node {
    const widgets = ui.widgets;
    const padding = ui.Padding.initSymmetric(20.0, 10.0);

    const root = try allocator.create(ui.Node);
    root.* = ui.Node.init("root");
    _ = root.with_position(ui.Position.initStatic(.top_left, .centered_wrapped, screen_width, screen_height, null));

    // Counter
    const counter_node = try widgets.button(
        allocator,
        "cntr",
        ui.Position.init(
            &calc_counter_pos,
            .relative,
            null,
            padding,
        ),
        ui.features.OnClick.init(reset_click, @ptrCast(obj)),
    );
    _ = counter_node
        .with_data(@ptrCast(obj))
        .with_render(ui.features.OnRender.init(&render_counter));

    try res.runtime.register(allocator, counter_node);
    try root.add_child(allocator, counter_node);

    return root;
}

fn update(dt: f32, obj: *Objects) !void {
    obj.counter.counter.update(dt);
    obj.timer.timer.update(dt);
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
