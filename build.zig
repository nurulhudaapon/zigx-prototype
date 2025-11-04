const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = mod },
            },
        }),
    });

    // Get the dependencies
    const httpz_dep = b.dependency("httpz", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("httpz", httpz_dep.module("httpz"));
    mod.addImport("httpz", httpz_dep.module("httpz"));

    // 2. Define an options struct to pass the version at comptime
    const options = b.addOptions();
    options.addOption([]const u8, "version_string", zon.version);

    // 3. Add the options module to your executable's root module
    mod.addOptions("zx_info", options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

pub fn setup(b: *std.Build, options: std.Build.ExecutableOptions) void {
    const zx_dep = b.dependency("zx", .{
        // .target = options.root_module.target,
        // .optimize = options.root_module.optimize,
    });

    // --- 1. Get the zx executable artifact ---
    const zx_exe = zx_dep.artifact("zx");

    // --- 2. Define the transpilation run command ---
    // This command generates the missing files in 'site/.zx'
    const transpile_cmd = b.addRunArtifact(zx_exe);
    transpile_cmd.addArgs(&[_][:0]const u8{
        "transpile",
        "site",
        "--output",
        "site/.zx",
    });
    // Ensure the build fails if transpilation fails
    // transpile_cmd.expect_exit_code = 0;

    // --- 3. Define the main executable artifact ---
    const exe = b.addExecutable(options);

    // NEW FIX: Add the project root path (where 'site' is located) as an
    // include path to help the compiler resolve paths to generated files
    // once the transpilation step has completed.
    exe.addIncludePath(b.path("."));
    exe.root_module.addImport("zx", zx_dep.module("zx"));

    // CRITICAL FIX: Force the compilation of the main executable to wait
    // until the transpilation command has completed and generated all files.
    exe.step.dependOn(&transpile_cmd.step);

    b.installArtifact(exe);

    // --- 4. Define the explicit 'transpile' step ---
    const transpile_step = b.step("transpile", "Transpile Zx components before running");
    transpile_step.dependOn(&transpile_cmd.step);

    // --- 5. Define the 'serve' step ---
    const run_step = b.step("serve", "Run the Zx website");
    const run_cmd = b.addRunArtifact(exe);

    // Ensure running (serving) also depends on transpilation finishing first.
    run_cmd.step.dependOn(&transpile_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| run_cmd.addArgs(args);
}
