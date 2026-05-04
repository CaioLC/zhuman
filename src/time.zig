pub fn Accumulator(comptime T: type) type {
    return struct {
        v: T,
    };
}

pub const Counter = struct {
    v: f32,
};

pub const Timer = struct {
    v: f32,
    start: f32,
    end: f32,
};
