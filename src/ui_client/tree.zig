//! The frame's tree-assembly return type. `build_ui` hands back a `Trees` — the flat list
//! of independent root trees the host lays out and draws in order (later trees on top).
//! The *flattening* of a builder's return shape into that list is `Node.collect`, an engine
//! mechanism (`src/ui/root.zig`); this file only names the wrapper type. Host-side (not on
//! the `ha` library surface) so `src/pages/` can build against it directly.

const cb = @import("./ctx_binding.zig");
const Node = cb.Node;

/// What `build_ui` hands back each frame: a flat list of independent root trees, laid out
/// and drawn in order (later trees paint on top). A named alias for the bare slice so the
/// frame return type reads as `Trees` at the `main.zig` call site. Formerly a one-field
/// struct wrapper; formerly named `Ui`.
pub const Trees = []const *Node;
