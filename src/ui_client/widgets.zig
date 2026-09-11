//! The widget palette: functions that own a node's whole subtree — graph, keyed data,
//! color, and layout. Built on `ctx_binding`'s concrete types and the feature `attach`
//! mixins (`features/`, re-exported as `data_text`/`data_img`/`data_sprite`).
//! Widgets paint themselves from `ctx.res.view.theme` (the palette `build_ui` installs —
//! see `ui_client/theme.zig`) rather than fixed module colors, so one palette swap moves the
//! whole HUD. Interaction *states* (idle/hover/disabled) map to theme *roles* (fg/acc/dim
//! respectively). Kept here (host policy) so the engine stays color-agnostic — it only
//! carries `node.render_data`.

const std = @import("std");
const ui = @import("../ui/root.zig");
const sdl = @import("sdl3");
const cb = @import("./ctx_binding.zig");
const drag = @import("./drag.zig");
const feat = @import("./features/root.zig");
const semantics = @import("./semantics.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Sprite = cb.Sprite;
const UiState = cb.UiState;
const data_text = feat.data_text;
const data_img = feat.data_img;
const data_sprite = feat.data_sprite;

/// Wheel delta → px scrolled per tick (`scroll_view`).
const scroll_speed: f32 = 24.0;
/// Scrollbar track/thumb width, in px.
const scrollbar_w: f32 = 6.0;

// --- Widget functions --------------------------------------------------------
//
// Build a node with `Node.create`/`pcreate` (the latter wires it to a parent, so its
// `key` is final), then attach data with a mixin like `data_text` and layout with
// `with_size`/`with_layout`. To make a node carry data, add the data type to UiState.
// To make a node interactive, add the flag to Interaction (the IntFlags pool).

/// Label: a content-sized text node wired to `parent` under `key`, laid out relative
/// to its siblings. Returns the node so the caller can query it (a clickable label
/// reads `.clicked`; a plain readout discards the return). The caller owns the text —
/// it's the data source, formatted at the call site and copied into the cache here.
pub fn label(ctx: *UiCtx, parent: *Node, key: []const u8, text: []const u8) !*Node {
    const node = try Node.pcreate(ctx.arena, key, parent);
    try data_text(ctx, node, text);
    _ = node.with_layout(.relative, null);
    return node;
}

/// Image widget: a leaf node showing `texture`, sized to it. Wires it to `parent`
/// under `key` and returns it so the caller can override layout (e.g. anchor).
pub fn img(ctx: *UiCtx, parent: *Node, key: []const u8, texture: sdl.render.Texture) !*Node {
    const node = try Node.pcreate(ctx.arena, key, parent);
    try data_img(ctx, node, texture);
    return node;
}

/// Progress bar: a fixed-size outlined outer track holding a filled inner whose width
/// is `frac` (0 → empty, 1 → full) of the track. Wires both nodes to `parent` under
/// `key` and returns the outer node so the caller can query/override it. The caller
/// computes `frac` — a countdown bar passes `timer.v / timer.start` (drains full→empty),
/// a fill bar the inverse. `fill` colors the inner bar; the track outline is themed `line2`.
pub fn progress_bar(ctx: *UiCtx, parent: *Node, key: []const u8, frac: f32, fill: cb.Color) !*Node {
    const outer = try Node.pcreate(ctx.arena, key, parent);
    outer.render_data.outline = .{ .color = ctx.res.view.theme.line2 };
    _ = outer.with_layout(.relative, null)
        .with_size(ui.features.Size.initFixed(240, 24));

    const inner = try Node.pcreate(ctx.arena, "inner", outer);
    inner.render_data.fill = fill;
    _ = inner.with_layout(.top_left, null)
        .with_size(ui.features.Size.init(.{ .pct_of_parent = frac }, .{ .pct_of_parent = 1.0 }));

    // INPUT-08: a determinate value indicator. The bar has no name of its own (the caller
    // labels it in surrounding copy), so the stock widget publishes an unnamed progress_bar
    // with an authoritative percentage readout formatted from the same `frac` it fills to.
    // A named readout comes from the domain helper when a caller wants a spoken name.
    var pbuf: [8]u8 = undefined;
    const pct = std.math.clamp(frac, 0, 1) * 100;
    const readout = std.fmt.bufPrint(&pbuf, "{d:.0}%", .{pct}) catch "?";
    ctx.res.semantics.publish(semantics.describeProgressBar(outer.key, "", readout));

    return outer;
}

/// Button: an outlined box that hugs its text label (plus a little padding so the
/// glyphs clear the border), wired to `parent` under `key`. Returns the outer node;
/// the caller reads `btn.query(ctx).clicked` to act on a completed release — querying also keeps
/// the node's interaction slot alive so its rect is stamped for next frame's hit-test.
/// The whole box is the clickable surface. The padding lives on the *label*, not the
/// box (the box carries none, so parent-padding inset is moot here): `draw_text` insets
/// by the text node's own padding, which centres the glyphs and lets the `fit_children`
/// box wrap `text + padding` exactly.
///
/// `enabled` remains caller authority and is published as `.disabled` every build. A
/// disabled button is dimmed; an enabled one accents while hovered or held. Callers still
/// enforce their domain gate when acting on `.clicked`; the interaction flag is a
/// projection, not a second source of truth.
pub fn button(ctx: *UiCtx, parent: *Node, key: []const u8, text: []const u8, enabled: bool) !*Node {
    const outer = try Node.pcreate(ctx.arena, key, parent);
    _ = outer.with_layout(.relative, .{ .dir = .row })
        .with_size(ui.features.Size.init(.fit_children, .fit_children));

    const lbl = try Node.pcreate(ctx.arena, "lbl", outer);
    try data_text(ctx, lbl, text); // sets content size + measured dims, keeps padding
    lbl.size.padding = ui.features.Padding.initSymmetric(8, 4);
    _ = lbl.with_layout(.relative, null);

    // Publish disabled from the caller's authoritative `enabled` value every build,
    // including false so a key cannot retain stale semantics across state changes.
    ctx.registerFocus(outer.key, enabled);
    const q = outer.query(ctx);
    if (q.clicked and enabled) _ = ctx.requestFocus(outer.key);
    const focused = ctx.isFocused(outer.key);
    cb.publishControlState(ctx, outer.key, .{
        .disabled = !enabled,
        .focused = focused,
        .focus_visible = focused,
    });
    // INPUT-08: mirror the same authoritative facts into the host semantic snapshot, in
    // paint order. Label is the button's own text; state matches what was just published.
    ctx.res.semantics.publish(semantics.describeButton(outer.key, text, enabled, focused));
    if (q.hovering) ctx.res.cursor.request(if (enabled) .pointer else .not_allowed);
    const t = ctx.res.view.theme;
    const c = if (!enabled) t.dim else if (q.held or q.hovering or focused) t.acc else t.fg;
    outer.render_data.outline = .{ .color = c };
    lbl.render_data.text = c;

    return outer;
}

/// Icon button: a clickable sprite cell drawn at `px`×`px`, with a hover/affordability
/// outline ringing it (host policy, mirroring `button`). The render walk draws the
/// outline *after* the image, so the ring shows over the opaque icon tile. Querying
/// keeps the slot alive for next frame's hit-test; the caller reads `.clicked` and
/// still enforces `enabled` as domain authority. The published projection drives
/// dim / bright-on-hover-or-held / idle chrome.
/// Text-on-hover is deferred; the icon alone is the affordance for now.
pub fn icon_button(ctx: *UiCtx, parent: *Node, key: []const u8, sprite: Sprite, px: f32, enabled: bool) !*Node {
    const node = try Node.pcreate(ctx.arena, key, parent);
    try data_sprite(ctx, node, sprite, px);
    _ = node.with_layout(.relative, null);
    ctx.registerFocus(node.key, enabled);
    const q = node.query(ctx);
    if (q.clicked and enabled) _ = ctx.requestFocus(node.key);
    const focused = ctx.isFocused(node.key);
    cb.publishControlState(ctx, node.key, .{
        .disabled = !enabled,
        .focused = focused,
        .focus_visible = focused,
    });
    // INPUT-08: an icon button has no text of its own, so it cannot supply an accessible
    // name from a widget fact — the sprite is not a string. The stock widget therefore
    // publishes an *unnamed* icon_button (empty label), and the field-refusal/empty-name
    // is honest: a game control that wants a spoken name must call the named variant (a
    // future `icon_button_named`) or describe it through a domain helper. Recorded rather
    // than invented. State still matches the interaction pool.
    ctx.res.semantics.publish(semantics.describeIconButton(node.key, "", enabled, focused));
    if (q.hovering) ctx.res.cursor.request(if (enabled) .pointer else .not_allowed);
    const t = ctx.res.view.theme;
    node.render_data.outline = .{ .color = if (!enabled) t.dim else if (q.held or q.hovering or focused) t.acc else t.fg };
    return node;
}

/// Tooltip: a floating, filled + bordered, padded box holding a single text line.
/// Built as its **own root** (no parent) so the host can place it as an overlay layer —
/// position it with `node.layout.with_origin(x, y)` and render it after the main tree so
/// it sits on top. Its opaque root is queried, so the same later order blocks pointer
/// events from controls covered by the popup; call `setPassThrough` explicitly for a
/// deliberately non-blocking overlay. Returns the box.
pub fn tooltip(ctx: *UiCtx, key: []const u8, text: []const u8) !*Node {
    const box = try Node.create(ctx.arena, key);
    box.render_data.fill = ctx.res.view.theme.panel;
    box.render_data.outline = .{ .color = ctx.res.view.theme.line2 };
    _ = box.with_layout(.top_left, .{ .dir = .column })
        .with_size(ui.features.Size.init(.fit_children, .fit_children));
    box.size.padding = ui.features.Padding.init(6); // padding is a style property now, not a Size.init arg
    _ = box.query(ctx); // opaque popup: later paint order also blocks covered controls

    const lbl = try Node.pcreate(ctx.arena, "lbl", box);
    try data_text(ctx, lbl, text);
    lbl.render_data.text = ctx.res.view.theme.fg;
    _ = lbl.with_layout(.relative, null);

    return box;
}

/// Panel: a titled, bordered, padded section that groups related content. Builds an
/// outlined outer box (border themed `line`) that hugs its children — inset by inner
/// `padding`, with a `gap` between them — and drops a title label at the top (themed
/// `dim`, matching the design's subdued section headers). Returns the outer node so the
/// caller appends content *after* the title; it flows vertically under it:
///   `const p = try panel(ctx, parent, "res", "Resources");`
///   `_ = try label(ctx, p, "energy", "Energy: 8 J");`
pub fn panel(ctx: *UiCtx, parent: *Node, key: []const u8, title: []const u8) !*Node {
    const outer = try Node.pcreate(ctx.arena, key, parent);
    outer.render_data.outline = .{ .color = ctx.res.view.theme.line };
    _ = outer.with_layout(.relative, .{ .dir = .column })
        .with_size(ui.features.Size.init(.fit_children, .fit_children));
    outer.layout.gap = 8;
    outer.size.padding = ui.features.Padding.init(12); // padding is a style property now, not a Size.init arg

    const ttl = try Node.pcreate(ctx.arena, "title", outer);
    try data_text(ctx, ttl, title);
    ttl.render_data.text = ctx.res.view.theme.dim;
    _ = ttl.with_layout(.relative, null);

    return outer;
}

pub const ScrollView = struct {
    outer: *Node, // wraps the viewport + scrollbar track side by side
    viewport: *Node, // fixed `width`×`height`, clipped
    content: *Node, // fit_children column — the caller's real rows attach here
};

/// Vertical scroll container: a fixed `width`×`height` `viewport` (clipped, via
/// `RenderData.clip`) holding a `fit_children` `content` column the caller appends rows
/// to. Routed wheel input scrolls the viewport; once content overflows, the thumb captures
/// primary input and maps outside-track pointer travel to the clamped offset. Its
/// `ScrollState` persists offset and host drag anchors by `key`, and the offset folds into
/// `content.layout.scroll_y`, which `place` uses to shift `content`'s children without a
/// second layout pass.
///
/// Clamping needs `content`'s height, but this frame's children aren't attached (let
/// alone laid out) yet — so, like the hover tooltip reading a prior-frame rect, this
/// reads *last frame's* `content.rect`. `content` is `query`'d here purely to keep its
/// interaction slot (and so its rect) alive for that read; the caller never reads its
/// flags. One-frame-stale means a newly-taller/shorter content clamps a frame late —
/// invisible at 60fps.
///
/// A thin track + thumb rides beside the viewport only while content overflows. It uses
/// grab/grabbing cursor requests and owner-checked capture release.
pub fn scroll_view(ctx: *UiCtx, parent: *Node, key: []const u8, width: f32, height: f32) !ScrollView {
    const outer = try Node.pcreate(ctx.arena, key, parent);
    _ = outer.with_layout(.relative, .{ .dir = .row })
        .with_size(ui.features.Size.init(.fit_children, .fit_children));

    const viewport = try Node.pcreate(ctx.arena, "viewport", outer);
    _ = viewport.with_layout(.relative, null)
        .with_size(ui.features.Size.initFixed(width, height));
    viewport.layout.overflow = .clip;
    viewport.render_data.outline = .{ .color = ctx.res.view.theme.line2 }; // dim frame marking the scrollable area

    const content = try Node.pcreate(ctx.arena, "content", viewport);
    _ = content.with_layout(.relative, .{ .dir = .column });
    content.layout.gap = 4;
    const content_h = if (content.rect(ctx)) |r| r.h else 0;
    ctx.setPassThrough(content.key, true); // geometry probe only — must not take the hit
    _ = content.query(ctx); // keep the slot alive so `content.rect` resolves next frame

    const max_offset = @max(0.0, content_h - height);
    const state = outer.state(ctx, UiState.ScrollState);
    if (viewport.query(ctx).wheel and ctx.res.input.pointer.wheel.y != 0) {
        state.offset -= ctx.res.input.pointer.wheel.y * scroll_speed; // wheel up ⇒ scroll toward the top
    }
    state.offset = std.math.clamp(state.offset, 0, max_offset);

    if (max_offset > 0) {
        const track = try Node.pcreate(ctx.arena, "track", outer);
        _ = track.with_layout(.relative, .{ .dir = .column })
            .with_size(ui.features.Size.initFixed(scrollbar_w, height));
        track.render_data.fill = ctx.res.view.theme.line;

        // The thumb owns capture from press through release, so capture-first routing
        // continues outside its narrow track. Pointer travel maps linearly to content.
        const thumb_h = @min(height, @max(16.0, height * height / content_h));
        const thumb_travel = height - thumb_h;

        const spacer = try Node.pcreate(ctx.arena, "above", track);
        _ = spacer.with_layout(.relative, null);

        const thumb = try Node.pcreate(ctx.arena, "thumb", track);
        _ = thumb.with_layout(.relative, null)
            .with_size(ui.features.Size.initFixed(scrollbar_w, thumb_h));
        const thumb_q = thumb.query(ctx);
        drag.updateScrollThumb(ctx, state, thumb.key, thumb_q.pressed, max_offset, thumb_travel);
        if (state.dragging) {
            ctx.res.cursor.request(.grabbing);
        } else if (thumb_q.hovering) {
            ctx.res.cursor.request(.grab);
        }
        thumb.render_data.fill = if (state.dragging) ctx.res.view.theme.acc else ctx.res.view.theme.line2;

        const thumb_y = (state.offset / max_offset) * thumb_travel;
        _ = spacer.with_size(ui.features.Size.initFixed(scrollbar_w, thumb_y));
    } else if (state.dragging) {
        drag.cancelScrollThumb(ctx, state);
    }

    content.layout.scroll_y = state.offset;

    return .{ .outer = outer, .viewport = viewport, .content = content };
}

pub const Modal = struct {
    root: *Node, // fullscreen scrim — its own root, so listing it last draws it over everything
    box: *Node, // centered dialog the caller fills with content (buttons, labels, …)
};

/// A modal dialog shell: a fullscreen, opaque scrim (its own root, no parent — the
/// caller lists it last in the frame's render trees so it draws over everything) behind
/// a centered, bordered box the caller appends content to. Mirrors `tooltip`'s "build my
/// own root, caller places it in the list" shape, but fills the whole window instead of
/// floating at a point.
///
/// The root and dialog both query interaction slots. Because independent roots are
/// stamped in draw order, listing this root last makes its fullscreen scrim the topmost
/// target outside the box, while the box and its controls win inside it. Hover, press,
/// release, wheel, and completed clicks therefore cannot reach the covered screen; no
/// caller-side `modal_open` guards are required.
///
/// Dismiss remains caller policy. This shell registers its root as the current topmost
/// Escape target, which receives transient `.dismissed`; callers may also inspect outside
/// pointer activation. After building dialog descendants, call
/// `ctx.consumeFlag(modal.box.key, .clicked)`; a subsequent
/// `modal.root.query(ctx).clicked` is then an outside activation. The same typed bubbling
/// and consumption rules used by nested controls apply. The box is queried here both as
/// a blocking target and to preserve its prior-frame geometry.
pub fn modal(ctx: *UiCtx, key: []const u8, title: []const u8) !Modal {
    // VIEW-02: the fullscreen scrim covers the whole drawable, in device px (the layout space).
    const m = ctx.res.view.metrics;
    const root = try Node.create(ctx.arena, key);
    _ = root.with_layout(.top_left, null)
        .with_size(ui.features.Size.initFixed(m.px_w, m.px_h));
    root.render_data.fill = ctx.res.view.theme.bg;
    _ = root.query(ctx); // fullscreen scrim: queried root structurally blocks lower trees
    ctx.res.commands.registerEscape(root.key);

    const box = try Node.pcreate(ctx.arena, "box", root);
    _ = box.with_layout(.center, .{ .dir = .column })
        .with_size(ui.features.Size.init(.fit_children, .fit_children));
    box.layout.gap = 10;
    box.size.padding = ui.features.Padding.init(16); // padding is a style property now, not a Size.init arg
    box.render_data.fill = ctx.res.view.theme.panel;
    box.render_data.outline = .{ .color = ctx.res.view.theme.line2 };
    _ = box.query(ctx); // keep the slot alive so `box.rect` resolves next frame

    _ = try label(ctx, box, "title", title);

    // INPUT-08: the dialog shell. `expanded` is genuinely owned here — a modal is either
    // built (open) or absent — and the scrim/dialog is a polite live region so opening it
    // can be announced. Title is the authoritative name. Published in paint order after
    // its title label so the bridge sees the container after its name node.
    ctx.res.semantics.publish(semantics.describeDialog(root.key, title, ctx.isFocused(root.key)));

    return .{ .root = root, .box = box };
}

/// Single-line search/text box backed by the authoritative host editor model
/// (`UiState.TextInputState` = `editor.LineEditor`, keyed like `ScrollState`). It registers
/// its stable node key in global traversal order and requests singular engine focus when
/// clicked. SDL delivers `.text_input` and key events as raw events, so `main.zig` routes
/// them into this same model — text through `insert` and caret/selection/clipboard/delete
/// through the editor's methods — against whichever key `ctx.focusedKey()` returns. Shows
/// `placeholder` (dimmed) when empty and unfocused; while focused it renders the model's
/// caret as a bar (or the selection wrapped in guillemets); plain text otherwise. Focus
/// draws accent chrome, and a refused edit (overflow / invalid / multi-line) draws a
/// `danger` outline until the next accepted edit. A trailing "✕" clears the field on click
/// (the pointer clear action; keyboard clear is Ctrl+A then Backspace, same model). The
/// widget starts SDL text input when it takes focus; Escape and outside clicks clear focus,
/// with the host stopping SDL text input on Escape.
pub fn text_input(ctx: *UiCtx, parent: *Node, key: []const u8, placeholder: []const u8, width: f32) !*Node {
    const node = try Node.pcreate(ctx.arena, key, parent);
    _ = node.with_layout(.relative, null);

    const state = node.state(ctx, UiState.TextInputState);
    ctx.registerFocus(node.key, true);
    ctx.res.commands.registerText(node.key, true);

    const q = node.query(ctx);
    if (q.hovering) ctx.res.cursor.request(.text);
    if (q.clicked) {
        _ = ctx.requestFocus(node.key);
    } else if (ctx.isFocused(node.key) and ctx.res.input.pointer.buttons.primary.pressed and !q.pressed) {
        ctx.clearFocus(); // primary press landed outside this field
    }
    const focused = ctx.isFocused(node.key);
    // Current desktop policy keeps every focused text field visibly outlined; INPUT-06
    // can later distinguish keyboard-origin focus without changing the vocabulary.
    cb.publishControlState(ctx, node.key, .{ .focused = focused, .focus_visible = focused });
    // INPUT-08: the accessible name is the placeholder/purpose; the value is the model's
    // authoritative text (never the caret/selection display string). A refused edit is
    // surfaced as an assertive live region, matching the widget's `danger` outline.
    ctx.res.semantics.publish(semantics.describeTextInput(
        node.key,
        placeholder,
        state.text(),
        focused,
        state.refused,
    ));
    if (focused and !sdl.keyboard.textInputActive(ctx.res.platform.window)) {
        sdl.keyboard.startTextInput(ctx.res.platform.window) catch {};
    } else if (ctx.focusedKey() == null and sdl.keyboard.textInputActive(ctx.res.platform.window)) {
        sdl.keyboard.stopTextInput(ctx.res.platform.window) catch {};
    }

    // Compose the display string from the authoritative editor model (INPUT-07). The
    // primitive `data_text` feature paints a single run and cannot place a sub-glyph
    // caret or a coloured selection band, so the caret is shown as a visible marker at
    // its codepoint position and a selection is bracketed. This honestly reflects the
    // model's caret/anchor without pretending to pixel-accurate glyph hit-testing that
    // the current text feature does not provide.
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

    try data_text(ctx, node, shown);
    node.size.padding = ui.features.Padding.initSymmetric(8, 4);
    node.size.w = .{ .fixed = width }; // data_text sized both axes to content — pin width
    node.render_data.text = if (state.len == 0 and !focused) ctx.res.view.theme.dim else ctx.res.view.theme.fg;
    // Focus-visible chrome, with a non-silent refusal cue: a rejected edit (overflow or
    // invalid/multi-line text) tints the outline `danger` until the next accepted edit.
    const outline_color = if (state.refused)
        ctx.res.view.theme.danger
    else if (focused)
        ctx.res.view.theme.acc
    else
        ctx.res.view.theme.line2;
    node.render_data.outline = .{ .color = outline_color };

    // Pointer clear affordance: a trailing "✕" hit region that empties the field on click
    // (the pointer half of the clear action; keyboard clear is Ctrl+A then Backspace, both
    // routed to the same model). Only shown while there is text to clear.
    if (!state.isEmpty()) {
        const clear_btn = try Node.pcreate(ctx.arena, "clear", node);
        _ = clear_btn.with_layout(.center_right, null);
        try data_text(ctx, clear_btn, "\u{2715}");
        clear_btn.size.padding = ui.features.Padding.initSymmetric(4, 0);
        const cq = clear_btn.query(ctx);
        if (cq.hovering) ctx.res.cursor.request(.pointer);
        clear_btn.render_data.text = if (cq.hovering) ctx.res.view.theme.fg else ctx.res.view.theme.dim;
        if (cq.clicked) {
            _ = state.clear();
            _ = ctx.requestFocus(node.key); // keep focus in the field after clearing
        }
    }

    return node;
}
