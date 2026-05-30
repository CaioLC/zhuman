const std = @import("std");
const ui = @import("./ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("./font.zig");
const Resources = @import("./res.zig").Resources;

/// The registry of widget-state types kept in the UI cache. One `Pool(T)` is
/// generated per declaration. This is where the generic `ui` engine meets the
/// concrete state types — see docs/ui-building-language-plan.md.
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
// Each takes `(seed, id)`, computes its own key `k`, self-serves persistent
// state from the cache, builds an ephemeral arena node, and returns it.

/// A text leaf. `text` is copied into the cached `TextData`, so a build-time
/// slice (e.g. a stack `bufPrint`) is safe to pass.
pub fn label(u: *Ui, seed: u64, id: []const u8, text: []const u8) !*ui.Node {
    const k = ui.key(seed, id);
    const idx = u.cache(k, TextData);
    u.pool(TextData).get(idx).update(text);

    const node = try ui.Node.create(u.arena, id);
    _ = node.with_size(ui.Size.init(&text_calc_size, null));
    _ = node.with_render(ui.OnRender.init(&text_render));
    node.state = idx;
    return node;
}

/// A clickable text leaf. (Step 2: still wired via `OnClick`; becomes a `Comm`
/// return in Step 3.)
pub fn button(u: *Ui, seed: u64, id: []const u8, text: []const u8, on_click: ui.OnClick) !*ui.Node {
    const node = try label(u, seed, id, text);
    _ = node.with_onclick(on_click);
    return node;
}
