//! Status/vitals readouts — pure functions over the actor's vigor, building no nodes. The
//! condition word, the heartbeat's pulse color, and the frame's warmth all read the same
//! one number, so the HUD never announces two different moods at once.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const uic = ha.ui_client;
const Theme = uic.Theme;
const Color = uic.Color;

/// A pulsing color between `t.dim` and `t.acc` (period ~1.1s) — the "heartbeat". Driven by
/// `elapsed` (the run clock), so it freezes the instant the actor dies.
pub fn heartbeat_color(t: Theme, elapsed: f32) Color {
    const phase = 0.5 + 0.5 * std.math.sin(elapsed * (2.0 * std.math.pi / 1.1));
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

/// This frame's 0..1 "warmth" mood — drives the COLD↔WARM theme blend and the vitals
/// figure. Simplified to the actor's vigor fraction for now (the satiety/capital inputs
/// went away with their mechanics); a rested actor reads warm, a spent one cold.
pub fn compute_warmth(vigor: *const comp.Vigor) f32 {
    return std.math.clamp(vigor.v / vigor.max, 0, 1);
}
