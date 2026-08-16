//! Shared read-side helpers over an action's `yields` — which resource dominates (by
//! mean), its display band, and the icon for its distribution shape. Used by the action
//! presentations (`action_button`, `action_card`, `action_tile`) so they never drift on
//! the pick. `yields` comes in as `anytype`: the `Yields` shape is deliberately private
//! to `components.zig` (see CLAUDE.md), so it can't be named here — field access is all
//! that's needed.

const ha = @import("ha");

pub const Dominant = struct {
    band: ha.dist.Stats,
    kind: ha.dist.Kind,
    /// 'f'/'m' — the header resource bar's one-letter vocabulary.
    letter: u8,
    /// "food"/"materials" — the teaching card's spelled-out form.
    word: []const u8,
};

/// The action's dominant yield (food vs materials, by mean) — the one a compact
/// presentation shows.
pub fn dominant(yields: anytype) Dominant {
    const food_band = ha.dist.stats(yields.food);
    const mat_band = ha.dist.stats(yields.materials);
    if (food_band.mean >= mat_band.mean)
        return .{ .band = food_band, .kind = yields.food.kind, .letter = 'f', .word = "food" };
    return .{ .band = mat_band, .kind = yields.materials.kind, .letter = 'm', .word = "materials" };
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
