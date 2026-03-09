const ui = @import("./root.zig");

pub fn button(id: []const u8, func: *const fn (?*anyopaque, ui.features.ClickEvent) void, data: ?*anyopaque) ui.Node {
    var node = ui.Node.init(id);
    node.on_click = ui.features.OnClick.init(func, data);
    return node;
}
