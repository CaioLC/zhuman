//! Implement Concrete Types for the Ui-Engine generic types

const std = @import("std");
const ui = @import("../ui/root.zig");
const sdl = @import("sdl3");
const theme = @import("./theme.zig");
const Resources = @import("../res.zig").Resources;
const editor = @import("./editor.zig");

/// The host color type, re-exposed here so the whole `ui_client` layer names one `Color`
/// (SDL's `pixels.Color`) — the engine carries it opaquely on `RenderData` and never
/// reads it. Defined in `ui_client/theme.zig` (the color leaf); aliased here for the layer.
pub const Color = theme.Color;

/// Context Binding
/// The registry of widget-state (render-state) types kept in the UI cache. One
/// `Pool(T)` is generated per declaration. This is where the generic `ui` engine
/// meets the concrete state types — see `README.md` in this folder.
pub const UiState = struct {
    /// Pure text-state data — one slot per text widget, sourced and blit by the `text`
    /// feature (`features/text.zig`). The `State` types live *here*, not with their
    /// feature: the pool registry `UiState` is scanned by `Ctx` to generate pools, and a
    /// feature module already imports `ctx_binding` for `UiCtx`/`Node` — so declaring the
    /// state in the feature and referencing it back here would be an import cycle. The
    /// feature exposes it as `pub const State = cb.UiState.TextState` for the contract.
    pub const TextState = struct {
        buf: [64]u8,
        len: usize,
        /// Point size to render this text at, in px. Set by the `text` feature's `attach`
        /// (default) and overridden by `style.apply` when a `font` fragment resolves — so
        /// the size travels from build to the feature's `draw`, which renders at it. The
        /// pool calls `init`, which seeds `px` at 0; `attach` (run every frame before `draw`)
        /// (re)sets this; a stray 0 would just clamp to the backend's 1px floor.
        px: f32,

        pub fn init() TextState {
            return .{ .buf = undefined, .len = 0, .px = 0 };
        }

        /// Copy `text` into the persistent buffer.
        pub fn update(self: *TextState, t: []const u8) void {
            const n = @min(t.len, self.buf.len);
            @memcpy(self.buf[0..n], t[0..n]);
            self.len = n;
        }

        /// The current text, reconstructed from `buf` + `len` at the call site.
        /// Returns `null` (renders nothing) when empty. Never store the result
        /// across a pool `acquire` — the slot may move; call this again instead.
        pub fn text(self: *const TextState) ?[]const u8 {
            return if (self.len == 0) null else self.buf[0..self.len];
        }
    };
    /// A scroll container's persisted offset and active thumb-drag anchors, keyed by its
    /// own `node.key`. The offset survives frame-arena reset; drag ownership remains in
    /// generic `Ctx` capture and these fields only preserve host scroll math.
    pub const ScrollState = struct {
        offset: f32 = 0,
        dragging: bool = false,
        drag_origin_y: f32 = 0,
        drag_origin_offset: f32 = 0,
        drag_pointer_kind: @import("input.zig").PointerKind = .unknown,
        drag_pointer_id: ?u64 = null,
        drag_owner_key: ?u64 = null,

        pub fn clearDrag(self: *ScrollState) void {
            self.dragging = false;
            self.drag_origin_y = 0;
            self.drag_origin_offset = 0;
            self.drag_pointer_kind = .unknown;
            self.drag_pointer_id = null;
            self.drag_owner_key = null;
        }
    };
    /// A tab strip's persisted selection (an index into its labels), keyed by the strip's
    /// own `node.key` — the `ScrollState` pattern for content that switches. Tab 0 is the
    /// semantic and bitwise-zero default, so this state uses the zeroable fallback.
    pub const TabsState = struct { active: usize = 0 };
    /// A multi-step panel's position in its sequence, keyed by the panel's own
    /// `node.key` — the `TabsState` pattern for content that advances rather than
    /// switches: the caller reads `step`, builds that step, and bumps it on a click.
    /// Step 0 is the semantic and bitwise-zero default.
    pub const StepState = struct { step: usize = 0 };
    /// The BUILD list's sort and filter, keyed on a node that is built **every** frame —
    /// the tab strip's container, not the list itself, which only exists while its tab is
    /// active and would have its slot pruned on every visit to the other one.
    ///
    /// `init` returns the declared semantic defaults, so enum declaration order can
    /// change without silently changing what the player sees on a fresh run.
    pub const BuildViewState = struct {
        pub const Sort = enum { reach, materials, time };
        pub const Show = enum { in_reach, ready, all };
        pub const Tier = enum { any, crude, manufactured };
        sort: Sort = .reach,
        show: Show = .in_reach,
        tier: Tier = .any,
        built: bool = false,

        pub fn init() BuildViewState {
            return .{};
        }
    };
    /// A `text_input`'s persisted, authoritative editing model (INPUT-07). This is the
    /// full host editor — buffer plus caret/anchor selection, UTF-8 and single-line
    /// validation, an explicit `max_query_bytes`, and non-silent refusal — defined in
    /// `ui_client/editor.zig` so the generic engine stays unaware of editor semantics.
    /// The widget acquires it via `node.state(ctx, UiState.TextInputState)` each frame and
    /// reads caret/selection to render; `main.zig` routes SDL text/clipboard/command
    /// events into its methods against whichever stable key `UiCtx.focusedKey()` returns.
    /// See `text_input`.
    pub const TextInputState = editor.LineEditor;
    /// The `svg` feature's cached rasterization (see `ui_client/features/svg.zig`): the
    /// texture SDL_image produced for the current source+size, plus the `src_key` hash
    /// that produced it — so the feature's `attach` re-rasterizes only when the source
    /// or target size changes. Unlike the POD states above, this **owns a GPU resource**,
    /// so it declares `deinit`: the pool's eviction hook (`cache.zig`) frees the texture
    /// when the node disappears or the app tears down. Without it, the texture would leak
    /// every time a scrolled-away / closed SVG node's slot is pruned. `src_key == 0` means
    /// "nothing rasterized yet"; `SvgState` intentionally uses the zeroable fallback.
    /// A polyline's points, keyed by its own `node.key`. The first state that carries
    /// *variable-length* data rather than a handle or a scalar — which is why it exists
    /// at all: `RenderData` holds one payload per feature per node, and coordinates do
    /// not fit in a tint. Fixed capacity keeps it POD (no `deinit`, no allocator), and a
    /// caller with more points than this wants a second node rather than a bigger buffer.
    /// `LineState` intentionally uses the zeroable fallback, so an unset line has
    /// `len == 0` and draws nothing.
    pub const LineState = struct {
        pub const cap = 64;
        buf: [cap]Point = undefined,
        len: usize = 0,

        pub fn set(self: *LineState, pts: []const Point) void {
            const n = @min(pts.len, cap);
            @memcpy(self.buf[0..n], pts[0..n]);
            self.len = n;
        }

        /// The stored points. Never hold the slice across a pool `acquire` — the slot
        /// may move; call this again instead.
        pub fn points(self: *const LineState) []const Point {
            return self.buf[0..self.len];
        }
    };
    pub const SvgState = struct {
        src_key: u64 = 0,
        tex: ?sdl.render.Texture = null,
        pub fn deinit(self: *SvgState) void {
            if (self.tex) |t| t.deinit();
            self.tex = null;
        }
    };
};

