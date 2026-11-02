//! The Act I curtain (`src/pages/` game content): the UI's response to `ActEnded`. By the time
//! it shows, the world has crossed into Act II (`cross_curtain`); `build_ui` opens
//! `CurtainState` on the fact, which pauses playback, so the world holds still while the player
//! reads. While it is open `build_ui` routes here instead of to the play screen, which also
//! makes the dialog's own button the only thing on the window a click can reach.
//!
//! Two beats with a Continue between them: the roof first, then who it brought. The pause
//! makes the arrival read as news rather than as more reward text. The beat is
//! `CurtainState.step`. The last beat's Continue dismisses the curtain, restoring the prior
//! pause state, and the next frame routes to the Act II page over the live, migrated world.

const ha = @import("ha");

const uic = ha.ui_client;

const t = @import("./templates/root.zig");

/// The curtain's script. The last beat's button closes the curtain.
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
        .button = "Continue",
    },
};

/// Build the curtain at the beat `CurtainState.step` names, and advance or dismiss on a click.
pub fn ui_act_one_end(ctx: *uic.UiCtx) !uic.Trees {
    // The Act I curtain lives in the one terminal shell; it needs only the main body.
    const regions = try t.shell(ctx, .{
        .id = "act1",
        .act = .act_one,
        .page_pad = ha.tokens.pad_page,
        .section_gap = ha.tokens.gap.section,
        // A curtain centred in the window; it never scrolls.
        .scroll = false,
    });
    const curtain = &ctx.res.curtain;
    if (curtain.step >= beats.len) curtain.step = 0; // the script shrank — stay valid
    const beat = beats[curtain.step];

    const c = try t.curtain(regions.body, "curtain", .{
        .title = "ACT I",
        .line = beat.line,
        .note = beat.note,
        .button = beat.button,
    });
    if (c.clicked) {
        if (curtain.step + 1 < beats.len) {
            curtain.step += 1;
        } else {
            curtain.dismiss(&ctx.res.playback);
        }
    }
    return try uic.oneRoot(ctx.arena, regions.root.get());
}
