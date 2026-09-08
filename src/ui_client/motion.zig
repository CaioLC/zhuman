//! Host-side reduced-motion policy (INPUT-10) — the deterministic seam that decides whether
//! *optional* UI transitions animate or **snap** to their end state, while functional
//! progress, state changes, pointer/focus feedback, and the simulation always remain visible.
//!
//! ## What this is, and what it is honestly *not*
//!
//! This is a one-bit presentation policy (`reduced_motion`), resolved **once at host init**
//! and then projected onto `View.reduced_motion` each build/frame. It is host-side only:
//! `src/ui/` stays generic and motion-unaware, and no simulation system reads or writes it.
//! It deliberately does **not** touch determinate progress indicators (the action-tile
//! underbar, the ration-dial fill), the day/clock readouts, or any state/focus cue — those
//! are *functional* and remain visible regardless of the policy. It only gates genuinely
//! *decorative* time-varying visuals (today: the mock screen's heartbeat oscillation), and
//! leaves a reusable `snap` gate for the future tween engine (RENDER-08).
//!
//! ## The platform preference (and its honest limitation)
//!
//! On Windows the OS-level reduced-motion flag is the "client area animation" system
//! parameter, read with `SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, …)` — the flag
//! behind Settings → Accessibility → Visual effects → Animation effects. Its BOOL is
//! *enable-animations*, so `reduced_motion = !client_area_animation_enabled`. This is the
//! documented, live-state query (unlike the registry `MinAnimate` value, which does not
//! reflect temporary changes), and it links against `user32` — already linked by the
//! vendored SDL C build — with no `build.zig` change and no per-frame OS call.
//!
//! SDL exposes no cross-platform reduced-motion abstraction (`zig-sdl3` 0.1.6 has only mouse
//! hints and a light/dark theme query), so there is nothing portable to build on. On every
//! non-Windows target the platform probe returns a deterministic `false` (motion allowed) —
//! recorded honestly rather than pretending a preference was read.
//!
//! ## Resolution & precedence (non-panicking)
//!
//! `resolve` composes three sources with a clear, total precedence:
//!
//!   1. **Explicit override** (env `HA_REDUCED_MOTION` or an injected config bool) — wins.
//!   2. **Platform probe** (the injected `Probe`; default is the deterministic `false`).
//!   3. **Fallback** — `false` (motion allowed) when neither above decides.
//!
//! The override parser (`parseOverride`) is case-insensitive and total: `1/true/yes/on` →
//! `true`, `0/false/no/off` → `false`, and **anything else — including empty or missing —
//! is ignored** (`null`), falling through to the probe. It never panics on garbage input,
//! which is the property the tests pin. `Probe` mirrors the a11y `Provider` seam: a tiny
//! injectable vtable so the Win32 call is swappable and every test stays SDL/OS-free.

const std = @import("std");
const builtin = @import("builtin");

/// The resolved one-bit policy carried on `Resources.motion` and projected to
/// `View.reduced_motion` each frame. A plain value type — no allocation, trivially copied.
pub const Policy = struct {
    /// `true` ⇒ the user prefers reduced motion: optional/decorative transitions must snap to
    /// their end state. Functional progress, state, pointer/focus cues, and the simulation are
    /// unaffected and remain visible.
    reduced_motion: bool = false,

    /// A reusable gate for the future tween engine (RENDER-08). Given an interpolation from
    /// `from` to `to` at parameter `t`, return `to` immediately when reduced motion is on
    /// (the transition *snaps*); otherwise return the caller's already-interpolated `value`.
    /// The tween math itself stays with RENDER-08 — this only defines *the gate* now, so
    /// every future optional transition routes its result through one policy check.
    pub fn snap(self: Policy, comptime T: type, to: T, value: T) T {
        return if (self.reduced_motion) to else value;
    }

    /// A convenience gate for a scalar animation *phase* in `[0,1]` (e.g. the heartbeat's
    /// sine phase): when reduced motion is on, collapse to a caller-chosen constant `frozen`
    /// so the visual holds still; otherwise pass the live `phase` through. Used by the mock
    /// heartbeat migration; kept general for RENDER-08.
    pub fn phase(self: Policy, live: f32, frozen: f32) f32 {
        return if (self.reduced_motion) frozen else live;
    }
};

/// Parse an explicit override string into a tri-state decision. Case-insensitive and total:
///   * `true`  ← `"1" "true" "yes" "on"`
///   * `false` ← `"0" "false" "no" "off"`
///   * `null`  ← anything else, including empty/whitespace/garbage — *ignored*, never a panic.
///
/// The pure, deterministic, SDL/OS-free unit the tests exercise exhaustively. `null` means
/// "no opinion" so `resolve` falls through to the platform probe.
pub fn parseOverride(raw: []const u8) ?bool {
    // Trim ASCII whitespace so `" true "` from a shell still decides; empty → null.
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;

    if (eqlIgnoreCase(s, "1") or eqlIgnoreCase(s, "true") or
        eqlIgnoreCase(s, "yes") or eqlIgnoreCase(s, "on")) return true;
    if (eqlIgnoreCase(s, "0") or eqlIgnoreCase(s, "false") or
        eqlIgnoreCase(s, "no") or eqlIgnoreCase(s, "off")) return false;
    return null;
}

