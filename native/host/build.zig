// Build for the live_cimgui native host.
//
//   zig build                       build `live_cimgui_host`
//   zig build test                  run host unit tests
//   zig build --prefix <dir>        install into <dir>/bin
//
// The vendored Dear ImGui/cimgui sources are compiled here with Zig's C++ front
// end; nothing is downloaded at build time, and the same Zig compiler that
// builds the Zigler NIF builds this executable.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const vendor = b.option([]const u8, "vendor", "path to the vendored cimgui tree") orelse "../vendor/cimgui";
    const sdl_include = b.option([]const u8, "sdl-include", "SDL2 include directory") orelse "/usr/include/SDL2";

    const cpp_flags = &.{ "-std=c++17", "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS" };

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ vendor, "imgui" }) });
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ vendor, "imgui", "backends" }) });
    mod.addIncludePath(.{ .cwd_relative = vendor });
    mod.addIncludePath(.{ .cwd_relative = sdl_include });
    mod.addIncludePath(b.path("src"));

    mod.addCSourceFiles(.{
        .root = .{ .cwd_relative = vendor },
        .files = &.{
            "cimgui.cpp",
            "imgui/imgui.cpp",
            "imgui/imgui_draw.cpp",
            "imgui/imgui_tables.cpp",
            "imgui/imgui_widgets.cpp",
            "imgui/imgui_demo.cpp",
            "imgui/backends/imgui_impl_sdl2.cpp",
            "imgui/backends/imgui_impl_opengl3.cpp",
        },
        .flags = cpp_flags,
    });
    mod.addCSourceFile(.{ .file = b.path("src/glue.cpp"), .flags = cpp_flags });

    mod.linkSystemLibrary("SDL2", .{});
    mod.linkSystemLibrary("GL", .{});
    mod.linkSystemLibrary("dl", .{});

    const exe = b.addExecutable(.{ .name = "live_cimgui_host", .root_module = mod });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ vendor, "imgui" }) });
    test_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ vendor, "imgui", "backends" }) });
    test_mod.addIncludePath(.{ .cwd_relative = vendor });
    test_mod.addIncludePath(.{ .cwd_relative = sdl_include });
    test_mod.addCSourceFiles(.{
        .root = .{ .cwd_relative = vendor },
        .files = &.{
            "cimgui.cpp",
            "imgui/imgui.cpp",
            "imgui/imgui_draw.cpp",
            "imgui/imgui_tables.cpp",
            "imgui/imgui_widgets.cpp",
            "imgui/imgui_demo.cpp",
            "imgui/backends/imgui_impl_sdl2.cpp",
            "imgui/backends/imgui_impl_opengl3.cpp",
        },
        .flags = cpp_flags,
    });
    test_mod.addCSourceFile(.{ .file = b.path("src/glue.cpp"), .flags = cpp_flags });
    test_mod.linkSystemLibrary("SDL2", .{});
    test_mod.linkSystemLibrary("GL", .{});
    test_mod.linkSystemLibrary("dl", .{});

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run host unit tests");
    test_step.dependOn(&run_unit_tests.step);
    b.default_step.dependOn(&unit_tests.step);
}
