//! Event log: the newest-first feed of what just happened (foraged, built, died).
//!
//! Global (one feed for the run), held on `Resources` so it outlives the per-frame UI
//! arena. Fixed-capacity ring buffer with inline message buffers, so pushing needs no
//! allocator. Callers format a message into a stack buffer, then `push` copies it in.
//! Leaf module: imports nothing.

/// Tone of a log line: drives the color the host paints it in (see `log_tone_color` in
/// `main.zig`). It lives here so both the sim (a death message) and the UI agree on it.
pub const Tone = enum { dim, normal, good, warn, danger };

/// Longest message kept per entry, in bytes. Sized to hold the game's log copy in full, with
/// headroom over the longest line ("{d} more are priced past one pair of hands." and the death
/// lines). A longer message is refused as a whole on `push`, never a silently cut prefix, so a
/// log line is either the complete message or the explicit `overflow_marker`, never a severed
/// UTF-8 codepoint.
pub const max_len = 256;
/// How many entries the ring buffer holds before overwriting the oldest.
pub const capacity = 64;

/// The visible marker substituted for a message that exceeds `max_len`. Refusal is non-silent:
/// rather than storing a cut prefix, the entry reports its refusal in the feed (and flags it),
/// matching `semantics.OwnedText` and the editor's whole-refusal policy.
pub const overflow_marker = "(log message too long)";

