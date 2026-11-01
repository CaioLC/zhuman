//! The `test-sim` root: the simulation alone. It proves the simulation compiles and its tests
//! pass with no UI host and no SDL. The module rooted here is given only `ecs` and the three
//! roster data files, so a sim file that imports `ui_client/`, `font.zig`, the host `res.zig`
//! or `sdl3` fails this step; the step's existence is the dependency rule. The root moves to
//! `src/sim/root.zig` when the sim files move under `src/sim/`.

test {
    _ = @import("./components.zig");
    _ = @import("./tags.zig");
    _ = @import("./log.zig");
    _ = @import("./dist.zig");
    _ = @import("./roster.zig");
    _ = @import("./ledger.zig");
    _ = @import("./effects.zig");
    _ = @import("./grid/root.zig");
    _ = @import("./migration.zig");
    _ = @import("./reload.zig");
    _ = @import("./market.zig");
    _ = @import("./neighbours.zig");
    _ = @import("./barter.zig");
    _ = @import("./world.zig");
    _ = @import("./ecs.zig");
    _ = @import("./systems.zig");
    _ = @import("./actions.zig");
    _ = @import("./capital.zig");
    _ = @import("./sim/root.zig");
}