/// A point in a node's own box, in the unit square: (0,0) is its top-left corner and
/// (1,1) its bottom-right. Relative rather than pixel so a polyline survives a resize
/// and a zoom without the caller recomputing it. See `features/line.zig`.
pub const Point = struct { x: f32, y: f32 };

/// A stroke: what a polyline is drawn *with*, as against where it goes (which is
/// variable-length, so it lives in `LineState`). Width is in px, unscaled.
pub const Stroke = struct { color: Color, width: f32 = 1 };

/// Host-defined interaction vocabulary (policy — the engine stores it opaquely,
/// keyed by widget key). Pointer-derived fields are transient and republished from
/// input/capture every frame. Semantic fields persist through the event stage, but a
/// control must publish all of them from its authoritative widget/domain owner each
/// build with `publishControlState`; none is an unowned toggle.
pub const Interaction = packed struct {
    hovering: bool = false,
    pressed: bool = false,
    held: bool = false,
    released: bool = false,
    wheel: bool = false,
    clicked: bool = false,
    dragging: bool = false,
    captured: bool = false,
    dismissed: bool = false,

    disabled: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    selected: bool = false,
    checked: bool = false,

    pub const transient = [_][]const u8{
        "hovering",
        "pressed",
        "held",
        "released",
        "wheel",
        "clicked",
        "dragging",
        "captured",
        "dismissed",
    };
};

