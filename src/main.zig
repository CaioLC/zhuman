const std = @import("std");

const sdl3 = @import("sdl3");
const Renderer = sdl3.render.Renderer;

const time = @import("./time.zig");
const ui = @import("./ui.zig");

const screen_width: c_int = 800;
const screen_height: c_int = 600;
const fps = 60;
const font_path = "assets/fonts/Kenney Mini Square.ttf";

// logger
const log_app = sdl3.log.Category.application;

// colors
const zfont = @import("./font.zig");
const white = zfont.white;

const Resources = struct {
    quit_app: bool,
    font: sdl3.ttf.Font,
    screen_height: c_int,
    screen_width: c_int,
    ui_root: ?*ui.Node,

    pub fn init() !Resources {
        return .{
            .quit_app = false,
            .font = try sdl3.ttf.Font.init(font_path, 24),
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

    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });
    try sdl3.ttf.init();
    defer sdl3.ttf.quit();

    const window, const renderer = try sdl3.render.Renderer.initWithWindow("Human Action", screen_width, screen_height, .{ .resizable = true });
    defer renderer.deinit();
    defer window.deinit();

    var frame_capper = sdl3.extras.FramerateCapper(f32){ .mode = .{ .unlimited = {} } };
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
    while (sdl3.events.poll()) |event| {
        switch (event) {
            .quit, .terminating => res.quit_app = true,
            .window_resized => |e| {
                res.screen_height = e.height;
                res.screen_width = e.width;
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
    root.* = try ui.Node.init(allocator, screen_width, screen_height, .top_left);

    // Counter
    var text_buffer: [256]u8 = undefined;
    const x = try std.fmt.bufPrint(&text_buffer, "Counter: {}", .{obj.counter.get()});
    const surface = try res.font.renderTextSolid(x, white);
    const surf_node = try allocator.create(ui.Node);
    surf_node.* = try ui.Node.init(
        allocator,
        @floatFromInt(surface.getWidth()),
        @floatFromInt(surface.getHeight()),
        .bottom_right,
    );
    surf_node.surface = surface;
    try root.add_child(allocator, surf_node);
    for (root.children.items, 0..) |_, i| {
        std.log.debug("children {}", .{i});
    }

    return root;
}

fn update(dt: f32, obj: *Objects) !void {
    obj.counter.update(dt);
    obj.timer.update(dt);
}

// build UI elements
fn update_ui(_: std.mem.Allocator, res: *Resources, _: Objects) !void {
    if (res.ui_root) |root| {
        root.set_global_pos();
    }
}

fn render(renderer: Renderer, res: Resources, obj: Objects) !void {
    var text_buffer: [256]u8 = undefined;
    var x = try std.fmt.bufPrint(&text_buffer, "Counter: {}", .{obj.counter.get()});
    const counter_texture = try renderer.createTextureFromSurface(try res.font.renderTextSolid(x, white));
    defer counter_texture.deinit();

    x = try std.fmt.bufPrint(&text_buffer, "Timer: {}", .{obj.timer.get()});
    const timer_texture = try renderer.createTextureFromSurface(try res.font.renderTextSolid(x, white));
    defer timer_texture.deinit();

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

    var y_pos: f32 = 10;
    const textures_to_render = [_]*const sdl3.render.Texture{
        &counter_texture,
        &timer_texture,
        // &energy_texture,
        // &food_texture,
        // &humans_texture,
    };
    for (textures_to_render) |tex_ptr| {
        const tex = tex_ptr.*;
        const width, const height = try tex.getSize();
        const center: f32 = @as(f32, screen_width) * 0.5 - width * 0.5;
        const dst = sdl3.rect.FRect{ .x = center, .y = y_pos, .w = width, .h = height };
        try renderer.renderTexture(tex, null, dst);
        y_pos += height + 5;
    }

    if (res.ui_root) |root| {
        var buf: [@sizeOf(*ui.Node) * 256]u8 = undefined;
        var bfa = std.heap.FixedBufferAllocator.init(&buf);
        const allocator = bfa.allocator();
        var node_stack: std.ArrayList(*ui.Node) = .empty;
        defer node_stack.clearRetainingCapacity();
        try root.collect(allocator, &node_stack);

        for (node_stack.items) |node| {
            const dst = sdl3.rect.FRect{
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
