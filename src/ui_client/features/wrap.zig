//! `wrap` — the host-side, **pure** line-breaking routine behind constrained multiline
//! text (TEXT-02). It is the *single source of truth* both `text.attach` (build-time
//! measurement) and `text.draw` (per-line render) run, so the reserved layout box always
//! matches the glyphs that get drawn — the same "measure and draw read one source"
//! invariant TEXT-01 pins for the single-line path, extended to N lines.
//!
//! **Why a separate module, and why parameterized by a `Measurer`:** the generic engine
//! `src/ui` must stay callback-free and typography-unaware; wrapping is host policy that
//! needs font metrics. Rather than reach into SDL here (which would make the routine
//! untestable without a live font + renderer), `wrapLines` takes a small `Measurer`
//! interface — `width(bytes)` and `prefixBytes(bytes, max_w)` — that the `text` feature
//! backs with the real `sdl.ttf.Font` and tests back with a deterministic fake (e.g.
//! 1px/byte). The routine itself does no allocation and no I/O: it walks the bytes once
//! and yields byte-spans through an inline callback, so both callers get identical breaks
//! from identical inputs.
//!
//! **Why host-driven breaks instead of SDL's own wrapper:** `TTF_GetStringSizeWrapped` /
//! `renderTextSolidWrapped` exist, but SDL owns the break points, does not guarantee its
//! measured line count equals what a separate render produces byte-for-byte, and its
//! over-long-word handling is not the deterministic UTF-8-safe hard-break this slice
//! requires. Driving the breaks here — greedy word wrap with a `measureString`-backed
//! hard-break fallback — is what lets "renders exactly the measured lines" be a guarantee
//! rather than a hope.
//!
//! This module does **no** clipping/ellipsis (that is TEXT-03) and **no** typography
//! changes (TEXT-04); it only decides where lines break for a given width.

const std = @import("std");

/// The font-metric surface `wrapLines` needs, kept abstract so the routine is pure and
/// SDL-free. The `text` feature adapts the live `sdl.ttf.Font` to this; tests supply a
/// deterministic fake. `ptr` is an opaque backing (a `*const Font`, or a test context).
///
/// - `width(text)` → the rendered px width of `text` on one line (no wrapping).
/// - `prefixBytes(text, max_w)` → the largest number of **codepoint-aligned** bytes of
///   `text` whose rendered width does not exceed `max_w`. Backed by `TTF_MeasureString`,
///   which measures on codepoint boundaries and never returns a mid-codepoint cut. Used
///   only for the hard-break fallback on a single over-long token.
pub const Measurer = struct {
    ptr: *const anyopaque,
    widthFn: *const fn (ptr: *const anyopaque, text: []const u8) f32,
    prefixBytesFn: *const fn (ptr: *const anyopaque, text: []const u8, max_w: f32) usize,

    pub fn width(self: Measurer, text: []const u8) f32 {
        return self.widthFn(self.ptr, text);
    }
    pub fn prefixBytes(self: Measurer, text: []const u8, max_w: f32) usize {
        return self.prefixBytesFn(self.ptr, text, max_w);
    }
};

/// One wrapped line: a byte range `[start, start+len)` into the original source. Empty
/// lines (`len == 0`) are real — a blank line from `\n\n` still occupies a row of height —
/// and are yielded like any other so measure and render agree on the line count.
pub const Line = struct { start: usize, len: usize };

