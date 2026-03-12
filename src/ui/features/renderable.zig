const ui = @import("../root.zig");

pub const OnRender = struct {
    run: *const fn (*ui.Node, ?*anyopaque) void,

    pub fn init(func: *const fn (*ui.Node, ?*anyopaque) void) OnRender {
        return .{ .run = func };
    }

    pub fn invoke(self: OnRender, node: *ui.Node, ctx: ?*anyopaque) void {
        self.run(node, ctx);
    }
};