pub const ControlState = struct {
    disabled: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    selected: bool = false,
    checked: bool = false,
};

/// Publish every semantic visual state, including false, from the control's actual
/// owner. These values survive into the next event stage but never self-toggle/latch.
pub fn publishControlState(ctx: *UiCtx, key: u64, state: ControlState) void {
    ctx.setFlag(key, .disabled, state.disabled);
    ctx.setFlag(key, .focused, state.focused);
    ctx.setFlag(key, .focus_visible, state.focus_visible);
    ctx.setFlag(key, .selected, state.selected);
    ctx.setFlag(key, .checked, state.checked);
}

/// Concrete UI context type, bound here where `ui` and `res` meet.
pub const UiCtx = ui.Ctx(UiState, Interaction, Resources);

/// Node Binding
pub const icon_cell = 512.0;
pub const Sprite = struct {
    texture: sdl.render.Texture,
    src: ?sdl.rect.FRect = null,
};
/// A stroked border for the `outline` feature. `width` is the bar thickness in px (drawn
/// *inward*, so it never grows the node's box); `style` picks solid / dashed / dotted. The
/// whole feature payload, so a caller can vary thickness and pattern per node — see
/// `features/outline.zig` for how each `style` rasterizes. Defaults (`width = 1`, `.solid`)
/// reproduce the old 1px box border.
pub const LineStyle = enum { solid, dashed, dotted };
pub const Outline = struct {
    color: Color,
    width: f32 = 1,
    style: LineStyle = .solid,
};

/// Name one cell of the shared icon sheet by grid (col, row). The single place that
/// knows the sheet lives on `res.platform.icons` and how big a cell is — callers reference a
/// cell, not a texture+rect, so the spritesheet isn't threaded through every icon.
pub fn icon_sprite(res: *Resources, col: f32, row: f32) Sprite {
    return .{
        .texture = res.platform.icons,
        .src = .{ .x = col * icon_cell, .y = row * icon_cell, .w = icon_cell, .h = icon_cell },
    };
}

/// Host-defined render descriptor carried on every node (policy — core stores it
/// opaquely, never reads it). One field per **paint feature** (`ui_client/features/`):
/// each is an *optional payload* — present ⟹ draw that aspect, and the value is the
/// payload the feature's `draw` needs (a `Color` to paint in, a `Sprite` to blit).
/// Composable: a node can set several at once. Hand-written (not generated), but kept
/// honest by `features.assertFeature`, which fails to compile if a listed feature's
/// `name`/`Payload` doesn't match a field here. Field *order* is irrelevant — the draw
/// z-order is the feature `list`'s order, not this struct's. Add a feature: add its
/// module to `features/`, list it, and add the matching field here — no engine change.
///
/// Overflow/clip is **not** here — it moved to `Layout.overflow` (it's geometry read by
/// the render walk *and* hit-testing, not a paint aspect). See `src/ui/features/layout.zig`.
pub const RenderData = struct {
    text: ?Color = null, // cached glyphs (in node.state(TextState)), blit in this color
    fill: ?Color = null, // solid rect spanning the node's resolved box, in this color
    outline: ?Outline = null, // stroked border (color + width + solid/dashed/dotted), drawn inward
    img: ?Sprite = null, // textured draw (texture + optional sheet cell), blit over the node's box
    svg: ?Color = null, // cached SVG raster (in node.state(SvgState)), tinted this color
    line: ?Stroke = null, // polyline through node.state(LineState)'s points, in this stroke
};

/// Concrete node type for this host, bound to the host's `RenderData`. Persistent
/// per-node state (the glyph surface, an svg raster) lives in a `UiState` pool keyed by
/// `node.key`, reached lazily via `node.state(u, T)` — the node itself holds no handle.
pub const Node = ui.Node(RenderData);

