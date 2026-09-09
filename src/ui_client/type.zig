//! `type` — the **centralized, SDL-free typography contract** (TEXT-04). One place that
//! declares the prototype's text roles (size in *logical* px, letter-spacing in `em`,
//! case transform), the single logical→device scale seam, and the pure tracking math both
//! measurement and rendering run. Everything here is host policy and deterministic — no
//! SDL, no allocation, no I/O — so the whole contract is unit-testable without a live font.
//!
//! **Why a module and not scattered constants:** before TEXT-04 the sizes lived as bare
//! `Style{ .font = N }` presets in `style.zig` and there was no scale layer at all. The
//! typography contract (prototype.css `:root`) is a *set* of coupled attributes — size +
//! tracking + case — that must travel together and be applied at exactly one multiply
//! point so VIEW-01 can later feed a real DPI factor without touching every call site.
//!
//! **The contract (confirmed against `prototypes/prototype.css`):**
//!   - body    = 14 logical px, tracking -0.025em, no transform   (the unstyled default)
//!   - small   = 11 logical px, tracking -0.025em, no transform
//!   - heading = 21 logical px, tracking -0.04em,  no transform    (prototype `--h3`)
//!   - eyebrow = 11 logical px, tracking +0.07em,  UPPERCASE       (mid of the 0.05–0.09em band)
//!   All roles are **regular weight (400)**; no bold/italic is packaged (see `docs/fonts.md`).
//!
//! **Scale seam (VIEW-01):** `toDevice(logical_px, scale)` is the *only* logical→device
//! multiply. Until VIEW-01 lands, `scale` is sourced from a single `View.scale` field that
//! defaults to `1`, so today the device px equals the logical px byte-for-byte and nothing
//! changes visually — but the seam exists and every font size already routes through it.
//!
//! **Tracking (the hard invariant):** SDL_ttf has no letter-spacing API, so tracking is
//! host-side. `deviceTracking(em, device_px)` converts an em spacing to an **integer**
//! device-px delta added after each glyph cluster. Rounding to whole device px keeps
//! hairline-crisp alignment (RENDER-06) and — crucially — makes the measure and draw passes
//! bit-identical: both add the *same* integer `dx` between the *same* clusters. The actual
//! cluster iteration lives in `features/text.zig` (it needs the live font's per-glyph
//! advance), but the *policy* (how many device px each gap is) is here, in one function.

const std = @import("std");

/// A case transform applied to the *rendered/measured* bytes of a role. Kept minimal: the
/// prototype only needs `none` and an ASCII `upper` for eyebrow/section labels. Declared
/// here (not in `Style`) so the role table and the transform application share one type.
pub const Transform = enum { none, upper };

/// A typography role: the coupled `(size, tracking, transform)` triple the prototype
/// authors together. `size_logical_px` is pre-scale (VIEW-01 multiplies it); `tracking_em`
/// is letter-spacing in `em` (negative = tighter, the prototype's global default; positive
/// = looser, only the uppercase eyebrow); `transform` is the case rule.
pub const Role = struct {
    size_logical_px: f32,
    tracking_em: f32,
    transform: Transform,
};

// —— The prototype typography contract, one authoritative table ————————————————————————
//
// `body` is the anchor: `style.default_font` equals `body.size_logical_px`, so an unstyled
// text leaf and one explicitly given `style.body` can never drift. All regular weight.

/// Body copy — the base of the ladder and the size a fresh text leaf seeds onto its node.
pub const body: Role = .{ .size_logical_px = 14, .tracking_em = -0.025, .transform = .none };
/// Small/secondary copy (captions, dense readouts).
pub const small: Role = .{ .size_logical_px = 11, .tracking_em = -0.025, .transform = .none };
/// Heading — the prototype `--h3` (21px) with its tighter -0.04em tracking.
pub const heading: Role = .{ .size_logical_px = 21, .tracking_em = -0.04, .transform = .none };
/// Uppercase eyebrow / section label — 11px, UPPERCASE, positive tracking at the middle of
/// the prototype's 0.05–0.09em band. The one role with loosened (positive) tracking.
pub const eyebrow: Role = .{ .size_logical_px = 11, .tracking_em = 0.07, .transform = .upper };

