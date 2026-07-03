comptime {
    // This will ensure that the file 'api.zig' is always discovered (as long as this file is discovered).
    // It is useful if 'api.zig' contains important exported declarations.
    // _ = @import("sdl3");
}
pub const sdl = @import("sdl3");
pub const ui = @import("./ui/root.zig");
pub const widgets = @import("./widgets.zig");
pub const UiCtx = widgets.UiCtx;
pub const comp = @import("./components.zig");
pub const tag = @import("./tags.zig");
pub const font = @import("./font.zig");
pub const log = @import("./log.zig");
pub const res = @import("./res.zig");
pub const world = @import("./world.zig");
pub const ecs = @import("./ecs.zig");
pub const systems = @import("./systems.zig");

test {
    _ = ui;
    _ = widgets;
    _ = comp;
    _ = tag;
    _ = font;
    _ = log;
    _ = res;

    _ = world;
    _ = ecs;
    _ = systems;
}


