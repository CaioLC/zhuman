//! The authoritative host-side single-line text editor model (INPUT-07).
//!
//! This is *policy*, owned by `ui_client`: the generic engine in `src/ui` knows nothing
//! about carets, selections, UTF-8 validation, or a maximum query length. A `LineEditor`
//! holds one control's persisted buffer plus the caret/anchor that describe the current
//! selection, and every mutation is a method here so the rules live in one place and can
//! be tested deterministically without SDL, a window, or a live frame.
//!
//! Boundaries:
//!   * `ui_client` (this file) owns the model and every editing rule.
//!   * `command.zig` maps SDL keys to a semantic `Command`; it never touches a buffer.
//!   * `main.zig` only routes platform events and the SDL clipboard into these methods.
//!   * `widgets.text_input` reads the model to render text, caret, selection, placeholder,
//!     focus-visible chrome, and the clear affordance.
//!
//! Text model:
//!   * The buffer is always valid UTF-8 (enforced on every insertion/paste).
//!   * "Single-line" means no line breaks or other C0/C1/DEL control codepoints; such text
//!     is *refused as a whole*, never silently stripped, so a paste is all-or-nothing.
//!   * The caret and anchor are byte offsets that always sit on UTF-8 codepoint
//!     boundaries. `caret == anchor` means no selection; otherwise the selection is the
//!     half-open byte range `[min(caret,anchor), max(caret,anchor))`.
//!   * `max_query_bytes` is the explicit, documented capacity. Any insertion or paste that
//!     would exceed it (after replacing the current selection) is refused as a whole and
//!     raises `refused`, rather than truncating to a partial codepoint or silently
//!     dropping the tail.
//!
//! `refused` is a visible, non-silent signal: it latches true on any rejected edit and is
//! cleared by the next accepted mutation (or an explicit `clearRefusal`). The host/widget
//! surfaces it (e.g. a shake/blink or a status hint) so the user learns the edit did not
//! take, instead of a change appearing to vanish.

const std = @import("std");
const unicode = std.unicode;

