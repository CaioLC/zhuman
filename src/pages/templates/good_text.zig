//! How a capital good is *written* — its display name and what owning it changes, in the
//! player's words. Presentation, so it lives here rather than on the component: the sim
//! states the same facts as numbers, and `capital.zig` owns those.
//!
//! Shared by the BUILD list and the HOLDINGS panel deliberately. They ask slightly
//! different questions — "what would this get me?" against "what is this doing for me?" —
//! but one sentence answers both, and two lists of sixteen strings would drift the first
//! time a good was re-tuned.

const ha = @import("ha");
const comp = ha.comp;

/// Title case, for a heading position. `capital.good_name` is the lowercase form, which
/// is what a sentence wants ("Your fish rod broke.").
pub fn display_name(comptime GoodT: type) []const u8 {
    return switch (GoodT) {
        comp.FishRod => "Fishing rod",
        comp.Hatchet => "Hatchet",
        comp.WireSnares => "Wire snares",
        comp.AirRifle => "Air rifle",
        comp.Sandals => "Sandals",
        comp.WorkGloves => "Work gloves",
        comp.Bicycle => "Bicycle",
        comp.Cookpot => "Cookpot",
        comp.RootCellar => "Root cellar",
        comp.Chainsaw => "Chainsaw",
        comp.LeafBed => "Leaf bed",
        comp.Pantry => "Pantry",
        comp.MedicineChest => "Medicine chest",
        comp.GardenBed => "Garden bed",
        comp.ChickenCoop => "Chicken coop",
        comp.Shelter => "Shelter",
        else => @compileError("no display name for " ++ @typeName(GoodT)),
    };
}

/// What owning it changes. A sentence, not a stat line — the notation the tiles used to
/// carry (`spoil ×0.5`, `+2 max v`) was five unit conventions in one column, and it was
/// the box that forced it.
pub fn effect(comptime GoodT: type) []const u8 {
    return switch (GoodT) {
        comp.FishRod => "you can fish",
        comp.Hatchet => "you can split wood",
        comp.WireSnares => "you can check traps",
        comp.AirRifle => "you can hunt",
        comp.Sandals => "foraging costs less",
        comp.WorkGloves => "splitting wood costs less",
        comp.Bicycle => "roaming costs less",
        comp.Cookpot => "food feeds you further",
        comp.RootCellar => "food keeps twice as long",
        comp.Chainsaw => "fuel does the work, not you",
        comp.LeafBed => "+1 vigor ceiling",
        comp.Pantry => "+2 vigor ceiling",
        comp.MedicineChest => "+2 vigor ceiling",
        comp.GardenBed => "grows food on its own",
        comp.ChickenCoop => "the hens lay for you",
        comp.Shelter => "room here for four",
        else => @compileError("no effect text for " ++ @typeName(GoodT)),
    };
}

/// The verb a good's prerequisite names, for a blocked row's `needs …`. Null when the
/// good has no prerequisite. Mirrors `capital.prereq_of`, which returns the *component*.
pub fn prereq_name(comptime GoodT: type) ?[]const u8 {
    const P = ha.capital.prereq_of(GoodT) orelse return null;
    return switch (P) {
        comp.ActionChopWood => "Split wood",
        comp.ActionFish => "Fish",
        comp.ActionCheckTraps => "Check traps",
        comp.ActionHunt => "Hunt",
        else => @compileError("no prereq name for " ++ @typeName(P)),
    };
}
