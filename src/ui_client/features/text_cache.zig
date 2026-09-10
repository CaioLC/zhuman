//! `text_cache` — the **pure, SDL-free seam** for TEXT-05 rendered-text texture caching.
//!
//! The per-frame text hot path (`features/text.zig`) used to rasterize *and* upload *and*
//! free a GPU texture for **every visible string every frame** — an unchanged label paid a
//! full `renderTextSolid → createTextureFromSurface → renderTexture → deinit` round trip
//! 60×/second, and every catalog-filter keystroke re-rasterized the whole visible result
//! set. TEXT-05 caches **one composite white texture per `TextState`** — for **every**
//! variant (single-line, tracked, wrapped, clip, ellipsis, and the tracked combinations) —
//! in the node's pooled `State` (mirroring the `svg` feature) and re-rasterizes **only**
//! when a render-affecting input changes. No variant re-rasterizes on a cache hit.
//!
//! This module owns the parts that need **no SDL**: the cache **key** (every input that
//! affects pixels), the **decision** (hit / miss-and-reupload / abandon-after-reset), and
//! the **backend interface** (`rasterize`/`destroy` + a `generation` source) that
//! `text.zig` backs with the live font+renderer and tests back with a counter-tallying
//! fake. Keeping the key/decision/lifecycle here — away from the renderer — is what makes
//! the whole cache lifecycle (hit, miss, invalidation, failure, reset, prune, reuse,
//! growth, deinit) unit-testable **deterministically and SDL-free**, matching the project's
//! `wrap.zig` fake-measurer and `Pool` tally-counter test culture.
//!
//! **Color strategy (tint-on-blit):** color is deliberately **not** a key dimension. The
//! glyphs are rasterized **white** and tinted at blit time via SDL `setColorMod`/
//! `setAlphaMod` — exactly the `svg.draw` model — so a hover/focus recolor reuses the same
//! cached texture and never churns the cache. This is the "color strategy" TEXT-05 keys on:
//! the strategy is fixed (tint-on-blit), so the RGBA never enters the key.
//!
//! **The generic/host boundary is preserved:** this is `ui_client` host policy. The generic
//! engine (`src/ui`) stays typography/texture-unaware; the `Pool` eviction hook (`cache.zig`)
//! already frees a resource-owning state via its `deinit`, unchanged.

const std = @import("std");

/// Every input that changes the **pixels** of a cached text **composite** — for any variant
/// (single-line, tracked, wrapped, clip, ellipsis, and tracked combinations) — folded into
/// one comparable value. Two states with equal keys produce byte-identical composites, so
/// a matching key is a safe cache hit; any change misses and re-rasterizes. Derived purely
/// from already-resolved `TextState` fields + the live renderer generation — see `keyOf`.
///
/// Enumerated against the TEXT-01..04 render-affecting set (docs/roadmap.md TEXT-05):
///   - `content_hash` — the **accepted, transformed** bytes (`State.text()`); the uppercase
///     eyebrow transform is already folded in-place into the buffer by `style.apply`, so
///     hashing the accepted bytes captures the transform for free. A refused/empty string
///     has no key (see `keyOf` returning null) → no texture.
///   - `px` — device font size (`State.px`, already `logical * scale`); a **scale** change
///     changes `px`, so scale is captured transitively (not double-counted).
///   - `font_id` — a font identity/weight token. One face today (a constant), but keyed now
///     so a future multi-face/weight change invalidates correctly.
///   - `tracking` — TEXT-04 device-px letter-spacing (changes glyph advances/positions).
///   - `overflow` / `overflow_width` — TEXT-03 cell discipline. `.clip` blits the whole
///     string (pixels depend on content only — the clip *rect* is a per-frame render-time
///     op, not a cached pixel), but `.ellipsis` changes the actual pixels (prefix + token),
///     so the cell width must be in the key for the ellipsis path.
///   - `wrap_width` — TEXT-02 constraint. Break spans are a *pure function* of already-keyed
///     inputs (content, width, px, tracking), so keying the width is sufficient.
///   - `generation` — the renderer generation (TEXT-05). A reset bumps it so a texture from
///     a dead renderer can never match and be blitted.
/// Color is **absent by design** (tint-on-blit, see the module doc-comment).
pub const Key = struct {
    content_hash: u64,
    px_bits: u32,
    font_id: u32,
    tracking_bits: u32,
    overflow: u8,
    overflow_width_bits: u32,
    wrap_width_bits: u32,
    generation: u32,

    /// Two keys are equal iff every render-affecting field matches — a cache hit.
    pub fn eql(a: Key, b: Key) bool {
        return a.content_hash == b.content_hash and
            a.px_bits == b.px_bits and
            a.font_id == b.font_id and
            a.tracking_bits == b.tracking_bits and
            a.overflow == b.overflow and
            a.overflow_width_bits == b.overflow_width_bits and
            a.wrap_width_bits == b.wrap_width_bits and
            a.generation == b.generation;
    }
};

