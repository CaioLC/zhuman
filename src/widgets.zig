const std = @import("std");
const ui = @import("./ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("./font.zig");
const Resources = @import("./res.zig").Resources;

/// The registry of widget-state (render-state) types kept in the UI cache. One
/// `Pool(T)` is generated per declaration. This is where the generic `ui` engine
/// meets the concrete state types — see docs/ui-building-language-plan.md.
pub const UiState = struct {
    pub const TextData = zfont.TextData;
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

/// Concrete UI context type, bound here where `ui`, `font` and `res` all meet.
pub const UiCtx = ui.Ctx(UiState, Interaction, Resources);

/// Host-defined render flags carried on every node (policy — core stores them
/// opaquely, never reads them). The render walk switches on these to decide what
/// to draw. A packed struct of defaulted bools: add a field (e.g. `border`,
/// `inactive`) the day the renderer grows a new aspect — one line, no engine
/// change. Composable: a node can be several at once.
pub const RenderFlags = packed struct {
    text: bool = false,
};

/// Concrete node type for this host, bound to the host's `RenderFlags`.
pub const Node = ui.Node(RenderFlags);

const TextData = zfont.TextData;

// --- Helper Functions ---------------------------------------------------

/// Draw a `.text` node: resolve its cached `TextData` via `node.data` and blit it.
/// One render primitive per `RenderFlags` aspect; the host's render loop (in `main.zig`)
/// walks the tree and calls the primitives whose flags are set. `data` should be
/// non-null whenever `.text` is — the guard is belt-and-suspenders.
pub fn draw_text(u: *UiCtx, node: *Node) void {
    const idx = node.data orelse return;
    const td = u.pool(TextData).get(idx);
    const s = node.size orelse return;
    const l = node.layout orelse return;
    const fmt = td.text() orelse return;

    var surface = u.res.font.renderTextSolid(fmt, zfont.white) catch return;
    defer surface.deinit();
    const texture = u.res.renderer.createTextureFromSurface(surface) catch return;
    defer texture.deinit();

    const dst = sdl.rect.FRect{
        .x = (l._global_x orelse return) + s.padding.left,
        .y = (l._global_y orelse return) + s.padding.up,
        .w = s.data_width,
        .h = s.data_height,
    };
    u.res.renderer.renderTexture(texture, null, dst) catch return;
}

/// Feature mixin: give `node` cached text — measured at build, content-sized, and
/// flagged for the render walk. Requires `node.key` (every node gets one in
/// `container`) and an existing `node.size` (the default from `container`).
fn add_text_data(ctx: *UiCtx, node: *Node, text: []const u8) !void {
    const idx = ctx.cache(node.key.?, TextData);
    ctx.pool(TextData).get(idx).update(text);
    node.data = idx;

    // Measure the content here, at build — the host has the font on hand. The
    // engine never measures; it just reads these dims (`content` rule + renderer).
    const tw, const th = try ctx.res.font.getStringSize(text);
    var size = node.size.?;
    size.w = .content;
    size.h = .content;
    size.data_width = @floatFromInt(tw);
    size.data_height = @floatFromInt(th);
    node.size = size;
    node.render_flags = .{ .text = true }; // flags how the host's render walk draws it
}

// --- Widget functions --------------------------------------------------------
//
// Each takes `(u, parent, id, …)` and derives its key from the **parent's key** +
// `id`, self-serves persistent state from the cache, builds an ephemeral arena node,
// and attaches it to `parent`. Widgets compose `container` + feature mixins.
// To make a node carry data, add the data type to UiState.
// To make a node interactive, add the flag to Interaction (the IntFlags pool).

/// The base widget: a fresh node whose `key` is hashed from its **parent's key** + its
/// `id`, so identity is structural (see the key-cache docs) — two same-`id` nodes under
/// different parents never collide. `parent` is **optional**: pass `null` to build a
/// root (the seed falls back to the `0` base and the node is left unattached). Wires the
/// given `size`/`layout` if provided. The key is universal — any node is markable/queryable.
pub fn container(ui_ctx: *UiCtx, parent: ?*Node, id: []const u8, layout: ?ui.Layout, size: ?ui.Size) !*Node {
    const node = try Node.create(ui_ctx.arena, id);
    node.key = ui.key(if (parent) |p| (p.key orelse 0) else 0, id);
    if (layout) |l| _ = node.with_layout(l);
    if (size) |s| _ = node.with_size(s);
    if (parent) |p| try p.add_child(ui_ctx.arena, node);
    return node;
}

/// A static text node: `container` + text.
pub fn text_container(ui_ctx: *UiCtx, parent: *Node, id: []const u8, layout: ui.Layout, text: []const u8) !*Node {
    const node = try container(ui_ctx, parent, id, layout, ui.Size.init(.content, .content, null));
    try add_text_data(ui_ctx, node, text);
    return node;
}

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
