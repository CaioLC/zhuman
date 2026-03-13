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

    pub fn typed(comptime T: type, comptime func: *const fn (*T, ClickEvent) void, data: *T) OnClick {
        const wrapper = struct {
            fn run(raw: ?*anyopaque, event: ClickEvent) void {
                const typed_data: *T = @ptrCast(@alignCast(raw orelse return));
                func(typed_data, event);
            }
        };
        return .{ .run = &wrapper.run, .data = @ptrCast(data) };
    }

    pub fn invoke(self: OnClick, event: ClickEvent) void {
        self.run(self.data, event);
    }
};
