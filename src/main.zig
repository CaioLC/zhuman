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
    ui_root: ?*ui.Node,

    pub fn init() !Resources {
        return .{
            .quit_app = false,
            .font = try sdl.ttf.Font.init(font_path, 24),
            .screen_height = screen_height,
            .screen_width = screen_width,
            .ui_root = null,
        };
    }

    pub fn deinit(self: *Resources, allocator: std.mem.Allocator) void {
        self.font.deinit();
        if (self.ui_root) |node| {
            node.deinit(allocator);
            allocator.destroy(node);
        }
    }
};

const Objects = struct {
    counter: time.Counter,
    timer: time.Timer,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit(.{ .video = true, .events = true });
    try sdl.ttf.init();
    defer sdl.ttf.quit();

    const window, const renderer = try sdl.render.Renderer.initWithWindow("Human Action", screen_width, screen_height, .{ .resizable = true });
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
    const counter = time.Counter.init(0.0);
    const timer = time.Timer.init(30.0, null);
    var obj: Objects = .{
        .counter = counter,
        .timer = timer,
    };

    // UI
    const ui_root = try setup_ui(allocator, res, obj);
    res.ui_root = ui_root;

    while (!res.quit_app) {
        try events(&res, &obj);
        try update(frame_capper.delay(), &obj);
        try update_ui(allocator, &res, obj);
        try render(renderer, res, obj);
    }
}

fn events(res: *Resources, obj: *Objects) !void {
    while (sdl.events.poll()) |event| {
        switch (event) {
            .quit, .terminating => res.quit_app = true,
            .window_resized => |e| {
                res.screen_height = e.height;
                res.screen_width = e.width;
                res.ui_root.?.height = @floatFromInt(e.height);
                res.ui_root.?.width = @floatFromInt(e.width);
            },
            .key_down => |key| {
                if (key.key == .escape) {
                    res.quit_app = true;
                }
            },
            .mouse_button_down => |mbutton| {
                if (mbutton.button == .left) {
                    try log_app.logInfo("Mouse clicked!", .{});
                    obj.counter.set(0.0);
                    obj.timer.reset();
                }
            },
            else => {},
        }
    }
}

fn setup_ui(allocator: std.mem.Allocator, res: Resources, obj: Objects) !*ui.Node {
    const root = try allocator.create(ui.Node);
    root.* = try ui.Node.init(allocator, "root", screen_width, screen_height, .top_left);

    // Counter
    var text_buffer: [256]u8 = undefined;
    var x = try std.fmt.bufPrint(&text_buffer, "Counter: {}", .{@trunc(obj.counter.get())});
    const counter_surface = try res.font.renderTextSolid(x, white);
    const surf_node = try allocator.create(ui.Node);
    surf_node.* = try ui.Node.init(
        allocator,
        "cntr",
        @floatFromInt(counter_surface.getWidth()),
        @floatFromInt(counter_surface.getHeight()),
        .center,
    );
    surf_node.surface = counter_surface;
    try root.add_child(allocator, surf_node);

    // Timer
    x = try std.fmt.bufPrint(&text_buffer, "Timer: {}", .{obj.timer.get()});
    const timer_surface = try res.font.renderTextSolid(x, white);
    const timer_node = try allocator.create(ui.Node);
    timer_node.* = try ui.Node.init(
        allocator,
        "timr",
        @floatFromInt(timer_surface.getWidth()),
        @floatFromInt(timer_surface.getHeight()),
        .center,
    );
    timer_node.surface = timer_surface;
    try root.add_child(allocator, timer_node);

    for (root.children.items, 0..) |child, i| {
        std.log.debug("{}: {s}", .{i, child.id});
    }

    return root;
}

fn update(dt: f32, obj: *Objects) !void {
    obj.counter.update(dt);
    obj.timer.update(dt);
}

// build UI elements
fn update_ui(_: std.mem.Allocator, res: *Resources, obj: Objects) !void {
    if (res.ui_root) |root| {
        root.set_global_pos();

        // update surface text
        if (root.get_id("cntr")) |counter| {
            counter.surface.?.deinit();
            var text_buffer: [256]u8 = undefined;
            const x = try std.fmt.bufPrint(&text_buffer, "Counter: {}", .{@trunc(obj.counter.get())});
            const surface = try res.font.renderTextSolid(x, white);
            counter.surface = surface;
            counter.width = @floatFromInt(surface.getWidth());
            counter.height = @floatFromInt(surface.getHeight());
        }
    }
}

fn render(renderer: Renderer, res: Resources, _: Objects) !void {
    // --- Rendering ---
    try renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
    try renderer.clear();

    // You are in the dark
    const energy_texture = try renderer.createTextureFromSurface(try res.font.renderTextSolid("You are in the dark", white));
    defer energy_texture.deinit();
    // You are hungry
    const food_texture = try renderer.createTextureFromSurface(try res.font.renderTextSolid("You are hungry", white));
    defer food_texture.deinit();
    // You are alone
    const humans_texture = try renderer.createTextureFromSurface(try res.font.renderTextSolid("You are alone", white));
    defer humans_texture.deinit();

    if (res.ui_root) |root| {
        var buf: [@sizeOf(*ui.Node) * 256]u8 = undefined;
        var bfa = std.heap.FixedBufferAllocator.init(&buf);
        const allocator = bfa.allocator();
        var node_stack: std.ArrayList(*ui.Node) = .empty;
        defer node_stack.clearRetainingCapacity();
        try root.collect(allocator, &node_stack);

        for (node_stack.items) |node| {
            const dst = sdl.rect.FRect{
                .x = node.global_x.?,
                .y = node.global_y.?,
                .h = node.height,
                .w = node.width,
            };
            if (node.surface) |surface| {
                // TODO: surfaces must be deinit
                const texture = try renderer.createTextureFromSurface(surface);
                try renderer.renderTexture(texture, null, dst);
            }
        }
    }

    try renderer.present();
}
