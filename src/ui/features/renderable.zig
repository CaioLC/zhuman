const ui = @import("../root.zig");

pub const OnRender = struct {
    run: *const fn (*anyopaque, *ui.Node) void,

    pub fn init(func: *const fn (*anyopaque, *ui.Node) void) OnRender {
        return .{ .run = func };
    }

    pub fn invoke(self: OnRender, ctx: *anyopaque, node: *ui.Node) void {
        self.run(ctx, node);
    }
};
