//! Compile + test entry for the **reusable UI layer in isolation** — the generic engine
//! (`src/ui/`) plus the host binding (`ctx_binding`/`features`/`draw`/`widgets`), but
//! *not* `pages.zig`. `pages.zig` is game-content screen building and imports the parked,
//! mid-refactor `main.zig` (see the manual-review workflow), which is why the full
//! `zig build test` is red. This root lets `zig build test-ui` verify the UI refactor on
//! its own while the sim half of the app is being rebuilt. See `build.zig`'s `test-ui` step.
//!
//! Lives in `src/` (not `src/ui_client/`) so its module path covers `ui/`, `ui_client/`,
//! and `res.zig` — Zig forbids `@import`ing files above a module's root. Referencing
//! `features/root.zig` runs the `comptime` conformance check over the feature `list`;
//! `refAllDecls` then forces the concrete widget/feature/draw bodies to compile
//! (`svg.attach` is referenced explicitly since no widget calls it yet).

const std = @import("std");

const cb = @import("./ui_client/ctx_binding.zig");
const features = @import("./ui_client/features/root.zig");
const draw = @import("./ui_client/draw.zig");
const widgets = @import("./ui_client/widgets.zig");

test {
    _ = @import("./ui/root.zig"); // engine's own unit tests + types
    std.testing.refAllDecls(cb);
    std.testing.refAllDecls(features);
    std.testing.refAllDecls(draw);
    std.testing.refAllDecls(widgets);
    _ = &features.data_svg; // svg.attach — compile it even though no widget calls it yet
}
