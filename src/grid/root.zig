//! `grid` — the Act II STRUCTURE board's content-and-logic layer.
//!
//! Two modules: `hex` (pointy-top axial geometry, classification, pixel transform — pure, it
//! names only `std`) and `board` (the adjacency rule and atomic research resolution). The
//! technologies themselves are records of the roster (`data/technologies.zon`), and `board`
//! runs over that `Catalog` and an agent's `comp.Research`. The STRUCTURE screen reads
//! positions from `hex`, records from the catalog, and per-tile states from `comp.Research`,
//! mapping a wedge/resource to a palette hue itself; nothing flows back in.

pub const hex = @import("./hex.zig");
pub const board = @import("./board.zig");

test {
    _ = hex;
    _ = board;
}