/// A single-line UTF-8 text editor with a caret and an anchored selection.
///
/// Zero-initialization is the empty, valid, unrefused editor: an all-zero `buf`, `len`,
/// `caret`, `anchor`, and `refused` describe "" with the caret at the start and no
/// selection, so the pooled state's zeroable default (see `cache.zig`) is already valid.
pub const LineEditor = struct {
    /// The explicit, documented maximum query length in bytes. UTF-8, so a codepoint may
    /// be 1–4 bytes; this bounds bytes, not codepoints, matching the storage and any
    /// downstream byte-oriented search consumer. Chosen to comfortably hold a search
    /// query while staying a small fixed POD buffer (no allocator, poolable by value).
    pub const max_query_bytes: usize = 128;

    buf: [max_query_bytes]u8 = undefined,
    len: usize = 0,
    /// Byte offset of the caret; always on a codepoint boundary in `0..=len`.
    caret: usize = 0,
    /// Byte offset of the selection anchor; equals `caret` when there is no selection.
    anchor: usize = 0,
    /// Latches true when an edit was refused (overflow or invalid/multi-line text). Any
    /// accepted mutation clears it. The host renders it so refusal is never silent.
    refused: bool = false,

    /// Outcome of a mutation. `accepted` means the model changed as asked; `refused`
    /// means it was rejected as a whole and `refused` is now set. `noop` means there was
    /// nothing to do (e.g. delete on an empty buffer) and is not a refusal.
    pub const Result = enum { accepted, refused, noop };

    pub fn text(self: *const LineEditor) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const LineEditor) bool {
        return self.len == 0;
    }

    pub fn hasSelection(self: *const LineEditor) bool {
        return self.caret != self.anchor;
    }

    /// The selection as a half-open byte range `[start, end)`. `start == end` when empty.
    pub fn selectionRange(self: *const LineEditor) struct { start: usize, end: usize } {
        const a = @min(self.caret, self.anchor);
        const b = @max(self.caret, self.anchor);
        return .{ .start = a, .end = b };
    }

    /// The selected bytes (empty slice when there is no selection).
    pub fn selectionSlice(self: *const LineEditor) []const u8 {
        const r = self.selectionRange();
        return self.buf[r.start..r.end];
    }

    fn markRefused(self: *LineEditor) Result {
        self.refused = true;
        return .refused;
    }

    /// Clear the refusal signal (e.g. after the host has surfaced it once).
    pub fn clearRefusal(self: *LineEditor) void {
        self.refused = false;
    }

    /// True iff `text` is valid UTF-8 and contains no codepoint that would break a single
    /// line: no C0 controls (includes '\n', '\r', '\t'), no DEL, and no C1 controls. This
    /// is the single admissibility rule for anything entering the buffer.
    pub fn isSingleLineUtf8(bytes: []const u8) bool {
        if (!unicode.utf8ValidateSlice(bytes)) return false;
        var view = unicode.Utf8View.initUnchecked(bytes);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp < 0x20) return false; // C0 controls incl. tab/newline/carriage return
            if (cp == 0x7f) return false; // DEL
            if (cp >= 0x80 and cp <= 0x9f) return false; // C1 controls
        }
        return true;
    }

    fn isBoundary(self: *const LineEditor, i: usize) bool {
        if (i == 0 or i == self.len) return true;
        return (self.buf[i] & 0xC0) != 0x80; // not a UTF-8 continuation byte
    }

    fn prevBoundary(self: *const LineEditor, i: usize) usize {
        if (i == 0) return 0;
        var n = i - 1;
        while (n > 0 and (self.buf[n] & 0xC0) == 0x80) n -= 1;
        return n;
    }

    fn nextBoundary(self: *const LineEditor, i: usize) usize {
        if (i >= self.len) return self.len;
        var n = i + 1;
        while (n < self.len and (self.buf[n] & 0xC0) == 0x80) n += 1;
        return n;
    }

    fn collapseTo(self: *LineEditor, pos: usize) void {
        self.caret = pos;
        self.anchor = pos;
    }

    /// Delete the current selection in place. Returns whether anything was removed. The
    /// caret collapses to the selection start. Does not touch `refused`.
    fn removeSelection(self: *LineEditor) bool {
        if (!self.hasSelection()) return false;
        const r = self.selectionRange();
        const tail_len = self.len - r.end;
        std.mem.copyForwards(u8, self.buf[r.start..][0..tail_len], self.buf[r.end..self.len]);
        self.len = r.start + tail_len;
        self.collapseTo(r.start);
        return true;
    }

    /// Insert `bytes` at the caret, replacing any selection. Refused *as a whole* (setting
    /// `refused`, mutating nothing) if `bytes` is not admissible single-line UTF-8 or if
    /// the result would exceed `max_query_bytes`. Empty input is a `noop`.
    pub fn insert(self: *LineEditor, bytes: []const u8) Result {
        if (bytes.len == 0) return .noop;
        if (!isSingleLineUtf8(bytes)) return self.markRefused();

        const r = self.selectionRange();
        const removed = r.end - r.start;
        // Capacity is checked against the post-replacement length so a paste that fills a
        // selection is judged on its net effect, never truncated mid-codepoint.
        if (self.len - removed + bytes.len > max_query_bytes) return self.markRefused();

        _ = self.removeSelection();
        const at = self.caret;
        const tail_len = self.len - at;
        // Shift the tail right to open a gap, then copy the new bytes in.
        std.mem.copyBackwards(u8, self.buf[at + bytes.len ..][0..tail_len], self.buf[at..self.len]);
        @memcpy(self.buf[at..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.collapseTo(at + bytes.len);
        self.refused = false;
        return .accepted;
    }

    /// Backspace: delete the selection if any, else the codepoint before the caret.
    pub fn deleteBackward(self: *LineEditor) Result {
        if (self.removeSelection()) {
            self.refused = false;
            return .accepted;
        }
        if (self.caret == 0) return .noop;
        const start = self.prevBoundary(self.caret);
        const removed = self.caret - start;
        const tail_len = self.len - self.caret;
        std.mem.copyForwards(u8, self.buf[start..][0..tail_len], self.buf[self.caret..self.len]);
        self.len -= removed;
        self.collapseTo(start);
        self.refused = false;
        return .accepted;
    }

    /// Delete (forward): delete the selection if any, else the codepoint at the caret.
    pub fn deleteForward(self: *LineEditor) Result {
        if (self.removeSelection()) {
            self.refused = false;
            return .accepted;
        }
        if (self.caret >= self.len) return .noop;
        const stop = self.nextBoundary(self.caret);
        const removed = stop - self.caret;
        const tail_len = self.len - stop;
        std.mem.copyForwards(u8, self.buf[self.caret..][0..tail_len], self.buf[stop..self.len]);
        self.len -= removed;
        self.collapseTo(self.caret); // caret stays; anchor re-synced
        self.refused = false;
        return .accepted;
    }

    /// Move the caret one codepoint left. With `extend`, moves the caret while keeping the
    /// anchor (growing/shrinking the selection); without, collapses any selection — to its
    /// left edge if one existed, otherwise one codepoint left.
    pub fn moveLeft(self: *LineEditor, extend: bool) void {
        if (!extend and self.hasSelection()) {
            self.collapseTo(self.selectionRange().start);
            return;
        }
        const pos = self.prevBoundary(self.caret);
        self.caret = pos;
        if (!extend) self.anchor = pos;
    }

    /// Move the caret one codepoint right. See `moveLeft` for the selection semantics.
    pub fn moveRight(self: *LineEditor, extend: bool) void {
        if (!extend and self.hasSelection()) {
            self.collapseTo(self.selectionRange().end);
            return;
        }
        const pos = self.nextBoundary(self.caret);
        self.caret = pos;
        if (!extend) self.anchor = pos;
    }

    /// Move the caret to the start of the line. `extend` keeps the anchor.
    pub fn home(self: *LineEditor, extend: bool) void {
        self.caret = 0;
        if (!extend) self.anchor = 0;
    }

    /// Move the caret to the end of the line. `extend` keeps the anchor.
    pub fn end(self: *LineEditor, extend: bool) void {
        self.caret = self.len;
        if (!extend) self.anchor = self.len;
    }

    /// Select the entire buffer, placing the caret at the end and the anchor at the start.
    pub fn selectAll(self: *LineEditor) void {
        self.anchor = 0;
        self.caret = self.len;
    }

    /// Empty the buffer and reset caret/anchor. This is the keyboard/pointer clear action.
    /// Returns `noop` when already empty so the host can avoid a spurious visible change.
    pub fn clear(self: *LineEditor) Result {
        if (self.len == 0 and !self.refused) return .noop;
        self.len = 0;
        self.collapseTo(0);
        self.refused = false;
        return .accepted;
    }

    /// Cut: return the selected bytes for the host to place on the clipboard and delete
    /// them. Returns `null` when there is no selection (nothing to cut); the caller then
    /// leaves the clipboard untouched. The returned slice points into the buffer and is
    /// only valid until the next mutation, so the caller must copy it out immediately.
    pub fn cutSelection(self: *LineEditor) ?[]const u8 {
        if (!self.hasSelection()) return null;
        const slice = self.selectionSlice();
        return slice;
    }
};

// ---------------------------------------------------------------------------------------
// Tests — deterministic, exhaustive, SDL-free. `test-ui` pulls these in via `command.zig`
// / the widget module surface (see `src/test_ui.zig`).
// ---------------------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "zero value is empty, valid, unrefused, caret at start" {
    const ed: LineEditor = .{};
    try expect(ed.isEmpty());
    try expect(!ed.hasSelection());
    try expect(!ed.refused);
    try expectEqual(@as(usize, 0), ed.caret);
    try expectEqualStrings("", ed.text());
}

