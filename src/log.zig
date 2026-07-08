//! Event log — the newest-first feed of what just happened (foraged, built, died).
//!
//! Global (one feed for the run), held on `Resources` so it outlives the per-frame UI
//! arena. Fixed-capacity ring buffer with inline message buffers, so pushing needs no
//! allocator. Callers format a message into a stack buffer, then `push` copies it in.
//! Leaf module — imports nothing.

/// Tone of a log line — drives the color the host paints it in (see `log_tone_color`
/// in `main.zig`). Kept here so both the sim (a death message) and the UI agree on it.
pub const Tone = enum { dim, normal, good, warn, danger };

/// Longest message kept per entry; longer text is truncated on `push`.
pub const max_len = 96;
/// How many entries the ring buffer holds before overwriting the oldest.
pub const capacity = 64;

/// One log line: an inline text buffer + its live length + tone. Fixed-size so entries
/// live in the ring buffer with no heap.
pub const Entry = struct {
    buf: [max_len]u8 = undefined,
    len: usize = 0,
    tone: Tone = .normal,

    /// The message text (the live slice of the inline buffer).
    pub fn text(self: *const Entry) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A fixed-capacity ring buffer of log entries. `push` writes at `head` and advances it,
/// overwriting the oldest once full; `get(0)` is the newest. Reset with `clear` on a new run.
pub const Log = struct {
    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    head: usize = 0, // next write slot (also the oldest, once full)
    count: usize = 0, // live entries, saturating at `capacity`

    /// Append a message with `tone`, truncated to `max_len`. Copies the bytes in, so the
    /// caller's buffer can be reused immediately after.
    pub fn push(self: *Log, tone: Tone, msg: []const u8) void {
        const e = &self.entries[self.head];
        const n = @min(msg.len, max_len);
        @memcpy(e.buf[0..n], msg[0..n]);
        e.len = n;
        e.tone = tone;
        self.head = (self.head + 1) % capacity;
        if (self.count < capacity) self.count += 1;
    }

    /// Drop every entry — used on "start over" so a new run begins with a clean feed.
    pub fn clear(self: *Log) void {
        self.head = 0;
        self.count = 0;
    }

    /// Entry `i` counting back from the newest (`0` = most recent). Caller keeps `i < count`.
    pub fn get(self: *const Log, i: usize) *const Entry {
        const idx = (self.head + capacity - 1 - i) % capacity;
        return &self.entries[idx];
    }
};