/// The single font-identity token today: one face (JetBrainsMonoNL-Regular) at one weight.
/// A constant so it costs nothing now, but present in the key so a future multi-face/weight
/// build invalidates on face/weight change without a key-shape migration.
pub const default_font_id: u32 = 0;

/// The render-affecting inputs `keyOf` folds — the SDL-free projection of a `TextState`
/// plus the live renderer generation. `text.zig` fills this from the pooled state; tests
/// fill it directly. `content` is `null` for a refused/empty string (⇒ no key, no texture).
pub const Inputs = struct {
    content: ?[]const u8,
    px: f32,
    font_id: u32 = default_font_id,
    tracking: f32 = 0,
    /// The `TextState.Overflow` tag as an integer (0 = visible, 1 = clip, 2 = ellipsis).
    overflow: u8 = 0,
    overflow_width: f32 = 0,
    wrap_width: f32 = 0,
    generation: u32,
};

/// Fold `Inputs` into a `Key`, or `null` when there is nothing to cache (a refused/empty
/// string — TEXT-01 whole-refusal — has no pixels and gets no texture). Float fields are
/// keyed by their exact bit pattern (`@bitCast`) so a change of any magnitude misses, and
/// two identical frames hit; content is hashed with Wyhash (same family the key-cache uses).
pub fn keyOf(in: Inputs) ?Key {
    const content = in.content orelse return null;
    if (content.len == 0) return null;
    return .{
        .content_hash = std.hash.Wyhash.hash(0, content),
        .px_bits = @bitCast(in.px),
        .font_id = in.font_id,
        .tracking_bits = @bitCast(in.tracking),
        .overflow = in.overflow,
        .overflow_width_bits = @bitCast(in.overflow_width),
        .wrap_width_bits = @bitCast(in.wrap_width),
        .generation = in.generation,
    };
}

/// What a cached slot should do this frame, decided **without touching the renderer** so the
/// whole lifecycle is testable. `text.draw`/`attach` maps each outcome onto SDL calls.
pub const Decision = union(enum) {
    /// No texture to draw and nothing to cache — a refused/empty string (`keyOf` == null).
    /// The slot must hold no texture; if it somehow does, the caller frees it (renderer alive).
    none,
    /// The stored texture matches the wanted key — reuse it, no rasterize, no upload.
    hit,
    /// Rasterize+upload afresh. `free_old` says whether an existing stored texture must be
    /// `deinit`ed first: true for an ordinary invalidation (content/px/tracking/… changed
    /// while the renderer generation is still live), false whenever the stored generation
    /// differs from the wanted generation. A reset invalidates the old GPU handle regardless
    /// of whether content or another attribute also changed that frame, so every stale-
    /// generation handle must be **abandoned** (set to null) without a `deinit` that could
    /// double-free an already-invalid GPU object.
    miss: struct { free_old: bool },
};

/// Decide this frame's action for a slot holding `stored` (its key, or null when empty)
/// against the `wanted` key (or null for a refused/empty string). The one place the
/// "free vs abandon" rule lives:
///   - wanted == null                      → `.none`
///   - no stored texture                   → `.miss{ free_old = false }`
///   - stored key equals wanted            → `.hit`
///   - stored key differs, same generation → `.miss{ free_old = true }`  (renderer alive: free)
///   - stored key differs, generation moved → `.miss{ free_old = false }` (dead texture: abandon)
///
/// Generation takes precedence over every other key difference. If a status label changes
/// content during the same frame as a device reset, its old texture is still from the dead
/// generation and must be abandoned rather than destroyed.
pub fn decide(stored: ?Key, has_texture: bool, wanted: ?Key) Decision {
    const want = wanted orelse return .none;
    if (!has_texture or stored == null) return .{ .miss = .{ .free_old = false } };
    const have = stored.?;
    if (have.eql(want)) return .hit;
    return .{ .miss = .{ .free_old = have.generation == want.generation } };
}

// ---------------------------------------------------------------------------------------
// Fake backend — deterministic, SDL-free, counter-tallying. Production code (`text.zig`)
// does not use this; it exists so the lifecycle/performance tests below (and the ones
// wired into `test_ui.zig`) can exercise hit/miss/invalidation/failure/reset/prune/reuse/
// growth/deinit with exact counts and no graphics context — the same discipline as
// `wrap.zig`'s 1px/byte fake measurer and the `Pool` tally tests.
// ---------------------------------------------------------------------------------------

/// A sentinel stand-in for an uploaded GPU texture: an id plus the fake generation it was
/// created under (so a test can assert a post-reset texture carries the new generation).
pub const FakeTexture = struct { id: u64, generation: u32 };