test "ascii insertion advances caret and appends" {
    var ed: LineEditor = .{};
    try expectEqual(LineEditor.Result.accepted, ed.insert("hi"));
    try expectEqualStrings("hi", ed.text());
    try expectEqual(@as(usize, 2), ed.caret);
    try expectEqual(LineEditor.Result.accepted, ed.insert("!"));
    try expectEqualStrings("hi!", ed.text());
}

test "insertion at caret in the middle splices, not appends" {
    var ed: LineEditor = .{};
    _ = ed.insert("ace");
    ed.moveLeft(false); // caret before 'e' -> between c and e
    _ = ed.insert("d");
    try expectEqualStrings("acde", ed.text());
    // caret sits right after the inserted 'd'
    try expectEqual(@as(usize, 3), ed.caret);
}

test "multibyte utf8 moves by whole codepoints" {
    var ed: LineEditor = .{};
    _ = ed.insert("aéb"); // 'é' is 2 bytes -> total 4 bytes
    try expectEqual(@as(usize, 4), ed.len);
    ed.end(false);
    ed.moveLeft(false); // over 'b'
    try expectEqual(@as(usize, 3), ed.caret);
    ed.moveLeft(false); // over 'é' (2 bytes)
    try expectEqual(@as(usize, 1), ed.caret);
    ed.moveLeft(false); // over 'a'
    try expectEqual(@as(usize, 0), ed.caret);
    ed.moveLeft(false); // clamped at start
    try expectEqual(@as(usize, 0), ed.caret);
}

