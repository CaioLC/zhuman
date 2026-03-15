const ui = @import("root.zig");
const Node = ui.Node;

const EventTag = enum {
    node_added,
};

pub const Event = union(EventTag) {
    node_added: *Node,
};

/// Type-erased event listener. Allows Node to emit events
/// without knowing the concrete type of the subscriber (e.g. Runtime).
pub const EventListener = struct {
    ctx: *anyopaque,
    handler: *const fn (*anyopaque, Event) void,

    pub fn emit(self: EventListener, ev: Event) void {
        self.handler(self.ctx, ev);
    }
};