/// A deterministic fake rasterizer/uploader. Increments `raster_count` on each successful
/// upload and `destroy_count` on each explicit free, hands out generation-tagged sentinel
/// ids, and can be told to fail the next `rasterize` (to test the no-partial-state retry).
/// `generation` is the live generation source the cache key folds — a test bumps it to
/// simulate a renderer reset. Shared shape: production `text.zig` performs the same three
/// operations against SDL; this fake performs them against counters.
pub const FakeBackend = struct {
    generation: u32 = 0,
    next_id: u64 = 1,
    raster_count: usize = 0,
    destroy_count: usize = 0,
    fail_next: bool = false,

    /// Rasterize+upload one string, returning a fresh generation-tagged sentinel — or
    /// `null` on an injected failure (the production path's `catch return`: no texture, no
    /// key latched, retry next frame). Never leaves partial owned state: a failure hands
    /// back nothing to store.
    pub fn rasterize(self: *FakeBackend) ?FakeTexture {
        if (self.fail_next) {
            self.fail_next = false;
            return null;
        }
        const id = self.next_id;
        self.next_id += 1;
        self.raster_count += 1;
        return .{ .id = id, .generation = self.generation };
    }

    /// Free one uploaded texture (the `deinit` a live-renderer invalidation/prune/teardown
    /// performs). A post-reset **abandon** deliberately does *not* call this.
    pub fn destroy(self: *FakeBackend, _: FakeTexture) void {
        self.destroy_count += 1;
    }
};

/// A pool-cached text slot backed by the **fake** backend — the SDL-free analogue of the
/// real `TextState`'s texture ownership, used only by tests to prove the exactly-once
/// release contract under prune/reuse/growth/teardown/reset through a real `Pool(T)`. It
/// mirrors the ownership rules the real state must honor: store texture+key together, free
/// on invalidation/prune/teardown (renderer alive), abandon on a generation bump.
pub const FakeSlot = struct {
    tex: ?FakeTexture = null,
    key: ?Key = null,
    /// A pointer to the shared backend, threaded in by the test so `deinit` can tally a
    /// destroy. Null in a freshly `init`ed/reused hole until the test wires it; a null
    /// backend with a live texture would be a test bug, not a production path.
    backend: ?*FakeBackend = null,

    pub fn init() FakeSlot {
        return .{};
    }

    /// Bring the slot up to date for `in` (the wanted inputs). Applies the pure `decide`
    /// outcome against the fake backend: hit reuses, miss frees-or-abandons then
    /// re-rasterizes, a rasterize failure latches **no** key (retry next frame), `none`
    /// clears. Returns whether a texture is present to "draw" afterward.
    pub fn sync(self: *FakeSlot, backend: *FakeBackend, in: Inputs) bool {
        self.backend = backend;
        const wanted = keyOf(in);
        switch (decide(self.key, self.tex != null, wanted)) {
            .none => {
                if (self.tex) |t| backend.destroy(t); // renderer alive at a normal clear
                self.tex = null;
                self.key = null;
                return false;
            },
            .hit => return true,
            .miss => |m| {
                if (m.free_old) {
                    if (self.tex) |t| backend.destroy(t);
                }
                // Abandon (no destroy) when !free_old: the old handle died with the renderer.
                self.tex = null;
                self.key = null;
                if (backend.rasterize()) |t| {
                    self.tex = t;
                    self.key = wanted; // latch only on success
                    return true;
                }
                return false; // failure: nothing owned, nothing latched, retry next frame
            },
        }
    }

    /// The `Pool` eviction hook: free the owned texture exactly once on prune/teardown
    /// (renderer alive). Mirrors `TextState.deinit`/`SvgState.deinit`.
    pub fn deinit(self: *FakeSlot) void {
        if (self.tex) |t| {
            if (self.backend) |b| b.destroy(t);
        }
        self.tex = null;
        self.key = null;
    }
};

// ============================ Tests (deterministic, SDL-free) =========================

const testing = std.testing;
const Pool = @import("../../ui/cache.zig").Pool;

test "text_cache: a refused/empty string has no key" {
    try testing.expect(keyOf(.{ .content = null, .px = 14, .generation = 0 }) == null);
    try testing.expect(keyOf(.{ .content = "", .px = 14, .generation = 0 }) == null);
    try testing.expect(keyOf(.{ .content = "x", .px = 14, .generation = 0 }) != null);
}

