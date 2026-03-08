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

pub const Clickable = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        on_click: *const fn (*anyopaque, ClickEvent) void,
    };

    pub fn on_click(self: Clickable, event: ClickEvent) void {
        self.vtable.on_click(self.ptr, event);
    }

    pub fn init(pointer: anytype) Clickable {
        const Ptr = @TypeOf(pointer);
        const ptr_info = @typeInfo(Ptr);

        comptime std.debug.assert(ptr_info == .pointer);
        comptime std.debug.assert(ptr_info.pointer.size == .one);

        const impl = struct {
            fn on_click(p: *anyopaque, event: ClickEvent) void {
                const self: Ptr = @ptrCast(@alignCast(p));
                self.on_click(event);
            }
        };

        return .{
            .ptr = pointer,
            .vtable = &.{
                .on_click = impl.on_click,
            },
        };
    }
};

test "clickable vtable dispatch" {
    const TestHandler = struct {
        called: bool = false,
        last_button: MouseButton = .other,

        pub fn on_click(self: *@This(), event: ClickEvent) void {
            self.called = true;
            self.last_button = event.button;
        }
    };

    var handler = TestHandler{};
    const clickable = Clickable.init(&handler);

    clickable.on_click(.{ .x = 10.0, .y = 20.0, .button = .left });

    try std.testing.expect(handler.called);
    try std.testing.expectEqual(MouseButton.left, handler.last_button);
}