/// Walk `text`, yielding each wrapped line's byte-span to `emit` in order. Pure: no
/// allocation, single forward pass, deterministic for a given `(text, max_w, measure)`.
///
/// Algorithm (greedy word wrap over an explicit pixel width):
///   - `max_w <= 0` is the **single-line fast path** — the whole string is one line,
///     honoring embedded `\n` only. Callers use this for dense/unconstrained rows so the
///     wrap machinery costs nothing there.
///   - Otherwise: accumulate space-separated words while the candidate line (words joined
///     by single spaces) still fits `max_w`. A `\n` forces a break (and `\n\n` yields an
///     empty line between). When a **single word alone** exceeds `max_w`, hard-break it on
///     a codepoint boundary via `measure.prefixBytes` (always ≥ 1 codepoint, so tiny positive
///     widths still make progress and never loop forever or split a codepoint), emit the
///     prefix, and continue with the remainder as the next word.
///
/// `emit` returns `bool`: `false` stops the walk early (a caller with a fixed line budget,
/// e.g. a POD span table, can cap lines without this routine knowing the cap). Returns the
/// total number of lines that *would* be produced if never stopped is **not** tracked here;
/// callers that need the count accumulate it in `emit`.
pub fn wrapLines(
    text: []const u8,
    max_w: f32,
    measure: Measurer,
    comptime Ctx: type,
    ctx: Ctx,
    comptime emit: fn (Ctx, Line) bool,
) void {
    // Empty source → zero lines (matches a refused/empty TextState reserving a zero box).
    if (text.len == 0) return;

    // Fast path: no width constraint. One line per newline-delimited segment; the common
    // no-newline case is a single line, exactly today's single-line behavior.
    if (max_w <= 0) {
        var seg_start: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\n') {
                if (!emit(ctx, .{ .start = seg_start, .len = i - seg_start })) return;
                seg_start = i + 1;
            }
        }
        _ = emit(ctx, .{ .start = seg_start, .len = text.len - seg_start });
        return;
    }

    // Constrained greedy word wrap. Process one newline-delimited paragraph at a time so a
    // `\n` is always a hard break and a `\n\n` contributes a genuine empty line.
    var para_start: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, text, para_start, '\n');
        const para_end = nl orelse text.len;
        if (!wrapParagraph(text, para_start, para_end, max_w, measure, Ctx, ctx, emit)) return;
        if (nl == null) break;
        para_start = nl.? + 1;
        // A trailing '\n' ends the text on an empty final line — emit it, then stop.
        if (para_start > text.len) break;
        if (para_start == text.len) {
            _ = emit(ctx, .{ .start = text.len, .len = 0 });
            break;
        }
    }
}

/// Wrap one paragraph (`text[start..end]`, no embedded '\n') into lines. Returns `false`
/// if `emit` asked to stop. An empty paragraph yields one empty line (a blank row).
fn wrapParagraph(
    text: []const u8,
    start: usize,
    end: usize,
    max_w: f32,
    measure: Measurer,
    comptime Ctx: type,
    ctx: Ctx,
    comptime emit: fn (Ctx, Line) bool,
) bool {
    if (start >= end) return emit(ctx, .{ .start = start, .len = 0 });

    // The current line spans `[line_start, line_end)`; it grows word by word. `line_end`
    // sits at the end of the last word placed (spaces between words are implied by the
    // single-space join used when measuring the candidate).
    var line_start: usize = start;
    var line_end: usize = start;
    var word_start: usize = start;
    var saw_word = false;

    while (word_start < end) {
        // Skip a run of spaces; the gap between words is a single implied space when we
        // measure/emit. Leading spaces on a line collapse into the line's start position.
        while (word_start < end and text[word_start] == ' ') word_start += 1;
        if (word_start >= end) break;
        saw_word = true;

        var word_end = word_start;
        while (word_end < end and text[word_end] != ' ') word_end += 1;

        // Starting a fresh (empty) line: snap its start to this word so leading spaces —
        // at the paragraph start or just after a break — never count toward the line width
        // or get emitted. A non-empty line keeps its existing start (the implied single
        // space between words is what the candidate measure below accounts for).
        if (line_end == line_start) {
            line_start = word_start;
            line_end = word_start;
        }

        // Candidate = the current line plus this word (measured as the source span, whose
        // interior single spaces are the join). Fits if within max_w, or the line is empty
        // (a first word always goes on, then hard-breaks below if it alone is too wide).
        const has_line = line_end > line_start;
        const candidate_fits = !has_line or measure.width(text[line_start..word_end]) <= max_w;

        if (has_line and !candidate_fits) {
            // The word does not fit after the current line → break before it, then snap the
            // new line's start to this word (again collapsing the separating spaces).
            if (!emit(ctx, .{ .start = line_start, .len = line_end - line_start })) return false;
            line_start = word_start;
            line_end = word_start;
        }

        // Now place the word onto the (possibly fresh) line. If the word *alone* still
        // exceeds max_w, hard-break it on codepoint boundaries.
        if (measure.width(text[word_start..word_end]) > max_w) {
            var seg_start = word_start;
            while (seg_start < word_end) {
                var take = measure.prefixBytes(text[seg_start..word_end], max_w);
                if (take == 0) {
                    // max_w cannot fit even one codepoint; still make progress by one
                    // whole codepoint so we never loop or split a codepoint.
                    take = std.unicode.utf8ByteSequenceLength(text[seg_start]) catch 1;
                }
                const seg_end = @min(seg_start + take, word_end);
                if (!emit(ctx, .{ .start = seg_start, .len = seg_end - seg_start })) return false;
                seg_start = seg_end;
            }
            // The hard-broken word consumed its own lines; start a new empty line after it.
            line_start = word_end;
            line_end = word_end;
        } else {
            // Word fits (either on the existing line or on the fresh one).
            line_end = word_end;
        }

        word_start = word_end;
    }

    // Flush the trailing line if it holds anything, or if the paragraph produced no line at
    // all yet (all-spaces paragraph → one empty line).
    if (line_end > line_start) {
        return emit(ctx, .{ .start = line_start, .len = line_end - line_start });
    }
    if (!saw_word) return emit(ctx, .{ .start = end, .len = 0 });
    return true;
}