test "text_cache: key folds every render-affecting dimension and ignores color" {
    const base = Inputs{ .content = "Iron Ingot", .px = 14, .tracking = 0, .overflow = 0, .overflow_width = 0, .wrap_width = 0, .generation = 0 };
    const k0 = keyOf(base).?;
    // Same inputs → equal key (a hit).
    try testing.expect(k0.eql(keyOf(base).?));
    // Content change → miss.
    try testing.expect(!k0.eql(keyOf(.{ .content = "Iron Ingots", .px = 14, .generation = 0 }).?));
    // px (⇐ scale/size) change → miss.
    try testing.expect(!k0.eql(keyOf(.{ .content = "Iron Ingot", .px = 21, .generation = 0 }).?));
    // font identity change → miss.
    try testing.expect(!k0.eql(keyOf(.{ .content = "Iron Ingot", .px = 14, .font_id = 1, .generation = 0 }).?));
    // tracking change → miss.
    try testing.expect(!k0.eql(keyOf(.{ .content = "Iron Ingot", .px = 14, .tracking = 1, .generation = 0 }).?));
    // overflow mode change → miss.
    try testing.expect(!k0.eql(keyOf(.{ .content = "Iron Ingot", .px = 14, .overflow = 2, .generation = 0 }).?));
    // overflow (ellipsis cell) width change → miss.
    try testing.expect(!k0.eql(keyOf(.{ .content = "Iron Ingot", .px = 14, .overflow = 2, .overflow_width = 40, .generation = 0 }).?));
    // wrap width change → miss.
    try testing.expect(!k0.eql(keyOf(.{ .content = "Iron Ingot", .px = 14, .wrap_width = 120, .generation = 0 }).?));
    // generation change → miss.
    try testing.expect(!k0.eql(keyOf(.{ .content = "Iron Ingot", .px = 14, .generation = 1 }).?));
}

test "text_cache: decide — none / first-miss / hit / free-on-content / abandon-on-reset" {
    const a = keyOf(.{ .content = "label", .px = 14, .generation = 0 }).?;
    // wanted == null → none.
    try testing.expectEqual(Decision.none, decide(a, true, null));
    // no stored texture → first miss, nothing to free.
    try testing.expectEqual(@as(bool, false), decide(null, false, a).miss.free_old);
    // stored == wanted → hit.
    try testing.expectEqual(Decision.hit, decide(a, true, a));
    // content changed, same generation → miss that frees the old texture.
    const b = keyOf(.{ .content = "label2", .px = 14, .generation = 0 }).?;
    try testing.expectEqual(@as(bool, true), decide(a, true, b).miss.free_old);
    // Generation advanced with identical text → abandon the stale handle.
    const a_next_gen = keyOf(.{ .content = "label", .px = 14, .generation = 1 }).?;
    try testing.expectEqual(@as(bool, false), decide(a, true, a_next_gen).miss.free_old);
    // Generation takes precedence over simultaneous content/attribute changes: that handle
    // still belongs to the dead renderer and must never be destroyed after reset.
    const changed_next_gen = keyOf(.{ .content = "label2", .px = 21, .tracking = 1, .generation = 1 }).?;
    try testing.expectEqual(@as(bool, false), decide(a, true, changed_next_gen).miss.free_old);
}

test "text_cache: unchanged label rasterizes and uploads exactly once across N frames" {
    var backend = FakeBackend{};
    var slot = FakeSlot.init();
    defer slot.deinit();
    const in = Inputs{ .content = "In Reach", .px = 14, .generation = backend.generation };
    var frame: usize = 0;
    while (frame < 120) : (frame += 1) {
        try testing.expect(slot.sync(&backend, in)); // a texture is present to draw every frame
    }
    try testing.expectEqual(@as(usize, 1), backend.raster_count); // rasterized once, not 120×
    try testing.expectEqual(@as(usize, 0), backend.destroy_count); // no per-frame churn
}

test "text_cache: a content change invalidates exactly once (old freed, new rasterized)" {
    var backend = FakeBackend{};
    var slot = FakeSlot.init();
    defer slot.deinit();
    _ = slot.sync(&backend, .{ .content = "Copper", .px = 14, .generation = backend.generation });
    _ = slot.sync(&backend, .{ .content = "Copper", .px = 14, .generation = backend.generation }); // hit
    try testing.expectEqual(@as(usize, 1), backend.raster_count);
    // Edit the string once.
    _ = slot.sync(&backend, .{ .content = "Copper Wire", .px = 14, .generation = backend.generation });
    try testing.expectEqual(@as(usize, 2), backend.raster_count); // +1, exactly one re-raster
    try testing.expectEqual(@as(usize, 1), backend.destroy_count); // old freed exactly once
}

