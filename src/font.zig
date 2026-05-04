const std = @import("std");
const sdl3 = @import("sdl3");
const ui = @import("./ui/root.zig");
const Resources = @import("./res.zig").Resources;

pub const white: sdl3.ttf.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

pub const TextData = struct {
    buf: [64]u8,
    fmt_text: ?[]const u8,

    pub fn init() TextData {
        return .{ .buf = undefined, .fmt_text = null };
    }

    pub fn update(self: *TextData, fmt_text: []const u8) void {
        self.fmt_text = fmt_text;
    }

    pub fn calc_size(raw_ctx: *anyopaque, node: *ui.Node) anyerror!struct { f32, f32 } {
        const ctx: *Resources = @ptrCast(@alignCast(raw_ctx));
        const data: *const TextData = @ptrCast(@alignCast(node.data orelse return .{ 0, 0 }));
        const fmt = data.fmt_text orelse return .{ 0, 0 };
        const w, const h = try ctx.font.getStringSize(fmt);
        return .{ @floatFromInt(w), @floatFromInt(h) };
    }

    pub fn render_text(raw_ctx: *anyopaque, node: *ui.Node) void {
        const ctx: *Resources = @ptrCast(@alignCast(raw_ctx));
        const data: *const TextData = @ptrCast(@alignCast(node.data orelse return));
        const s = node.size orelse return;
        const l = node.layout orelse return;
        const fmt = data.fmt_text orelse return;
        var surface = ctx.font.renderTextSolid(fmt, white) catch return;
        defer surface.deinit();
        const texture = ctx.renderer.createTextureFromSurface(surface) catch return;
        defer texture.deinit();

        const dst = sdl3.rect.FRect{
            .x = (l._global_x orelse return) + s.padding.left,
            .y = (l._global_y orelse return) + s.padding.up,
            .w = s.data_width,
            .h = s.data_height,
        };
        ctx.renderer.renderTexture(texture, null, dst) catch return;
    }
};