/// Case-insensitive ASCII equality (small, allocation-free — the input tokens are tiny).
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// The environment variable name that carries the deterministic override, read once at init.
/// Suitable for tests, CI, and development without any OS accessibility setting.
pub const env_var_name = "HA_REDUCED_MOTION";

/// The narrow platform-probe seam — mirrors `a11y.Provider`. A single function pointer plus an
/// opaque `ctx`, so the Win32 query is injectable and tests stay OS-free. `probe` returns the
/// platform's reduced-motion preference, or `null` when the platform has no such notion (so
/// `resolve` can fall through to the deterministic `false`).
pub const Probe = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        probe: *const fn (ctx: *anyopaque) ?bool,
    };

    pub fn probe(self: Probe) ?bool {
        return self.vtable.probe(self.ctx);
    }
};

/// The default probe: the real, OS-appropriate query. On Windows it calls
/// `SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, …)` **once**; on every other target it
/// deterministically reports `null` (no platform preference → motion allowed). Stateless
/// singleton, like `a11y.NoopProvider`.
pub const PlatformProbe = struct {
    var shared: PlatformProbe = .{};

    fn probeFn(_: *anyopaque) ?bool {
        return queryPlatformReducedMotion();
    }

    const vtable: Probe.VTable = .{ .probe = probeFn };

    pub fn instance() Probe {
        return .{ .ctx = @ptrCast(&shared), .vtable = &vtable };
    }
};

/// A deterministic probe that always reports a fixed decision (or `null`). Used by tests and
/// available as a config seam; `nullProbe()` is the OS-free default for non-Windows-style
/// determinism.
pub const FixedProbe = struct {
    value: ?bool,

    fn probeFn(ctx: *anyopaque) ?bool {
        const self: *FixedProbe = @ptrCast(@alignCast(ctx));
        return self.value;
    }

    const vtable: Probe.VTable = .{ .probe = probeFn };

    pub fn probe(self: *FixedProbe) Probe {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }
};

/// A probe that always reports "no platform opinion" (`null`). The safe default when a real
/// query is unavailable; `resolve` then uses the `false` fallback.
pub fn nullProbe() Probe {
    return (struct {
        var p: FixedProbe = .{ .value = null };
        fn get() Probe {
            return p.probe();
        }
    }).get();
}

// --- Windows platform query -------------------------------------------------------------

/// `SPI_GETCLIENTAREAANIMATION` — the documented system parameter whose BOOL says whether the
/// user wants client-area animations. `FALSE` ⇒ animations off ⇒ reduced motion on.
const SPI_GETCLIENTAREAANIMATION: u32 = 0x1042;

// Declared only on Windows; links against `user32`, already linked by the vendored SDL C
// build (kernel32/user32/gdi32/winmm/imm32), so no `build.zig` change is needed.
const win32 = if (builtin.os.tag == .windows) struct {
    // BOOL SystemParametersInfoW(UINT uiAction, UINT uiParam, PVOID pvParam, UINT fWinIni);
    extern "user32" fn SystemParametersInfoW(
        uiAction: u32,
        uiParam: u32,
        pvParam: ?*anyopaque,
        fWinIni: u32,
    ) callconv(.winapi) i32;
} else struct {};

/// The real platform query. On Windows, ask the OS once; on any failure treat it as "no
/// opinion" (`null`) rather than guessing. On non-Windows, `null` (no platform notion).
pub fn queryPlatformReducedMotion() ?bool {
    if (builtin.os.tag != .windows) return null;

    var enabled: i32 = 1; // BOOL out-param; default to "animations enabled" if the call no-ops.
    const ok = win32.SystemParametersInfoW(
        SPI_GETCLIENTAREAANIMATION,
        0,
        @ptrCast(&enabled),
        0,
    );
    if (ok == 0) return null; // the call failed — report no opinion, fall through to fallback.
    // BOOL is "animations enabled"; reduced motion is its negation.
    return enabled == 0;
}

// --- Resolution -------------------------------------------------------------------------

/// Resolve the effective policy from the three sources, in strict precedence:
///   1. `override` (already-parsed tri-state; `parseOverride` produces it) — wins if non-null.
///   2. `probe.probe()` — the platform preference, if the probe has an opinion.
///   3. `false` — the deterministic motion-allowed fallback.
///
/// Total and non-panicking: any combination of inputs yields a defined `Policy`.
pub fn resolve(override: ?bool, probe: Probe) Policy {
    if (override) |o| return .{ .reduced_motion = o };
    if (probe.probe()) |p| return .{ .reduced_motion = p };
    return .{ .reduced_motion = false };
}