test "text_cache: renderer reset abandons stale texture even when content changes" {
    var backend = FakeBackend{};
    var slot = FakeSlot.init();
    defer slot.deinit();
    _ = slot.sync(&backend, .{ .content = "Day 42", .px = 14, .generation = backend.generation });
    const old_tex = slot.tex.?;
    try testing.expectEqual(@as(u32, 0), old_tex.generation);
    // Simulate a render-device reset in the same frame that a live status label advances.
    backend.generation = 1;
    _ = slot.sync(&backend, .{ .content = "Day 43", .px = 14, .generation = backend.generation });
    try testing.expectEqual(@as(usize, 2), backend.raster_count); // re-rasterized changed content post-reset
    try testing.expectEqual(@as(usize, 0), backend.destroy_count); // stale handle ABANDONED, never freed
    try testing.expectEqual(@as(u32, 1), slot.tex.?.generation); // new texture carries the new generation
    // Teardown now frees exactly the one live (post-reset) texture.
}

test "text_cache: a rasterize failure latches no key and the next frame retries" {
    var backend = FakeBackend{};
    var slot = FakeSlot.init();
    defer slot.deinit();
    backend.fail_next = true;
    try testing.expect(!slot.sync(&backend, .{ .content = "flaky", .px = 14, .generation = backend.generation }));
    try testing.expect(slot.tex == null); // no partial owned state
    try testing.expect(slot.key == null); // no bad key latched
    try testing.expectEqual(@as(usize, 0), backend.raster_count);
    // Next frame retries and succeeds.
    try testing.expect(slot.sync(&backend, .{ .content = "flaky", .px = 14, .generation = backend.generation }));
    try testing.expectEqual(@as(usize, 1), backend.raster_count);
}

test "text_cache: Pool prune frees a slot's texture exactly once" {
    const alloc = testing.allocator;
    var backend = FakeBackend{};
    var p: Pool(FakeSlot) = .{};
    defer p.deinit(alloc);

    const h = try p.acquire(alloc, 111, 1);
    _ = p.get(h).sync(&backend, .{ .content = "row", .px = 14, .generation = backend.generation });
    try testing.expectEqual(@as(usize, 1), backend.raster_count);
    // Node scrolled away / filtered out: pruned on a later frame → evict frees the texture once.
    try p.prune(alloc, 2);
    try testing.expectEqual(@as(usize, 1), backend.destroy_count);
}

test "text_cache: Pool reuse of a pruned hole re-inits clean (no stale texture, no double free)" {
    const alloc = testing.allocator;
    var backend = FakeBackend{};
    var p: Pool(FakeSlot) = .{};
    defer p.deinit(alloc);

    const a = try p.acquire(alloc, 111, 1);
    _ = p.get(a).sync(&backend, .{ .content = "old", .px = 14, .generation = backend.generation });
    try p.prune(alloc, 2); // frees once
    try testing.expectEqual(@as(usize, 1), backend.destroy_count);

    const reused = try p.acquire(alloc, 222, 2);
    try testing.expectEqual(a, reused); // same physical hole
    try testing.expect(p.get(reused).tex == null); // re-inited clean: no inherited texture
    try testing.expect(p.get(reused).key == null);
    _ = p.get(reused).sync(&backend, .{ .content = "new", .px = 14, .generation = backend.generation });
    try testing.expectEqual(@as(usize, 2), backend.raster_count);
    try testing.expectEqual(@as(usize, 1), backend.destroy_count); // no double free of the pruned occupant
}

test "text_cache: Pool teardown frees each live slot's texture exactly once" {
    const alloc = testing.allocator;
    var backend = FakeBackend{};
    var p: Pool(FakeSlot) = .{};

    const a = try p.acquire(alloc, 1, 1);
    const b = try p.acquire(alloc, 2, 1);
    _ = p.get(a).sync(&backend, .{ .content = "a", .px = 14, .generation = backend.generation });
    _ = p.get(b).sync(&backend, .{ .content = "b", .px = 14, .generation = backend.generation });
    try testing.expectEqual(@as(usize, 2), backend.raster_count);

    p.deinit(alloc); // teardown evicts both live slots
    try testing.expectEqual(@as(usize, 2), backend.destroy_count); // exactly once each
}

test "text_cache: texture handles survive pool growth (handle, not pointer)" {
    const alloc = testing.allocator;
    var backend = FakeBackend{};
    var p: Pool(FakeSlot) = .{};
    defer p.deinit(alloc);

    const h0 = try p.acquire(alloc, 1, 1);
    _ = p.get(h0).sync(&backend, .{ .content = "anchor", .px = 14, .generation = backend.generation });
    const anchor_id = p.get(h0).tex.?.id;

    // Force the backing array to reallocate/move.
    var n: u64 = 2;
    while (n < 300) : (n += 1) {
        const h = try p.acquire(alloc, n, 1);
        _ = p.get(h).sync(&backend, .{ .content = "filler", .px = 14, .generation = backend.generation });
    }
    // The original handle still names the same cached texture after the move.
    try testing.expectEqual(anchor_id, p.get(h0).tex.?.id);
    // Growth did not spuriously re-rasterize the anchor.
    _ = p.get(h0).sync(&backend, .{ .content = "anchor", .px = 14, .generation = backend.generation });
    try testing.expectEqual(anchor_id, p.get(h0).tex.?.id);
}

