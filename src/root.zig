comptime {
    // This will ensure that the file 'api.zig' is always discovered (as long as this file is discovered).
    // It is useful if 'api.zig' contains important exported declarations.
    // _ = @import("sdl3");
}
pub const sdl = @import("sdl3");
pub const ui = @import("ui");
pub const ui_client = @import("./ui_client/root.zig");
pub const UiCtx = ui_client.UiCtx;
pub const font = @import("./font.zig");
pub const palette = @import("./palette.zig");
pub const tokens = @import("./tokens.zig");
pub const query = @import("./query.zig");
pub const eating = @import("./eating.zig");
pub const body = @import("./body.zig");
pub const res = @import("./res.zig");
pub const sim = @import("./sim/root.zig");

test {
    _ = ui;
    _ = ui_client;
    _ = palette;
    _ = tokens;
    _ = query;
    _ = eating;
    _ = body;
    _ = res;
    _ = sim;
}
