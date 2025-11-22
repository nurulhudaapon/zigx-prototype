pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "dev",
        .description = "Start the app in development mode with rebuild on change",
    }, dev);

    try cmd.addFlag(flag.binpath_flag);

    return cmd;
}

const RESTART_INTERVAL_NS = std.time.ns_per_ms * 100; // 100ms
const BIN_DIR = "zig-out/bin";

fn dev(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const binpath = ctx.flag("binpath", []const u8);

    buildjs(ctx, binpath) catch |err| {
        log.info("Error building TS! {any}", .{err});
    };

    log.debug("First time building, we will run zig build first", .{});
    var build_builder = std.process.Child.init(&.{ "zig", "build" }, allocator);
    try build_builder.spawn();
    _ = try build_builder.wait();

    log.debug("Building complete, finding ZX executable", .{});

    var builder = std.process.Child.init(&.{ "zig", "build", "--watch" }, allocator);
    try builder.spawn();
    defer _ = builder.kill() catch unreachable;

    var program_meta = util.findprogram(allocator, binpath) catch |err| {
        try ctx.writer.print("Error finding ZX executable! {any}\n", .{err});
        return err;
    };
    defer program_meta.deinit(allocator);

    const program_path = program_meta.binpath orelse {
        try ctx.writer.print("Error finding ZX executable!\n", .{});
        return;
    };

    buildjs(ctx, binpath) catch |err| {
        log.info("Error building TS! {any}", .{err});
    };

    var runner = std.process.Child.init(&.{program_path}, allocator);
    try runner.spawn();
    defer _ = runner.kill() catch unreachable;

    var bin_mtime: i128 = 0;
    while (true) {
        std.Thread.sleep(RESTART_INTERVAL_NS);
        const stat = try std.fs.cwd().statFile(program_path);

        const should_restart = stat.mtime != bin_mtime and bin_mtime != 0;
        if (should_restart) {
            std.debug.print("Change detected, restarting server...\n", .{});

            _ = try runner.kill();
            try runner.spawn();

            std.debug.print("\n", .{});

            buildjs(ctx, binpath) catch |err| {
                log.info("Error watching TS! {any}", .{err});
            };
        }
        if (should_restart or bin_mtime == 0) bin_mtime = stat.mtime;
    }

    errdefer {
        // _ = builder.kill() catch unreachable;
        _ = if (runner.id != 0) runner.kill() catch unreachable;
    }
}

const PackageJson = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    dependencies: ?std.json.Value = null,
    devDependencies: ?std.json.Value = null,
    scripts: ?std.json.Value = null,
    packageManager: ?PM = null,

    const PM = enum {
        npm,
        pnpm,
        yarn,
        bun,
    };

    fn parse(allocator: std.mem.Allocator) !std.json.Parsed(PackageJson) {
        log.info("Parsing package.json", .{});
        const package_json_str = std.fs.cwd().readFileAlloc(allocator, "package.json", std.math.maxInt(usize)) catch |err| switch (err) {
            error.FileNotFound => {
                log.info("Package.json not found", .{});
                return error.PackageJsonNotFound;
            },
            else => return err,
        };
        defer allocator.free(package_json_str);

        log.debug("Found package.json: {s}", .{package_json_str});
        const package_json_parsed: std.json.Parsed(PackageJson) = std.json.parseFromSlice(
            PackageJson,
            allocator,
            package_json_str,
            .{},
        ) catch |err| switch (err) {
            else => return error.InvalidPackageJson,
        };
        log.debug("Parsed package.json: {any}", .{package_json_parsed.value});

        return package_json_parsed;
    }

    fn getPackageManager(self: *PackageJson) PM {
        if (self.packageManager) |pm| return pm;
        if (self.dependencies) |deps| {
            switch (deps) {
                .object => |obj| {
                    if (obj.get("bun")) |_| return .bun;
                    if (obj.get("pnpm")) |_| return .pnpm;
                    if (obj.get("yarn")) |_| return .yarn;
                    if (obj.get("npm")) |_| return .npm;
                },
                else => {},
            }
        }

        // Check for package-lock.json
        if (std.fs.cwd().statFile("package-lock.json") catch null) |_| return .npm;
        if (std.fs.cwd().statFile("pnpm-lock.yaml") catch null) |_| return .pnpm;
        if (std.fs.cwd().statFile("yarn.lock") catch null) |_| return .yarn;
        if (std.fs.cwd().statFile("bun.lock") catch null) |_| return .bun;
        if (std.fs.cwd().statFile("bun.lockb") catch null) |_| return .bun;

        return .npm;
    }
};

fn buildjs(ctx: zli.CommandContext, binpath: []const u8) !void {
    var program_meta = try util.findprogram(ctx.allocator, binpath);
    defer program_meta.deinit(ctx.allocator);

    const rootdir = program_meta.rootdir orelse return error.RootdirNotFound;

    var package_json_parsed = try PackageJson.parse(ctx.allocator);
    defer package_json_parsed.deinit();

    var package_json = package_json_parsed.value;

    const pm = package_json.getPackageManager();
    log.info("Package manager: {s}", .{@tagName(pm)});

    const has_esbuild_bin = if (std.fs.cwd().statFile("node_modules/.bin/esbuild") catch null) |_| true else false;
    if (!has_esbuild_bin) {
        log.info("Installing dependencies for JavaScript", .{});
        var installer = std.process.Child.init(&.{ @tagName(pm), "install" }, ctx.allocator);
        try installer.spawn();
        _ = try installer.wait();

        log.info("Dependencies installed", .{});
    } else {
        log.info("Esbuild binary found", .{});
    }

    const outfile_arg = try std.fmt.allocPrintSentinel(ctx.allocator, "--outfile={s}/assets/main.js", .{rootdir}, 0);
    defer ctx.allocator.free(outfile_arg);
    const esbuild_args = [_][:0]const u8{
        "node_modules/.bin/esbuild",
        "main.tsx",
        "--bundle",
        "--minify",
        outfile_arg,
        // "--define:process.env.NODE_ENV=\\\"production\\\"",
        // "--define:__DEV__=false",
    };
    var esbuild_cmd = std.process.Child.init(&esbuild_args, ctx.allocator);
    try esbuild_cmd.spawn();
    _ = try esbuild_cmd.wait();
}

const std = @import("std");
const zli = @import("zli");
const util = @import("shared/util.zig");
const flag = @import("shared/flag.zig");
const log = std.log.scoped(.cli);
const zx = @import("zx");
