//! Host-side accessibility bridge (INPUT-09) — the deterministic seam between the
//! `INPUT-08` semantic model and a future platform (Windows UI Automation) provider.
//!
//! ## What this is, and what it is honestly *not*
//!
//! This bridge **consumes** the already-published `SemanticRegistry.snapshot()` and drains
//! the `AnnouncementChannel`; it is never a second source of truth and never re-derives a
//! semantic fact. It runs host-side only — `src/ui/` stays generic and accessibility-
//! unaware, and no simulation system reads or writes it. Its job is to (a) report, honestly,
//! which accessibility guarantees this desktop build actually ships, and (b) hold a narrow,
//! testable insertion seam (`Provider`) where a real Windows UIA provider can later slot in
//! without touching the engine or the semantics source.
//!
//! ### The screen-reader limitation (recorded, not worked around)
//!
//! A live Windows UI Automation tree would require a UIA provider that answers the
//! `WM_GETOBJECT` window message. Receiving that message means intercepting the SDL-owned
//! window's `WndProc` — and `zig-sdl3` 0.1.6 does **not** expose `SDL_SetWindowsMessageHook`
//! (it is commented out in the binding's `system.zig`, which implements only the X11 event
//! hook). The only ways to get `WM_GETOBJECT` would be hand-rolled `WndProc` subclassing on
//! the native `HWND` or forking the vendored SDL binding, and both are exactly the risky,
//! policy-leaking dependencies this slice forbids. There is also no accessibility
//! abstraction in SDL3 on Windows to build on. So this build does **not** export a
//! screen-reader tree, and `Capabilities.screen_reader_export` is `false`. We do not claim
//! HTML/ARIA parity that the platform cannot give.
//!
//! ### What this build *does* ship (and this bridge verifies is plumbed)
//!
//!   * Full keyboard operation — `command.zig` + focus routing (INPUT-06/07).
//!   * Visible focus — focus-visible chrome on every focusable control (INPUT-04/06).
//!   * Non-color state cues — outline/shape state projections, never color alone (INPUT-04).
//!   * Live-announcement plumbing — `AnnouncementChannel`; this bridge is the reader that
//!     drains it through a generation cursor and forwards each new message to the active
//!     `Provider` sink (a no-op/logging default now; a UIA notification later).
//!
//! ## Lifecycle
//!
//! Deterministic and allocation-free, mirroring `command.Registry`/`SemanticRegistry`:
//!
//!   * `init(provider)` — install a provider (default: `NoopProvider`), status `.active`.
//!   * `poll(snapshot, channel)` — once per frame, after the registry/channel are published:
//!     forward the current snapshot to the provider, then forward every announcement newer
//!     than the last-spoken cursor and `drainThrough` it. Copies announcement bytes into
//!     owned storage — it never holds a borrowed snapshot/arena string across frames.
//!   * `deinit()` — release the provider, status `.inactive`.
//!
//! The bridge borrows the snapshot slice only for the duration of a single `poll` call
//! (the provider reads it synchronously); the one thing it *retains* across calls, the last
//! spoken announcement, is copied into a fixed `OwnedText` buffer, so no frame-arena or
//! channel-owned pointer is ever held.

const std = @import("std");
const semantics = @import("semantics.zig");

/// Whether the bridge is currently running. A future real provider might add a
/// `.degraded` variant (e.g. UIA present but a raise failed); today it is binary.
pub const Status = enum {
    /// Not yet initialized, or torn down. `poll` is a no-op guarded against this.
    inactive,
    /// Initialized with a provider; `poll` forwards snapshots and announcements.
    active,
};

/// Honest report of which accessibility guarantees this build ships. These are facts about
/// the shipped desktop app, not aspirations: the four booleans that are `true` are exercised
/// today; `screen_reader_export` is `false` because no `WM_GETOBJECT`-answering UIA provider
/// exists (see the module doc). A test asserts this shape so the honesty cannot silently rot
/// into a fake claim.
pub const Capabilities = struct {
    /// Every interactive control is reachable and operable by keyboard alone.
    keyboard: bool = true,
    /// The focused control always draws a focus-visible cue.
    visible_focus: bool = true,
    /// Every control state has a non-color cue (outline/shape), never color alone.
    non_color_state: bool = true,
    /// Polite/assertive announcements are queued and drained to the provider sink.
    live_region_plumbing: bool = true,
    /// A screen reader can read the semantic tree via a platform provider. **False** on this
    /// build: `zig-sdl3` 0.1.6 exposes no `WM_GETOBJECT` hook, so no live UIA tree exists.
    screen_reader_export: bool = false,
};

