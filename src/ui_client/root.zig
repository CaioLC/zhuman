//! Barrel for the `ui_client` host-binding layer — everything UI code that isn't the
//! generic engine (`src/ui/`) and isn't game content (the `ui_*` screen builders, which
//! live in `src/pages/`, outside the `ha` library). Re-exported flat so callers use one
//! namespace instead of several:
//!   - `ctx_binding` — the concrete engine types (`UiCtx`, `Node`, `RenderData`, `Sprite`)
//!   - `theme`       — `Color` + the `Theme` roles every widget paints from (neutral defaults)
//!   - `features`    — the paint-feature registry (text/fill/outline/img/svg) + `attach` mixins
//!   - `draw`        — the render walk (paint a whole laid-out tree, with the clip stack)
//!   - `tree`        — frame assembly (`collect` flattens builder returns; `Trees` wraps them)
//!   - `text_input` / `modal` / `tooltip` — the foundation compositions, functions over `El`
const ctx_binding = @import("./ctx_binding.zig");
const features = @import("./features/root.zig");
const draw = @import("./draw.zig");
const tree = @import("./tree.zig");
const text_input_mod = @import("./text_input.zig");
const modal_mod = @import("./modal.zig");
const tooltip_mod = @import("./tooltip.zig");
const control_mod = @import("./control.zig");
const cursor = @import("./cursor.zig");
const drag = @import("./drag.zig");
const command = @import("./command.zig");
const semantics = @import("./semantics.zig");
const a11y = @import("./a11y.zig");
const motion = @import("./motion.zig");

/// Reusable shadow/backdrop composition: bounded translucent layers approximating
/// the prototype's soft drop shadows, plus the modal backdrop scrim color. SDL-free layer math
/// (`shadow.layers`) with thin `El` emitters (`shadow.drop`, `shadow.backdropColor`).
pub const shadow = @import("./shadow.zig");

/// Host-layer transition/tween state: scalar transitions keyed by stable
/// node/domain id, interrupt/reverse from current value, obeying the reduced-motion
/// policy, with the prototype's functional durations. A value provider, not a node feature.
pub const tween = @import("./tween.zig");

/// Frame-local view metrics: the logical viewport, DPI scale, centered terminal
/// rect, and responsive width class computed once per frame against the 900×820 reference.
/// `build_ui`'s prologue computes it into `Resources.view.metrics`; responsive templates read
/// it. Pure `compute` + `ViewMetrics`/`WidthClass` types, SDL-free and unit-tested.
pub const view = @import("./view.zig");

/// The style + placement composition layers (`Style`/`resolve`, `Placement`/presets).
/// Exposed as a namespace so call sites read `uic.style.h1`, `uic.style.row`, etc.
pub const style = @import("./style.zig");
/// The centralized typography contract: the prototype text roles
/// (`body`/`small`/`heading`/`eyebrow`), the single logical→device scale seam
/// (`toDevice`), and the pure tracking math (`deviceTracking`). SDL-free host policy;
/// `style` projects these roles into composable fragments. See `type.zig`.
pub const typography = @import("./type.zig");
/// The content layer — pure content leaves (`text`/`image`/`svg`) + the `el` sugar.
pub const elements = @import("./elements.zig");
/// The color vocabulary — `Color`, the blend math, and `Theme`'s nine roles with plain
/// neutral defaults. A game installs its own values (`ha.palette`) onto `res.view.theme`;
/// this layer only ever names the roles.
pub const theme = @import("./theme.zig");

// ctx_binding

// frame input and activation model
pub const input = @import("./input.zig");
pub const activation = @import("./activation.zig");
pub const Input = input.Input;
pub const InputPoint = input.Point;
pub const PointerKind = input.PointerKind;
pub const PointerButton = input.PointerButton;
pub const KeyAction = input.KeyAction;
pub const Modifiers = input.Modifiers;
pub const PointerActivation = activation.PointerActivation;
pub const Command = command.Command;
pub const CommandRegistry = command.Registry;
pub const commandFromKeyEvent = command.fromKeyEvent;

// Scripted synthetic-input driver: the SDL-free lower half of the event loop
// (pointer activation + semantic commands + the engine's `mark*` event stage), lifted into one
// reusable harness so interaction state machines can be regression-tested and deterministic
// fixtures can script gestures without SDL polling. See `replay.zig`.
pub const replay = @import("./replay.zig");
pub const ReplayDriver = replay.Driver;
pub const ReplayEvent = replay.Event;
pub const ReplayCommandOutcome = replay.CommandOutcome;

// Keyboard-only interaction journeys (QA-14/15): multi-frame keyboard scripts over a
// representative stamped control set, built on the replay driver, asserting focus traversal,
// activation, roving movement, and dismissal reach every control without a pointer. See
// `journey.zig`.
pub const journey = @import("./journey.zig");
pub const JourneyScene = journey.Scene;
pub const JourneyControl = journey.Control;

