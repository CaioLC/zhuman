const std = @import("std");
const ui = @import("./ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("./font.zig");
const Resources = @import("./res.zig").Resources;

/// A widget's last-laid-out screen rect, cached for next-frame hit-testing.
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

/// Interaction result for a widget this frame (read inline at build time).
pub const Comm = struct {
    clicked: bool = false,
    hovering: bool = false,
};

/// The registry of widget-state types kept in the UI cache. One `Pool(T)` is
/// generated per declaration. This is where the generic `ui` engine meets the
/// concrete state types — see docs/ui-building-language-plan.md.
pub const UiState = struct {
    pub const TextData = zfont.TextData;
    pub const InteractionRect = Rect;
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
// itself to `parent`. Interactive widgets read input inline and return a `Comm`.

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

/// A clickable text leaf. Returns this frame's `Comm`, hit-tested against the
/// previous frame's cached rect — read it inline: `if ((try button(..)).clicked)`.
pub fn button(u: *Ui, parent: *ui.Node, seed: u64, id: []const u8, text: []const u8) !Comm {
    const node = try make_text(u, parent, seed, id, text);
    const k = ui.key(seed, id);
    node.key = k; // enables rect capture + comm
    return comm(u, k);
}

/// Hit-test a widget's previous-frame rect against the current mouse state.
fn comm(u: *Ui, k: u64) Comm {
    const idx = u.cache(k, Rect); // ensure the slot exists and is kept alive
    const r = u.pool(Rect).get(idx).*; // zeroed on the first frame → no hit
    const inside = u.input.mouse_x >= r.x and u.input.mouse_x <= r.x + r.w and
        u.input.mouse_y >= r.y and u.input.mouse_y <= r.y + r.h;
    return .{ .hovering = inside, .clicked = inside and u.input.mouse_down };
}

/// Post-layout: store each interactive node's resolved rect into the cache, for
/// next frame's `comm` to hit-test against. Call once after `set_global_pos`.
pub fn capture_rects(u: *Ui, node: *ui.Node) void {
    if (node.key) |k| {
        if (node.size) |s| if (node.layout) |l| {
            const idx = u.cache(k, Rect);
            u.pool(Rect).get(idx).* = .{
                .x = l._global_x orelse 0,
                .y = l._global_y orelse 0,
                .w = s.width,
                .h = s.height,
            };
        };
    }
    for (node.children.items) |child| capture_rects(u, child);
}
