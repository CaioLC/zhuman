const sdl3 = @import("sdl3");
const Renderer = sdl3.render.Renderer;

const std = @import("std");
const time = @import("./time.zig");

const screen_width: c_int = 800;
const screen_height: c_int = 600;
const fps = 60;
const font_path = "assets/fonts/Kenney Mini Square.ttf";

// logger
const log_app = sdl3.log.Category.application;

// colors
const zfont = @import("./font.zig");
const white = zfont.white;

const Objects = struct {
    counter: time.Counter,
    timer: time.Timer,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

    var font = try sdl3.ttf.Font.init(font_path, 24);
    defer font.deinit();

    var quit_app = false;

    // Objects
    const counter = time.Counter.init(0.0);
    const timer = time.Timer.init(30.0, null);
    var objects: Objects = .{
        .counter = counter,
        .timer = timer,
    };

    while (!quit_app) {
        try events(&quit_app, &objects);
        try update(frame_capper.delay(), &objects);
        try render(renderer, font, objects);
    }
}

fn events(quit_app: *bool, obj: *Objects) !void {
    while (sdl3.events.poll()) |event| {
        switch (event) {
            .quit, .terminating => quit_app.* = true,
            .key_down => |key| {
                if (key.key == .escape) {
                    quit_app.* = true;
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

fn update(dt: f32, obj: *Objects) !void {
    obj.counter.update(dt);
    obj.timer.update(dt);
}

fn render(renderer: Renderer, font: sdl3.ttf.Font, obj: Objects) !void {
    var text_buffer: [256]u8 = undefined;
    var x = try std.fmt.bufPrint(&text_buffer, "Counter: {}", .{obj.counter.get()});
    const counter_texture = try textureFromSurface(renderer, try font.renderTextSolid(x, white));
    defer counter_texture.deinit();

    x = try std.fmt.bufPrint(&text_buffer, "Timer: {}", .{obj.timer.get()});
    const timer_texture = try textureFromSurface(renderer, try font.renderTextSolid(x, white));
    defer timer_texture.deinit();

    // --- Rendering ---
    try renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
    try renderer.clear();

    var y_pos: f32 = 10;
    const textures_to_render = [_]*const sdl3.render.Texture{
        &counter_texture,
        &timer_texture,
        // &blended_texture,
        // &styled_texture,
        // &outlined_texture,
        // &outlined_miter_texture,
        // &props_texture,
        // &truncated_texture,
        // &wrapped_texture,
    };
    for (textures_to_render) |tex_ptr| {
        const tex = tex_ptr.*;
        const width, const height = try tex.getSize();
        const dst = sdl3.rect.FRect{ .x = 10, .y = y_pos, .w = width, .h = height };
        try renderer.renderTexture(tex, null, dst);
        y_pos += height + 5;
    }

    try renderer.present();
}

fn textureFromSurface(renderer: sdl3.render.Renderer, surface: sdl3.surface.Surface) !sdl3.render.Texture {
    defer surface.deinit();
    return try renderer.createTextureFromSurface(surface);
}
