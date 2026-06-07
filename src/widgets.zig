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

// --- Text widget rendering ---------------------------------------------------

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

// --- Widget functions --------------------------------------------------------
// Each takes `(parent, seed, id)`, computes its own key `k`, self-serves
// persistent state from the cache, builds an ephemeral arena node, attaches it
// to `parent`, and returns the `*Node`. Interactive widgets also carry an
// `interaction_key` (so the event-stage `mark_*` walks can flag them); read
// their state with `node.query(u)`.

/// Build a `.relative` text node, cache+update its `TextData`, attach to parent.
/// Returns the node and its key `k = ui.key(seed, id)`, so an interactive caller
/// can reuse the key without re-hashing.
fn make_text(u: *UiCtx, parent: *Node, seed: u64, id: []const u8, text: []const u8) !struct { *Node, u64 } {
    const k = ui.key(seed, id);
    const idx = u.cache(k, TextData);
    u.pool(TextData).get(idx).update(text);

    // Measure the content here, at build — the host has the font on hand. The
    // engine never measures; it just reads these dims (`content` rule + renderer).
    const tw, const th = try u.res.font.getStringSize(text);

    const node = try Node.create(u.arena, id);
    _ = node.with_size(ui.Size.initContent(@floatFromInt(tw), @floatFromInt(th), null));
    _ = node.with_layout(ui.Layout.init(.relative, null));
    node.data = idx;
    node.render_flags = .{ .text = true }; // flags how the host's render walk draws it
    try parent.add_child(u.arena, node);
    return .{ node, k };
}

/// A non-interactive text leaf. `text` is copied into the cached `TextData`, so
/// a build-time slice (e.g. a stack `bufPrint`) is safe to pass.
pub fn label(u: *UiCtx, parent: *Node, seed: u64, id: []const u8, text: []const u8) !*Node {
    const node, _ = try make_text(u, parent, seed, id, text);
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

/// An interactive text leaf. Carries an `interaction_key` so the event-stage
/// `mark_*` walks can flag it. Returns the `*Node`; read its interaction with
/// `node.query(u)` — the flags reflect the previous frame's geometry against this
/// frame's input (immediate-mode's inherent one-frame delay):
/// `const b = try button(..); if (b.query(u).clicked) ...`.
pub fn button(u: *UiCtx, parent: *Node, seed: u64, id: []const u8, text: []const u8) !*Node {
    const node, const k = try make_text(u, parent, seed, id, text);
    node.interaction_key = k; // opt-in: only keyed nodes are marked/queryable
    return node;
}