/// The eyebrow tracking band the prototype uses (inclusive), pinned so a test can assert the
/// chosen `eyebrow.tracking_em` sits inside it and future edits stay in range.
pub const eyebrow_tracking_min: f32 = 0.05;
pub const eyebrow_tracking_max: f32 = 0.09;

/// The unstyled/default logical size — defined *from* the body role so "unstyled" and
/// "explicitly body" are provably the same number. `style.default_font` re-exports this.
pub const default_logical_px: f32 = body.size_logical_px;

/// The **one** logical→device multiply (VIEW-01 seam). Clamped to a positive scale and a
/// ≥1px floor so a degenerate scale can never ask the font backend for a 0/negative size.
/// Every font size in the host routes through here before it reaches `Fonts.at`.
pub fn toDevice(logical_px: f32, scale: f32) f32 {
    const s = if (scale > 0) scale else 1;
    return @max(1, logical_px * s);
}

/// The integer device-px letter-spacing added *between* glyph clusters for `tracking_em` at
/// a given device size. Rounded to a whole device pixel so measure and draw stay bit-identical
/// and hairlines stay crisp (RENDER-06). Negative for tighter (the global default), positive
/// for the eyebrow. `0em` (or a rounding that lands on 0) yields `0` — the untracked fast path.
pub fn deviceTracking(tracking_em: f32, device_px: f32) f32 {
    return @round(tracking_em * device_px);
}

/// Apply a role's case transform to `src`, writing into `out` and returning the written
/// slice (or `src` unchanged for `.none`, avoiding a copy on the common path). ASCII-only
/// uppercasing: the prototype eyebrow labels are ASCII, and an ASCII fold never changes a
/// byte's length, so byte offsets — and thus every downstream measure/wrap/clip that indexes
/// the string — are preserved. A non-ASCII byte is passed through untouched (no partial
/// multibyte fold). `out` must be at least `src.len` bytes; on a short buffer the transform
/// declines and returns `src` (caller renders the untransformed source rather than a cut one).
pub fn applyTransform(t: Transform, src: []const u8, out: []u8) []const u8 {
    switch (t) {
        .none => return src,
        .upper => {
            if (out.len < src.len) return src;
            for (src, 0..) |c, i| out[i] = std.ascii.toUpper(c);
            return out[0..src.len];
        },
    }
}

// ============================ Tests (deterministic, SDL-free) =========================

const testing = std.testing;

test "type: role contract matches the prototype (sizes, tracking, transform, weight)" {
    // Sizes — logical px, from prototype.css :root.
    try testing.expectEqual(@as(f32, 14), body.size_logical_px);
    try testing.expectEqual(@as(f32, 11), small.size_logical_px);
    try testing.expectEqual(@as(f32, 21), heading.size_logical_px);
    try testing.expectEqual(@as(f32, 11), eyebrow.size_logical_px);
    // Tracking — global -0.025em, heading -0.04em, eyebrow positive in-band.
    try testing.expectEqual(@as(f32, -0.025), body.tracking_em);
    try testing.expectEqual(@as(f32, -0.025), small.tracking_em);
    try testing.expectEqual(@as(f32, -0.04), heading.tracking_em);
    // Transforms — only the eyebrow is uppercased.
    try testing.expectEqual(Transform.none, body.transform);
    try testing.expectEqual(Transform.none, small.transform);
    try testing.expectEqual(Transform.none, heading.transform);
    try testing.expectEqual(Transform.upper, eyebrow.transform);
}

