//! Host-side reduced-motion policy — the deterministic seam that decides whether
//! *optional* UI transitions animate or **snap** to their end state, while functional
//! progress, state changes, pointer/focus feedback, and the simulation always remain visible.
//!
//! ## What this is, and what it is not
//!
//! This is a one-bit presentation policy (`reduced_motion`), off by default, resolved **once
//! at host init** and then projected onto `View.reduced_motion` each build/frame. It is host-side only:
//! `src/ui/` stays generic and motion-unaware, and no simulation system reads or writes it.
//! It deliberately does **not** touch determinate progress indicators (the action-tile
//! underbar, the eating-policy slider position), the day/clock readouts, or any state/focus
//! cue: those are *functional* and remain visible regardless of the policy. It only gates
//! *decorative* time-varying visuals (none ships), and provides the `snap` gate the tween
//! registry routes every optional transition through.
//!
//! ## Opt-in
//!
//! Motion is on unless someone asks otherwise. The policy is `reduced_motion` only when the
//! environment variable `HA_REDUCED_MOTION` says so (or a fixture sets the bit); the
//! operating system's animation setting is not consulted, because turning window animations
//! off in the OS is not a request for a game to hold still.
//!
//! The override parser (`parseOverride`) is case-insensitive and total: `1/true/yes/on` →
//! `true`, `0/false/no/off` → `false`, and **anything else — including empty or missing —
//! is ignored** (`null`), which leaves motion on. It never panics on garbage input, which is
//! the property the tests pin.

const std = @import("std");

/// The resolved one-bit policy carried on `Resources.motion` and projected to
/// `View.reduced_motion` each frame. A plain value type — no allocation, trivially copied.
pub const Policy = struct {
    /// `true` ⇒ the user prefers reduced motion: optional/decorative transitions must snap to
    /// their end state. Functional progress, state, pointer/focus cues, and the simulation are
    /// unaffected and remain visible.
    reduced_motion: bool = false,

    /// The gate the tween registry routes optional transitions through. Given an interpolation from
    /// `from` to `to` at parameter `t`, return `to` immediately when reduced motion is on
    /// (the transition *snaps*); otherwise return the caller's already-interpolated `value`.
    /// The tween math lives in `tween.zig`; this only defines *the gate*, so every optional
    /// transition routes its result through one policy check.
    pub fn snap(self: Policy, comptime T: type, to: T, value: T) T {
        return if (self.reduced_motion) to else value;
    }

    /// A convenience gate for a scalar animation *phase* in `[0,1]` (e.g. the heartbeat's
    /// sine phase): when reduced motion is on, collapse to a caller-chosen constant `frozen`
    /// so the visual holds still; otherwise pass the live `phase` through. General for any
    /// phase-driven decorative visual.
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
/// "no opinion", which `resolve` reads as motion allowed.
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
/// The one way to ask for reduced motion.
pub const env_var_name = "HA_REDUCED_MOTION";

/// Resolve the effective policy from an already-parsed override (`parseOverride` produces
/// it): reduced motion only when the override asks for it, motion allowed otherwise.
pub fn resolve(override: ?bool) Policy {
    return .{ .reduced_motion = override orelse false };
}

/// The init-time convenience used by the host: read the env override once from `environ`
/// and `resolve` it. Never panics on a missing/garbage value — those leave motion on.
/// Allocation-free; nothing is retained.
pub fn resolveFromEnv(environ: *const std.process.Environ.Map) Policy {
    return resolve(if (environ.get(env_var_name)) |raw| parseOverride(raw) else null);
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

test "resolve: reduced motion only when the override asks for it" {
    try testing.expect(resolve(true).reduced_motion);
    try testing.expect(!resolve(false).reduced_motion);
    try testing.expect(!resolve(null).reduced_motion);
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

test "resolveFromEnv: motion is on unless the env var asks for reduced motion" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    try testing.expect(!resolveFromEnv(&env).reduced_motion);
    try env.put(env_var_name, "sometimes");
    try testing.expect(!resolveFromEnv(&env).reduced_motion);
    try env.put(env_var_name, "0");
    try testing.expect(!resolveFromEnv(&env).reduced_motion);
    try env.put(env_var_name, "1");
    try testing.expect(resolveFromEnv(&env).reduced_motion);
}

test "default Policy is motion-allowed" {
    const p = Policy{};
    try testing.expect(!p.reduced_motion);
}