/// The init-time convenience used by the host: read the env override once (allocation-free
/// via a fixed stack buffer), then `resolve` against the given probe. Never panics on a
/// missing/oversized/garbage value — those simply become "no override". `allocator` is used
/// only transiently to read the env var and is not retained.
pub fn resolveFromEnv(allocator: std.mem.Allocator, probe: Probe) Policy {
    const override = readEnvOverride(allocator);
    return resolve(override, probe);
}

/// Read `HA_REDUCED_MOTION` and parse it, or `null` if unset/unreadable/unrecognized. The
/// value is read into owned memory, parsed, and freed before returning — nothing is retained.
fn readEnvOverride(allocator: std.mem.Allocator) ?bool {
    const raw = std.process.getEnvVarOwned(allocator, env_var_name) catch return null;
    defer allocator.free(raw);
    return parseOverride(raw);
}

// --- Tests ------------------------------------------------------------------------------

const testing = std.testing;

test "parseOverride truth table: recognized true tokens, case-insensitive" {
    for ([_][]const u8{ "1", "true", "TRUE", "True", "yes", "YES", "on", "On" }) |s| {
        try testing.expectEqual(@as(?bool, true), parseOverride(s));
    }
}

test "parseOverride truth table: recognized false tokens, case-insensitive" {
    for ([_][]const u8{ "0", "false", "FALSE", "False", "no", "NO", "off", "Off" }) |s| {
        try testing.expectEqual(@as(?bool, false), parseOverride(s));
    }
}

test "parseOverride ignores empty/whitespace/garbage without panicking" {
    for ([_][]const u8{ "", " ", "\t\r\n", "maybe", "2", "truee", "o", "yesno", "enable" }) |s| {
        try testing.expectEqual(@as(?bool, null), parseOverride(s));
    }
}

test "parseOverride trims surrounding whitespace before matching" {
    try testing.expectEqual(@as(?bool, true), parseOverride("  true "));
    try testing.expectEqual(@as(?bool, false), parseOverride("\toff\n"));
    // Interior junk is still garbage → null.
    try testing.expectEqual(@as(?bool, null), parseOverride("tr ue"));
}

test "resolve precedence: explicit override beats the platform probe" {
    var on = FixedProbe{ .value = false }; // platform says motion allowed…
    // …but an explicit `true` override wins.
    try testing.expect(resolve(true, on.probe()).reduced_motion);

    var off = FixedProbe{ .value = true }; // platform says reduced…
    // …but an explicit `false` override wins.
    try testing.expect(!resolve(false, off.probe()).reduced_motion);
}

test "resolve precedence: probe used only when there is no override" {
    var reduced = FixedProbe{ .value = true };
    try testing.expect(resolve(null, reduced.probe()).reduced_motion);

    var allowed = FixedProbe{ .value = false };
    try testing.expect(!resolve(null, allowed.probe()).reduced_motion);
}

test "resolve fallback: no override and no platform opinion => false (motion allowed)" {
    try testing.expect(!resolve(null, nullProbe()).reduced_motion);
}

test "nullProbe reports no platform opinion" {
    try testing.expectEqual(@as(?bool, null), nullProbe().probe());
}

test "non-Windows platform query is a deterministic null (motion allowed via fallback)" {
    if (builtin.os.tag != .windows) {
        try testing.expectEqual(@as(?bool, null), queryPlatformReducedMotion());
        try testing.expect(!resolve(null, PlatformProbe.instance()).reduced_motion);
    }
}

test "snap gate: returns the end state when reduced motion is on, else the interpolated value" {
    const on = Policy{ .reduced_motion = true };
    const off = Policy{ .reduced_motion = false };
    // Reduced motion snaps straight to `to`, ignoring the mid-interpolation value.
    try testing.expectEqual(@as(f32, 10.0), on.snap(f32, 10.0, 3.5));
    // Motion allowed passes the caller's interpolated value through unchanged.
    try testing.expectEqual(@as(f32, 3.5), off.snap(f32, 10.0, 3.5));
    // Works for integer channels too (e.g. a color byte).
    try testing.expectEqual(@as(u8, 255), on.snap(u8, 255, 128));
    try testing.expectEqual(@as(u8, 128), off.snap(u8, 255, 128));
}

test "phase gate: freezes an oscillation to a constant under reduced motion" {
    const on = Policy{ .reduced_motion = true };
    const off = Policy{ .reduced_motion = false };
    try testing.expectEqual(@as(f32, 0.5), on.phase(0.9, 0.5));
    try testing.expectEqual(@as(f32, 0.9), off.phase(0.9, 0.5));
}

test "resolveFromEnv falls back to the probe when the env var is unset/garbage" {
    // The test environment does not set HA_REDUCED_MOTION, so the probe decides.
    var reduced = FixedProbe{ .value = true };
    try testing.expect(resolveFromEnv(testing.allocator, reduced.probe()).reduced_motion);

    var allowed = FixedProbe{ .value = false };
    try testing.expect(!resolveFromEnv(testing.allocator, allowed.probe()).reduced_motion);
}

test "default Policy is motion-allowed" {
    const p = Policy{};
    try testing.expect(!p.reduced_motion);
}
