const std = @import("std");

pub const MouseButton = enum {
    left,
    middle,
    right,
    other,
};

pub const ClickEvent = struct {
    x: f32,
    y: f32,
    button: MouseButton,
};

pub const OnClick = struct {
    run: *const fn (?*anyopaque, ClickEvent) void,
    data: ?*anyopaque,

    pub fn init(func: *const fn (?*anyopaque, ClickEvent) void, data: ?*anyopaque) OnClick {
        return .{ .run = func, .data = data };
    }

    pub fn invoke(self: OnClick, event: ClickEvent) void {
        self.run(self.data, event);
    }
};
