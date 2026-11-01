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

    // The UI engine is a package of its own (`src/ui/build.zig.zon`), named in `build.zig.zon`
    // as a path dependency. The library and the UI tests import it as the module `ui`; a
    // relative import into `src/ui/` would put an engine file in two modules, which Zig refuses.
    const ui_dep = b.dependency("ui", .{ .target = target, .optimize = optimize });
    const ui_mod = ui_dep.module("ui");
    // The ECS engine is a package the same way (`src/ecs/build.zig.zon`), imported as `ecs`;
    // `src/world.zig` and `src/ecs.zig` instantiate it over this game's types.
    const ecs_dep = b.dependency("ecs", .{ .target = target, .optimize = optimize });
    const ecs_mod = ecs_dep.module("ecs");

    // My lib
    const ha_mod = b.addModule("human_action", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ha_mod.addImport("sdl3", sdl3.module("sdl3"));
    ha_mod.addImport("ui", ui_mod);
    ha_mod.addImport("ecs", ecs_mod);
    // The authored roster (`src/roster.zig`) compiles the shipped data files in by name
    // (`@embedFile("actions.zon")`), so a release build carries its content and the parser
    // runs over the same bytes a dev build reads from `data/`.
    ha_mod.addAnonymousImport("actions.zon", .{ .root_source_file = b.path("data/actions.zon") });
    ha_mod.addAnonymousImport("goods.zon", .{ .root_source_file = b.path("data/goods.zon") });
    ha_mod.addAnonymousImport("technologies.zon", .{ .root_source_file = b.path("data/technologies.zon") });

    // Executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("ha", ha_mod);
    exe_mod.addImport("ecs", ecs_mod);

    // Build for desktop.
    const exe = b.addExecutable(.{
        .name = "human_action",
        .root_module = exe_mod,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    // Package the UI typeface and its license next to the binary. SDL_ttf opens
    // the font from `assets/fonts/...` at runtime (see `main.font_path`), so the packaged
    // build must carry both the TTF and — as SIL OFL 1.1 §2 requires — the verbatim license
    // + copyright notice alongside it. These `installFile` steps run on `zig build`
    // (`installArtifact` above already wires the default install step), so `zig-out/` is a
    // self-contained, legally-redistributable bundle. Provenance: `docs/fonts.md`.
    b.installFile("assets/fonts/JetBrainsMonoNL-Regular.ttf", "assets/fonts/JetBrainsMonoNL-Regular.ttf");
    b.installFile("assets/fonts/JetBrainsMono-OFL.txt", "assets/fonts/JetBrainsMono-OFL.txt");

    // Run App
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);

    // Unit tests
    const unit_tests = b.addTest(.{ .root_module = ha_mod, .use_llvm = true });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Game-content tests. `src/pages/` sits outside the `ha` library (it imports `ha` and
    // `main.zig`), so its test blocks need a root of their own: the executable module. The
    // one `test` step runs both binaries.
    const page_tests = b.addTest(.{ .root_module = exe_mod, .use_llvm = true });
    const run_page_tests = b.addRunArtifact(page_tests);
    test_step.dependOn(&run_page_tests.step);

    // UI-layer unit tests: the reusable engine + host binding (features/draw/compositions)
    // in isolation, without game content. See `src/test_ui.zig`.
    const ui_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_test_mod.addImport("sdl3", sdl3.module("sdl3"));
    ui_test_mod.addImport("ui", ui_mod);
    // `res.zig` embeds `sim/res.zig`, which carries the authored roster, and the UI tests
    // compile `res.zig`, so the data files resolve here too.
    ui_test_mod.addAnonymousImport("actions.zon", .{ .root_source_file = b.path("data/actions.zon") });
    ui_test_mod.addAnonymousImport("goods.zon", .{ .root_source_file = b.path("data/goods.zon") });
    ui_test_mod.addAnonymousImport("technologies.zon", .{ .root_source_file = b.path("data/technologies.zon") });
    const ui_tests = b.addTest(.{ .root_module = ui_test_mod, .use_llvm = true });
    const run_ui_tests = b.addRunArtifact(ui_tests);

    const test_ui_step = b.step("test-ui", "Run UI-layer unit tests (engine + host binding, minus game content)");
    test_ui_step.dependOn(&run_ui_tests.step);

    // The engines' own tests, from their packages' modules, in both test steps.
    const engine_tests = b.addTest(.{ .root_module = ui_mod, .use_llvm = true });
    const run_engine_tests = b.addRunArtifact(engine_tests);
    test_step.dependOn(&run_engine_tests.step);
    test_ui_step.dependOn(&run_engine_tests.step);

    const ecs_tests = b.addTest(.{ .root_module = ecs_mod, .use_llvm = true });
    const run_ecs_tests = b.addRunArtifact(ecs_tests);
    test_step.dependOn(&run_ecs_tests.step);
    test_ui_step.dependOn(&run_ecs_tests.step);

    // The simulation alone (`src/test_sim.zig`): the sim files and the `ecs` package, with no
    // `sdl3`, no `ui` and no `ha`, so a sim file that reaches the host stops compiling here.
    // `test` does not depend on it: the same tests already run under `ha_mod`.
    const sim_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_sim.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_test_mod.addImport("ecs", ecs_mod);
    sim_test_mod.addAnonymousImport("actions.zon", .{ .root_source_file = b.path("data/actions.zon") });
    sim_test_mod.addAnonymousImport("goods.zon", .{ .root_source_file = b.path("data/goods.zon") });
    sim_test_mod.addAnonymousImport("technologies.zon", .{ .root_source_file = b.path("data/technologies.zon") });
    const sim_tests = b.addTest(.{ .root_module = sim_test_mod, .use_llvm = true });
    const run_sim_tests = b.addRunArtifact(sim_tests);

    const test_sim_step = b.step("test-sim", "Run the simulation's unit tests alone (src/ecs + the sim files, no UI host, no SDL)");
    test_sim_step.dependOn(&run_sim_tests.step);
    test_sim_step.dependOn(&run_ecs_tests.step);
}
