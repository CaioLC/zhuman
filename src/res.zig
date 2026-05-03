const sdl = @import("sdl3");

pub const Resources = struct {
    font: *sdl.ttf.Font,
    renderer: *const sdl.render.Renderer,
    window: sdl.video.Window,
};