const std = @import("std");
const ui = @import("./ui/root.zig");
const sdl = @import("sdl3");
const zfont = @import("./font.zig");
const Resources = @import("./res.zig").Resources;

pub const DataType = enum { text, sprite };

pub const Data = union(DataType) {
    text: zfont.TextData,
    sprite: void,

    pub fn init(data_type: DataType) Data {
        return switch (data_type) {
            .text => .{ .text = zfont.TextData.init() },
            .sprite => @panic("sprite not yet implemented"),
        };
    }
};

fn wire_data_node(node: *ui.Node, data: *Data) void {
    switch (data.*) {
        .text => |*t| {
            _ = node.with_data(@ptrCast(t));
            _ = node.with_size(ui.Size.init(&zfont.TextData.calc_size, null));
            _ = node.with_render(ui.OnRender.init(&zfont.TextData.render_text));
        },
        .sprite => @panic("sprite not yet implemented"),
    }
}

pub const El = struct {
    node: ui.Node,
    data: Data,

    pub fn init(id: []const u8, data_type: DataType) El {
        return .{
            .node = ui.Node.init(id),
            .data = Data.init(data_type),
        };
    }

    pub fn wire(self: *El) void {
        wire_data_node(&self.node, &self.data);
    }
};

pub const Button = struct {
    node: ui.Node,
    data: Data,
    on_click: ui.OnClick,

    pub fn init(id: []const u8, on_click: ui.OnClick, data_type: DataType) Button {
        return .{
            .node = ui.Node.init(id),
            .data = Data.init(data_type),
            .on_click = on_click,
        };
    }

    pub fn wire(self: *Button) void {
        wire_data_node(&self.node, &self.data);
        _ = self.node.with_onclick(self.on_click);
    }
};
