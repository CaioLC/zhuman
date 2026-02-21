comptime {
    // This will ensure that the file 'api.zig' is always discovered (as long as this file is discovered).
    // It is useful if 'api.zig' contains important exported declarations.
    // _ = @import("sdl3");
}
pub const sdl = @import("sdl3");
pub const ui = @import("./ui.zig");
pub const time = @import("./time.zig");
pub const font = @import("./font.zig");

test {
    _ = ui;
    _ = time;
    _ = font;
}


