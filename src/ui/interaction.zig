//! Interaction state flags, peppered onto the node tree by the core `mark_*`
//! functions (see root.zig). A flag *set* — any combination can be on at once.
//!
//! Mechanism vs policy: the engine only sets these bits; *what drives them*
//! (mouse, keyboard, gamepad, custom logic) and *what they mean* is userland.
//! `Resources` is never read here — conditions are passed in.

/// Per-node interaction state. `hovering`/`clicked` are **transient** (cleared
/// and recomputed every frame); `active` is **latched** (persists across frames
/// until userland clears it).
pub const Interaction = packed struct {
    hovering: bool = false,
    clicked: bool = false,
    active: bool = false,
};

/// Selects which `Interaction` field a `mark_*` call writes.
pub const Flag = enum { hovering, clicked, active };