test "type: eyebrow tracking sits inside the prototype 0.05-0.09em band" {
    try testing.expect(eyebrow.tracking_em >= eyebrow_tracking_min);
    try testing.expect(eyebrow.tracking_em <= eyebrow_tracking_max);
}

test "type: default logical size is the body role (unstyled == body)" {
    try testing.expectEqual(body.size_logical_px, default_logical_px);
    try testing.expectEqual(@as(f32, 14), default_logical_px);
}

test "type: toDevice is identity at scale 1 (VIEW-01 not yet feeding a factor)" {
    try testing.expectEqual(@as(f32, 14), toDevice(14, 1));
    try testing.expectEqual(@as(f32, 21), toDevice(21, 1));
}

test "type: toDevice multiplies by scale and floors at 1px" {
    try testing.expectEqual(@as(f32, 28), toDevice(14, 2));
    try testing.expectEqual(@as(f32, 31.5), toDevice(21, 1.5));
    // A non-positive scale is treated as 1 (never a 0/negative size); then the ≥1px floor.
    try testing.expectEqual(@as(f32, 14), toDevice(14, 0)); // scale<=0 → treated as 1 → 14
    try testing.expectEqual(@as(f32, 14), toDevice(14, -3)); // negative scale → treated as 1 → 14
    try testing.expectEqual(@as(f32, 1), toDevice(0.1, 1)); // 0.1px logical floors to 1px device
}

test "type: deviceTracking rounds em*px to a whole device pixel (crisp, measure==draw)" {
    // -0.025em at 14px = -0.35 → rounds to 0 (the untracked fast path at body size).
    try testing.expectEqual(@as(f32, 0), deviceTracking(-0.025, 14));
    // -0.04em at 21px = -0.84 → -1px.
    try testing.expectEqual(@as(f32, -1), deviceTracking(-0.04, 21));
    // +0.07em at 11px = 0.77 → +1px (eyebrow loosening).
    try testing.expectEqual(@as(f32, 1), deviceTracking(0.07, 11));
    // At a larger (scaled) device size the same em yields a larger integer delta.
    try testing.expectEqual(@as(f32, -1), deviceTracking(-0.025, 42)); // -1.05 → -1
    try testing.expectEqual(@as(f32, 0), deviceTracking(0, 100)); // 0em is always 0
}

test "type: applyTransform none returns the source unchanged (no copy)" {
    var buf: [16]u8 = undefined;
    const r = applyTransform(.none, "Ready", &buf);
    try testing.expectEqualStrings("Ready", r);
    try testing.expectEqual(@as([*]const u8, "Ready"), r.ptr); // same pointer: no copy
}

test "type: applyTransform upper ASCII-folds and preserves byte length/offsets" {
    var buf: [16]u8 = undefined;
    const r = applyTransform(.upper, "In Reach", &buf);
    try testing.expectEqualStrings("IN REACH", r);
    try testing.expectEqual(@as(usize, "In Reach".len), r.len); // length preserved → offsets stable
}

test "type: applyTransform upper leaves non-ASCII bytes untouched (no partial multibyte fold)" {
    var buf: [16]u8 = undefined;
    // "café" — the 'é' is 2 bytes (0xC3 0xA9); ASCII fold must not touch them.
    const src = "cafe\u{0301}"; // 'e' + combining acute, ASCII 'e' folds, combining byte passes
    const r = applyTransform(.upper, src, &buf);
    try testing.expect(std.unicode.utf8ValidateSlice(r)); // still valid UTF-8
    try testing.expectEqual(src.len, r.len);
    try testing.expectEqual(@as(u8, 'E'), r[3]); // the ASCII 'e' uppercased
}

test "type: applyTransform declines on a too-small buffer (returns source, never a cut)" {
    var small_buf: [3]u8 = undefined;
    const r = applyTransform(.upper, "toolong", &small_buf);
    try testing.expectEqualStrings("toolong", r); // untransformed source, not a truncated fold
}
