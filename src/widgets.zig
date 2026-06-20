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
};

/// A textured draw: which texture (cached on `Resources`), and an optional `src`
/// sub-rect selecting one cell of a sprite sheet. `src == null` blits the whole
/// texture. The on-screen size comes from the node's resolved box, not from `src` —
/// `data_img`/`data_sprite` set that box, so a 512px sheet cell can draw at 48px.
pub const Sprite = struct {
    texture: sdl.render.Texture,
    src: ?sdl.rect.FRect = null,
};

/// Concrete node type for this host, bound to the host's `RenderData`. Persistent
/// per-node state (the glyph surface) lives in a `UiState` pool keyed by `node.key`,
/// reached via the engine's `node.data` handle — not on the node itself.
pub const Node = ui.Node(RenderData);

const TextData = zfont.TextData;

// --- Helper Functions ---------------------------------------------------

/// Draw a text node: resolve its cached `TextData` via `node.data` and blit it in `c`.
/// One render primitive per `RenderData` aspect; the host's render loop (in `main.zig`)
/// unwraps each optional aspect and passes its color in. `data` should be non-null
/// whenever `text` is present — the guard is belt-and-suspenders.
pub fn draw_text(u: *UiCtx, node: *Node, c: ui.Color) void {
    const idx = node.data orelse return;
    const td = u.pool(TextData).get(idx);
    const s = node.size;
    const l = node.layout;
    const fmt = td.text() orelse return;

    var surface = u.res.font.renderTextSolid(fmt, .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
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

/// Draw a textured node: blit `sprite` (whole texture, or its `src` cell) into the
/// node's resolved box. Same dst geometry as `draw_text` — global pos inset by padding,
/// sized by the node's measured `data_*` dims.
pub fn draw_texture(u: *UiCtx, node: *Node, sprite: Sprite) void {
    const s = node.size;
    const l = node.layout;
    const dst = sdl.rect.FRect{
        .x = (l._global_x orelse return) + s.padding.left,
        .y = (l._global_y orelse return) + s.padding.up,
        .w = s.data_width,
        .h = s.data_height,
    };
    u.res.renderer.renderTexture(sprite.texture, sprite.src, dst) catch return;
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

/// Draw a fill node: a solid rect in color `c` over its resolved box.
pub fn draw_fill(u: *UiCtx, node: *Node, c: ui.Color) void {
    const box = node_box(node) orelse return;
    u.res.renderer.setDrawColor(.{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
    u.res.renderer.renderFillRect(box) catch return;
}

/// Draw an outline node: a box border in color `c` around its resolved box.
pub fn draw_outline(u: *UiCtx, node: *Node, c: ui.Color) void {
    const box = node_box(node) orelse return;
    u.res.renderer.setDrawColor(.{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }) catch return;
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
    node.render_data.text = .{}; // present (white) ⟹ render walk blits it; caller may recolor
}

/// Feature mixin: give `node` a cached texture (owned by `Resources`, not pooled per-node
/// like `TextData`). Sizes the node to the whole texture and flags the `img` aspect.
pub fn data_img(_: *UiCtx, node: *Node, texture: sdl.render.Texture) !void {
    const w, const h = try texture.getSize();
    node.size = ui.features.Size.initContent(w, h, null);
    node.render_data.img = .{ .texture = texture };
}

/// Feature mixin: draw one `src` cell of a sprite sheet at a fixed `px`×`px` on screen.
/// Unlike `data_img`, the display size is the caller's choice (sheet cells are large),
/// so the source rect and on-screen box are decoupled.
pub fn data_sprite(_: *UiCtx, node: *Node, texture: sdl.render.Texture, src: sdl.rect.FRect, px: f32) !void {
    node.size = ui.features.Size.initContent(px, px, null);
    node.render_data.img = .{ .texture = texture, .src = src };
}

// --- Widget palette ----------------------------------------------------------
// Interaction-state colors the widgets paint themselves in. Kept here (host
// policy) so the engine stays color-agnostic — it only carries `node.render_data`.

const col_normal = ui.Color{ .r = 200, .g = 200, .b = 210 }; // idle button: soft white
const col_hover = ui.Color.white; // hovered: full bright
const col_disabled = ui.Color{ .r = 90, .g = 90, .b = 105 }; // can't afford: dim grey
const col_track = ui.Color{ .r = 90, .g = 90, .b = 105 }; // progress-bar track outline
const col_stamina = ui.Color{ .r = 230, .g = 180, .b = 80 }; // stamina fill: warm amber
const col_panel = ui.Color{ .r = 100, .g = 110, .b = 140 }; // panel border: muted blue-grey
const col_title = ui.Color{ .r = 170, .g = 195, .b = 235 }; // panel title: cool light blue

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

/// Image widget: a leaf node showing `texture`, sized to it. Wires it to `parent`
/// under `key` and returns it so the caller can override layout (e.g. anchor).
pub fn img(ctx: *UiCtx, parent: *Node, key: []const u8, texture: sdl.render.Texture) !*Node {
    const node = try Node.pcreate(ctx.arena, key, parent);
    try data_img(ctx, node, texture);
    return node;
}

/// Progress bar: a fixed-size outlined outer track holding a filled inner whose width
/// is `frac` (0 → empty, 1 → full) of the track. Wires both nodes to `parent` under
/// `key` and returns the outer node so the caller can query/override it. The caller
/// computes `frac` — a countdown bar passes `timer.v / timer.start` (drains full→empty),
/// a fill bar the inverse. `fill` colors the inner bar; the track outline is a dim grey.
pub fn progress_bar(ctx: *UiCtx, parent: *Node, key: []const u8, frac: f32, fill: ui.Color) !*Node {
    const outer = try Node.pcreate(ctx.arena, key, parent);
    outer.render_data.outline = col_track;
    _ = outer.with_layout(ui.features.Layout.init(.relative, null))
        .with_size(ui.features.Size.initFixed(240, 24, null));

    const inner = try Node.pcreate(ctx.arena, "inner", outer);
    inner.render_data.fill = fill;
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
///
/// `enabled` drives the visual state (host policy): a disabled button is dimmed, an
/// enabled one brightens on hover (read off its own slot, set at the event stage from
/// last frame's rect) and is the soft idle color otherwise. The caller still guards
/// the click — `enabled` is purely the look; pass it whatever "affordable" means.
pub fn button(ctx: *UiCtx, parent: *Node, key: []const u8, text: []const u8, enabled: bool) !*Node {
    const outer = try Node.pcreate(ctx.arena, key, parent);
    _ = outer.with_layout(ui.features.Layout.init(.relative, .horizontal))
        .with_size(ui.features.Size.init(.fit_children, .fit_children, null));

    const lbl = try Node.pcreate(ctx.arena, "lbl", outer);
    try data_text(ctx, lbl, text); // sets content size + measured dims, keeps padding
    lbl.size.padding = ui.features.Padding.initSymmetric(8, 4);
    _ = lbl.with_layout(ui.features.Layout.init(.relative, null));

    // State color: dim if disabled, else bright on hover, else idle. Querying here
    // also keeps the slot alive (same as the caller's `.clicked` read). The box draws
    // an outline, the label its text — both in `c`.
    const c = if (!enabled) col_disabled else if (outer.query(ctx).hovering) col_hover else col_normal;
    outer.render_data.outline = c;
    lbl.render_data.text = c;

    return outer;
}

/// Icon button: a clickable sprite cell drawn at `px`×`px`, with a hover/affordability
/// outline ringing it (host policy, mirroring `button`). The render walk draws the
/// outline *after* the image, so the ring shows over the opaque icon tile. Querying
/// keeps the slot alive for next frame's hit-test; the caller reads `.clicked` and
/// still guards the click — `enabled` is purely the look (dim / bright-on-hover / idle).
/// Text-on-hover is deferred; the icon alone is the affordance for now.
pub fn icon_button(ctx: *UiCtx, parent: *Node, key: []const u8, texture: sdl.render.Texture, src: sdl.rect.FRect, px: f32, enabled: bool) !*Node {
    const node = try Node.pcreate(ctx.arena, key, parent);
    try data_sprite(ctx, node, texture, src, px);
    _ = node.with_layout(ui.features.Layout.init(.relative, null));
    node.render_data.outline = if (!enabled) col_disabled else if (node.query(ctx).hovering) col_hover else col_normal;
    return node;
}

/// Panel: a titled, bordered, padded section that groups related content. Builds an
/// outlined outer box (border in `col_panel`) that hugs its children — inset by inner
/// `padding`, with a `gap` between them — and drops a title label at the top (in
/// `col_title`). Returns the outer node so the caller appends content *after* the
/// title; it flows vertically under it:
///   `const p = try panel(ctx, parent, "res", "Resources");`
///   `_ = try label(ctx, p, "energy", "Energy: 8 J");`
pub fn panel(ctx: *UiCtx, parent: *Node, key: []const u8, title: []const u8) !*Node {
    const outer = try Node.pcreate(ctx.arena, key, parent);
    outer.render_data.outline = col_panel;
    _ = outer.with_layout(ui.features.Layout.init(.relative, .vertical).with_gap(8))
        .with_size(ui.features.Size.init(.fit_children, .fit_children, ui.features.Padding.init(12)));

    const ttl = try Node.pcreate(ctx.arena, "title", outer);
    try data_text(ctx, ttl, title);
    ttl.render_data.text = col_title;
    _ = ttl.with_layout(ui.features.Layout.init(.relative, null));

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
