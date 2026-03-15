pub const ui = @import("root.zig");
pub const Node = ui.Node;

const EventTag = enum {
    node_created,
};

pub const Event = union(EventTag) {
    node_created: *Node,
};