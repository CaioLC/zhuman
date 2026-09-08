//! Compile + test entry for the **reusable UI layer in isolation** — the generic engine
//! (`src/ui/`) plus the host binding (`ctx_binding`/`features`/`draw`/`widgets`), but
//! *not* `pages.zig`. `pages.zig` is game-content screen building and imports `main.zig`;
//! the focused target deliberately validates the reusable UI boundary separately from the
//! complete project `test` step. See `build.zig`'s `test-ui` step.
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
const style = @import("./ui_client/style.zig");
const elements = @import("./ui_client/elements.zig");
const input = @import("./ui_client/input.zig");
const activation = @import("./ui_client/activation.zig");
const command = @import("./ui_client/command.zig");
const cursor = @import("./ui_client/cursor.zig");
const drag = @import("./ui_client/drag.zig");
const editor = @import("./ui_client/editor.zig");
const semantics = @import("./ui_client/semantics.zig");

test {
    _ = @import("./ui/root.zig"); // engine's own unit tests + types
    _ = input; // host frame-input model + deterministic edge/state tests
    _ = activation; // release activation, drag/cancel suppression, and one-shot tests
    _ = command; // semantic key mapping and prior-build command-owner registry
    _ = cursor; // cursor request lifecycle and SDL system-shape mappings
    _ = drag; // strict threshold and capture-backed scrollbar drag tests
    _ = editor; // authoritative single-line editor model: UTF-8/selection/refusal tests
    _ = semantics; // INPUT-08 host-side semantic registry + announcement channel tests
    std.testing.refAllDecls(cb);
    std.testing.refAllDecls(features);
    std.testing.refAllDecls(draw);
    std.testing.refAllDecls(widgets);
    std.testing.refAllDecls(style); // style/placement fold + its unit tests
    std.testing.refAllDecls(elements); // content leaves + `el` — force the bodies to compile
    _ = &features.data_svg; // svg.attach — compile it even though no widget calls it yet
}