// --- Single-line overflow: ellipsis fitting (TEXT-03) -----------------------------------
//
// The pure counterpart to `wrapLines` for the *single-line* overflow case. Like wrap, it is
// SDL-free (it asks the same `Measurer` for widths) and deterministic, so `text.remeasure`
// and `text.draw` compute the identical fit from identical inputs — the drawn glyphs and the
// selection agree, and both are testable with the 1px/byte fake below.

/// The result of fitting `text` into a cell for `.ellipsis` overflow. `prefix_len` is the
/// byte length of the codepoint-aligned prefix of `text` to draw; `elided` is whether the
/// ellipsis token is appended after it. When `!elided`, the whole string fit and
/// `prefix_len == text.len` (no ellipsis). When `elided`, draw `text[0..prefix_len]` then
/// the ellipsis; `prefix_len` may be `0` (ellipsis alone, or a zero-width result when even
/// the ellipsis does not fit).
pub const Fit = struct {
    prefix_len: usize,
    elided: bool,
};

/// Deterministically choose the longest codepoint-aligned prefix of `text` that, followed
/// by an ellipsis of measured width `ellipsis_w`, fits the allocated cell `cell_w`. Pure and
/// UTF-8-safe (the prefix comes from `Measurer.prefixBytes`, which never cuts mid-codepoint).
///
/// Algorithm — one source of truth for measure and render:
///  1. `cell_w <= 0` (a zero/degenerate cell): draw nothing. `{ prefix_len = 0, elided = false }`.
///  2. The whole string already fits (`width(text) <= cell_w`): no elision — draw it whole.
///     `{ prefix_len = text.len, elided = false }`. (Measure and draw both draw everything.)
///  3. Otherwise the string is too wide, so an ellipsis is needed. The budget for real
///     glyphs is `cell_w - ellipsis_w`:
///       - budget `<= 0` (the cell is narrower than the ellipsis token itself, or a
///         font-measure error reported `ellipsis_w >= cell_w`): **deterministic empty** —
///         draw neither prefix nor ellipsis (`{ 0, false }`), never a floating ellipsis
///         wider than the allocated cell. No overdraw, ever.
///       - budget `> 0`: `prefix_len = prefixBytes(text, budget)` (codepoint-aligned, may be
///         `0`), and `elided = true` — draw the prefix (possibly empty) plus the ellipsis.
///
/// Because step 3 only fires when the string is genuinely too wide, an ellipsis is drawn
/// **iff** the text is clipped — a caller can trust `elided` as "was anything hidden".
pub fn ellipsisFit(text: []const u8, cell_w: f32, ellipsis_w: f32, measure: Measurer) Fit {
    if (cell_w <= 0) return .{ .prefix_len = 0, .elided = false };
    if (measure.width(text) <= cell_w) return .{ .prefix_len = text.len, .elided = false };
    const budget = cell_w - ellipsis_w;
    if (budget <= 0) return .{ .prefix_len = 0, .elided = false };
    return .{ .prefix_len = measure.prefixBytes(text, budget), .elided = true };
}

