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

const ResetHandler = struct {
    obj: *Objects,

    pub fn on_click(self: *ResetHandler, _: ui.clickable.ClickEvent) void {
        self.obj.counter.set(0.0);
        self.obj.timer.reset();
    }
};

const Resources = struct {
    quit_app: bool,
    font: sdl.ttf.Font,
    screen_height: c_int,
    screen_width: c_int,
    ui_root: ?*ui.Node,
    runtime: ui.runtime.Runtime,
    reset_handler: ?*ResetHandler,

    pub fn init() !Resources {
        return .{
            .quit_app = false,
            .font = try sdl.ttf.Font.init(font_path, 24),
            .screen_height = screen_height,
            .screen_width = screen_width,
            .ui_root = null,
            .runtime = ui.runtime.Runtime.init(),
            .reset_handler = null,
        };
    }

    pub fn deinit(self: *Resources, allocator: std.mem.Allocator) void {
        self.runtime.deinit(allocator);
        if (self.reset_handler) |h| allocator.destroy(h);
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
    const ui_root = try setup_ui(allocator, &res, &obj);
    res.ui_root = ui_root;

    while (!res.quit_app) {
        try events(&res, &obj);
        try update(frame_capper.delay(), &obj);
        try update_ui(allocator, &res, obj);
        try render(renderer, res, obj);
    }
}

fn events(res: *Resources, _: *Objects) !void {
    while (sdl.events.poll()) |event| {
        switch (event) {
            .quit, .terminating => res.quit_app = true,
            .window_resized => |e| {
                res.screen_height = e.height;
                res.screen_width = e.width;
                res.ui_root.?.inner_height = @floatFromInt(e.height);
                res.ui_root.?.inner_width = @floatFromInt(e.width);
            },
            .key_down => |key| {
                if (key.key == .escape) {
                    res.quit_app = true;
                }
            },
            .mouse_button_down => |mbutton| {
                const button: ui.clickable.MouseButton = switch (mbutton.button) {
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

fn text_node(
    allocator: std.mem.Allocator,
    res: Resources,
    id: []const u8,
    text: []const u8,
    anchor: ui.Anchor,
) !*ui.Node {
    const surface = try res.font.renderTextSolid(text, white);
    const node = try allocator.create(ui.Node);
    node.* = try ui.Node.init(
        allocator,
        id,
        anchor,
        null,
        @floatFromInt(surface.getWidth()),
        @floatFromInt(surface.getHeight()),
        surface,
        .initSymmetric(20.0, 10.0),
    );
    return node;
}

fn setup_ui(allocator: std.mem.Allocator, res: *Resources, obj: *Objects) !*ui.Node {
    const root = try allocator.create(ui.Node);
    root.* = try ui.Node.init(
        allocator,
        "root",
        .top_left,
        .centered_wrapped,
        screen_width,
        screen_height,
        null,
        null,
    );

    // Counter
    var text_buffer: [256]u8 = undefined;
    var x = try std.fmt.bufPrint(&text_buffer, "Counter: {}", .{@trunc(obj.counter.get())});
    const surf_node = try text_node(
        allocator,
        res.*,
        "cntr",
        x,
        .relative,
    );

    // Attach clickable feature to counter node
    const reset_handler = try allocator.create(ResetHandler);
    reset_handler.* = .{ .obj = obj };
    surf_node.clickable = ui.clickable.Clickable.init(reset_handler);
    res.reset_handler = reset_handler;
    try res.runtime.register(allocator, surf_node);

    try root.add_child(allocator, surf_node);

    // Timer
    x = try std.fmt.bufPrint(&text_buffer, "Timer: {}", .{obj.timer.get()});
    const timer_node = try text_node(
        allocator,
        res.*,
        "timr",
        "Timer template",
        .relative,
    );
    try root.add_child(allocator, timer_node);

    // another text element
    x = try std.fmt.bufPrint(&text_buffer, "Timer: {}", .{obj.timer.get()});
    const other_node = try text_node(
        allocator,
        res.*,
        "othr",
        "Yet another node",
        .relative,
    );
    try root.add_child(allocator, other_node);

    // another text element
    x = try std.fmt.bufPrint(&text_buffer, "Timer: {}", .{obj.timer.get()});
    const another_node = try text_node(
        allocator,
        res.*,
        "othr",
        "And another one",
        .relative,
    );
    try root.add_child(allocator, another_node);

    for (root._children_indep.items, 0..) |child, i| {
        std.log.debug("Indep Node {}: {s}", .{ i, child.id });
    }
    for (root._children_dep.items, 0..) |child, i| {
        std.log.debug("Dep {}: {s}", .{ i, child.id });
    }

    return root;
}

fn update(dt: f32, obj: *Objects) !void {
    obj.counter.update(dt);
    obj.timer.update(dt);
}

fn update_ui(_: std.mem.Allocator, res: *Resources, obj: Objects) !void {
    // build UI elements
    if (res.ui_root) |root| {
        try root.set_global_pos(null);
        // std.log.debug("root X: {}, root Y: {}", .{ root._global_x.?, root._global_y.? });

        // update surface text
        if (root.get_id("cntr")) |counter| {
            counter.surface.?.deinit();
            var text_buffer: [256]u8 = undefined;
            const x = try std.fmt.bufPrint(&text_buffer, "Counter: {}", .{@trunc(obj.counter.get())});
            const surface = try res.font.renderTextSolid(x, white);
            counter.surface = surface;
            counter.inner_width = @floatFromInt(surface.getWidth());
            counter.inner_height = @floatFromInt(surface.getHeight());
            // std.log.debug("counter X: {}, counter Y: {}", .{ counter._global_x.?, counter._global_y.? });
        }
        // if (root.get_id("timr")) |timer| {
        //     std.log.debug("timer X: {}, timer Y: {}", .{ timer._global_x.?, timer._global_y.? });
        // }
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
                .x = node._global_x.? + node.padding.left,
                .y = node._global_y.? + node.padding.up,
                .h = node.inner_height,
                .w = node.inner_width,
            };
            if (node.surface) |surface| {
                const texture = try renderer.createTextureFromSurface(surface);
                defer texture.deinit();
                try renderer.renderTexture(texture, null, dst);
            }
        }
    }

    try renderer.present();
}
