const std = @import("std");
const ui = @import("./ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("./font.zig");

const white = zfont.white;

// --- TextNode: dynamic text, re-rasterized every frame ---
pub fn TextNode(comptime Source: type, comptime Ctx: type) type {
    return struct {
        const Self = @This();

        format: *const fn (*Source, []u8) ?[]const u8,
        source: *Source,

        pub fn renderSurface(self: *Self, font: *sdl.ttf.Font) ?sdl.surface.Surface {
            var text_buffer: [256]u8 = undefined;
            const text = self.format(self.source, &text_buffer) orelse return null;
            return font.renderTextSolid(text, white) catch null;
        }

        pub fn deinit_node(allocator: std.mem.Allocator, data: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(data));
            allocator.destroy(self);
        }

        pub fn render(node: *ui.Node, raw_ctx: ?*anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw_ctx orelse return));
            const self: *Self = @ptrCast(@alignCast(node.data orelse return));
            const pos = node.position orelse return;
            var surface = self.renderSurface(ctx.font) orelse return;
            defer surface.deinit();
            const texture = ctx.renderer.createTextureFromSurface(surface) catch return;
            defer texture.deinit();
            const dst = sdl.rect.FRect{
                .x = (pos._global_x orelse return) + pos.padding.left,
                .y = (pos._global_y orelse return) + pos.padding.up,
                .w = pos.data_width,
                .h = pos.data_height,
            };
            ctx.renderer.renderTexture(texture, null, dst) catch return;
        }

        pub fn calc_pos(node: *ui.Node, raw_ctx: ?*anyopaque) struct { f32, f32 } {
            const ctx: *Ctx = @ptrCast(@alignCast(raw_ctx orelse return .{ 0, 0 }));
            const self: *Self = @ptrCast(@alignCast(node.data orelse return .{ 0, 0 }));
            var surface = self.renderSurface(ctx.font) orelse return .{ 0, 0 };
            defer surface.deinit();
            return .{ @floatFromInt(surface.getWidth()), @floatFromInt(surface.getHeight()) };
        }
    };
}

// --- TextNodeStatic: rasterized once, reused every frame ---
pub fn TextNodeStatic(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        text: []const u8,
        surface: ?sdl.surface.Surface,

        pub fn renderSurface(self: *Self, font: *sdl.ttf.Font) ?sdl.surface.Surface {
            if (self.surface) |s| return s;
            self.surface = font.renderTextSolid(self.text, white) catch null;
            return self.surface;
        }

        pub fn deinit_node(allocator: std.mem.Allocator, data: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(data));
            self.deinit();
            allocator.destroy(self);
        }

        pub fn deinit(self: *Self) void {
            if (self.surface) |*s| s.deinit();
            self.surface = null;
        }

        pub fn render(node: *ui.Node, raw_ctx: ?*anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw_ctx orelse return));
            const self: *Self = @ptrCast(@alignCast(node.data orelse return));
            const pos = node.position orelse return;
            const surface = self.renderSurface(ctx.font) orelse return;
            const texture = ctx.renderer.createTextureFromSurface(surface) catch return;
            defer texture.deinit();
            const dst = sdl.rect.FRect{
                .x = (pos._global_x orelse return) + pos.padding.left,
                .y = (pos._global_y orelse return) + pos.padding.up,
                .w = pos.data_width,
                .h = pos.data_height,
            };
            ctx.renderer.renderTexture(texture, null, dst) catch return;
        }

        pub fn calc_pos(node: *ui.Node, raw_ctx: ?*anyopaque) struct { f32, f32 } {
            const ctx: *Ctx = @ptrCast(@alignCast(raw_ctx orelse return .{ 0, 0 }));
            const self: *Self = @ptrCast(@alignCast(node.data orelse return .{ 0, 0 }));
            const surface = self.renderSurface(ctx.font) orelse return .{ 0, 0 };
            return .{ @floatFromInt(surface.getWidth()), @floatFromInt(surface.getHeight()) };
        }
    };
}

// --- UiCtx: shared context bound to Runtime ---
pub const UiCtx = struct {
    font: *sdl.ttf.Font,
    renderer: *const sdl.render.Renderer,
};
