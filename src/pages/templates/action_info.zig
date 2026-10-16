//! Shared read-side helpers over a verb's output lines — which line dominates (by mean),
//! its display band, and the icon for its distribution shape. Used by the action
//! presentations (`action_button`, `action_tile`) so they never drift on
//! the pick.

const ha = @import("ha");
const roster = ha.roster;

pub const Dominant = struct {
    band: ha.dist.Stats,
    kind: ha.dist.Kind,
    /// The resource's letter — the header resource bar's one-letter vocabulary — or, for a
    /// good, its id.
    letter: []const u8,
    /// "food"/"materials" — the teaching card's spelled-out form.
    word: []const u8,
};

/// The dominant once-output of a verb's effective terms, by mean — the one a compact
/// presentation shows. Null when the verb yields nothing at completion.
pub fn dominant(cat: *const roster.Catalog, output: []const roster.Line) ?Dominant {
    var best: ?Dominant = null;
    for (output) |l| {
        if (l.per != .once) continue;
        const band = ha.dist.stats(l.asDist());
        if (best == null or band.mean > best.?.band.mean) {
            best = .{ .band = band, .kind = l.kind, .letter = letterOf(l.item), .word = ha.actions.itemWord(cat, l.item) };
        }
    }
    return best;
}

/// The letter an amount of `item` is written with: a resource's, or the id of a good.
pub fn letterOf(item: []const u8) []const u8 {
    if (roster.Catalog.resource(item)) |r| return r.letter();
    return item;
}

/// The tiny curve icon for a distribution shape — a tile's one-glance risk profile.
pub fn kind_icon(kind: ha.dist.Kind) [:0]const u8 {
    return switch (kind) {
        .normal => "assets/svg/dist_normal.svg",
        .poisson => "assets/svg/dist_poisson.svg",
        .uniform => "assets/svg/dist_uniform.svg",
        .exponential => "assets/svg/dist_exponential.svg",
        .fixed => "assets/svg/dist_fixed.svg",
    };
}
