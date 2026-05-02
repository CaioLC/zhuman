const std = @import("std");
const ui = @import("./ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("./font.zig");
const res = @import("./res.zig");
const white = zfont.white;
const TextData = zfont.TextData;
const TextDataStatic = zfont.TextDataStatic;
const Resources = res.Resources;

pub fn screen_size(raw_ctx: *anyopaque, _: *ui.Node) anyerror!struct { f32, f32 } {
    const ctx: *Resources = @ptrCast(@alignCast(raw_ctx));
    const width, const height = try ctx.window.getSize();
    return .{ @floatFromInt(width), @floatFromInt(height) };
}

fn calc_size_text_impl(comptime T: type, raw_ctx: *anyopaque, node: *ui.Node) anyerror!struct { f32, f32 } {
    const ctx: *Resources = @ptrCast(@alignCast(raw_ctx));
    const data = node.data orelse {
        std.log.err("Attempted rendering node with no text data.", .{});
        return error.NoDataToRender;
    };
    const text_data: *T = @ptrCast(@alignCast(data));
    const surface = text_data.surface orelse blk: {
        const fmt = text_data.fmt_text orelse return error.NoDataToRender;
        const surf = try ctx.font.renderTextSolid(fmt, white);
        text_data.surface = surf;
        break :blk surf;
    };
    return .{ @floatFromInt(surface.getWidth()), @floatFromInt(surface.getHeight()) };
}

pub fn calc_size_text(raw_ctx: *anyopaque, node: *ui.Node) anyerror!struct { f32, f32 } {
    return calc_size_text_impl(TextData, raw_ctx, node);
}

pub fn calc_size_text_static(raw_ctx: *anyopaque, node: *ui.Node) anyerror!struct { f32, f32 } {
    return calc_size_text_impl(TextDataStatic, raw_ctx, node);
}

fn render_text_impl(comptime T: type, raw_ctx: *anyopaque, node: *ui.Node) void {
    const ctx: *Resources = @ptrCast(@alignCast(raw_ctx));
    const pos = node.position orelse return;
    const data = node.data orelse return;
    const text_data: *T = @ptrCast(@alignCast(data));

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

pub fn sdl_render_text(raw_ctx: *anyopaque, node: *ui.Node) void {
    render_text_impl(TextData, raw_ctx, node);
}

pub fn sdl_render_text_static(raw_ctx: *anyopaque, node: *ui.Node) void {
    render_text_impl(TextDataStatic, raw_ctx, node);
}