// Host-side semantic model (the platform bridge's source). All host-side;
// the generic engine never sees it. See `semantics.zig`.
pub const semantic = semantics;
pub const SemanticRole = semantics.Role;
pub const SemanticState = semantics.SemanticState;
pub const SemanticLiveRegion = semantics.LiveRegion;
pub const SemanticNode = semantics.SemanticNode;
pub const SemanticRelations = semantics.Relations;
pub const SemanticRegistry = semantics.SemanticRegistry;
pub const AnnouncementChannel = semantics.AnnouncementChannel;

// Host-side accessibility bridge: the deterministic seam that consumes the
// snapshot + announcement channel and holds a future Windows UIA provider slot. All platform
// policy stays here in `ui_client`; `src/ui` never sees it. See `a11y.zig`.
pub const a11y_bridge = a11y;
pub const AccessibilityBridge = a11y.Bridge;
pub const AccessibilityStatus = a11y.Status;
pub const AccessibilityCapabilities = a11y.Capabilities;
pub const AccessibilityProvider = a11y.Provider;
pub const NoopAccessibilityProvider = a11y.NoopProvider;

// Host-side reduced-motion policy: a one-bit `Policy` resolved once at init (an
// explicit `HA_REDUCED_MOTION` override, else a Windows `SPI_GETCLIENTAREAANIMATION` probe,
// else a deterministic `false` fallback) and projected onto `view.reduced_motion` each frame.
// Optional/decorative transitions snap under it via `Policy.snap`/`Policy.phase`; functional
// progress/state/focus and the simulation are never gated. All platform policy stays here in
// `ui_client`; `src/ui` never sees it. See `motion.zig`.
pub const motion_policy = motion;
pub const MotionPolicy = motion.Policy;
pub const MotionProbe = motion.Probe;
pub const PlatformMotionProbe = motion.PlatformProbe;
pub const FixedMotionProbe = motion.FixedProbe;
pub const nullMotionProbe = motion.nullProbe;
pub const resolveMotionFromEnv = motion.resolveFromEnv;
pub const resolveMotion = motion.resolve;
pub const parseMotionOverride = motion.parseOverride;
pub const CursorKind = cursor.Kind;
pub const CursorState = cursor.State;
pub const PlatformCursors = cursor.PlatformCursors;
pub const ThresholdDrag = drag.ThresholdDrag;
pub const drag_threshold = drag.drag_threshold;
pub const updateScrollThumb = drag.updateScrollThumb;
pub const cancelScrollThumb = drag.cancelScrollThumb;

pub const UiCtx = ctx_binding.UiCtx;
pub const ControlState = ctx_binding.ControlState;
pub const publishControlState = ctx_binding.publishControlState;
pub const Node = ctx_binding.Node;
pub const Color = ctx_binding.Color; // the host color type (SDL's), carried on RenderData
pub const Theme = theme.Theme; // the nine paint roles (neutral defaults; a game overrides)
pub const mix = theme.mix; // per-channel color blend
pub const rgb = theme.rgb; // opaque RGB shorthand
pub const UiState = ctx_binding.UiState;
pub const Sprite = ctx_binding.Sprite;
pub const Point = ctx_binding.Point; // a polyline vertex in a node's unit square (see features/line.zig)
pub const Stroke = ctx_binding.Stroke; // what a polyline is drawn with — color + width
pub const icon_sprite = ctx_binding.icon_sprite;

// draw
pub const draw_tree = draw.draw_tree;

// engine re-exports the game needs, so `pages/` + `main.zig` import only `ha.ui_client`
// (never `ha.ui`). `stamp_rects` is the post-layout walk main runs each frame.
pub const stamp_rects = @import("ui").stamp_rects;

pub const FrameProfileSample = @import("ui").FrameProfileSample;
pub const FrameProfileReport = @import("ui").FrameProfileReport;
pub const FrameProfiler = @import("ui").FrameProfiler;

// frame assembly
pub const Trees = tree.Trees; // the return-type wrapper (host)
pub const collect = Node.collect; // the flatten mechanism (engine)
pub const oneRoot = tree.oneRoot; // a single-root page as `Trees`

// features (attach mixins — the old `data_*` names)
pub const data_text = features.data_text;
pub const data_img = features.data_img;
pub const data_sprite = features.data_sprite;
pub const data_svg = features.data_svg;

// foundation compositions — functions over `El` that bind host services (the editor model and
// SDL text input, the Escape owner and focus trap, the pass-through overlay root). The game's
// templates wrap them with chrome.
pub const text_input = text_input_mod.text_input;
pub const Modal = modal_mod.Modal;
pub const modal = modal_mod.modal;
pub const tooltip = tooltip_mod.tooltip;
pub const clampToTerminal = tooltip_mod.clampToTerminal;
/// The one control lifecycle `El.control` runs; its options type, for callers that build one.
pub const ControlOptions = control_mod.Options;

test {
    _ = input;
    _ = activation;
    _ = theme;
    _ = ctx_binding;
    _ = features;
    _ = draw;
    _ = tree;
    _ = text_input_mod;
    _ = modal_mod;
    _ = tooltip_mod;
    _ = control_mod;
    _ = cursor;
    _ = drag;
    _ = command;
    _ = @import("./replay.zig");
    _ = @import("./journey.zig");
    _ = semantics;
    _ = a11y;
    _ = motion;
    _ = style;
    _ = typography;
}
