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
    runtime: ui.runtime.Runtime,

    pub fn init() !Resources {
        return .{
            .quit_app = false,
            .font = try sdl.ttf.Font.init(font_path, 24),
            .screen_height = screen_height,
            .screen_width = screen_width,
            .ui_root = null,
            .runtime = ui.runtime.Runtime.init(),
        };
    }

    pub fn deinit(self: *Resources, allocator: std.mem.Allocator) void {
        self.runtime.deinit(allocator);
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

fn reset_click(data: ?*anyopaque, _: ui.features.ClickEvent) void {
    const obj: *Objects = @ptrCast(@alignCast(data.?));
    obj.counter.set(0.0);
    obj.timer.reset();
}

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
                if (res.ui_root) |root| {
                    root.position.?.inner_height = @floatFromInt(e.height);
                    root.position.?.inner_width = @floatFromInt(e.width);
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

fn text_node(
    allocator: std.mem.Allocator,
    res: Resources,
    id: []const u8,
    text: []const u8,
    anchor: ui.Anchor,
) !*ui.Node {
    const surface = try res.font.renderTextSolid(text, white);
    const w: f32 = @floatFromInt(surface.getWidth());
    const h: f32 = @floatFromInt(surface.getHeight());

    const node = try allocator.create(ui.Node);
    node.* = ui.Node.init(id);
    _ = node.with_position(ui.Position.init(anchor, null, w, h, ui.Padding.initSymmetric(20.0, 10.0)));

    // Store surface as opaque data
    const surf = try allocator.create(@TypeOf(surface));
    surf.* = surface;
    node.data = @ptrCast(surf);

    return node;
}

fn setup_ui(allocator: std.mem.Allocator, res: *Resources, obj: *Objects) !*ui.Node {
    const root = try allocator.create(ui.Node);
    root.* = ui.Node.init("root");
    _ = root.with_position(ui.Position.init(.top_left, .centered_wrapped, screen_width, screen_height, null));

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
    surf_node.on_click = ui.features.OnClick.init(reset_click, @ptrCast(obj));
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

    for (root.children.items, 0..) |child, i| {
        std.log.debug("Child {}: {s}", .{ i, child.id });
    }

    return root;
}

fn update(dt: f32, obj: *Objects) !void {
    obj.counter.update(dt);
    obj.timer.update(dt);
}

fn update_ui(_: std.mem.Allocator, res: *Resources, obj: Objects) !void {
    if (res.ui_root) |root| {
        try root.set_global_pos(null);

        if (root.get_by_id("cntr")) |counter| {
            // Update surface text
            const surf: *sdl.surface.Surface = @ptrCast(@alignCast(counter.data.?));
            surf.deinit();
            var text_buffer: [256]u8 = undefined;
            const x = try std.fmt.bufPrint(&text_buffer, "Counter: {}", .{@trunc(obj.counter.get())});
            const new_surface = try res.font.renderTextSolid(x, white);
            surf.* = new_surface;
            counter.position.?.inner_width = @floatFromInt(new_surface.getWidth());
            counter.position.?.inner_height = @floatFromInt(new_surface.getHeight());
        }
    }
}

fn render(renderer: Renderer, res: Resources, _: Objects) !void {
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
            const pos = node.position orelse continue;
            if (node.data) |d| {
                const surf: *sdl.surface.Surface = @ptrCast(@alignCast(d));
                const dst = sdl.rect.FRect{
                    .x = pos._global_x.? + pos.padding.left,
                    .y = pos._global_y.? + pos.padding.up,
                    .h = pos.inner_height,
                    .w = pos.inner_width,
                };
                const texture = try renderer.createTextureFromSurface(surf.*);
                defer texture.deinit();
                try renderer.renderTexture(texture, null, dst);
            }
        }
    }

    try renderer.present();
}
