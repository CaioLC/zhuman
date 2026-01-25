const sdl3 = @import("sdl3");

pub const white: sdl3.ttf.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

// try log_app.logInfo("Font Family: {s}", .{font.getFamilyName()});
// try log_app.logInfo("Font Style: {s}", .{font.getStyleName()});
// try log_app.logInfo("Font is fixed width: {}", .{font.isFixedWidth()});
// try log_app.logInfo("Font is scalable: {}", .{font.isScalable()});
// try log_app.logInfo("Font height: {d}", .{font.getHeight()});
// try log_app.logInfo("Font ascent: {d}", .{font.getAscent()});
// try log_app.logInfo("Font descent: {d}", .{font.getDescent()});
// try log_app.logInfo("Font lineskip: {d}", .{font.getLineSkip()});
// try log_app.logInfo("Font faces: {d}", .{font.getNumFaces()});
// try log_app.logInfo("Font kerning enabled: {}", .{font.getKerning()});
// try log_app.logInfo("Font has glyph 'A': {}", .{font.hasGlyph('A')});
// if (font.getGlyphMetrics('A')) |metrics| {
//     try log_app.logInfo("Glyph 'A' metrics: minx={d}, maxx={d}, miny={d}, maxy={d}, advance={d}", .{
//         metrics.minx, metrics.maxx, metrics.miny, metrics.maxy, metrics.advance,
//     });
// } else |err| {
//     try log_app.logWarn("Could not get glyph metrics for 'A': {s}", .{@errorName(err)});
// }
// if (font.getGlyphKerning('V', 'A')) |kerning| {
//     try log_app.logInfo("Kerning for 'VA': {d}", .{kerning});
// } else |err| {
//     try log_app.logWarn("Could not get glyph kerning for 'VA': {s}", .{@errorName(err)});
// }

// const solid_texture = try textureFromSurface(renderer, try font.renderTextSolid("Solid Text", white));
// defer solid_texture.deinit();

// const shaded_texture = try textureFromSurface(renderer, try font.renderTextShaded("Shaded Text", yellow, .{ .r = 50, .g = 50, .b = 50, .a = 255 }));
// defer shaded_texture.deinit();

// const blended_texture = try textureFromSurface(renderer, try font.renderTextBlended("Blended Text", cyan));
// defer blended_texture.deinit();

// const wrapped_text = "This is a looooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooong text that will be wrapped.";
// const wrapped_texture = try textureFromSurface(renderer, try font.renderTextBlendedWrapped(wrapped_text, magenta, 400));
// defer wrapped_texture.deinit();

// font.setStyle(.{ .bold = true, .italic = true });
// const styled_texture = try textureFromSurface(renderer, try font.renderTextBlended("Bold and Italic", white));
// defer styled_texture.deinit();
// font.setStyle(.{}); // Reset.

// try font.setOutline(2);
// const outlined_texture = try textureFromSurface(renderer, try font.renderTextBlended("Outlined (Round)", yellow));
// defer outlined_texture.deinit();

// // https://freetype.org/freetype2/docs/reference/ft2-glyph_stroker.html#ft_stroker_linejoin
// try font.setProperties(.{ .outline_line_join = 2 }); // MITER
// const outlined_miter_texture = try textureFromSurface(renderer, try font.renderTextBlended("Outlined (Miter)", magenta));
// defer outlined_miter_texture.deinit();
// try font.setProperties(.{ .outline_line_join = 0 }); // ROUND
// try font.setOutline(0); // Reset.

// const font_with_props: sdl3.ttf.Font = try .initWithProperties(.{ .filename = font_path, .size = 36 });
// defer font_with_props.deinit();
// const props_texture = try textureFromSurface(renderer, try font_with_props.renderTextBlended("Font from Properties", white));
// defer props_texture.deinit();

// const long_text = "This is a very long string that we want to fit into a small space.";
// const max_width = 200;
// _, const measured_length = try font.measureString(long_text, max_width);
// const truncated_text = try std.fmt.allocPrint(allocator, "{s}...", .{long_text[0..measured_length]});
// defer allocator.free(truncated_text);
// const truncated_texture = try textureFromSurface(renderer, try font.renderTextBlended(truncated_text, white));
// defer truncated_texture.deinit();

