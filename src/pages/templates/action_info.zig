//! Shared read-side helpers over a verb's yields — which one dominates (by mean), its display
//! band, and the icon for its distribution shape. Used by the action presentations
//! (`action_tile` and the generator tile) so they never drift on the pick.

const std = @import("std");
const ha = @import("ha");
const roster = ha.sim.data.roster;

pub const Dominant = struct {
    band: ha.sim.kernel.dist.Stats,
    kind: ha.sim.kernel.dist.Kind,
    /// The resource's two-letter unit (`fo`, `ma`).
    letter: []const u8,
    /// "food"/"materials" — the teaching card's spelled-out form.
    word: []const u8,
};

/// The dominant yield of a verb's effective terms, by mean — the one a compact presentation
/// shows. Null when the verb draws nothing at completion.
pub fn dominant(act: u8, output: *const roster.Output) ?Dominant {
    var best: ?Dominant = null;
    for (std.enums.values(roster.Resource)) |r| {
        const d = output.get(r) orelse continue;
        const band = ha.sim.kernel.dist.stats(d.asDist());
        if (best == null or band.mean > best.?.band.mean) {
            best = .{ .band = band, .kind = d.kind(), .letter = r.letterIn(act), .word = r.wordIn(act) };
        }
    }
    return best;
}

/// The letter an amount of resource `r` is written with.
pub fn letterOf(act: u8, r: roster.Resource) []const u8 {
    return r.letterIn(act);
}

/// The tiny curve icon for a distribution shape — a tile's one-glance risk profile.
pub fn kind_icon(kind: ha.sim.kernel.dist.Kind) [:0]const u8 {
    return switch (kind) {
        .normal => "assets/svg/dist_normal.svg",
        .poisson => "assets/svg/dist_poisson.svg",
        .uniform => "assets/svg/dist_uniform.svg",
        .exponential => "assets/svg/dist_exponential.svg",
        .fixed => "assets/svg/dist_fixed.svg",
    };
}
