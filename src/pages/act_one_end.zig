//! The Act I curtain (`src/pages/` game content). Owning a `Shelter` *is* the win, so
//! `build_ui` routes here the frame the build resolves and stops building the HUD at all.
//! That is also what makes the dialog's own button the only thing on the window a click
//! can reach — a real overlay would leave the play screen live underneath it.
//!
//! Two beats with a Continue between them: the roof first, then who it brought. The
//! pause is the point — the arrival reads as news rather than as more reward text. The
//! beat lives in the dialog's own pooled `StepState` (the `TabsState` pattern), so it
//! survives the frame-arena reset without touching `Resources`.

const ha = @import("ha");
const app = @import("../main.zig");

const comp = ha.comp;
const tag = ha.tag;
const ecs = ha.ecs;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const World = ha.world.World;
const Entity = ha.world.Entity;
const StepState = uic.UiState.StepState;

const t = @import("./templates/root.zig");

/// The prose column width for the curtain's note, in px — an explicit dialog measure so the
/// note wraps as a paragraph rather than stretching the `fit_children` panel to one long
/// line. A template constant today; VIEW-01's `ViewMetrics` will feed the same parameter.
const dialog_prose_w: f32 = 320;

/// The curtain's script. The last beat's button is the one that starts a new run.
const Beat = struct { line: []const u8, note: []const u8, button: []const u8 };
const beats = [_]Beat{
    .{
        .line = "You have a house to live in.",
        .note = "Room enough for four under one roof.",
        .button = "Continue",
    },
    .{
        .line = "Two others asked to move in.",
        .note = "You are not alone here anymore. Act I ends.",
        .button = "Start over",
    },
};

pub fn ui_act_one_end(ctx: *uic.UiCtx, world: *World) !*uic.Node {
    const th = ctx.res.view.theme;

    // KIT-04: the Act I curtain lives in the one terminal shell; it needs only the main body.
    const regions = try t.shell(ctx, .{
        .id = "act1",
        .act = .act_one,
        .page_pad = ha.tokens.pad_page,
        .section_gap = ha.tokens.gap.section,
    });
    const dialog = try t.panel(ctx, regions.body, "curtain", "ACT I");
    _ = dialog.with_layout(.center);

    const st = dialog.get().state(ctx, StepState);
    if (st.step >= beats.len) st.step = 0; // the script shrank across frames — stay valid
    const beat = beats[st.step];

    // Stable keys across beats: the text nodes persist and re-source their content, the
    // way every other rebuilt leaf does.
    _ = (try el.text(ctx, dialog, "line", beat.line))
        .with_style(.{ style.h2, Style{ .text = th.fg } });
    // The note is genuine prose, longer than a heading and worth reading as a paragraph —
    // constrain it to an explicit dialog column so it wraps on word boundaries instead of
    // stretching the panel to a single long line. The width is a template constant (the
    // dialog's prose measure); VIEW-01's ViewMetrics will later feed the same parameter.
    _ = (try el.text(ctx, dialog, "note", beat.note))
        .with_wrap(dialog_prose_w)
        .with_style(.{ style.body, Style{ .text = th.dim } });

    const go = try t.button(ctx, dialog, "go", beat.button, true);
    if (go.query().clicked) {
        if (st.step + 1 < beats.len) {
            st.step += 1;
        } else {
            // Nothing follows Act I yet, so the only way on is back to the start. The
            // settled actor has to go first: unlike the game-over path, this player is
            // still alive, and spawning over them would leave two.
            const settled = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
            if (settled.get()) |entry| world.despawn(entry[0]);
            _ = app.spawn_player(world);
            ctx.res.sim.reset(); // clock, log and the teaching flag all start over together
            ctx.res.sim.log.push(.dim, "You wake alone. Cold. Hungry.");
            st.step = 0;
        }
    }
    return regions.root.get();
}
