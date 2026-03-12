const std = @import("std");
const ui = @import("./ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("./font.zig");

const white = zfont.white;

// --- TextNode: a cached text display driven by a dynamic value ---

pub const TextNode = struct {
    value: *const fn (*anyopaque) f32,
    source: *anyopaque,
    label: []const u8,
    cached_surface: ?sdl.surface.Surface,
    last_value: f32,

    pub fn format_text(self: *TextNode, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s} {}", .{
            self.label,
            @trunc(self.value(self.source)),
        }) catch null;
    }

    pub fn refresh(self: *TextNode, font: *sdl.ttf.Font) void {
        const current = self.value(self.source);
        if (self.cached_surface != null and current == self.last_value) return;
        if (self.cached_surface) |*s| s.deinit();
        var text_buffer: [64]u8 = undefined;
        const text = self.format_text(&text_buffer) orelse return;
        self.cached_surface = font.renderTextSolid(text, white) catch null;
        self.last_value = current;
    }

    pub fn deinit(self: *TextNode) void {
        if (self.cached_surface) |*s| s.deinit();
        self.cached_surface = null;
    }
};

pub fn render_text_node(node: *ui.Node, ctx: ?*anyopaque) void {
    const ui_ctx: *UiCtx = @ptrCast(@alignCast(ctx orelse return));
    const tn: *TextNode = @ptrCast(@alignCast(node.data orelse return));
    const pos = node.position orelse return;
    tn.refresh(ui_ctx.font);
    const surface = tn.cached_surface orelse return;
    const texture = ui_ctx.renderer.createTextureFromSurface(surface) catch return;
    defer texture.deinit();
    const dst = sdl.rect.FRect{
        .x = (pos._global_x orelse return) + pos.padding.left,
        .y = (pos._global_y orelse return) + pos.padding.up,
        .w = pos.data_width,
        .h = pos.data_height,
    };
    ui_ctx.renderer.renderTexture(texture, null, dst) catch return;
}

pub fn calc_text_node_pos(node: *ui.Node, ctx: ?*anyopaque) struct { f32, f32 } {
    const ui_ctx: *UiCtx = @ptrCast(@alignCast(ctx orelse return .{ 0, 0 }));
    const tn: *TextNode = @ptrCast(@alignCast(node.data orelse return .{ 0, 0 }));
    tn.refresh(ui_ctx.font);
    const surface = tn.cached_surface orelse return .{ 0, 0 };
    return .{ @floatFromInt(surface.getWidth()), @floatFromInt(surface.getHeight()) };
}

// --- UiCtx: shared context bound to Runtime ---

pub const UiCtx = struct {
    font: *sdl.ttf.Font,
    renderer: *const sdl.render.Renderer,
};

// --- button: convenience constructor for clickable nodes ---

pub fn button(
    allocator: std.mem.Allocator,
    id: []const u8,
    position: ui.Position,
    on_click: ui.features.OnClick,
) !*ui.Node {
    const node = try allocator.create(ui.Node);
    node.* = ui.Node.init(id);
    _ = node
        .with_position(position)
        .with_onclick(on_click);
    return node;
}