test "text_cache: filtering a catalog frees only pruned rows, survivors keep one texture" {
    // The TEXT-05 acceptance proof: a scrollable/filterable catalog of M row-label slots.
    // Over several "filter" frames the visible subset changes; only the rows that actually
    // leave the result set are pruned+freed, and every surviving row keeps its single
    // texture (no per-frame re-raster, no per-frame destroy churn).
    const alloc = testing.allocator;
    var backend = FakeBackend{};
    var p: Pool(FakeSlot) = .{};
    defer p.deinit(alloc);

    const M = 8;
    const names = [_][]const u8{ "Iron", "Copper", "Tin", "Coal", "Stone", "Wood", "Clay", "Sand" };
    var keys: [M]u64 = undefined;
    for (0..M) |i| keys[i] = @intCast(1000 + i);

    // Frame 1: all M rows visible → each rasterizes once.
    for (0..M) |i| {
        const h = try p.acquire(alloc, keys[i], 1);
        _ = p.get(h).sync(&backend, .{ .content = names[i], .px = 14, .generation = backend.generation });
    }
    try testing.expectEqual(@as(usize, M), backend.raster_count);
    try testing.expectEqual(@as(usize, 0), backend.destroy_count);

    // Frames 2..K: a filter narrows to the first 3 rows. The other 5 are not re-acquired,
    // so they prune (and free) exactly once total; the 3 survivors hit their cache each
    // frame (no re-raster, no destroy).
    var frame: u64 = 2;
    while (frame < 12) : (frame += 1) {
        for (0..3) |i| {
            const h = try p.acquire(alloc, keys[i], frame);
            try testing.expect(p.get(h).sync(&backend, .{ .content = names[i], .px = 14, .generation = backend.generation }));
        }
        try p.prune(alloc, frame);
    }

    // Survivors never re-rasterized (still M total); the 5 filtered-out rows freed once each.
    try testing.expectEqual(@as(usize, M), backend.raster_count);
    try testing.expectEqual(@as(usize, 5), backend.destroy_count);
}

// ===================== Per-variant composite proofs (all variants cached) =============
//
// TEXT-05 caches EVERY accepted variant as one composite white texture: normal, tracked,
// wrapped, clip, ellipsis, and the tracked combinations. `keyOf` already folds every
// pixel-affecting dimension, and `decide`/`FakeSlot.sync` are variant-agnostic, so these
// prove — SDL-free — that each variant (a) rasterizes+uploads exactly once across 120
// frames of identical inputs (the composite is generated on the miss and blitted, never
// re-rasterized on a hit) and (b) invalidates exactly once when its own pixel-affecting
// key changes, freeing the old composite and uploading a new one. The production
// composite generator (`features/text.zig`'s `renderComposite`) performs the same single
// upload per miss against SDL; here it is one `raster_count` per miss against the fake.

/// Inputs for each variant, all with the same content so the ONLY difference is the
/// variant's own pixel-affecting fields — proving the key distinguishes them.
const variant_inputs = struct {
    const content = "Forage the ridge";
    fn normal(gen: u32) Inputs {
        return .{ .content = content, .px = 14, .generation = gen };
    }
    fn tracked(gen: u32) Inputs {
        return .{ .content = content, .px = 14, .tracking = 1, .generation = gen };
    }
    fn wrapped(gen: u32) Inputs {
        return .{ .content = content, .px = 14, .wrap_width = 80, .generation = gen };
    }
    fn tracked_wrapped(gen: u32) Inputs {
        return .{ .content = content, .px = 14, .tracking = 1, .wrap_width = 80, .generation = gen };
    }
    fn clip(gen: u32) Inputs {
        return .{ .content = content, .px = 14, .overflow = 1, .overflow_width = 64, .generation = gen };
    }
    fn ellipsis(gen: u32) Inputs {
        return .{ .content = content, .px = 14, .overflow = 2, .overflow_width = 64, .generation = gen };
    }
    fn tracked_ellipsis(gen: u32) Inputs {
        return .{ .content = content, .px = 14, .tracking = 1, .overflow = 2, .overflow_width = 64, .generation = gen };
    }
};

