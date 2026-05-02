const ui = @import("../root.zig");

pub const Padding = struct {
    up: f32,
    right: f32,
    down: f32,
    left: f32,

    pub fn init(p: f32) Padding {
        return .{ .up = p, .right = p, .down = p, .left = p };
    }

    pub fn initSymmetric(w: f32, h: f32) Padding {
        return .{ .up = h, .right = w, .down = h, .left = w };
    }

    pub fn initEach(u: f32, r: f32, d: f32, l: f32) Padding {
        return .{ .up = u, .right = r, .down = d, .left = l };
    }
};

pub const Size = struct {
    calc: *const fn (*anyopaque, *ui.Node) anyerror!struct { f32, f32 },
    padding: Padding,
    width: f32,
    height: f32,
    data_width: f32,
    data_height: f32,

    pub fn init(
        calc: *const fn (*anyopaque, *ui.Node) anyerror!struct { f32, f32 },
        padding: ?Padding,
    ) Size {
        const pad = padding orelse Padding.init(0);
        return .{
            .calc = calc,
            .padding = pad,
            .width = pad.left + pad.right,
            .height = pad.up + pad.down,
            .data_width = 0,
            .data_height = 0,
        };
    }

    pub fn initFixed(width: f32, height: f32, padding: ?Padding) Size {
        const pad = padding orelse Padding.init(0);
        return .{
            .calc = &static_calc_size,
            .padding = pad,
            .width = width + pad.left + pad.right,
            .height = height + pad.up + pad.down,
            .data_width = width,
            .data_height = height,
        };
    }
};

pub fn static_calc_size(_: *anyopaque, node: *ui.Node) anyerror!struct { f32, f32 } {
    const s = node.size orelse return .{ 0, 0 };
    return .{ s.data_width, s.data_height };
}

pub fn recalculate_size(node: *ui.Node, ctx: *anyopaque) !void {
    for (node.children.items) |c| try recalculate_size(c, ctx);
    if (node.size) |*s| {
        s.data_width, s.data_height = try s.calc(ctx, node);
        s.width = s.data_width + s.padding.left + s.padding.right;
        s.height = s.data_height + s.padding.up + s.padding.down;
    }
}