// --- Tests: deterministic, SDL-free (fake 1px/byte measurer) ----------------------------
//
// The wrap routine is pure and parameterized by `Measurer`, so these run with a fake that
// bills 1px per byte. That makes pixel widths equal byte counts, so "fits in max_w" reads
// as "≤ max_w bytes" — every break/exact-fit/off-by-one case below is exact and needs no
// font. `text.attach`/`draw` back the same interface with the real font; the shared routine
// is what makes their measure/render agree, which is the property these tests pin.

const testing = std.testing;

/// A fake measurer: every byte is 1px wide. `prefixBytes` returns the most codepoint-
/// aligned bytes that fit `max_w` (i.e. up to `floor(max_w)` bytes, but never mid-codepoint).
const FakeFont = struct {
    fn width(_: *const anyopaque, text: []const u8) f32 {
        return @floatFromInt(text.len);
    }
    fn prefixBytes(_: *const anyopaque, text: []const u8, max_w: f32) usize {
        const budget: usize = if (max_w <= 0) 0 else @intFromFloat(@floor(max_w));
        var i: usize = 0;
        // Walk codepoints, never stopping mid-sequence.
        while (i < text.len) {
            const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + seq > budget) break;
            i += seq;
        }
        return i;
    }
    fn measurer(self: *const FakeFont) Measurer {
        return .{ .ptr = self, .widthFn = width, .prefixBytesFn = prefixBytes };
    }
};

/// Collect wrapped lines as owned strings for assertion.
const Collector = struct {
    src: []const u8,
    lines: std.ArrayListUnmanaged([]const u8) = .{},
    alloc: std.mem.Allocator,
    limit: usize = std.math.maxInt(usize),

    fn take(self: *Collector, line: Line) bool {
        if (self.lines.items.len >= self.limit) return false;
        self.lines.append(self.alloc, self.src[line.start .. line.start + line.len]) catch return false;
        return true;
    }
};

fn collect(alloc: std.mem.Allocator, src: []const u8, max_w: f32) !Collector {
    var f = FakeFont{};
    var c = Collector{ .src = src, .alloc = alloc };
    wrapLines(src, max_w, f.measurer(), *Collector, &c, Collector.take);
    return c;
}

test "wrap: single-line fast path (max_w <= 0) is one line, unchanged behavior" {
    var c = try collect(testing.allocator, "Forage the ridge", 0);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), c.lines.items.len);
    try testing.expectEqualStrings("Forage the ridge", c.lines.items[0]);
}

test "wrap: fast path still splits on explicit newlines" {
    var c = try collect(testing.allocator, "a\nbb\nccc", 0);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), c.lines.items.len);
    try testing.expectEqualStrings("a", c.lines.items[0]);
    try testing.expectEqualStrings("bb", c.lines.items[1]);
    try testing.expectEqualStrings("ccc", c.lines.items[2]);
}

test "wrap: ASCII greedy word wrap at a width" {
    // 1px/byte, max 10 → "hello" (5) + " " + "world" (5) = 11 > 10, so they split.
    var c = try collect(testing.allocator, "hello world", 10);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), c.lines.items.len);
    try testing.expectEqualStrings("hello", c.lines.items[0]);
    try testing.expectEqualStrings("world", c.lines.items[1]);
}

test "wrap: multiple words pack greedily then wrap" {
    // width 11: "one two" = 7 fits; + " six" = 11 fits exactly; + " ten" = 15 breaks.
    var c = try collect(testing.allocator, "one two six ten", 11);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), c.lines.items.len);
    try testing.expectEqualStrings("one two six", c.lines.items[0]);
    try testing.expectEqualStrings("ten", c.lines.items[1]);
}

