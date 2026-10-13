//! Compile + test entry for the **reusable UI layer in isolation** — the host binding
//! (`ctx_binding`/`features`/`draw`/the compositions) over the engine module `ui`, but
//! *not* `pages.zig`. `pages.zig` is game-content screen building and imports `main.zig`;
//! the focused target deliberately validates the reusable UI boundary separately from the
//! complete project `test` step. See `build.zig`'s `test-ui` step.
//!
//! Lives in `src/` (not `src/ui_client/`) so its module path covers `ui_client/` and
//! `res.zig` — Zig forbids `@import`ing files above a module's root. The engine's own tests
//! run from its package (`build.zig`), in this step and in `test`. Referencing
//! `features/root.zig` runs the `comptime` conformance check over the feature `list`;
//! `refAllDecls` then forces the concrete composition/feature/draw bodies to compile
//! (`svg.attach` is referenced explicitly since no composition calls it yet).

const std = @import("std");

const cb = @import("./ui_client/ctx_binding.zig");
const features = @import("./ui_client/features/root.zig");
const draw = @import("./ui_client/draw.zig");
const text_input = @import("./ui_client/text_input.zig");
const modal = @import("./ui_client/modal.zig");
const tooltip = @import("./ui_client/tooltip.zig");
const control = @import("./ui_client/control.zig");
const style = @import("./ui_client/style.zig");
const elements = @import("./ui_client/elements.zig");
const input = @import("./ui_client/input.zig");
const activation = @import("./ui_client/activation.zig");
const command = @import("./ui_client/command.zig");
const replay = @import("./ui_client/replay.zig");
const journey = @import("./ui_client/journey.zig");
const cursor = @import("./ui_client/cursor.zig");
const drag = @import("./ui_client/drag.zig");
const editor = @import("./ui_client/editor.zig");
const semantics = @import("./ui_client/semantics.zig");
const a11y = @import("./ui_client/a11y.zig");
const motion = @import("./ui_client/motion.zig");
const typography = @import("./ui_client/type.zig");
const shadow = @import("./ui_client/shadow.zig");
const tween = @import("./ui_client/tween.zig");
const view = @import("./ui_client/view.zig");
const text_feature = @import("./ui_client/features/text.zig");
const text_cache = @import("./ui_client/features/text_cache.zig");

test {
    _ = input; // host frame-input model + deterministic edge/state tests
    _ = activation; // release activation, drag/cancel suppression, and one-shot tests
    _ = command; // semantic key mapping and prior-build command-owner registry
    _ = replay; // SDL-free scripted-input driver: pointer/key/text/wheel event-stage replay tests
    _ = journey; // keyboard-only Act I/II interaction journeys over the replay driver (QA-14/15)
    _ = cursor; // cursor request lifecycle and SDL system-shape mappings
    _ = drag; // strict threshold and capture-backed scrollbar drag tests
    _ = editor; // authoritative single-line editor model: UTF-8/selection/refusal tests
    _ = semantics; // host-side semantic registry + announcement channel tests
    _ = a11y; // host-side accessibility bridge: lifecycle, capabilities, seam, drain tests
    _ = motion; // host-side reduced-motion policy: override parse/precedence/fallback + snap/phase gate tests
    _ = typography; // typography contract: roles/scale/tracking/transform pure tests
    _ = shadow; // shadow/backdrop composition: pure layer math tests
    _ = tween; // host-layer tween registry: interp/interrupt/reduced-motion/keying tests
    _ = view; // frame-local metrics: breakpoint classification + reference-fit/center/DPI tests
    _ = text_feature; // text feature state + tracking-aware advance/measure tests (pulls wrap.zig)
    _ = text_cache; // pure cache-key/decision/lifecycle seam + fake-backend counter tests (hit/miss/invalidate/failure/reset/prune/reuse/growth/deinit + catalog-filter perf)
    std.testing.refAllDecls(cb);
    std.testing.refAllDecls(features);
    std.testing.refAllDecls(draw);
    std.testing.refAllDecls(text_input); // the foundation compositions — force the bodies to compile
    std.testing.refAllDecls(modal);
    std.testing.refAllDecls(tooltip);
    std.testing.refAllDecls(control); // the one control lifecycle
    std.testing.refAllDecls(style); // style/placement fold + its unit tests
    std.testing.refAllDecls(elements); // content leaves + `el` — force the bodies to compile
    _ = &features.data_svg; // svg.attach — compile it even though no widget calls it yet
}
