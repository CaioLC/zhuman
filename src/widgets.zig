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
    fill: bool = false, // solid rect spanning the node's resolved box
    outline: bool = false, // 1px box border around the node's resolved box
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
    const s = node.size;
    const l = node.layout;
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

/// The node's resolved on-screen box (global pos from layout + solved size), or null
/// if it hasn't been laid out yet. The shape SDL's rect primitives draw into.
fn node_box(node: *Node) ?sdl.rect.FRect {
    return .{
        .x = node.layout._global_x orelse return null,
        .y = node.layout._global_y orelse return null,
        .w = node.size.width,
        .h = node.size.height,
    };
}

/// Draw a `.fill` node: a solid white rect over the node's resolved box.
pub fn draw_fill(u: *UiCtx, node: *Node) void {
    const box = node_box(node) orelse return;
    u.res.renderer.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 }) catch return;
    u.res.renderer.renderFillRect(box) catch return;
}

/// Draw an `.outline` node: a white box border around the node's resolved box.
pub fn draw_outline(u: *UiCtx, node: *Node) void {
    const box = node_box(node) orelse return;
    u.res.renderer.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 }) catch return;
    u.res.renderer.renderRect(box) catch return;
}

/// Feature mixin: give `node` cached text — measured at build, content-sized, and
/// flagged for the render walk. Apply it **after** the node is wired into the tree,
/// so `node.key` is final (see `Node.rekey`). Overrides both size axes to `.content`,
/// keeping the node's existing padding.
pub fn data_text(ctx: *UiCtx, node: *Node, text: []const u8) !void {
    const idx = ctx.cache(node.key, TextData);
    ctx.pool(TextData).get(idx).update(text);
    node.data = idx;

    // Measure the content here, at build — the host has the font on hand. The
    // engine never measures; it just reads these dims (`content` rule + renderer).
    const tw, const th = try ctx.res.font.getStringSize(text);
    var size = node.size;
    size.w = .content;
    size.h = .content;
    size.data_width = @floatFromInt(tw);
    size.data_height = @floatFromInt(th);
    node.size = size;
    node.render_flags = .{ .text = true }; // flags how the host's render walk draws it
}

// --- Widget functions --------------------------------------------------------
//
// Build a node with `Node.create`/`pcreate` (the latter wires it to a parent, so its
// `key` is final), then attach data with a mixin like `data_text` and layout with
// `with_size`/`with_layout`. To make a node carry data, add the data type to UiState.
// To make a node interactive, add the flag to Interaction (the IntFlags pool).

/// Label: a content-sized text node wired to `parent` under `key`, laid out relative
/// to its siblings. Returns the node so the caller can query it (a clickable label
/// reads `.clicked`; a plain readout discards the return). The caller owns the text —
/// it's the data source, formatted at the call site and copied into the cache here.
pub fn label(ctx: *UiCtx, parent: *Node, key: []const u8, text: []const u8) !*Node {
    const node = try Node.pcreate(ctx.arena, key, parent);
    try data_text(ctx, node, text);
    _ = node.with_layout(ui.features.Layout.init(.relative, null));
    return node;
}

/// Progress bar: a fixed-size outlined outer track holding a filled inner whose width
/// is `frac` (0 → empty, 1 → full) of the track. Wires both nodes to `parent` under
/// `key` and returns the outer node so the caller can query/override it. The caller
/// computes `frac` — a countdown bar passes `timer.v / timer.start` (drains full→empty),
/// a fill bar the inverse.
pub fn progress_bar(ctx: *UiCtx, parent: *Node, key: []const u8, frac: f32) !*Node {
    const outer = try Node.pcreate(ctx.arena, key, parent);
    outer.render_flags.outline = true;
    _ = outer.with_layout(ui.features.Layout.init(.relative, null))
        .with_size(ui.features.Size.initFixed(240, 24, null));

    const inner = try Node.pcreate(ctx.arena, "inner", outer);
    inner.render_flags.fill = true;
    _ = inner.with_layout(ui.features.Layout.init(.top_left, null))
        .with_size(ui.features.Size.init(.{ .pct_of_parent = frac }, .{ .pct_of_parent = 1.0 }, null));

    return outer;
}

/// Button: an outlined box that hugs its text label (plus a little padding so the
/// glyphs clear the border), wired to `parent` under `key`. Returns the outer node;
/// the caller reads `btn.query(ctx).clicked` to act on a press — querying also keeps
/// the node's interaction slot alive so its rect is stamped for next frame's hit-test.
/// The whole box is the clickable surface. The padding lives on the *label*, not the
/// box: `place` puts a child at the parent's origin (ignoring parent padding) and
/// `draw_text` insets by the text node's own padding, so this is what centres the
/// glyphs and lets the `fit_children` box wrap `text + padding` exactly.
pub fn button(ctx: *UiCtx, parent: *Node, key: []const u8, text: []const u8) !*Node {
    const outer = try Node.pcreate(ctx.arena, key, parent);
    outer.render_flags.outline = true;
    _ = outer.with_layout(ui.features.Layout.init(.relative, .horizontal))
        .with_size(ui.features.Size.init(.fit_children, .fit_children, null));

    const lbl = try Node.pcreate(ctx.arena, "lbl", outer);
    try data_text(ctx, lbl, text); // sets content size + measured dims, keeps padding
    lbl.size.padding = ui.features.Padding.initSymmetric(8, 4);
    _ = lbl.with_layout(ui.features.Layout.init(.relative, null));

    return outer;
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
