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

pub fn buildjs(ctx: zli.CommandContext, binpath: []const u8, is_dev: bool, verbose: bool) !void {
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
        // "--metafile=esbuild-meta.json",
        main_tsx_argz,
        "--bundle",
        "--minify",
        outfile_arg,
        if (is_dev) "--define:process.env.NODE_ENV=\"development\"" else "--define:process.env.NODE_ENV=\"production\"",
        if (is_dev) "--define:__DEV__=true" else "--define:__DEV__=false",
    };

    log.debug("Esbuild args: {s}", .{try std.mem.join(ctx.allocator, " ", &esbuild_args)});
    var esbuild_cmd = std.process.Child.init(&esbuild_args, ctx.allocator);

    esbuild_cmd.stderr_behavior = .Pipe;
    esbuild_cmd.stdout_behavior = .Pipe;
    try esbuild_cmd.spawn();

    var stdout = std.ArrayList(u8).empty;
    var stderr = std.ArrayList(u8).empty;
    esbuild_cmd.collectOutput(ctx.allocator, &stdout, &stderr, 8192) catch |err| {
        std.debug.print("Error collecting output: {any}", .{err});
    };

    log.debug("Esbuild stdout: {s} \n stderr: {s}", .{ stdout.items, stderr.items });

    const esbuild_output = try parseEsbuildOutput(stderr.items);

    // Pretty print esbuild output with colors
    if (verbose and esbuild_output.path.len > 0 and esbuild_output.size.len > 0 and esbuild_output.time.len > 0) {
        // Colorize the output: path cyan, size green, time yellow, emoji: package 📦
        const cyan = "\x1b[36m";
        const green = "\x1b[32m";
        const yellow = "\x1b[33m";
        const reset = "\x1b[0m";
        try ctx.writer.print(
            "📦 Bundled JS to {s}{s}{s} ({s}{s}{s}) in {s}{s}{s}\n",
            .{
                cyan,   esbuild_output.path, reset,
                green,  esbuild_output.size, reset,
                yellow, esbuild_output.time, reset,
            },
        );
    }
}

const EsbuildOutput = struct {
    path: []const u8,
    size: []const u8,
    time: []const u8,
};

// Example output:
//   site/.zx/assets/main.js  190.7kb
// ⚡ Done in 21ms
fn parseEsbuildOutput(stdout: []const u8) !EsbuildOutput {
    // First trim by line break and whitespace
    const trimmed_output = std.mem.trim(u8, stdout, " \t\n\r");

    // Split by line
    var lines = std.mem.splitSequence(u8, trimmed_output, "\n");

    var path: []const u8 = "";
    var size: []const u8 = "";
    var time: []const u8 = "";

    var line_count: usize = 0;

    // Continue with while loop and only take lines that have length
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len > 0) {
            if (line_count == 0) {
                // First found one is path (and size)
                // Find the last space-separated token (the size)
                var last_space: ?usize = null;
                var i = trimmed_line.len;
                while (i > 0) {
                    i -= 1;
                    if (trimmed_line[i] == ' ' or trimmed_line[i] == '\t') {
                        last_space = i;
                        break;
                    }
                }

                if (last_space) |space_idx| {
                    path = std.mem.trim(u8, trimmed_line[0..space_idx], " \t");
                    size = std.mem.trim(u8, trimmed_line[space_idx + 1 ..], " \t");
                } else {
                    path = trimmed_line;
                }
                line_count += 1;
            } else if (line_count == 1) {
                // Second found one is time
                // Look for "Done in" pattern
                if (std.mem.indexOf(u8, trimmed_line, "Done in")) |done_idx| {
                    const time_start = done_idx + 7; // "Done in" is 7 chars
                    if (time_start < trimmed_line.len) {
                        time = std.mem.trim(u8, trimmed_line[time_start..], " \t\r");
                    }
                }
                line_count += 1;
                break; // We found both, no need to continue
            }
        }
    }

    return EsbuildOutput{
        .path = path,
        .size = size,
        .time = time,
    };
}

const std = @import("std");
const zli = @import("zli");
const util = @import("util.zig");
const log = std.log.scoped(.cli);