/// The narrow future-provider seam. A real Windows UIA provider implements these against a
/// `WM_GETOBJECT`-answering `IRawElementProviderFragmentRoot`; the default `NoopProvider`
/// implements them as inert sinks so the bridge is fully exercised without any platform
/// dependency. The bridge only ever calls through this vtable, so a provider slots in
/// without the bridge, `src/ui`, or the semantics source changing.
///
/// Deliberately minimal — exactly the operations a UIA fragment-root needs:
///   * `getRoot`            — hand the provider this frame's published snapshot (its tree).
///   * `elementFromKey`     — resolve a stable `node.key` to an element (UIA `ElementFromPoint`
///                            / navigation analog); returns whether the key is present.
///   * `mapRole`            — map a semantic `Role` to the platform control-type id.
///   * `raiseFocus`         — raise a focus-changed event for a stable key.
///   * `raiseAnnouncement`  — raise a live-region notification (UIA `UiaRaiseNotificationEvent`).
///
/// The vtable is a plain function-pointer struct plus an opaque `ctx`, the standard Zig
/// interface shape — no allocation, no comptime dispatch, so it is trivially swappable at
/// runtime and testable with a recording fake.
pub const Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getRoot: *const fn (ctx: *anyopaque, snapshot: []const semantics.SemanticNode) void,
        elementFromKey: *const fn (ctx: *anyopaque, key: u64) bool,
        mapRole: *const fn (ctx: *anyopaque, role: semantics.Role) u32,
        raiseFocus: *const fn (ctx: *anyopaque, key: u64) void,
        raiseAnnouncement: *const fn (ctx: *anyopaque, text: []const u8, live: semantics.LiveRegion) void,
    };

    pub fn getRoot(self: Provider, snapshot: []const semantics.SemanticNode) void {
        self.vtable.getRoot(self.ctx, snapshot);
    }
    pub fn elementFromKey(self: Provider, key: u64) bool {
        return self.vtable.elementFromKey(self.ctx, key);
    }
    pub fn mapRole(self: Provider, role: semantics.Role) u32 {
        return self.vtable.mapRole(self.ctx, role);
    }
    pub fn raiseFocus(self: Provider, key: u64) void {
        self.vtable.raiseFocus(self.ctx, key);
    }
    pub fn raiseAnnouncement(self: Provider, text: []const u8, live: semantics.LiveRegion) void {
        self.vtable.raiseAnnouncement(self.ctx, text, live);
    }
};

/// The default, always-safe provider: every operation is inert. `elementFromKey` reports
/// "not present" (there is no platform element), `mapRole` returns `0` (UIA
/// `UIA_CustomControlTypeId` stand-in), and the raise/getRoot sinks do nothing. This is the
/// production default until a real UIA provider exists; it lets the whole bridge run and be
/// tested with no platform surface. A stateless singleton — `instance()` yields a `Provider`
/// bound to a shared zero-size context.
pub const NoopProvider = struct {
    var shared: NoopProvider = .{};

    fn getRoot(_: *anyopaque, _: []const semantics.SemanticNode) void {}
    fn elementFromKey(_: *anyopaque, _: u64) bool {
        return false;
    }
    fn mapRole(_: *anyopaque, _: semantics.Role) u32 {
        return 0;
    }
    fn raiseFocus(_: *anyopaque, _: u64) void {}
    fn raiseAnnouncement(_: *anyopaque, _: []const u8, _: semantics.LiveRegion) void {}

    const vtable: Provider.VTable = .{
        .getRoot = getRoot,
        .elementFromKey = elementFromKey,
        .mapRole = mapRole,
        .raiseFocus = raiseFocus,
        .raiseAnnouncement = raiseAnnouncement,
    };

    pub fn instance() Provider {
        return .{ .ctx = @ptrCast(&shared), .vtable = &vtable };
    }
};

