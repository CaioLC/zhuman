//! `baselines` (ACT1-01) — the authoritative **starting baselines** for a fresh agent, named
//! once. Before this, `main.spawn_agent` carried bare literals (`Vigor{10,10}`,
//! `InventoryFood{4,1,0.05}`) that Holdings could not compare against; now the values live on
//! the component **field defaults**, and this module surfaces them as the canonical baseline a
//! new agent spawns at and Holdings measures current-vs-base against. `spawn_agent` spawns the
//! default-valued components (`comp.Vigor{}`, `comp.InventoryFood{}`, `comp.Metabolism{}`), so
//! there is exactly one source for "what a new player starts with".
//!
//! Leaf module — imports only the components. The values here are *reads* of the component
//! defaults (`(comp.Vigor{}).max`), never a second copy, so a default edit moves both the spawn
//! and the baseline together and they can never drift.

const ha = @import("ha");
const comp = ha.comp;

/// The vigor ceiling a fresh agent spawns at (its `Vigor.max` default).
pub const vigor_ceiling: f32 = (comp.Vigor{}).max;
/// The larder a fresh agent spawns with — units, quality, and spoilage (the `InventoryFood`
/// defaults). Holdings shows the vigor ceiling and larder quality/spoilage as current-vs-base.
pub const food_units: f32 = (comp.InventoryFood{}).v;
pub const food_quality: u8 = (comp.InventoryFood{}).quality;
pub const food_spoils: f32 = (comp.InventoryFood{}).spoils;

// ============================ Tests =====================================================
const std = @import("std");

test "baselines mirror the component defaults (single source, no drift)" {
    // A fresh agent's components equal the baseline — the same numbers Holdings compares to.
    try std.testing.expectEqual(@as(f32, 10), vigor_ceiling);
    try std.testing.expectEqual((comp.Vigor{}).max, vigor_ceiling);
    try std.testing.expectEqual((comp.Vigor{}).v, vigor_ceiling); // rested: v == max at spawn
    try std.testing.expectEqual(@as(f32, 4), food_units);
    try std.testing.expectEqual(@as(u8, 1), food_quality);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), food_spoils, 1e-6);
    try std.testing.expectEqual((comp.InventoryFood{}).quality, food_quality);
}
