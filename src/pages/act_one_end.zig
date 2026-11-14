//! The Act I curtain (`src/pages/` game content): the UI's response to `ActEnded`. By the time
//! it shows, the world has crossed into Act II (`cross_curtain`); `build_ui` opens
//! `CurtainState` on the fact, which pauses playback, so the world holds still while the player
//! watches. While it is open `build_ui` routes here instead of to the play screen.
//!
//! The curtain is a scene (`shelter.zig`): inside the shelter at the fire, the others walking
//! up out of the snow and their faces coming into the light, then `The shelter stands.` and
//! `You are no longer alone.` `CONTINUE \u{2192}` fades out; in the dark the curtain closes,
//! restoring the prior pause state, and the Act II page comes up over the live, migrated
//! world. In the demo (`Resources.demo`) the thank-you comes up instead, and Act II is never
//! shown.
//! `REPLAY` starts the scene over, and a click on the scene skips to its end.

const ha = @import("ha");

const uic = ha.ui_client;

const t = @import("./templates/root.zig");
const shelter = @import("./shelter.zig");

pub fn ui_act_one_end(ctx: *uic.UiCtx) !uic.Trees {
    const clock = &ctx.res.scene.seconds;
    clock.* += ctx.res.game.time.real_dt;

    const cells = shelter.compose(clock.*);
    const s = try t.scene(ctx, "act_one_end", .{
        .cells = &cells,
        .caption = shelter.caption,
        .caption_s = clock.* - shelter.caption_s,
        .go = "CONTINUE \u{2192}",
    });
    if (s.skip) clock.* = @max(clock.*, shelter.played_s);
    if (s.replay) clock.* = 0;
    // The demo ends here, on the thank-you; the game goes on into Act II.
    if (s.go) ctx.res.fade.to(if (ctx.res.demo) .thanks else .act_two);
    return try uic.oneRoot(ctx.arena, s.root);
}

/// Open the thank-you from its first frame, the run held still behind it.
pub fn openThanks(ctx: *uic.UiCtx) void {
    ctx.res.route = .thanks;
    ctx.res.scene = .{};
}