test "wrap: exact fit stays on the line; one pixel less breaks" {
    // "abcde fghij" is 11 bytes. width 11 = exact fit → one line.
    {
        var c = try collect(testing.allocator, "abcde fghij", 11);
        defer c.lines.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), c.lines.items.len);
        try testing.expectEqualStrings("abcde fghij", c.lines.items[0]);
    }
    // width 10 = one less → breaks into two lines.
    {
        var c = try collect(testing.allocator, "abcde fghij", 10);
        defer c.lines.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), c.lines.items.len);
        try testing.expectEqualStrings("abcde", c.lines.items[0]);
        try testing.expectEqualStrings("fghij", c.lines.items[1]);
    }
}

test "wrap: a single word longer than the width hard-breaks on codepoint boundaries" {
    // 26-byte word, width 10 → 10 + 10 + 6.
    var c = try collect(testing.allocator, "abcdefghijklmnopqrstuvwxyz", 10);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), c.lines.items.len);
    try testing.expectEqualStrings("abcdefghij", c.lines.items[0]);
    try testing.expectEqualStrings("klmnopqrst", c.lines.items[1]);
    try testing.expectEqualStrings("uvwxyz", c.lines.items[2]);
}

test "wrap: UTF-8 multibyte word never splits mid-codepoint" {
    // Four snowmen (U+2603, 3 bytes each = 12 bytes). width 7 fits two snowmen (6 bytes),
    // never 7 (which would cut the third snowman's 3-byte sequence in the middle).
    const snowman = "\u{2603}";
    const src = snowman ** 4;
    var c = try collect(testing.allocator, src, 7);
    defer c.lines.deinit(testing.allocator);
    for (c.lines.items) |ln| {
        try testing.expect(std.unicode.utf8ValidateSlice(ln)); // no severed codepoint
    }
    // 12 bytes at 2 snowmen (6 bytes) per line → 2 lines.
    try testing.expectEqual(@as(usize, 2), c.lines.items.len);
    try testing.expectEqualStrings(snowman ** 2, c.lines.items[0]);
    try testing.expectEqualStrings(snowman ** 2, c.lines.items[1]);
}

test "wrap: leading/trailing/multiple spaces collapse at breaks" {
    var c = try collect(testing.allocator, "  hello   world  ", 10);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), c.lines.items.len);
    try testing.expectEqualStrings("hello", c.lines.items[0]);
    try testing.expectEqualStrings("world", c.lines.items[1]);
}

test "wrap: all-space paragraph collapses to one empty line" {
    var c = try collect(testing.allocator, "     ", 10);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), c.lines.items.len);
    try testing.expectEqualStrings("", c.lines.items[0]);
}

test "wrap: embedded newline forces a break within the width" {
    var c = try collect(testing.allocator, "ab\ncd", 100);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), c.lines.items.len);
    try testing.expectEqualStrings("ab", c.lines.items[0]);
    try testing.expectEqualStrings("cd", c.lines.items[1]);
}

test "wrap: double newline yields a genuine empty line" {
    var c = try collect(testing.allocator, "ab\n\ncd", 100);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), c.lines.items.len);
    try testing.expectEqualStrings("ab", c.lines.items[0]);
    try testing.expectEqualStrings("", c.lines.items[1]); // blank row
    try testing.expectEqualStrings("cd", c.lines.items[2]);
}

test "wrap: empty string yields zero lines (zero box)" {
    var c = try collect(testing.allocator, "", 100);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), c.lines.items.len);
}

test "wrap: tiny positive width terminates and emits at least one codepoint per line" {
    // width 1 with a multibyte snowman: prefixBytes floors to 1 byte < 3, so the fallback
    // must still advance one whole codepoint per line rather than loop forever.
    const snowman = "\u{2603}";
    const src = snowman ** 3;
    var c = try collect(testing.allocator, src, 1);
    defer c.lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), c.lines.items.len);
    for (c.lines.items) |ln| {
        try testing.expect(std.unicode.utf8ValidateSlice(ln));
        try testing.expectEqualStrings(snowman, ln); // exactly one codepoint per line
    }
}

