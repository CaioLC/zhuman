/// A simple counter
pub const Counter = struct {
    v: f32,

    pub fn init(v: f32) Counter {
        return Counter{
            .v = v,
        };
    }

    pub fn update(self: *Counter, dt: f32) void {
        self.v += dt;
    }

    pub fn set(self: *Counter, v: f32) void {
        self.v = v;
    }

    pub fn get(self: Counter) f32 {
        return self.v;
    }
};

/// A simple timer
pub const Timer = struct {
    v: f32,
    start: f32,
    end: f32,

    pub fn init(start: f32, end: ?f32) Timer {
        const safe_end = end orelse 0.0;
        return Timer{
            .v = start,
            .start = start,
            .end = safe_end,
        };
    }

    pub fn update(self: *Timer, dt: f32) void {
        if (self.v > self.end) {
            self.v -= dt;
        }
        if (self.v < self.end) {
            self.v = self.end;
        }
    }

    pub fn reset(self: *Timer) void {
        self.v = self.start;
    }

    pub fn get(self: Timer) f32 {
        return self.v;
    }
};