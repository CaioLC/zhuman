const sdl3 = @import("sdl3");
const std = @import("std");

const screen_width: c_int = 800;
const screen_height: c_int = 600;

const fps = 60;

const GameState = struct { text_textures: [60]*const sdl3.render.Texture };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var text_buffer: [32]u8 = undefined;
    const time: u32 = 35;
    const x = try std.fmt.bufPrint(&text_buffer, "Counter: {}", .{time});

    const log_app = sdl3.log.Category.application;
    try log_app.logInfo("{s}", .{x});

    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    try sdl3.ttf.init();
    defer sdl3.ttf.quit();

    const window, const renderer = try sdl3.render.Renderer.initWithWindow(
        "Human Action",
        screen_width,
        screen_height,
        .{ .resizable = true },
    );
    defer renderer.deinit();
    defer window.deinit();

    var frame_capper = sdl3.extras.FramerateCapper(f32){ .mode = .{ .unlimited = {} } };
    renderer.setVSync(.{ .on_each_num_refresh = 1 }) catch {
        frame_capper.mode = .{ .limited = fps };
    };

    const font_path = "assets/fonts/Kenney Mini Square.ttf";
    var font = try sdl3.ttf.Font.init(font_path, 24);
    defer font.deinit();

    try log_app.logInfo("Font properties: {}\n", .{try font.getProperties()});

    const white: sdl3.ttf.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    // const yellow: sdl3.ttf.Color = .{ .r = 255, .g = 255, .b = 0, .a = 255 };
    // const cyan: sdl3.ttf.Color = .{ .r = 0, .g = 255, .b = 255, .a = 255 };
    // const magenta: sdl3.ttf.Color = .{ .r = 255, .g = 0, .b = 255, .a = 255 };

    const solid_texture = try textureFromSurface(renderer, try font.renderTextSolid(x, white));
    defer solid_texture.deinit();

    var quit_app = false;
    while (!quit_app) {
        const dt = frame_capper.delay();
        _ = dt;

        while (sdl3.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => quit_app = true,
                .key_down => |key| {
                    if (key.key == .escape) {
                        quit_app = true;
                    }
                },
                .mouse_button_down => |mbutton| {
                    if (mbutton.button == .left) {
                        try log_app.logInfo("Mouse clicked!", .{});
                    }
                },
                else => {},
            }
        }

        // --- Rendering ---
        try renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
        try renderer.clear();

        var y_pos: f32 = 10;
        const textures_to_render = [_]*const sdl3.render.Texture{
            &solid_texture,
            // &shaded_texture,
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
}

fn textureFromSurface(renderer: sdl3.render.Renderer, surface: sdl3.surface.Surface) !sdl3.render.Texture {
    defer surface.deinit();
    return try renderer.createTextureFromSurface(surface);
}
