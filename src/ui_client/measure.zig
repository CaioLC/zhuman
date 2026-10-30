//! The host's layout measurer: the struct `Driver.step` hands to the engine's
//! `set_global_pos_measured_profiled`. The engine calls `height_for_width` once per solve for
//! each `Size.measure_h` node, after every width is final and before any height is computed
//! (see `ui/features/layout.zig`). Today only text measures: a `.fill` leaf wraps at its
//! solved width (`text.heightForWidth`), and a `.cell_fill` leaf records its solved width
//! (and returns null). Anything else returns null and keeps its build-time `data_height`.

const ui = @import("ui");
const cb = @import("ctx_binding.zig");
const text = @import("features/text.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const TextMeasurer = struct {
    ui: *UiCtx,

    /// The new `data_height`/`baseline` for `node` at content width `w` (device px), or null
    /// to keep the build-time values. Reads and writes the node's host-side text state only
    /// (the `.fill` memo and solved width, the `.cell_fill` solved width that draw elides at);
    /// it never touches the tree's layout.
    pub fn height_for_width(self: TextMeasurer, node: *Node, w: f32) ?ui.Measured {
        if (node.render_data.text == null) return null; // the text aspect is the only measurer
        return text.heightForWidth(self.ui, node, w);
    }
};
