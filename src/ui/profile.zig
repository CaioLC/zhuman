const std = @import("std");

/// Nanoseconds spent in the five UI passes relevant to stamping decisions.
pub const Sample = struct {
    intrinsic: u64 = 0,
    relative: u64 = 0,
    placement: u64 = 0,
    stamping: u64 = 0,
    drawing: u64 = 0,

    pub fn add(self: *Sample, other: Sample) void {
        inline for (@typeInfo(Sample).@"struct".fields) |field| {
            @field(self, field.name) +|= @field(other, field.name);
        }
    }

    pub fn total(self: Sample) u64 {
        var result: u64 = 0;
        inline for (@typeInfo(Sample).@"struct".fields) |field| {
            result +|= @field(self, field.name);
        }
        return result;
    }
};

pub const Report = struct {
    frames: u64,
    total: Sample,
    average: Sample,
    maximum: Sample,

    /// Stamping's thousandths of the measured five-pass total (1000 == 100%).
    pub fn stampingPermille(self: Report) u64 {
        const all = self.total.total();
        if (all == 0) return 0;
        return @intCast((@as(u128, self.total.stamping) * 1000) / all);
    }
};

/// Low-overhead aggregate storage. Callers own clocks and pass exact durations, keeping
/// the profiler deterministic and the normal layout solver callback-free.
pub const FrameProfiler = struct {
    frames: u64 = 0,
    total: Sample = .{},
    maximum: Sample = .{},

    pub fn record(self: *FrameProfiler, sample: Sample) void {
        self.frames +|= 1;
        self.total.add(sample);
        inline for (@typeInfo(Sample).@"struct".fields) |field| {
            @field(self.maximum, field.name) = @max(@field(self.maximum, field.name), @field(sample, field.name));
        }
    }

    pub fn reset(self: *FrameProfiler) void {
        self.* = .{};
    }

    pub fn snapshot(self: FrameProfiler) ?Report {
        if (self.frames == 0) return null;
        var average: Sample = .{};
        inline for (@typeInfo(Sample).@"struct".fields) |field| {
            @field(average, field.name) = @field(self.total, field.name) / self.frames;
        }
        return .{ .frames = self.frames, .total = self.total, .average = average, .maximum = self.maximum };
    }

    /// Return and reset a report once `window` samples have accumulated.
    pub fn takeIfReady(self: *FrameProfiler, window: u64) ?Report {
        if (window == 0 or self.frames < window) return null;
        const report = self.snapshot().?;
        self.reset();
        return report;
    }
};

test "frame profiler aggregates averages maxima and stamping share" {
    var profiler: FrameProfiler = .{};
    try std.testing.expectEqual(@as(?Report, null), profiler.snapshot());

    profiler.record(.{ .intrinsic = 10, .relative = 20, .placement = 30, .stamping = 40, .drawing = 100 });
    profiler.record(.{ .intrinsic = 30, .relative = 40, .placement = 50, .stamping = 60, .drawing = 120 });

    const report = profiler.snapshot().?;
    try std.testing.expectEqual(@as(u64, 2), report.frames);
    try std.testing.expectEqual(Sample{ .intrinsic = 40, .relative = 60, .placement = 80, .stamping = 100, .drawing = 220 }, report.total);
    try std.testing.expectEqual(Sample{ .intrinsic = 20, .relative = 30, .placement = 40, .stamping = 50, .drawing = 110 }, report.average);
    try std.testing.expectEqual(Sample{ .intrinsic = 30, .relative = 40, .placement = 50, .stamping = 60, .drawing = 120 }, report.maximum);
    try std.testing.expectEqual(@as(u64, 200), report.stampingPermille());
}

test "report window resets only after becoming ready" {
    var profiler: FrameProfiler = .{};
    profiler.record(.{ .stamping = 7 });
    try std.testing.expectEqual(@as(?Report, null), profiler.takeIfReady(2));
    try std.testing.expectEqual(@as(u64, 1), profiler.frames);

    profiler.record(.{ .drawing = 3 });
    const report = profiler.takeIfReady(2).?;
    try std.testing.expectEqual(@as(u64, 2), report.frames);
    try std.testing.expectEqual(@as(u64, 7), report.total.stamping);
    try std.testing.expectEqual(@as(u64, 0), profiler.frames);
    try std.testing.expectEqual(@as(?Report, null), profiler.snapshot());
    try std.testing.expectEqual(@as(?Report, null), profiler.takeIfReady(0));
}