test "wrap: emit stop (line budget) halts the walk early" {
    var f = FakeFont{};
    var c = Collector{ .src = "a b c d e", .alloc = testing.allocator, .limit = 2 };
    defer c.lines.deinit(testing.allocator);
    wrapLines("a b c d e", 1, f.measurer(), *Collector, &c, Collector.take);
    try testing.expectEqual(@as(usize, 2), c.lines.items.len);
}

test "wrap: measure and render agreement — one routine, identical spans" {
    // The property the whole design rests on: calling the routine twice with the same
    // inputs (as attach and draw do) yields byte-identical line spans.
    const src = "the quick brown fox jumps";
    var a = try collect(testing.allocator, src, 12);
    defer a.lines.deinit(testing.allocator);
    var b = try collect(testing.allocator, src, 12);
    defer b.lines.deinit(testing.allocator);
    try testing.expectEqual(a.lines.items.len, b.lines.items.len);
    for (a.lines.items, b.lines.items) |la, lb| {
        try testing.expectEqualStrings(la, lb);
    }
}

// --- Tests: ellipsisFit (TEXT-03), same 1px/byte fake ----------------------------------
//
// The fake bills 1px/byte and its `prefixBytes` returns the codepoint-aligned bytes fitting
// `floor(max_w)`. So a cell width reads as a byte budget, and every fit/boundary/UTF-8/tiny
// case below is exact without a font — the same property the wrap tests rely on.

/// Convenience: run `ellipsisFit` with the 1px/byte fake.
fn fit(text: []const u8, cell_w: f32, ellipsis_w: f32) Fit {
    var f = FakeFont{};
    return ellipsisFit(text, cell_w, ellipsis_w, f.measurer());
}

test "ellipsisFit: whole string fits exactly → no elision, full prefix" {
    // 5 bytes, cell 5 → fits exactly, draw it all, no ellipsis.
    const r = fit("hello", 5, 1);
    try testing.expect(!r.elided);
    try testing.expectEqual(@as(usize, 5), r.prefix_len);
}

test "ellipsisFit: one pixel less than full → elides on a codepoint boundary, fits budget" {
    // 5 bytes, cell 4 (one less) with ellipsis_w 1 → budget 3 → prefix "hel", elided.
    const r = fit("hello", 4, 1);
    try testing.expect(r.elided);
    try testing.expectEqual(@as(usize, 3), r.prefix_len); // "hel"
    // prefix + ellipsis must fit the cell: 3 + 1 == 4 <= 4.
    try testing.expect(@as(f32, @floatFromInt(r.prefix_len)) + 1 <= 4);
}

test "ellipsisFit: multibyte prefix never splits a codepoint" {
    // Snowman U+2603 is 3 bytes. Five of them = 15 bytes; cell 8, ellipsis_w 2 → budget 6 →
    // exactly two snowmen (6 bytes), never a mid-sequence 7th byte.
    const snowman = "\u{2603}";
    const src = snowman ** 5;
    const r = fit(src, 8, 2);
    try testing.expect(r.elided);
    try testing.expectEqual(@as(usize, 6), r.prefix_len); // two whole snowmen
    try testing.expect(std.unicode.utf8ValidateSlice(src[0..r.prefix_len]));
}

test "ellipsisFit: budget zero (cell == ellipsis width) → deterministic empty, no overdraw" {
    // Too wide to fit, and ellipsis alone would consume the whole cell → draw nothing.
    const r = fit("hello", 3, 3);
    try testing.expect(!r.elided);
    try testing.expectEqual(@as(usize, 0), r.prefix_len);
}

test "ellipsisFit: cell narrower than the ellipsis → deterministic empty" {
    // budget = cell - ellipsis_w = 2 - 5 < 0 → empty, never a floating ellipsis > cell.
    const r = fit("hello", 2, 5);
    try testing.expect(!r.elided);
    try testing.expectEqual(@as(usize, 0), r.prefix_len);
}

