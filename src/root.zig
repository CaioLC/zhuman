comptime {
    // This will ensure that the file 'api.zig' is always discovered (as long as this file is discovered).
    // It is useful if 'api.zig' contains important exported declarations.
    // _ = @import("sdl3");
}
pub const sdl = @import("sdl3");
pub const ui = @import("./ui/root.zig");
pub const ui_client = @import("./ui_client/root.zig");
pub const UiCtx = ui_client.UiCtx;
pub const comp = @import("./components.zig");
pub const tag = @import("./tags.zig");
pub const log = @import("./log.zig");
pub const font = @import("./font.zig");
pub const dist = @import("./dist.zig");
pub const theme = @import("./theme.zig");
pub const res = @import("./res.zig");
pub const world = @import("./world.zig");
pub const ecs = @import("./ecs.zig");
pub const systems = @import("./systems.zig");
pub const actions = @import("./actions.zig");
pub const capital = @import("./capital.zig");

test {
    _ = ui;
    _ = ui_client;
    _ = comp;
    _ = tag;
    _ = log;
    _ = dist;
    _ = theme;
    _ = res;
    _ = actions;
    _ = capital;

    _ = world;
    _ = ecs;
    _ = systems;
}