test "text_cache: every variant rasterizes its composite exactly once across 120 frames" {
    const variants = [_]*const fn (u32) Inputs{
        variant_inputs.normal,
        variant_inputs.tracked,
        variant_inputs.wrapped,
        variant_inputs.tracked_wrapped,
        variant_inputs.clip,
        variant_inputs.ellipsis,
        variant_inputs.tracked_ellipsis,
    };
    for (variants) |make| {
        var backend = FakeBackend{};
        var slot = FakeSlot.init();
        defer slot.deinit();
        const in = make(backend.generation);
        var frame: usize = 0;
        while (frame < 120) : (frame += 1) {
            try testing.expect(slot.sync(&backend, in)); // a composite is present to blit every frame
        }
        try testing.expectEqual(@as(usize, 1), backend.raster_count); // one composite, not 120
        try testing.expectEqual(@as(usize, 0), backend.destroy_count); // no per-frame churn on any variant
    }
}

test "text_cache: tracked variant invalidates on tracking change, hits otherwise" {
    var backend = FakeBackend{};
    var slot = FakeSlot.init();
    defer slot.deinit();
    _ = slot.sync(&backend, variant_inputs.tracked(backend.generation));
    _ = slot.sync(&backend, variant_inputs.tracked(backend.generation)); // hit
    try testing.expectEqual(@as(usize, 1), backend.raster_count);
    // Change tracking (a pixel-affecting dimension) → exactly one re-raster, old freed once.
    _ = slot.sync(&backend, .{ .content = variant_inputs.content, .px = 14, .tracking = 2, .generation = backend.generation });
    try testing.expectEqual(@as(usize, 2), backend.raster_count);
    try testing.expectEqual(@as(usize, 1), backend.destroy_count);
}

test "text_cache: wrapped variant invalidates on wrap-width change, hits otherwise" {
    var backend = FakeBackend{};
    var slot = FakeSlot.init();
    defer slot.deinit();
    _ = slot.sync(&backend, variant_inputs.wrapped(backend.generation));
    _ = slot.sync(&backend, variant_inputs.wrapped(backend.generation)); // hit
    try testing.expectEqual(@as(usize, 1), backend.raster_count);
    // A different wrap width breaks lines differently → new composite pixels, one re-raster.
    _ = slot.sync(&backend, .{ .content = variant_inputs.content, .px = 14, .wrap_width = 120, .generation = backend.generation });
    try testing.expectEqual(@as(usize, 2), backend.raster_count);
    try testing.expectEqual(@as(usize, 1), backend.destroy_count);
}

test "text_cache: ellipsis variant invalidates on cell-width change (prefix+token pixels), hits otherwise" {
    var backend = FakeBackend{};
    var slot = FakeSlot.init();
    defer slot.deinit();
    _ = slot.sync(&backend, variant_inputs.ellipsis(backend.generation));
    _ = slot.sync(&backend, variant_inputs.ellipsis(backend.generation)); // hit
    try testing.expectEqual(@as(usize, 1), backend.raster_count);
    // The ellipsis cell width changes the fitted prefix + token, i.e. the actual pixels →
    // one re-raster, old freed once. (For `.clip` the cell width is a conservative miss —
    // same guarantee, never a stale hit.)
    _ = slot.sync(&backend, .{ .content = variant_inputs.content, .px = 14, .overflow = 2, .overflow_width = 40, .generation = backend.generation });
    try testing.expectEqual(@as(usize, 2), backend.raster_count);
    try testing.expectEqual(@as(usize, 1), backend.destroy_count);
}

test "text_cache: clip variant caches whole-string pixels; content change invalidates once" {
    var backend = FakeBackend{};
    var slot = FakeSlot.init();
    defer slot.deinit();
    _ = slot.sync(&backend, variant_inputs.clip(backend.generation));
    _ = slot.sync(&backend, variant_inputs.clip(backend.generation)); // hit — the clip RECT is per-frame, the pixels are cached
    try testing.expectEqual(@as(usize, 1), backend.raster_count);
    // The clip cell's cached pixels are the whole string; a content edit re-rasterizes once.
    _ = slot.sync(&backend, .{ .content = "Forage the vale", .px = 14, .overflow = 1, .overflow_width = 64, .generation = backend.generation });
    try testing.expectEqual(@as(usize, 2), backend.raster_count);
    try testing.expectEqual(@as(usize, 1), backend.destroy_count);
}

test "text_cache: switching variant on the same node invalidates once per switch (no stale hit)" {
    // A pooled node reused as a different variant (e.g. a label re-purposed as a wrapped
    // block, then an ellipsis cell) must never blit a stale composite: each switch is a
    // key change ⇒ exactly one re-raster and one free of the prior composite.
    var backend = FakeBackend{};
    var slot = FakeSlot.init();
    defer slot.deinit();
    _ = slot.sync(&backend, variant_inputs.normal(backend.generation));
    try testing.expectEqual(@as(usize, 1), backend.raster_count);
    _ = slot.sync(&backend, variant_inputs.wrapped(backend.generation));
    try testing.expectEqual(@as(usize, 2), backend.raster_count);
    try testing.expectEqual(@as(usize, 1), backend.destroy_count);
    _ = slot.sync(&backend, variant_inputs.ellipsis(backend.generation));
    try testing.expectEqual(@as(usize, 3), backend.raster_count);
    try testing.expectEqual(@as(usize, 2), backend.destroy_count);
    _ = slot.sync(&backend, variant_inputs.tracked(backend.generation));
    try testing.expectEqual(@as(usize, 4), backend.raster_count);
    try testing.expectEqual(@as(usize, 3), backend.destroy_count);
}

