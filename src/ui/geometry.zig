//! Pure geometry primitives for the UI engine. No platform or userland deps —
//! the caller supplies coordinates; the engine never reaches into `Resources`.

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    /// Inclusive point-in-rect test. The caller passes the point; interpreting
    /// *where* the point came from (mouse, touch, …) is userland's concern.
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and x <= self.x + self.w and
            y >= self.y and y <= self.y + self.h;
    }

    /// The overlapping region of `self` and `other`. Non-overlapping inputs collapse to
    /// a zero-area rect (`w`/`h` floored at 0) rather than going negative — used to nest
    /// clip regions (a scroll viewport inside another) without a special not-visible case.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.w, other.x + other.w);
        const y1 = @min(self.y + self.h, other.y + other.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }
};
