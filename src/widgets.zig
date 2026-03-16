const std = @import("std");
const ui = @import("./ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("./font.zig");

const white = zfont.white;

// --- UiCtx: shared context bound to Runtime ---
pub const UiCtx = struct {
    font: *sdl.ttf.Font,
    renderer: *const sdl.render.Renderer,
    window: sdl.video.Window,
};

pub fn screen_size(raw_ctx: *anyopaque, _: *ui.Node) anyerror!struct { f32, f32 } {
    const ctx: *UiCtx = @ptrCast(@alignCast(raw_ctx));
    const width, const height = try ctx.window.getSize();
    return .{ @floatFromInt(width), @floatFromInt(height) };
}

pub const TextData = struct {
    buf: [64]u8,
    fmt_text: ?[]const u8,
    surface: ?sdl.surface.Surface,

    pub fn create(allocator: std.mem.Allocator) !*TextData {
        const self = try allocator.create(TextData);
        self.* = .{ .buf = undefined, .fmt_text = null, .surface = null };
        return self;
    }
    pub fn deinit(allocator: std.mem.Allocator, raw: *anyopaque) void {
        const self: *TextData = @ptrCast(@alignCast(raw));
        if (self.surface) |*surf| {
            surf.deinit();
        }
        allocator.destroy(self);
    }
    pub fn update(self: *TextData, fmt_text: []const u8) void {
        self.fmt_text = fmt_text;
        if (self.surface) |surf| {
            surf.deinit();
        }
        self.surface = null;
    }
};

pub fn calc_size_text(raw_ctx: *anyopaque, node: *ui.Node) anyerror!struct { f32, f32 } {
    const ctx: *UiCtx = @ptrCast(@alignCast(raw_ctx));
    const data = node.data orelse {
        std.log.err("Attempted rendering node with no text data.", .{});
        return error.NoDataToRender;
    };
    const text_data: *TextData = @ptrCast(@alignCast(data));
    const surface = text_data.surface orelse blk: {
        const fmt = text_data.fmt_text orelse return error.NoDataToRender;
        const surf = try ctx.font.renderTextSolid(fmt, white);
        text_data.surface = surf;
        break :blk surf;
    };
    return .{ @floatFromInt(surface.getWidth()), @floatFromInt(surface.getHeight()) };
}

pub fn sdl_render_text(raw_ctx: *anyopaque, node: *ui.Node) void {
    const ctx: *UiCtx = @ptrCast(@alignCast(raw_ctx));
    const pos = node.position orelse return;
    const data = node.data orelse return;
    const text_data: *TextData = @ptrCast(@alignCast(data));

    const surface = text_data.surface orelse blk: {
        const fmt = text_data.fmt_text orelse return;
        const surf = ctx.font.renderTextSolid(fmt, white) catch return;
        text_data.surface = surf;
        break :blk surf;
    };
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
