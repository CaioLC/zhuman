//! Status/vitals readouts — pure functions over the actor's vigor, building no nodes. The
//! condition word and the vitals figure read the same one number, so the HUD never
//! announces two different moods at once.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const uic = ha.ui_client;
const Theme = uic.Theme;
const Color = uic.Color;

/// A pulsing color between `t.dim` and `t.acc` (period ~1.1s) — the "heartbeat". Driven by
/// `elapsed` (the run clock), so it freezes the instant the actor dies.
///
/// This is the one genuinely *decorative* time-varying visual in the project (a clock-driven
/// oscillation with no functional readout — it lives only on the mock showcase screen). Under
/// reduced motion (INPUT-10) it snaps: the sine phase is frozen to a constant `0.5`
/// mid-blend, so the color holds still at the midpoint between `dim` and `acc` instead of
/// oscillating. Functional readouts (the action-tile underbar and eating-policy slider) and all
/// state/focus cues are *not* gated by this — they remain fully visible regardless.
pub fn heartbeat_color(t: Theme, elapsed: f32, motion: uic.MotionPolicy) Color {
    const live = 0.5 + 0.5 * std.math.sin(elapsed * (2.0 * std.math.pi / 1.1));
    // Snap the oscillation to its midpoint when the user prefers reduced motion.
    const phase = motion.phase(live, 0.5);
    return uic.mix(t.dim, t.acc, phase);
}

/// The actor's condition word + a severity color. The bands come from `Config` — the
/// same call the vigor chip, the hunger log lines and labor's yield penalty make.
pub const Status = struct { word: []const u8, color: Color };
pub fn actor_status(t: Theme, vigor: *const comp.Vigor, cfg: ha.res.Config) Status {
    return switch (cfg.condition(vigor.v / vigor.max)) {
        .spent => .{ .word = "SPENT", .color = t.danger },
        .weary => .{ .word = "WEARY", .color = t.warn },
        .alive => .{ .word = "ALIVE", .color = t.acc },
    };
}