test "backspace deletes a whole multibyte codepoint" {
    var ed: LineEditor = .{};
    _ = ed.insert("aé");
    try expectEqual(@as(usize, 3), ed.len);
    try expectEqual(LineEditor.Result.accepted, ed.deleteBackward());
    try expectEqualStrings("a", ed.text());
    try expectEqual(LineEditor.Result.accepted, ed.deleteBackward());
    try expectEqualStrings("", ed.text());
    try expectEqual(LineEditor.Result.noop, ed.deleteBackward());
}

test "delete forward removes codepoint at caret" {
    var ed: LineEditor = .{};
    _ = ed.insert("éb");
    ed.home(false);
    try expectEqual(LineEditor.Result.accepted, ed.deleteForward()); // removes 'é'
    try expectEqualStrings("b", ed.text());
    try expectEqual(@as(usize, 0), ed.caret);
    try expectEqual(LineEditor.Result.accepted, ed.deleteForward()); // removes 'b'
    try expectEqualStrings("", ed.text());
    try expectEqual(LineEditor.Result.noop, ed.deleteForward());
}

test "shift-arrow anchors and extends selection both directions" {
    var ed: LineEditor = .{};
    _ = ed.insert("abcd");
    ed.home(false);
    ed.moveRight(true); // select 'a'
    ed.moveRight(true); // select 'ab'
    try expect(ed.hasSelection());
    try expectEqualStrings("ab", ed.selectionSlice());
    ed.moveLeft(true); // shrink to 'a'
    try expectEqualStrings("a", ed.selectionSlice());
    ed.moveLeft(true); // collapse
    try expect(!ed.hasSelection());
    ed.moveLeft(true); // extend leftward past origin does nothing at start
    try expectEqual(@as(usize, 0), ed.caret);
}

test "shift-home and shift-end select to edges" {
    var ed: LineEditor = .{};
    _ = ed.insert("abcd");
    ed.moveLeft(false);
    ed.moveLeft(false); // caret between b and c
    ed.home(true);
    try expectEqualStrings("ab", ed.selectionSlice());
    ed.end(false); // collapse to end
    try expect(!ed.hasSelection());
    ed.home(false);
    ed.end(true);
    try expectEqualStrings("abcd", ed.selectionSlice());
}

test "plain arrow collapses selection to the correct edge" {
    var ed: LineEditor = .{};
    _ = ed.insert("abcd");
    ed.home(false);
    ed.moveRight(true);
    ed.moveRight(true); // selection 'ab', caret at 2, anchor at 0
    ed.moveLeft(false); // collapse to left edge
    try expectEqual(@as(usize, 0), ed.caret);
    try expect(!ed.hasSelection());

    ed.moveRight(true);
    ed.moveRight(true); // selection 'ab' again
    ed.moveRight(false); // collapse to right edge
    try expectEqual(@as(usize, 2), ed.caret);
    try expect(!ed.hasSelection());
}

test "typing over a selection replaces it" {
    var ed: LineEditor = .{};
    _ = ed.insert("hello");
    ed.selectAll();
    try expectEqualStrings("hello", ed.selectionSlice());
    try expectEqual(LineEditor.Result.accepted, ed.insert("bye"));
    try expectEqualStrings("bye", ed.text());
    try expect(!ed.hasSelection());
    try expectEqual(@as(usize, 3), ed.caret);
}

test "backspace with a selection deletes only the selection" {
    var ed: LineEditor = .{};
    _ = ed.insert("abcd");
    ed.home(false);
    ed.moveRight(true);
    ed.moveRight(true); // select 'ab'
    try expectEqual(LineEditor.Result.accepted, ed.deleteBackward());
    try expectEqualStrings("cd", ed.text());
    try expectEqual(@as(usize, 0), ed.caret);
}

test "delete-forward with a selection deletes only the selection" {
    var ed: LineEditor = .{};
    _ = ed.insert("abcd");
    ed.home(false);
    ed.moveRight(true);
    ed.moveRight(true); // select 'ab'
    try expectEqual(LineEditor.Result.accepted, ed.deleteForward());
    try expectEqualStrings("cd", ed.text());
    try expectEqual(@as(usize, 0), ed.caret);
}

