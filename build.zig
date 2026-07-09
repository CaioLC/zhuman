const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL dependency
    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,

        // Lib options.
        // .callbacks = false,
        .ext_image = true,
        // .ext_net = false,
        .ext_ttf = true,
        // .log_message_stack_size = 1024,
        // .main = false,
        // .renderer_debug_text_stack_size = 1024,

        // Options passed directly to https://github.com/castholm/SDL (SDL3 C Bindings):
        // .c_sdl_preferred_linkage = .static,
        // .c_sdl_strip = false,
        // .c_sdl_sanitize_c = .off,
        // .c_sdl_lto = .none,
        // .c_sdl_emscripten_pthreads = false,
        // .c_sdl_install_build_config_h = false,

        // Options if `ext_image` is enabled:
        .image_enable_bmp = true,
        // .image_enable_gif = true,
        // .image_enable_jpg = true,
        // .image_enable_lbm = true,
        // .image_enable_pcx = true,
        .image_enable_png = true,
        // .image_enable_pnm = true,
        // .image_enable_qoi = true,
        .image_enable_svg = true,
        // .image_enable_tga = true,
        // .image_enable_xcf = true,
        // .image_enable_xpm = true,
        // .image_enable_xv = true,
    });

    // My lib
    const ha_mod = b.addModule("human_action", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ha_mod.addImport("sdl3", sdl3.module("sdl3"));
    // Library-internal files (components/actions/capital) reach the library's own public
    // surface via `@import("ha")` (e.g. `ha.dist`), so the module must import itself under
    // that name. Without it the self-import resolves only when `ha_mod` happens to be the
    // compilation root (`zig build test`); the exe build, which drives the component types
    // through `World`, would fail to find module 'ha'.
    ha_mod.addImport("ha", ha_mod);

    // Executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("ha", ha_mod);

    // Build for desktop.
    const exe = b.addExecutable(.{
        .name = "human_action",
        .root_module = exe_mod,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    // Run App
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);

    // Unit tests
    const unit_tests = b.addTest(.{ .root_module = ha_mod, .use_llvm = true });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // UI-layer unit tests: the reusable engine + host binding (features/draw/widgets),
    // excluding `pages.zig` (game-content screens that import the parked-broken
    // `main.zig`). Lets the UI be verified in isolation while the sim half is mid-refactor.
    // See `src/ui_client/test_ui.zig`.
    const ui_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_test_mod.addImport("sdl3", sdl3.module("sdl3"));
    const ui_tests = b.addTest(.{ .root_module = ui_test_mod, .use_llvm = true });
    const run_ui_tests = b.addRunArtifact(ui_tests);

    const test_ui_step = b.step("test-ui", "Run UI-layer unit tests (engine + host binding, minus game content)");
    test_ui_step.dependOn(&run_ui_tests.step);
}
