const std = @import("std");
const ui = @import("./root.zig");

pub fn button(
    allocator: std.mem.Allocator,
    id: []const u8,
    position: ui.Position,
    on_click: ui.features.OnClick
) !*ui.Node {
    const node = try allocator.create(ui.Node);
    node.* = ui.Node.init(id);
    _ = node
        .with_position(position)
        .with_onclick(on_click);
    return node;
}
