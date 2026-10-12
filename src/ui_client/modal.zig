//! `modal` — the modal shell: a fullscreen scrim that is its **own root** behind a centered,
//! bordered box the caller fills. The page lists the root last in the frame's root list, so it
//! draws over everything. Because independent roots are stamped in draw order, the queried
//! scrim is the topmost target outside the box while the box and its controls win inside it:
//! hover, press, release, wheel and completed clicks cannot reach the covered screen, and no
//! caller-side `modal_open` guards exist.
//!
//! Dismiss is caller policy. The shell registers its root as the current topmost Escape
//! target, which receives transient `.dismissed`; callers may also inspect outside pointer
//! activation. After building the dialog's descendants, consume `.clicked` on the box; a
//! subsequent `.clicked` on the root is then an outside activation (the game's modal template
//! packages this as `dismissed`).
//!
//! **Focus.** The shell opens a focus trap (`ctx.beginFocusScope`) before the
//! caller's dialog focusables are built, so Tab/Shift+Tab cycle only within the dialog while
//! it is open; nothing the scrim covers is Tab-reachable. The shell also sees the open edge:
//! a pooled `ModalState` on its root, pruned once the dialog stops building, records the key
//! focused when the dialog first builds (`opener`) and reports `first_open`. The caller's
//! end-of-dialog step uses both — initial focus to its primary control on the open frame,
//! focus back to the opener on the closing frame (the game's `modal.dismissed`).

const cb = @import("./ctx_binding.zig");
const el = @import("./elements.zig");
const style = @import("./style.zig");
const semantics = @import("./semantics.zig");

const UiCtx = cb.UiCtx;
const El = el.El;
const Style = style.Style;

pub const Modal = struct {
    /// The fullscreen scrim — an independent root the page lists last.
    root: El,
    /// The centered dialog box the caller fills with content.
    box: El,
    /// True on the frame the dialog first builds: the frame for initial focus.
    first_open: bool,
    /// The key focused when the dialog opened, to restore on close; null when nothing was.
    opener: ?u64,
};

/// Build the shell. `title` is published as the dialog's accessible name; the caller authors
/// its visible header.
pub fn modal(ctx: *UiCtx, id: []const u8, title: []const u8) !Modal {
    const th = ctx.res.view.theme;

    // `el.root` sizes the scrim to the whole drawable, in device px (the layout space).
    const root = try el.root(ctx, id);
    _ = root.with_style(.{Style{ .fill = th.bg }});
    _ = root.track(); // fullscreen scrim: a queried root structurally blocks lower trees
    ctx.res.commands.registerEscape(root.get().key);

    const box = try root.div("box");
    _ = box.with_layout(.center)
        .with_flow(.{ .dir = .column, .cross = .start })
        .with_size(.fit_children, .fit_children)
        .with_style(.{Style{ .fill = th.bg, .outline_color = th.line2 }});
    _ = box.track(); // a blocking target, and keeps the slot alive so its prior geometry resolves

    // Focus trap: everything registered from here on (the caller's controls) is the
    // trapped set. The modal is listed last, so its content is exactly this suffix.
    ctx.beginFocusScope();

    // Open-edge memory, pooled on the root: the slot exists only while the dialog builds, so
    // every open starts clean and the opener is whatever held focus on the opening frame.
    const st = root.state(cb.UiState.ModalState);
    const first_open = !st.seen;
    if (first_open) {
        st.seen = true;
        st.opener = ctx.focusedKey();
    }

    ctx.res.semantics.publish(semantics.describeDialog(root.get().key, title, ctx.isFocused(root.get().key)));

    return .{ .root = root, .box = box, .first_open = first_open, .opener = st.opener };
}
