const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zigx",
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
    const zigx_dep = b.dependency("zigx", .{
        // .target = options.root_module.target,
        // .optimize = options.root_module.optimize,
    });

    // --- 1. Get the zigx executable artifact ---
    const zigx_exe = zigx_dep.artifact("zigx");

    // --- 2. Define the transpilation run command ---
    // This command generates the missing files in 'site/.zigx'
    const transpile_cmd = b.addRunArtifact(zigx_exe);
    transpile_cmd.addArgs(&[_][:0]const u8{
        "transpile",
        "site",
        "--output",
        "site/.zigx",
    });
    // Ensure the build fails if transpilation fails
    // transpile_cmd.expect_exit_code = 0;

    // --- 3. Define the main executable artifact ---
    const exe = b.addExecutable(options);

    // NEW FIX: Add the project root path (where 'site' is located) as an
    // include path to help the compiler resolve paths to generated files
    // once the transpilation step has completed.
    exe.addIncludePath(b.path("."));
    exe.root_module.addImport("zx", zigx_dep.module("zx"));

    // CRITICAL FIX: Force the compilation of the main executable to wait
    // until the transpilation command has completed and generated all files.
    exe.step.dependOn(&transpile_cmd.step);

    b.installArtifact(exe);

    // --- 4. Define the explicit 'transpile' step ---
    const transpile_step = b.step("transpile", "Transpile ZigX components before running");
    transpile_step.dependOn(&transpile_cmd.step);

    // --- 5. Define the 'serve' step ---
    const run_step = b.step("serve", "Run the ZigX website");
    const run_cmd = b.addRunArtifact(exe);

    // Ensure running (serving) also depends on transpilation finishing first.
    run_cmd.step.dependOn(&transpile_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| run_cmd.addArgs(args);
}
