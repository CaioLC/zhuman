//! Implement Concrete Types for the Ui-Engine generic types

const std = @import("std");
const ui = @import("../ui/root.zig");
const sdl = @import("sdl3");
const theme = @import("../theme.zig");
const Resources = @import("../res.zig").Resources;

/// The host color type, re-exposed here so the whole `ui_client` layer names one `Color`
/// (SDL's `pixels.Color`) — the engine carries it opaquely on `RenderData` and never
/// reads it. Defined in `theme.zig` (the color leaf); aliased here for the features/widgets.
pub const Color = theme.Color;

/// Context Binding
/// The registry of widget-state (render-state) types kept in the UI cache. One
/// `Pool(T)` is generated per declaration. This is where the generic `ui` engine
/// meets the concrete state types — see docs/ui-building-language-plan.md.
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
        /// the size travels from build to the feature's `draw`, which renders at it. Pool
        /// slots are zero-initialized, so `attach` (run every frame before `draw`) always
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
    /// A scroll container's persisted offset (px), keyed by its own `node.key` — survives
    /// the frame-arena reset the same way `TextData` does. See `scroll_view`.
    pub const ScrollState = struct { offset: f32 = 0 };
    /// A tab strip's persisted selection (an index into its labels), keyed by the strip's
    /// own `node.key` — same pattern as `ScrollState`. NOTE: pool slots are seeded with
    /// `std.mem.zeroes`, not the struct's field defaults — a fresh strip always starts on
    /// tab 0, and a non-zero "default tab" would need the template to set it explicitly.
    pub const TabsState = struct { active: usize = 0 };
    /// A `text_input`'s persisted UTF-8 buffer, keyed by its own `node.key`. `main.zig`'s
    /// event loop appends `.text_input` events and handles backspace directly against
    /// whichever field `Resources.focused_text` names — the widget itself only reads it
    /// to render. See `text_input`.
    pub const TextInputState = struct { buf: [64]u8 = undefined, len: usize = 0 };
    /// The `svg` feature's cached rasterization (see `ui_client/features/svg.zig`): the
    /// texture SDL_image produced for the current source+size, plus the `src_key` hash
    /// that produced it — so the feature's `attach` re-rasterizes only when the source
    /// or target size changes. Unlike the POD states above, this **owns a GPU resource**,
    /// so it declares `deinit`: the pool's eviction hook (`cache.zig`) frees the texture
    /// when the node disappears or the app tears down. Without it, the texture would leak
    /// every time a scrolled-away / closed SVG node's slot is pruned. `src_key == 0` means
    /// "nothing rasterized yet" (a fresh, zero-initialized slot).
    pub const SvgState = struct {
        src_key: u64 = 0,
        tex: ?sdl.render.Texture = null,
        pub fn deinit(self: *SvgState) void {
            if (self.tex) |t| t.deinit();
            self.tex = null;
        }
    };
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
/// knows the sheet lives on `res.icons` and how big a cell is — callers reference a
/// cell, not a texture+rect, so the spritesheet isn't threaded through every icon.
pub fn icon_sprite(res: *Resources, col: f32, row: f32) Sprite {
    return .{
        .texture = res.icons,
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
};

/// Concrete node type for this host, bound to the host's `RenderData`. Persistent
/// per-node state (the glyph surface, an svg raster) lives in a `UiState` pool keyed by
/// `node.key`, reached lazily via `node.state(u, T)` — the node itself holds no handle.
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