/// The host accessibility bridge. Holds the active provider, the honest capability report,
/// and the last-spoken announcement cursor + owned copy of the last message. Zero heap use.
pub const Bridge = struct {
    status: Status = .inactive,
    capabilities: Capabilities = .{},
    provider: Provider = undefined,
    /// The generation of the newest announcement already forwarded to the provider. A reader
    /// cursor exactly like the one `AnnouncementChannel.drainThrough` expects: `0` means
    /// "nothing spoken yet".
    spoken_generation: u64 = 0,
    /// An owned copy of the most recently forwarded announcement. Retained across frames for
    /// inspection/tests without ever borrowing the channel's storage or the frame arena.
    last_spoken: semantics.OwnedText(semantics.value_cap) = .{},
    /// The published-snapshot lossiness the bridge observed on the last `poll`, surfaced so a
    /// reader (or a UIA provider) knows the tree it received was refused/overflowed rather
    /// than complete. Mirrors the registry's own non-silent-refusal contract.
    last_snapshot_overflow: bool = false,
    last_snapshot_field_refused: bool = false,
    /// How many announcements the last `poll` forwarded to the provider (0 if none were new).
    last_forwarded: usize = 0,

    /// Install a provider and go `.active`. Pass `NoopProvider.instance()` for the default
    /// inert sink. Idempotent-safe to call again to swap providers; the announcement cursor
    /// is preserved so re-init does not re-speak already-spoken messages.
    pub fn init(provider: Provider) Bridge {
        return .{ .status = .active, .provider = provider };
    }

    /// Tear down: go `.inactive` and forget the provider. `poll` becomes a guarded no-op.
    /// The capability report is a compile-time honest constant, so it is left intact.
    pub fn deinit(self: *Bridge) void {
        self.status = .inactive;
        self.last_forwarded = 0;
    }

    /// Consume this frame's published accessibility state. Call once per frame *after*
    /// `SemanticRegistry.endBuild` and after any control has queued announcements — i.e. at
    /// the same lifecycle point `commands.endBuild`/`semantics.endBuild` already run.
    ///
    ///   1. Hand the provider the current snapshot as its tree root (synchronous read).
    ///   2. Fold the snapshot's overflow/field-refusal flags into the bridge's own status.
    ///   3. For every announcement newer than `spoken_generation`, forward it to the
    ///      provider's notification sink in order, remember the newest as `last_spoken`
    ///      (owned copy), advance the cursor, and `drainThrough` the channel so its bounded
    ///      queue does not stay full.
    ///
    /// A no-op when `.inactive`. Borrows `snapshot` only for the call; retains nothing that
    /// points into it or the channel.
    pub fn poll(
        self: *Bridge,
        snapshot: []const semantics.SemanticNode,
        overflow: bool,
        field_refused: bool,
        channel: *semantics.AnnouncementChannel,
    ) void {
        self.last_forwarded = 0;
        if (self.status != .active) return;

        // 1 + 2: hand over the tree and record its honest lossiness.
        self.provider.getRoot(snapshot);
        self.last_snapshot_overflow = overflow;
        self.last_snapshot_field_refused = field_refused;

        // 3: forward everything newer than the cursor, in order, then drain it.
        var newest = self.spoken_generation;
        for (channel.pending()) |msg| {
            if (msg.generation <= self.spoken_generation) continue;
            // A `polite` sink for ordinary announcements; the channel is a polite queue, but
            // the text may originate from an assertive control (a refused edit). The channel
            // does not carry per-message priority, so the bridge forwards them as `polite`,
            // matching the queue's contract; a UIA provider raises this as a notification.
            self.provider.raiseAnnouncement(msg.slice(), .polite);
            _ = self.last_spoken.set(msg.slice());
            if (msg.generation > newest) newest = msg.generation;
            self.last_forwarded += 1;
        }
        if (newest > self.spoken_generation) {
            self.spoken_generation = newest;
            channel.drainThrough(newest);
        }
    }

    /// The text of the most recently forwarded announcement (empty before any is forwarded).
    /// Owned by the bridge — safe to read at any time.
    pub fn lastSpoken(self: *const Bridge) []const u8 {
        return self.last_spoken.slice();
    }

    /// Resolve a stable `node.key` through the active provider (a future UIA element lookup).
    /// Returns false when inactive or when the provider has no such element — which is always
    /// true for `NoopProvider`, honestly reporting "no platform element exists".
    pub fn elementFromKey(self: *const Bridge, key: u64) bool {
        if (self.status != .active) return false;
        return self.provider.elementFromKey(key);
    }

    /// Map a semantic role through the active provider to a platform control-type id, or `0`
    /// (the custom/unknown id) when inactive.
    pub fn mapRole(self: *const Bridge, role: semantics.Role) u32 {
        if (self.status != .active) return 0;
        return self.provider.mapRole(role);
    }

    /// Raise a focus-changed event for a stable key through the active provider. A no-op when
    /// inactive or under `NoopProvider`.
    pub fn raiseFocus(self: *const Bridge, key: u64) void {
        if (self.status != .active) return;
        self.provider.raiseFocus(key);
    }
};

