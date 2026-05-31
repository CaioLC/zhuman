const std = @import("std");
const ui = @import("./ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("./font.zig");
const Resources = @import("./res.zig").Resources;

/// The registry of widget-state types kept in the UI cache. One `Pool(T)` is
/// generated per declaration. This is where the generic `ui` engine meets the
/// concrete state types — see docs/ui-building-language-plan.md. (Interaction
/// state is engine-owned on `Ui`, not registered here.)
pub const UiState = struct {
    pub const TextData = zfont.TextData;
};

/// Concrete UI context type, bound here where `ui`, `font` and `res` all meet.
pub const Ui = ui.Ui(UiState, Resources);

const TextData = zfont.TextData;

// --- Text widget callbacks ---------------------------------------------------
// The ctx passed to render/size is `*Ui`. Each callback resolves its own state
// from the cache via `node.state` (the handle), supplying the concrete type.

fn text_calc_size(raw_ctx: *anyopaque, node: *ui.Node) anyerror!struct { f32, f32 } {
    const u: *Ui = @ptrCast(@alignCast(raw_ctx));
    const idx = node.state orelse return .{ 0, 0 };
    const td = u.pool(TextData).get(idx);
    const fmt = td.text() orelse return .{ 0, 0 };
    const w, const h = try u.res.font.getStringSize(fmt);
    return .{ @floatFromInt(w), @floatFromInt(h) };
}

fn text_render(raw_ctx: *anyopaque, node: *ui.Node) void {
    const u: *Ui = @ptrCast(@alignCast(raw_ctx));
    const idx = node.state orelse return;
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
// persistent state from the cache, builds an ephemeral arena node, and attaches
// itself to `parent`. Interactive widgets carry a `key` (so the event-stage
// `mark_*` walks can flag them) and stamp their `Interaction` from the store.

/// Build a `.relative` text node, cache+update its `TextData`, attach to parent.
fn make_text(u: *Ui, parent: *ui.Node, seed: u64, id: []const u8, text: []const u8) !*ui.Node {
    const k = ui.key(seed, id);
    const idx = u.cache(k, TextData);
    u.pool(TextData).get(idx).update(text);

    const node = try ui.Node.create(u.arena, id);
    _ = node.with_size(ui.Size.init(&text_calc_size, null));
    _ = node.with_render(ui.OnRender.init(&text_render));
    _ = node.with_layout(ui.Layout.init(.relative, null));
    node.state = idx;
    try parent.add_child(u.arena, node);
    return node;
}

/// A non-interactive text leaf. `text` is copied into the cached `TextData`, so
/// a build-time slice (e.g. a stack `bufPrint`) is safe to pass.
pub fn label(u: *Ui, parent: *ui.Node, seed: u64, id: []const u8, text: []const u8) !void {
    _ = try make_text(u, parent, seed, id, text);
}

test "interaction store: active latches, transient flags clear each frame" {
    // res/arena are untouched by the interaction methods, so `undefined` is safe.
    var u = Ui.init(undefined, std.testing.allocator, undefined);
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

/// An interactive text leaf. Carries a `key` so the event-stage `mark_*` walks
/// can flag it, and stamps its `Interaction` from the store. The flags reflect
/// the previous frame's geometry against this frame's input (immediate-mode's
/// inherent one-frame delay). Read inline: `if ((try button(..)).clicked)`.
pub fn button(u: *Ui, parent: *ui.Node, seed: u64, id: []const u8, text: []const u8) !ui.Interaction {
    const node = try make_text(u, parent, seed, id, text);
    node.key = ui.key(seed, id); // opt-in: only keyed nodes are marked/queryable
    return u.interactionOf(node.key.?); // read-through: allocates/keeps the slot
}