test "text_cache: composite generation is atomic — a failed generation latches no key and retries, on any variant" {
    // Failure atomicity of the composite generator: if `renderComposite` fails (target
    // create / clear / any stamp aborts), the production path frees the partial texture and
    // latches NO key, so the slot owns nothing and the next frame retries. The fake models
    // this exactly: a failed `rasterize` returns null, `sync` stores neither texture nor key.
    const variants = [_]*const fn (u32) Inputs{
        variant_inputs.tracked,
        variant_inputs.wrapped,
        variant_inputs.clip,
        variant_inputs.ellipsis,
        variant_inputs.tracked_ellipsis,
    };
    for (variants) |make| {
        var backend = FakeBackend{};
        var slot = FakeSlot.init();
        defer slot.deinit();
        backend.fail_next = true;
        try testing.expect(!slot.sync(&backend, make(backend.generation))); // composite failed
        try testing.expect(slot.tex == null); // no partial owned composite
        try testing.expect(slot.key == null); // no key latched on a failed generation
        try testing.expectEqual(@as(usize, 0), backend.raster_count);
        try testing.expectEqual(@as(usize, 0), backend.destroy_count);
        // Next frame retries and succeeds — the composite is generated exactly once.
        try testing.expect(slot.sync(&backend, make(backend.generation)));
        try testing.expectEqual(@as(usize, 1), backend.raster_count);
    }
}

test "text_cache: renderer reset abandons then re-rasterizes each variant's composite (never double-free)" {
    // A render-device reset invalidates every uploaded composite. A generation change
    // must ABANDON the dead handle (no destroy — the GPU object already died with the device)
    // and re-rasterize under the new generation, on every variant. Verified here for the
    // multi-surface variants that previously re-rasterized per frame.
    const variants = [_]*const fn (u32) Inputs{
        variant_inputs.tracked,
        variant_inputs.wrapped,
        variant_inputs.ellipsis,
        variant_inputs.clip,
    };
    for (variants) |make| {
        var backend = FakeBackend{};
        var slot = FakeSlot.init();
        defer slot.deinit();
        _ = slot.sync(&backend, make(backend.generation));
        try testing.expectEqual(@as(u32, 0), slot.tex.?.generation);
        backend.generation = 1; // device reset
        _ = slot.sync(&backend, make(backend.generation));
        try testing.expectEqual(@as(usize, 2), backend.raster_count); // re-rasterized post-reset
        try testing.expectEqual(@as(usize, 0), backend.destroy_count); // abandoned, never freed
        try testing.expectEqual(@as(u32, 1), slot.tex.?.generation); // new composite, new generation
    }
}

test "text_cache: a catalog of mixed variants keeps one composite each across 120 frames" {
    // The acceptance proof generalized to mixed variants (the real HUD mixes labels, wrapped
    // body copy, ellipsized cells, and tracked eyebrows): every surviving slot rasterizes its
    // composite once and blits it for 120 frames — no per-frame raster or destroy for ANY
    // variant, through a real Pool.
    const alloc = testing.allocator;
    var backend = FakeBackend{};
    var p: Pool(FakeSlot) = .{};
    defer p.deinit(alloc);

    const makers = [_]*const fn (u32) Inputs{
        variant_inputs.normal,
        variant_inputs.tracked,
        variant_inputs.wrapped,
        variant_inputs.tracked_wrapped,
        variant_inputs.clip,
        variant_inputs.ellipsis,
        variant_inputs.tracked_ellipsis,
    };
    const N = makers.len;

    var frame: u64 = 1;
    while (frame < 121) : (frame += 1) {
        for (0..N) |i| {
            // Re-acquire each slot every frame (a live catalog row), then sync its variant.
            const h = try p.acquire(alloc, @intCast(2000 + i), frame);
            try testing.expect(p.get(h).sync(&backend, makers[i](backend.generation)));
        }
        try p.prune(alloc, frame); // nothing leaves the result set, so nothing is pruned
    }
    try testing.expectEqual(@as(usize, N), backend.raster_count); // one composite per variant, ever
    try testing.expectEqual(@as(usize, 0), backend.destroy_count); // zero churn across 120 frames
}
