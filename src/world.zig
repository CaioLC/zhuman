const time = @import("./time.zig");

pub fn FixedList(comptime T: type, comptime cap: usize) type {
    return struct {
        buf: [cap]T = undefined,
        len: usize = 0,

        pub fn slice(self: *@This()) []T {
            return self.buf[0..self.len];
        }

        pub fn constSlice(self: *const @This()) []const T {
            return self.buf[0..self.len];
        }

        pub fn append(self: *@This(), v: T) !void {
            if (self.len >= cap) return error.Overflow;
            self.buf[self.len] = v;
            self.len += 1;
        }
    };
}

pub const Producer = struct {
    value: time.Accumulator(i32),
};

pub const Consumer = struct {
    value: time.Accumulator(i32),
};

pub const World = struct {
    producers: FixedList(Producer, 64),
    consumers: FixedList(Consumer, 64),

    pub fn init() World {
        return .{
            .producers = .{},
            .consumers = .{},
        };
    }

    pub fn deinit(_: *World) void {}
};