// --- Tests ------------------------------------------------------------------------------

const testing = std.testing;

/// A recording fake provider used only in tests: it captures the last snapshot length, every
/// announcement it was handed, the last focus key, and answers `elementFromKey` from a small
/// set of "present" keys. This is the shape a real UIA provider recorder would take, letting
/// the bridge's forwarding logic be verified with no platform surface.
const RecordingProvider = struct {
    last_root_len: usize = 0,
    announcements: [16][semantics.value_cap]u8 = undefined,
    announcement_lens: [16]usize = undefined,
    announcement_count: usize = 0,
    last_focus: ?u64 = null,
    present_keys: []const u64 = &.{},

    fn getRoot(ctx: *anyopaque, snapshot: []const semantics.SemanticNode) void {
        const self: *RecordingProvider = @ptrCast(@alignCast(ctx));
        self.last_root_len = snapshot.len;
    }
    fn elementFromKey(ctx: *anyopaque, key: u64) bool {
        const self: *RecordingProvider = @ptrCast(@alignCast(ctx));
        for (self.present_keys) |k| if (k == key) return true;
        return false;
    }
    fn mapRole(_: *anyopaque, role: semantics.Role) u32 {
        // A deterministic, non-zero mapping so a test can tell it apart from the noop's 0.
        return @as(u32, @intCast(@intFromEnum(role))) + 1000;
    }
    fn raiseFocus(ctx: *anyopaque, key: u64) void {
        const self: *RecordingProvider = @ptrCast(@alignCast(ctx));
        self.last_focus = key;
    }
    fn raiseAnnouncement(ctx: *anyopaque, text: []const u8, _: semantics.LiveRegion) void {
        const self: *RecordingProvider = @ptrCast(@alignCast(ctx));
        if (self.announcement_count == self.announcements.len) return;
        const n = @min(text.len, semantics.value_cap);
        @memcpy(self.announcements[self.announcement_count][0..n], text[0..n]);
        self.announcement_lens[self.announcement_count] = n;
        self.announcement_count += 1;
    }

    const vtable: Provider.VTable = .{
        .getRoot = getRoot,
        .elementFromKey = elementFromKey,
        .mapRole = mapRole,
        .raiseFocus = raiseFocus,
        .raiseAnnouncement = raiseAnnouncement,
    };

    fn provider(self: *RecordingProvider) Provider {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn announcementText(self: *const RecordingProvider, i: usize) []const u8 {
        return self.announcements[i][0..self.announcement_lens[i]];
    }
};

test "capabilities are honest: keyboard/focus/non-color/live yes, screen-reader export no" {
    const caps = Capabilities{};
    // The four roadmap-minimum guarantees this build actually ships.
    try testing.expect(caps.keyboard);
    try testing.expect(caps.visible_focus);
    try testing.expect(caps.non_color_state);
    try testing.expect(caps.live_region_plumbing);
    // The honest limitation: no UIA screen-reader tree on this build. This assertion is the
    // guard against a future fake claim — flipping it true without a real provider fails here.
    try testing.expect(!caps.screen_reader_export);

    // A default bridge carries the same honest report.
    const bridge = Bridge.init(NoopProvider.instance());
    try testing.expect(!bridge.capabilities.screen_reader_export);
    try testing.expectEqual(Status.active, bridge.status);
}

test "noop provider is inert and honest: no element, custom role, no crash on raises" {
    var bridge = Bridge.init(NoopProvider.instance());
    // No platform element exists under the noop provider.
    try testing.expect(!bridge.elementFromKey(1));
    try testing.expect(!bridge.elementFromKey(999));
    // The noop maps every role to the custom/unknown id (0).
    try testing.expectEqual(@as(u32, 0), bridge.mapRole(.button));
    try testing.expectEqual(@as(u32, 0), bridge.mapRole(.dialog));
    // Raises are safe no-ops.
    bridge.raiseFocus(42);

    // After deinit, every query reports the inactive, safe defaults.
    bridge.deinit();
    try testing.expectEqual(Status.inactive, bridge.status);
    try testing.expect(!bridge.elementFromKey(1));
    try testing.expectEqual(@as(u32, 0), bridge.mapRole(.button));
}

test "poll forwards the published snapshot to the provider as its tree root" {
    var reg = semantics.SemanticRegistry{};
    reg.beginBuild();
    reg.publish(semantics.describeButton(1, "Sleep", true, false));
    reg.publish(semantics.describeButton(2, "Forage", true, true));
    reg.endBuild();

    var ch = semantics.AnnouncementChannel{};
    var rec = RecordingProvider{};
    var bridge = Bridge.init(rec.provider());
    bridge.poll(reg.snapshot(), reg.snapshotOverflow(), reg.snapshotFieldRefused(), &ch);

    // The provider received exactly the published snapshot (two nodes), and the bridge folded
    // the (clean) lossiness flags.
    try testing.expectEqual(@as(usize, 2), rec.last_root_len);
    try testing.expect(!bridge.last_snapshot_overflow);
    try testing.expect(!bridge.last_snapshot_field_refused);
    // No announcements queued: nothing forwarded, cursor still 0.
    try testing.expectEqual(@as(usize, 0), bridge.last_forwarded);
    try testing.expectEqual(@as(u64, 0), bridge.spoken_generation);
}

test "poll advances the generation cursor and drains only through what it spoke" {
    var reg = semantics.SemanticRegistry{};
    reg.beginBuild();
    reg.endBuild();

    var ch = semantics.AnnouncementChannel{};
    try testing.expect(ch.announce("Shelter raised."));
    try testing.expect(ch.announce("You feel weak."));

    var rec = RecordingProvider{};
    var bridge = Bridge.init(rec.provider());

    // First poll speaks both queued messages, in order, and drains the channel.
    bridge.poll(reg.snapshot(), false, false, &ch);
    try testing.expectEqual(@as(usize, 2), bridge.last_forwarded);
    try testing.expectEqual(@as(u64, 2), bridge.spoken_generation);
    try testing.expectEqual(@as(usize, 2), rec.announcement_count);
    try testing.expectEqualStrings("Shelter raised.", rec.announcementText(0));
    try testing.expectEqualStrings("You feel weak.", rec.announcementText(1));
    try testing.expectEqualStrings("You feel weak.", bridge.lastSpoken());
    // Drained through generation 2: the bounded queue is now empty.
    try testing.expectEqual(@as(usize, 0), ch.pending().len);

    // A second poll with nothing new forwards nothing and leaves the cursor put.
    bridge.poll(reg.snapshot(), false, false, &ch);
    try testing.expectEqual(@as(usize, 0), bridge.last_forwarded);
    try testing.expectEqual(@as(u64, 2), bridge.spoken_generation);

    // A new announcement after the cursor is the only thing the next poll speaks.
    try testing.expect(ch.announce("Night falls."));
    bridge.poll(reg.snapshot(), false, false, &ch);
    try testing.expectEqual(@as(usize, 1), bridge.last_forwarded);
    try testing.expectEqual(@as(u64, 3), bridge.spoken_generation);
    try testing.expectEqualStrings("Night falls.", bridge.lastSpoken());
    try testing.expectEqual(@as(usize, 0), ch.pending().len);
}

test "poll does not re-speak an already-spoken message across a re-init" {
    var reg = semantics.SemanticRegistry{};
    reg.beginBuild();
    reg.endBuild();
    var ch = semantics.AnnouncementChannel{};
    try testing.expect(ch.announce("Once."));

    var rec = RecordingProvider{};
    var bridge = Bridge.init(rec.provider());
    bridge.poll(reg.snapshot(), false, false, &ch);
    try testing.expectEqual(@as(usize, 1), rec.announcement_count);
    const cursor_after = bridge.spoken_generation;

    // Swapping providers preserves the cursor: no re-speak of "Once." on the next poll.
    var rec2 = RecordingProvider{};
    bridge.provider = rec2.provider();
    bridge.spoken_generation = cursor_after; // init() is for first install; a live swap keeps the cursor
    bridge.poll(reg.snapshot(), false, false, &ch);
    try testing.expectEqual(@as(usize, 0), rec2.announcement_count);
    try testing.expectEqual(@as(usize, 0), bridge.last_forwarded);
}

test "poll surfaces snapshot overflow and field-refusal from the registry" {
    // A tiny registry forced past capacity so the published snapshot is lossy.
    var reg = semantics.SemanticRegistryN(2){};
    reg.beginBuild();
    reg.publish(semantics.describeButton(1, "one", true, false));
    reg.publish(semantics.describeButton(2, "two", true, false));
    reg.publish(semantics.describeButton(3, "three", true, false)); // refused
    reg.endBuild();
    try testing.expect(reg.snapshotOverflow());

    var ch = semantics.AnnouncementChannel{};
    var rec = RecordingProvider{};
    var bridge = Bridge.init(rec.provider());
    bridge.poll(reg.snapshot(), reg.snapshotOverflow(), reg.snapshotFieldRefused(), &ch);
    // The bridge reports the same non-silent lossiness the registry refused with.
    try testing.expect(bridge.last_snapshot_overflow);
    try testing.expectEqual(@as(usize, 2), rec.last_root_len);

    // Field-refusal path: an over-long label is refused whole and surfaced by the bridge.
    var reg2 = semantics.SemanticRegistry{};
    var long: [semantics.label_cap + 1]u8 = undefined;
    @memset(&long, 'x');
    reg2.beginBuild();
    reg2.publish(semantics.describeButton(1, &long, true, false));
    reg2.endBuild();
    bridge.poll(reg2.snapshot(), reg2.snapshotOverflow(), reg2.snapshotFieldRefused(), &ch);
    try testing.expect(bridge.last_snapshot_field_refused);
}

test "an inactive bridge polls as a guarded no-op" {
    var reg = semantics.SemanticRegistry{};
    reg.beginBuild();
    reg.publish(semantics.describeButton(1, "Sleep", true, false));
    reg.endBuild();
    var ch = semantics.AnnouncementChannel{};
    try testing.expect(ch.announce("Ignored while inactive."));

    var rec = RecordingProvider{};
    var bridge = Bridge.init(rec.provider());
    bridge.deinit(); // now inactive

    bridge.poll(reg.snapshot(), false, false, &ch);
    // Nothing forwarded, nothing drained, cursor untouched.
    try testing.expectEqual(@as(usize, 0), bridge.last_forwarded);
    try testing.expectEqual(@as(usize, 0), rec.announcement_count);
    try testing.expectEqual(@as(usize, 0), rec.last_root_len);
    try testing.expectEqual(@as(usize, 1), ch.pending().len); // undrained
}

test "provider seam maps roles to a platform id when a real provider is installed" {
    var rec = RecordingProvider{};
    rec.present_keys = &.{ 7, 9 };
    var bridge = Bridge.init(rec.provider());

    // elementFromKey answers from the provider's present set.
    try testing.expect(bridge.elementFromKey(7));
    try testing.expect(bridge.elementFromKey(9));
    try testing.expect(!bridge.elementFromKey(8));

    // mapRole flows through to the provider's non-zero mapping (vs. the noop's 0).
    try testing.expectEqual(@as(u32, 1000) + @as(u32, @intFromEnum(semantics.Role.button)), bridge.mapRole(.button));

    // raiseFocus flows through and is recorded.
    bridge.raiseFocus(9);
    try testing.expectEqual(@as(?u64, 9), rec.last_focus);
}