test "ellipsisFit: zero-width cell → draws nothing, terminates" {
    const r = fit("hello", 0, 1);
    try testing.expect(!r.elided);
    try testing.expectEqual(@as(usize, 0), r.prefix_len);
}

test "ellipsisFit: tiny positive cell smaller than one codepoint → empty prefix + ellipsis" {
    // Snowman (3 bytes). cell 2, ellipsis_w 1 → budget 1 → prefixBytes floors to 0 whole
    // codepoints, so empty prefix but ellipsis is applied (deterministic, no split, no loop).
    const r = fit("\u{2603}", 2, 1);
    try testing.expect(r.elided);
    try testing.expectEqual(@as(usize, 0), r.prefix_len);
}

test "ellipsisFit: font-error surrogate (width 0) degrades to no elision" {
    // A width function that always reports 0 (the real FontMeasurer's error path) makes the
    // whole string "fit" any positive cell → no elision, draw whole (safe, never loops).
    const Zero = struct {
        fn width(_: *const anyopaque, _: []const u8) f32 {
            return 0;
        }
        fn prefixBytes(_: *const anyopaque, _: []const u8, _: f32) usize {
            return 0;
        }
        fn measurer(self: *const @This()) Measurer {
            return .{ .ptr = self, .widthFn = width, .prefixBytesFn = prefixBytes };
        }
    };
    var z = Zero{};
    const r = ellipsisFit("anything", 10, 3, z.measurer());
    try testing.expect(!r.elided);
    try testing.expectEqual(@as(usize, "anything".len), r.prefix_len);
}

test "ellipsisFit: determinism — identical inputs yield identical fit (measure == draw)" {
    // remeasure and draw call this with the same inputs; the result must be bit-identical.
    const a = fit("a long enough label to elide", 12, 3);
    const b = fit("a long enough label to elide", 12, 3);
    try testing.expectEqual(a.elided, b.elided);
    try testing.expectEqual(a.prefix_len, b.prefix_len);
}

// --- Tests: TEXT-04 tracking-aware measurer feeds wrap/ellipsis unchanged ----------------
//
// TEXT-04's leverage point: `wrapLines`/`ellipsisFit` take ONLY a `Measurer`, so making the
// measurer tracking-aware (add a fixed device-px `dx` between clusters) makes wrap and
// ellipsis tracking-correct with ZERO changes to these pure routines. This fake bills
// 1px/byte PLUS `dx` between adjacent ASCII bytes (one byte == one cluster here), exactly
// mirroring the real `FontMeasurer`'s tracked path (Σ advances + dx*(n-1)). Because the same
// routine drives both `text.remeasure` (box) and `text.draw` (glyph positions), proving the
// break/fit points shift correctly here proves measure and draw agree under tracking.

/// 1px/byte plus a fixed inter-byte `dx`. For an n-byte ASCII string the width is
/// `n + dx*(n-1)` — the same shape as the font-backed tracked measurer, so break math is exact.
const TrackedFake = struct {
    dx: f32,
    fn width(ptr: *const anyopaque, text: []const u8) f32 {
        const self: *const TrackedFake = @ptrCast(@alignCast(ptr));
        if (text.len == 0) return 0;
        const n: f32 = @floatFromInt(text.len);
        return n + self.dx * (n - 1);
    }
    fn prefixBytes(ptr: *const anyopaque, text: []const u8, max_w: f32) usize {
        const self: *const TrackedFake = @ptrCast(@alignCast(ptr));
        if (max_w <= 0) return 0;
        // Largest k with k + dx*(k-1) <= max_w, walking cluster-by-cluster like the real one.
        var k: usize = 0;
        var w: f32 = 0;
        while (k < text.len) {
            var next = w;
            if (k > 0) next += self.dx;
            next += 1;
            if (next > max_w) break;
            w = next;
            k += 1;
        }
        return k;
    }
    fn measurer(self: *const TrackedFake) Measurer {
        return .{ .ptr = self, .widthFn = width, .prefixBytesFn = prefixBytes };
    }
};

