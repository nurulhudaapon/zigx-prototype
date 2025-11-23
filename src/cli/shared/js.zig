const PackageJson = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    dependencies: ?std.json.Value = null,
    devDependencies: ?std.json.Value = null,
    scripts: ?std.json.Value = null,
    packageManager: ?PM = null,
    main: ?[]const u8 = null,

    const PM = enum {
        npm,
        pnpm,
        yarn,
        bun,
    };

    fn parse(allocator: std.mem.Allocator) !std.json.Parsed(PackageJson) {
        log.debug("Parsing package.json", .{});
        const package_json_str = std.fs.cwd().readFileAlloc(allocator, "package.json", std.math.maxInt(usize)) catch |err| switch (err) {
            error.FileNotFound => {
                log.debug("Package.json not found", .{});
                return error.PackageJsonNotFound;
            },
            else => return err,
        };
        // Don't free package_json_str here - std.json.parseFromSlice may reuse the buffer
        // The Parsed struct will manage the memory through its deinit() method

        log.debug("Found package.json: {s}", .{package_json_str});
        const package_json_parsed: std.json.Parsed(PackageJson) = std.json.parseFromSlice(
            PackageJson,
            allocator,
            package_json_str,
            .{},
        ) catch |err| switch (err) {
            else => {
                allocator.free(package_json_str);
                return error.InvalidPackageJson;
            },
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

        // Check for lockfiles
        if (std.fs.cwd().statFile("package-lock.json") catch null) |_| return .npm;
        if (std.fs.cwd().statFile("pnpm-lock.yaml") catch null) |_| return .pnpm;
        if (std.fs.cwd().statFile("yarn.lock") catch null) |_| return .yarn;
        if (std.fs.cwd().statFile("bun.lock") catch null) |_| return .bun;
        if (std.fs.cwd().statFile("bun.lockb") catch null) |_| return .bun;

        // Check for binary in path
        return .npm;
    }
};

pub fn checkEsbuildBin() bool {
    return if (std.fs.cwd().statFile("node_modules/.bin/esbuild") catch null) |_| true else false;
}

pub fn buildjs(ctx: zli.CommandContext, binpath: []const u8, verbose: bool) !void {
    var program_meta = try util.findprogram(ctx.allocator, binpath);
    defer program_meta.deinit(ctx.allocator);

    const rootdir = program_meta.rootdir orelse return error.RootdirNotFound;

    var package_json_parsed = try PackageJson.parse(ctx.allocator);
    defer package_json_parsed.deinit();

    var package_json = package_json_parsed.value;

    const pm = package_json.getPackageManager();
    log.debug("Package manager: {s}", .{@tagName(pm)});

    if (!checkEsbuildBin()) {
        log.debug("Installing dependencies for JavaScript", .{});
        log.debug("We try bun first", .{});
        var bun_installer = std.process.Child.init(&.{ "bun", "install" }, ctx.allocator);
        try bun_installer.spawn();
        const status = try bun_installer.wait();

        log.debug("Bun installer status: {s}", .{@tagName(status)});

        if (!checkEsbuildBin()) {
            var installer = std.process.Child.init(&.{ @tagName(pm), "install" }, ctx.allocator);
            try installer.spawn();
            _ = try installer.wait();
        }
        if (!checkEsbuildBin()) {
            std.debug.print(
                \\
                \\Could not find a Node.js package manager on your system. 
                \\We tried running '{s} install' but it failed.
                \\Please ensure you have a package manager (npm, pnpm, yarn, or bun) installed,
                \\or set the correct "packageManager" field in your package.json.
                \\You may need to run "npm install" or equivalent manually.
                \\
            , .{@tagName(pm)});
        } else {
            log.debug("Dependencies installed", .{});
        }
    } else {
        log.debug("Esbuild binary found", .{});
    }

    const outfile_arg = try std.fmt.allocPrintSentinel(ctx.allocator, "--outfile={s}/assets/main.js", .{rootdir}, 0);
    const main_tsx_arg = package_json.main orelse "site/main.tsx";
    defer ctx.allocator.free(outfile_arg);

    const main_tsx_argz = try ctx.allocator.dupeZ(u8, main_tsx_arg);
    defer ctx.allocator.free(main_tsx_argz);

    log.debug("Building main.tsx: in package.json: {s}", .{package_json.main orelse "na"});
    log.debug("Outfile: {s}", .{outfile_arg});

    const esbuild_args = [_][:0]const u8{
        "node_modules/.bin/esbuild",
        main_tsx_argz,
        "--bundle",
        "--minify",
        outfile_arg,
        // "--define:process.env.NODE_ENV=\\\"production\\\"",
        // "--define:__DEV__=false",
    };
    var esbuild_cmd = std.process.Child.init(&esbuild_args, ctx.allocator);
    if (!verbose) {
        esbuild_cmd.stdout_behavior = .Ignore;
        esbuild_cmd.stderr_behavior = .Ignore;
    }

    if (verbose) try ctx.writer.print("\n\x1b[1m─────────────────── Bundling JS ───────────────────\x1b[0m\n", .{});

    try esbuild_cmd.spawn();
    _ = try esbuild_cmd.wait();

    if (verbose) try ctx.writer.print("\x1b[1m─────────────────────────────────────────────────────\x1b[0m\n\n", .{});
}

const std = @import("std");
const zli = @import("zli");
const util = @import("util.zig");
const log = std.log.scoped(.cli);
