comptime {
    // This will ensure that the file 'api.zig' is always discovered (as long as this file is discovered).
    // It is useful if 'api.zig' contains important exported declarations.
    // _ = @import("sdl3");
}
pub const sdl = @import("sdl3");
pub const ui = @import("./ui/root.zig");
pub const widgets = @import("./widgets.zig");
pub const time = @import("./time.zig");
pub const font = @import("./font.zig");
pub const res = @import("./res.zig");
pub const world = @import("./world.zig");
pub const systems = @import("./systems.zig");

test {
    _ = ui;
    _ = time;
    _ = font;
    _ = res;

    _ = world;
    _ = systems;
}