test "select-all then clear empties" {
    var ed: LineEditor = .{};
    _ = ed.insert("abc");
    ed.selectAll();
    try expectEqual(LineEditor.Result.accepted, ed.clear());
    try expect(ed.isEmpty());
    try expectEqual(LineEditor.Result.noop, ed.clear());
}

test "overflow is refused as a whole and is non-silent" {
    var ed: LineEditor = .{};
    var big: [LineEditor.max_query_bytes]u8 = @splat('x');
    try expectEqual(LineEditor.Result.accepted, ed.insert(&big));
    try expectEqual(LineEditor.max_query_bytes, ed.len);
    // One more byte cannot fit: whole insertion refused, buffer unchanged, flag raised.
    try expectEqual(LineEditor.Result.refused, ed.insert("y"));
    try expectEqual(LineEditor.max_query_bytes, ed.len);
    try expect(ed.refused);
    // An accepted edit clears the visible refusal.
    try expectEqual(LineEditor.Result.accepted, ed.deleteBackward());
    try expect(!ed.refused);
}

test "paste filling a selection is judged on net length, not gross" {
    var ed: LineEditor = .{};
    var big: [LineEditor.max_query_bytes]u8 = @splat('x');
    _ = ed.insert(&big); // buffer full
    ed.selectAll();
    // Replacing all bytes with an equal-length run must fit (net change is zero).
    var repl: [LineEditor.max_query_bytes]u8 = @splat('y');
    try expectEqual(LineEditor.Result.accepted, ed.insert(&repl));
    try expectEqual(LineEditor.max_query_bytes, ed.len);
    try expectEqual(ed.text()[0], 'y');
}

test "invalid utf8 is refused, buffer untouched" {
    var ed: LineEditor = .{};
    _ = ed.insert("ok");
    const bad = [_]u8{ 0xff, 0xfe }; // never valid UTF-8
    try expectEqual(LineEditor.Result.refused, ed.insert(&bad));
    try expectEqualStrings("ok", ed.text());
    try expect(ed.refused);
}

test "multi-line and control text is refused as a whole" {
    var ed: LineEditor = .{};
    try expectEqual(LineEditor.Result.refused, ed.insert("a\nb"));
    try expect(ed.isEmpty());
    try expect(ed.refused);
    ed.clearRefusal();
    try expectEqual(LineEditor.Result.refused, ed.insert("a\tb"));
    try expect(ed.isEmpty());
    try expectEqual(LineEditor.Result.refused, ed.insert("a\rb"));
    try expect(ed.isEmpty());
    // A bare DEL / C1 control is equally refused.
    try expectEqual(LineEditor.Result.refused, ed.insert(&[_]u8{0x7f}));
    try expect(ed.isEmpty());
}

test "isSingleLineUtf8 admits normal text and multibyte, rejects breaks" {
    try expect(LineEditor.isSingleLineUtf8("hello world"));
    try expect(LineEditor.isSingleLineUtf8("café — déjà"));
    try expect(!LineEditor.isSingleLineUtf8("line\nbreak"));
    try expect(!LineEditor.isSingleLineUtf8("tab\there"));
    try expect(!LineEditor.isSingleLineUtf8(&[_]u8{0x0b})); // vertical tab
    try expect(LineEditor.isSingleLineUtf8("")); // empty is trivially admissible
}

test "cutSelection returns selection bytes and leaves deletion to caller flow" {
    var ed: LineEditor = .{};
    _ = ed.insert("abcd");
    try expect(ed.cutSelection() == null); // nothing selected
    ed.home(false);
    ed.moveRight(true);
    ed.moveRight(true); // select 'ab'
    const cut = ed.cutSelection().?;
    try expectEqualStrings("ab", cut);
    // Model still holds the text until the host deletes it (delete-selection path).
    try expectEqual(LineEditor.Result.accepted, ed.deleteBackward());
    try expectEqualStrings("cd", ed.text());
}

test "caret and anchor always remain on codepoint boundaries" {
    var ed: LineEditor = .{};
    _ = ed.insert("αβγ"); // three 2-byte codepoints -> 6 bytes
    ed.home(false);
    // Walk right across the whole string; every caret stop must be a boundary.
    while (ed.caret < ed.len) {
        try expect(ed.isBoundary(ed.caret));
        ed.moveRight(false);
    }
    try expectEqual(@as(usize, 6), ed.caret);
    while (ed.caret > 0) {
        ed.moveLeft(false);
        try expect(ed.isBoundary(ed.caret));
    }
}
