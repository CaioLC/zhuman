//! Tag definitions (zero-sized marker types).
//!
//! WARNING: only `pub const <Name> = struct {};` type declarations may
//! live in this file. The ECS world enumerates every public decl here
//! at comptime and generates one SparseSet per type. Any non-type decl
//! will fail compilation.

pub const Player = struct {};