test "pointer states reset while authoritative control states persist and republish false" {
    // res/arena are untouched by the interaction methods, so `undefined` is safe.
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const k = ui.key(0, "btn");
    u.setFlag(k, .hovering, true);
    u.setFlag(k, .pressed, true);
    u.setFlag(k, .held, true);
    u.setFlag(k, .released, true);
    u.setFlag(k, .wheel, true);
    u.setFlag(k, .clicked, true);
    u.setFlag(k, .dragging, true);
    u.setFlag(k, .captured, true);
    u.setFlag(k, .dismissed, true);
    publishControlState(&u, k, .{
        .disabled = true,
        .focused = true,
        .focus_visible = true,
        .selected = true,
        .checked = true,
    });

    const on = u.interactionOf(k);
    try std.testing.expect(on.hovering and on.pressed and on.held and on.released and on.wheel and on.clicked);
    try std.testing.expect(on.dragging and on.captured and on.dismissed);
    try std.testing.expect(on.disabled and on.focused and on.focus_visible and on.selected and on.checked);

    u.clearTransient();
    const after = u.interactionOf(k);
    try std.testing.expect(!after.hovering and !after.pressed and !after.held and !after.released and !after.wheel and !after.clicked);
    try std.testing.expect(!after.dragging and !after.captured and !after.dismissed);
    try std.testing.expect(after.disabled and after.focused and after.focus_visible and after.selected and after.checked);

    publishControlState(&u, k, .{});
    const cleared = u.interactionOf(k);
    try std.testing.expect(!cleared.disabled and !cleared.focused and !cleared.focus_visible and !cleared.selected and !cleared.checked);
}

test "control activation marks press immediately and click once on valid release" {
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const parent = ui.key(0, "activation-parent");
    const control = ui.key(parent, "activation-control");
    _ = u.interactionOf(parent);
    _ = u.stampRect(parent, .{ .x = 0, .y = 0, .w = 100, .h = 40 }, null, null);
    _ = u.interactionOf(control);
    _ = u.stampRect(control, .{ .x = 60, .y = 0, .w = 40, .h = 40 }, null, parent);

    var gesture: @import("activation.zig").PointerActivation = .{};
    const pressed_target = u.markTarget(.pressed, 80, 20);
    gesture.press(pressed_target, .mouse, 1, .{ .x = 80, .y = 20 });
    try std.testing.expect(u.interactionOf(control).pressed);
    try std.testing.expect(u.interactionOf(parent).pressed);
    try std.testing.expect(!u.interactionOf(control).clicked);

    try std.testing.expectEqual(@as(?u64, control), u.markTarget(.released, 80, 20));
    try std.testing.expect(u.interactionOf(control).released);
    try std.testing.expect(u.interactionOf(parent).released);
    try std.testing.expect(!u.interactionOf(control).clicked);
    if (gesture.release(u.targetAt(80, 20), .mouse, 1, .{ .x = 80, .y = 20 })) |key| {
        try std.testing.expect(u.markKey(key, .clicked));
    }
    try std.testing.expect(u.interactionOf(control).clicked);
    try std.testing.expect(u.interactionOf(parent).clicked);
    try std.testing.expectEqual(@as(?u64, null), gesture.release(u.targetAt(80, 20), .mouse, 1, .{ .x = 80, .y = 20 }));
}

test "held dragging and captured states follow pointer owners and reset" {
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const key = ui.key(0, "drag-owner");
    _ = u.interactionOf(key);
    _ = u.stampRect(key, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, null, null);

    var gesture: @import("activation.zig").PointerActivation = .{};
    gesture.press(key, .mouse, 1, .{ .x = 5, .y = 5 });
    try std.testing.expect(u.markKey(gesture.pressedKey().?, .held));
    gesture.motion(.mouse, 1, .{ .x = 10, .y = 5 });
    try std.testing.expect(u.markKey(gesture.draggingKey().?, .dragging));
    try std.testing.expect(u.capturePointer(key));
    u.setFlag(u.capturedPointerKey().?, .captured, true);

    const on = u.interactionOf(key);
    try std.testing.expect(on.held and on.dragging and on.captured);
    u.clearTransient();
    const cleared = u.interactionOf(key);
    try std.testing.expect(!cleared.held and !cleared.dragging and !cleared.captured);
}
