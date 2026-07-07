//! Tag definitions (zero-sized marker types).
//!
//! WARNING: only `pub const <Name> = struct {};` type declarations may
//! live in this file. The ECS world enumerates every public decl here
//! at comptime and generates one SparseSet per type. Any non-type decl
//! will fail compilation.

pub const Player = struct {};

// Generic tags
pub const Created = struct {};
pub const Dead = struct {};

// Capital tags
pub const Idle = struct {}; // Marks Capital as Idle if the resources were not paid this round.
pub const Generator = struct {}; // marks capital as a generator
pub const ActionModifier = struct {}; // marks capital as an action modifier

// Category Tags
pub const Food = struct {};
pub const Comfort = struct {};
pub const Tool = struct {};
pub const WoodCutting = struct {};
// TODO: Continue categorizing
