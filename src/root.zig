//! By convention, root.zig is the root source file when making a library.
comptime {
    // This will ensure that the file 'api.zig' is always discovered (as long as this file is discovered).
    // It is useful if 'api.zig' contains important exported declarations.
    _ = @import("./ui.zig");
}
const std = @import("std");

