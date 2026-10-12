//! `text_input` — the single-line search/text field, an `El` composition over the
//! authoritative host editor model (`UiState.TextInputState` = `editor.LineEditor`, pooled by
//! the field's node key or by an owner the caller names). The field registers its stable key in global traversal order and as
//! the `/` search target, requests singular engine focus when clicked, and clears focus on a
//! primary press that lands outside it. SDL delivers text and key events as raw events, so
//! `main.zig` routes them into this same model — text through `insert`, caret/selection/
//! clipboard/delete through the editor's methods — against whichever key `ctx.focusedKey()`
//! returns.
//!
//! Rendering reads the model: `placeholder` (dim) when empty and unfocused; while focused the
//! caret as a bar, or the selection wrapped in guillemets; plain text otherwise. The primitive
//! text feature paints one run and cannot place a sub-glyph caret or a colored selection band,
//! so the caret is a visible marker at its codepoint position and a selection is bracketed —
//! an honest reflection of the model without pretending to glyph hit-testing. Focus draws
//! accent chrome, and a refused edit (overflow / invalid / multi-line) draws a `danger` outline
//! until the next accepted edit. A trailing "✕" clears the field on click (the pointer half of
//! the clear action; keyboard clear is Ctrl+A then Backspace, same model). The field starts SDL
//! text input when it takes focus and stops it when nothing is focused.

const std = @import("std");
const sdl = @import("sdl3");
const cb = @import("./ctx_binding.zig");
const el = @import("./elements.zig");
const style = @import("./style.zig");
const semantics = @import("./semantics.zig");

const UiCtx = cb.UiCtx;
const UiState = cb.UiState;
const El = el.El;
const Style = style.Style;

/// Build a text field of `width` logical px into `parent`. The editor model lives on `owner`
/// when given — an always-built node, so the text survives the field not being built — else
/// on the field itself; the command registry maps the field to that key so the host routes
/// keys and text into the right slot. Returns the field box; the caller reads the model
/// through `owner.state(UiState.TextInputState)` (or the field's).
pub fn text_input(parent: El, id: []const u8, placeholder: []const u8, width: f32, owner: ?El) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;

    // The box is created first so its key is final before the model is acquired.
    const field = try parent.div(id);
    const key = field.get().key;
    const holder = owner orelse field;
    const state = holder.state(UiState.TextInputState);
    ctx.res.commands.registerText(key, holder.get().key, true);

    // A primary press that lands outside a focused field clears focus; read it before the
    // lifecycle so the published focus is this frame's truth.
    const pre = field.query();
    if (!pre.clicked and ctx.isFocused(key) and ctx.res.input.pointer.buttons.primary.pressed and !pre.pressed) {
        ctx.clearFocus();
    }
    // The accessible name is the placeholder/purpose; the value is the model's
    // authoritative text (never the caret/selection display string). A refused edit is an
    // assertive live region, matching the `danger` outline.
    const q = field.control(.{
        .name = placeholder,
        .role = .text_input,
        .value = state.text(),
        .cursor = .text,
        .live = if (state.refused) .assertive else .off,
    });
    const focused = q.focused;
    if (focused and !sdl.keyboard.textInputActive(ctx.res.platform.window)) {
        sdl.keyboard.startTextInput(ctx.res.platform.window) catch {};
    } else if (ctx.focusedKey() == null and sdl.keyboard.textInputActive(ctx.res.platform.window)) {
        sdl.keyboard.stopTextInput(ctx.res.platform.window) catch {};
    }

    // Compose the display string from the authoritative editor model.
    var buf: [UiState.TextInputState.max_query_bytes + 8]u8 = undefined;
    const shown: []const u8 = blk: {
        if (state.len == 0 and !focused) break :blk placeholder;
        if (!focused) break :blk state.text();
        const sel = state.selectionRange();
        if (state.hasSelection()) {
            // …selected…  → wrap the selected run in guillemets, caret side implicit.
            break :blk std.fmt.bufPrint(&buf, "{s}\u{00AB}{s}\u{00BB}{s}", .{
                state.buf[0..sel.start],
                state.buf[sel.start..sel.end],
                state.buf[sel.end..state.len],
            }) catch state.text();
        }
        // No selection: a caret bar at the caret byte offset.
        break :blk std.fmt.bufPrint(&buf, "{s}|{s}", .{
            state.buf[0..state.caret],
            state.buf[state.caret..state.len],
        }) catch state.text();
    };

    // Focus-visible chrome, with a non-silent refusal cue: a rejected edit (overflow or
    // invalid/multi-line text) tints the outline `danger` until the next accepted edit.
    const outline = if (state.refused) th.danger else if (focused) th.acc else th.line2;
    _ = field.with_flow(.{ .dir = .row, .cross = .center })
        .with_size(.{ .fixed = width }, .fit_children)
        .with_style(.{ style.pad_sym(8, 4), Style{ .outline_color = outline } });
    const ink = if (state.len == 0 and !focused) th.dim else th.fg;
    _ = (try field.text("shown", shown)).with_style(.{Style{ .text = ink }});

    // Pointer clear affordance: a trailing "✕" hit region that empties the field on click.
    // Only shown while there is text to clear.
    if (!state.isEmpty()) {
        const clear = try field.text("clear", "\u{2715}");
        const cq = clear.query();
        if (cq.hovering) ctx.res.cursor.request(.pointer);
        _ = clear.with_layout(.center_right)
            .with_style(.{ style.pad_sym(4, 0), Style{ .text = if (cq.hovering) th.fg else th.dim } });
        if (cq.clicked) {
            _ = state.clear();
            _ = ctx.requestFocus(key); // keep focus in the field after clearing
        }
    }

    return field;
}