/// One log line: an inline text buffer, its live length and its tone. Fixed-size so entries
/// live in the ring buffer with no heap.
pub const Entry = struct {
    buf: [max_len]u8 = undefined,
    len: usize = 0,
    tone: Tone = .normal,
    /// Game-seconds elapsed when the line was pushed (`Log.now` at push time). The UI turns
    /// it into a day + time-of-day stamp; the log itself knows nothing of day length.
    at: f32 = 0,
    /// The message pushed here exceeded `max_len` and was refused whole: `buf`/`len` hold
    /// the `overflow_marker`, not a cut prefix. Lets a reader know the feed is lossy for this
    /// line.
    refused: bool = false,

    /// The message text (the live slice of the inline buffer). For a refused entry this is
    /// the `overflow_marker`, never a truncated prefix of the original.
    pub fn text(self: *const Entry) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A fixed-capacity ring buffer of log entries. `push` writes at `head` and advances it,
/// overwriting the oldest once full; `get(0)` is the newest. Reset with `clear` on a new run.
pub const Log = struct {
    entries: [capacity]Entry = @splat(.{}),
    head: usize = 0, // next write slot (also the oldest, once full)
    count: usize = 0, // live entries, saturating at `capacity`
    /// Every line ever pushed this run, monotonic (`clear` keeps it): a reader that remembers
    /// the total it last saw knows exactly which lines are new, even two identical ones.
    pushed: u64 = 0,
    /// The run clock in game-seconds, kept current by `advance_clock`; every `push` stamps
    /// it on the entry so call sites need not pass a time.
    now: f32 = 0,

    /// Append a message with `tone`. The bytes are copied in full when they fit `max_len`, so
    /// the caller's buffer can be reused immediately after. A message past `max_len` is
    /// refused as a whole: the entry stores the visible `overflow_marker` and sets
    /// `Entry.refused`, never a silently cut or mid-codepoint prefix. The refusal is
    /// observable on the stored `Entry` (its `refused` flag and the marker text), not in a
    /// return value, so call sites are fire-and-forget.
    pub fn push(self: *Log, tone: Tone, msg: []const u8) void {
        const e = &self.entries[self.head];
        const accepted = msg.len <= max_len;
        const src = if (accepted) msg else overflow_marker;
        @memcpy(e.buf[0..src.len], src);
        e.len = src.len;
        e.tone = tone;
        e.refused = !accepted;
        e.at = self.now;
        self.head = (self.head + 1) % capacity;
        if (self.count < capacity) self.count += 1;
        self.pushed += 1;
    }

    /// How many of the newest entries arrived after a reader saw `seen` lines in all, capped at
    /// what the ring still holds. `get(n - 1)` is the oldest of them, `get(0)` the newest.
    pub fn newSince(self: *const Log, seen: u64) usize {
        if (self.pushed <= seen) return 0;
        return @intCast(@min(self.pushed - seen, self.count));
    }

    /// Drop every entry, so a new run begins with a clean feed.
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

// --- Tests (non-silent log storage) --------------------------------------------

const std = @import("std");
const testing = std.testing;

test "log push stores a fitting message in full" {
    var log: Log = .{};
    log.push(.good, "Shelter raised.");
    try testing.expectEqual(@as(usize, 1), log.count);
    const e = log.get(0);
    try testing.expect(!e.refused);
    try testing.expectEqualStrings("Shelter raised.", e.text());
    try testing.expectEqual(Tone.good, e.tone);
}

test "log push stores a message exactly at max_len in full" {
    var log: Log = .{};
    var at_cap: [max_len]u8 = undefined;
    @memset(&at_cap, 'a');
    log.push(.normal, &at_cap);
    const e = log.get(0);
    try testing.expect(!e.refused);
    try testing.expectEqual(@as(usize, max_len), e.text().len);
}

test "log push refuses an over-length message as a whole, never a cut prefix" {
    var log: Log = .{};
    var over: [max_len + 1]u8 = undefined;
    @memset(&over, 'x');
    log.push(.warn, &over);
    const e = log.get(0);
    try testing.expect(e.refused);
    // The stored text is the explicit marker, not a truncated prefix of the original.
    try testing.expectEqualStrings(overflow_marker, e.text());
    try testing.expectEqual(Tone.warn, e.tone); // tone still recorded
}

test "log push refuses long multibyte UTF-8 whole, never cutting a codepoint" {
    var log: Log = .{};
    const snowman = "\u{2603}"; // E2 98 83
    var buf: [max_len + 3]u8 = undefined;
    var n: usize = 0;
    while (n + snowman.len <= buf.len) : (n += snowman.len) @memcpy(buf[n .. n + snowman.len], snowman);
    try testing.expect(n > max_len);
    log.push(.danger, buf[0..n]);
    const e = log.get(0);
    try testing.expect(e.refused);
    try testing.expectEqualStrings(overflow_marker, e.text());
    // A multibyte message that fits is stored intact and stays valid UTF-8.
    log.push(.normal, "\u{2603}\u{2603}\u{2603}\u{2603}");
    try testing.expect(!log.get(0).refused);
    try testing.expect(std.unicode.utf8ValidateSlice(log.get(0).text()));
    try testing.expectEqualStrings("\u{2603}\u{2603}\u{2603}\u{2603}", log.get(0).text());
}

test "log ring overwrites oldest and get(0) is newest after refusals" {
    var log: Log = .{};
    var i: usize = 0;
    while (i < capacity + 3) : (i += 1) {
        var b: [16]u8 = undefined;
        const msg = std.mem.print(&b, "n{d}", .{i}) catch unreachable;
        log.push(.normal, msg);
    }
    try testing.expectEqual(capacity, log.count); // saturated
    // Newest is the last pushed; oldest surviving is (count) back.
    var newest: [16]u8 = undefined;
    const newest_msg = std.mem.print(&newest, "n{d}", .{capacity + 2}) catch unreachable;
    try testing.expectEqualStrings(newest_msg, log.get(0).text());
    // A refused push still advances the ring and is the new newest (as the marker).
    var over: [max_len + 1]u8 = undefined;
    @memset(&over, 'y');
    log.push(.warn, &over);
    try testing.expect(log.get(0).refused);
    try testing.expectEqualStrings(overflow_marker, log.get(0).text());
}

test "log push stamps the current clock" {
    var log: Log = .{};
    log.now = 12.5;
    log.push(.normal, "a");
    log.now = 30;
    log.push(.normal, "b");
    try testing.expectEqual(@as(f32, 30), log.get(0).at);
    try testing.expectEqual(@as(f32, 12.5), log.get(1).at);
}

test "log clear resets the feed" {
    var log: Log = .{};
    log.push(.normal, "a");
    log.push(.normal, "b");
    log.clear();
    try testing.expectEqual(@as(usize, 0), log.count);
    try testing.expectEqual(@as(usize, 0), log.head);
}

test "newSince counts the lines a reader has not seen, identical ones included" {
    var log = Log{};
    try testing.expectEqual(@as(usize, 0), log.newSince(0));
    log.push(.normal, "You return with 3 food.");
    log.push(.normal, "You return with 3 food.");
    try testing.expectEqual(@as(usize, 2), log.newSince(0));
    try testing.expectEqual(@as(usize, 1), log.newSince(1));
    try testing.expectEqual(@as(usize, 0), log.newSince(2));
    // A reader far behind hears at most what the ring still holds.
    for (0..capacity + 5) |_| log.push(.dim, "tick");
    try testing.expectEqual(capacity, log.newSince(2));
    // `clear` keeps the running total, so a cleared feed is not replayed.
    const total = log.pushed;
    log.clear();
    try testing.expectEqual(@as(usize, 0), log.newSince(total));
}
