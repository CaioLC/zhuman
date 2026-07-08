//! Implement Concrete Types for the Ui-Engine generic types

const std = @import("std");
const ui = @import("../ui/root.zig");
const sdl = @import("sdl3");
const Resources = @import("../res.zig").Resources;

/// Context Binding
/// The registry of widget-state (render-state) types kept in the UI cache. One
/// `Pool(T)` is generated per declaration. This is where the generic `ui` engine
/// meets the concrete state types — see docs/ui-building-language-plan.md.
pub const UiState = struct {
    /// Pure text-state data — one slot per text widget, sourced by `data.data_text` and
    /// blit by `draw.draw_text`. Defined here rather than a standalone leaf module: it's a
    /// widget-state type like `ScrollState`/`TextInputState` below, and both `data.zig` and
    /// `draw.zig` already depend on this file for `UiCtx`/`Node`, so a separate file would
    /// need `ctx_binding.zig` to import back out to it — a cycle, since `data.zig` imports
    /// `ctx_binding.zig` for its own types.
    pub const TextData = struct {
        buf: [64]u8,
        len: usize,

        pub fn init() TextData {
            return .{ .buf = undefined, .len = 0 };
        }

        /// Copy `text` into the persistent buffer.
        pub fn update(self: *TextData, t: []const u8) void {
            const n = @min(t.len, self.buf.len);
            @memcpy(self.buf[0..n], t[0..n]);
            self.len = n;
        }

        /// The current text, reconstructed from `buf` + `len` at the call site.
        /// Returns `null` (renders nothing) when empty. Never store the result
        /// across a pool `acquire` — the slot may move; call this again instead.
        pub fn text(self: *const TextData) ?[]const u8 {
            return if (self.len == 0) null else self.buf[0..self.len];
        }
    };
    /// A scroll container's persisted offset (px), keyed by its own `node.key` — survives
    /// the frame-arena reset the same way `TextData` does. See `scroll_view`.
    pub const ScrollState = struct { offset: f32 = 0 };
    /// A `text_input`'s persisted UTF-8 buffer, keyed by its own `node.key`. `main.zig`'s
    /// event loop appends `.text_input` events and handles backspace directly against
    /// whichever field `Resources.focused_text` names — the widget itself only reads it
    /// to render. See `text_input`.
    pub const TextInputState = struct { buf: [64]u8 = undefined, len: usize = 0 };
};

/// Host-defined interaction vocabulary (policy — the engine stores it opaquely,
/// keyed by widget key). `mark_*` writes fields at the event stage; the build reads
/// them back via `node.query`. `transient` names the fields the engine zeroes every
/// frame (recomputed from input); fields not listed latch until userland clears them.
/// Add a field (e.g. `dragging`, `focused`) the day a widget grows a new behaviour.
pub const Interaction = packed struct {
    hovering: bool = false,
    clicked: bool = false,
    active: bool = false,

    pub const transient = [_][]const u8{ "hovering", "clicked" };
};

/// Concrete UI context type, bound here where `ui` and `res` meet.
pub const UiCtx = ui.Ctx(UiState, Interaction, Resources);

/// Node Binding
pub const icon_cell = 512.0;
pub const Sprite = struct {
    texture: sdl.render.Texture,
    src: ?sdl.rect.FRect = null,
};
/// Name one cell of the shared icon sheet by grid (col, row). The single place that
/// knows the sheet lives on `res.icons` and how big a cell is — callers reference a
/// cell, not a texture+rect, so the spritesheet isn't threaded through every icon.
pub fn icon_sprite(res: *Resources, col: f32, row: f32) Sprite {
    return .{
        .texture = res.icons,
        .src = .{ .x = col * icon_cell, .y = row * icon_cell, .w = icon_cell, .h = icon_cell },
    };
}

/// Host-defined render descriptor carried on every node (policy — core stores it
/// opaquely, never reads it). The render walk switches on its fields to decide what
/// to draw. Each aspect is an *optional payload*, not a bare bit: present ⟹ draw that
/// aspect, and the value is the `Color` to paint it in (color is frame-local visual
/// state, so it rides here rather than in a separate field). Add an aspect (e.g. a
/// `sprite` handle) the day the renderer grows one — one line, no engine change.
/// Composable: a node can set several aspects at once.
pub const RenderData = struct {
    text: ?ui.Color = null, // cached glyphs (handle in node.data), blit in this color
    fill: ?ui.Color = null, // solid rect spanning the node's resolved box, in this color
    outline: ?ui.Color = null, // 1px box border around the node's resolved box, in this color
    img: ?Sprite = null, // textured draw (texture + optional sheet cell), blit over the node's box
    /// True ⟹ the render walk crops everything drawn under this node to its own resolved
    /// box (a scroll viewport). Not a color like the other aspects — there's nothing to
    /// paint, just a clip region to push/pop around this subtree.
    clip: bool = false,
};

/// Concrete node type for this host, bound to the host's `RenderData`. Persistent
/// per-node state (the glyph surface) lives in a `UiState` pool keyed by `node.key`,
/// reached via the engine's `node.data` handle — not on the node itself.
pub const Node = ui.Node(RenderData);

test "interaction store: active latches, transient flags clear each frame" {
    // res/arena are untouched by the interaction methods, so `undefined` is safe.
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const k = ui.key(0, "btn");
    u.setFlag(k, .hovering, true);
    u.setFlag(k, .clicked, true);
    u.setFlag(k, .active, true);

    const on = u.interactionOf(k);
    try std.testing.expect(on.hovering and on.clicked and on.active);

    u.clearTransient();
    const after = u.interactionOf(k);
    try std.testing.expect(!after.hovering);
    try std.testing.expect(!after.clicked);
    try std.testing.expect(after.active); // latched — survives the frame boundary
}