fn collectTracked(alloc: std.mem.Allocator, src: []const u8, max_w: f32, dx: f32) !Collector {
    var f = TrackedFake{ .dx = dx };
    var c = Collector{ .src = src, .alloc = alloc };
    wrapLines(src, max_w, f.measurer(), *Collector, &c, Collector.take);
    return c;
}

test "wrap+tracking: positive tracking makes a line that fit untracked now break" {
    // "abcde fghij" is 11 bytes → untracked width 11 fits a cell of 11 on one line.
    {
        var c = try collect(testing.allocator, "abcde fghij", 11);
        defer c.lines.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), c.lines.items.len);
    }
    // With +1px tracking, "abcde fghij" (11 clusters) = 11 + 1*10 = 21 > 11, so it must wrap.
    // "abcde" alone = 5 + 1*4 = 9 <= 11 fits; adding " fghij" pushes past → break before it.
    {
        var c = try collectTracked(testing.allocator, "abcde fghij", 11, 1);
        defer c.lines.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), c.lines.items.len);
        try testing.expectEqualStrings("abcde", c.lines.items[0]);
        try testing.expectEqualStrings("fghij", c.lines.items[1]);
    }
}

test "wrap+tracking: negative tracking keeps a wider line on one row" {
    // "abcdef ghijkl" is 13 bytes → untracked 13 > 12 wraps to two lines.
    {
        var c = try collect(testing.allocator, "abcdef ghijkl", 12);
        defer c.lines.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), c.lines.items.len);
    }
    // With -0.2px tracking the whole string is 13 + (-0.2)*12 = 10.6 <= 12 → one line.
    {
        var c = try collectTracked(testing.allocator, "abcdef ghijkl", 12, -0.2);
        defer c.lines.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), c.lines.items.len);
        try testing.expectEqualStrings("abcdef ghijkl", c.lines.items[0]);
    }
}

test "wrap+tracking: measure==draw — same tracked measurer yields identical spans twice" {
    // remeasure and draw both feed the tracking-aware measurer; identical inputs must give
    // byte-identical spans, so the reserved box and the drawn (spaced) lines cannot drift.
    const src = "the quick brown fox";
    var a = try collectTracked(testing.allocator, src, 12, 0.5);
    defer a.lines.deinit(testing.allocator);
    var b = try collectTracked(testing.allocator, src, 12, 0.5);
    defer b.lines.deinit(testing.allocator);
    try testing.expectEqual(a.lines.items.len, b.lines.items.len);
    for (a.lines.items, b.lines.items) |la, lb| try testing.expectEqualStrings(la, lb);
}

/// Run `ellipsisFit` with the tracking-aware fake.
fn fitTracked(text: []const u8, cell_w: f32, ellipsis_w: f32, dx: f32) Fit {
    var f = TrackedFake{ .dx = dx };
    return ellipsisFit(text, cell_w, ellipsis_w, f.measurer());
}

test "ellipsisFit+tracking: positive tracking shrinks the fitted prefix" {
    // Untracked: "hello" (5) in cell 5 fits whole, no elision.
    {
        const r = fit("hello", 5, 1);
        try testing.expect(!r.elided);
        try testing.expectEqual(@as(usize, 5), r.prefix_len);
    }
    // With +1px tracking "hello" = 5 + 1*4 = 9 > 5, so it elides. Budget = 5 - 1 = 4;
    // prefixBytes: "hel" = 3 + 1*2 = 5 > 4; "he" = 2 + 1*1 = 3 <= 4 → 2 bytes.
    {
        const r = fitTracked("hello", 5, 1, 1);
        try testing.expect(r.elided);
        try testing.expectEqual(@as(usize, 2), r.prefix_len);
    }
}

test "ellipsisFit+tracking: determinism under tracking (measure == draw)" {
    const a = fitTracked("a long label to elide", 12, 3, 0.5);
    const b = fitTracked("a long label to elide", 12, 3, 0.5);
    try testing.expectEqual(a.elided, b.elided);
    try testing.expectEqual(a.prefix_len, b.prefix_len);
}
