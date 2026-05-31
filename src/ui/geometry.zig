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
};
