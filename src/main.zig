pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    return mainWithArgs(gpa, args[1..]);
}

pub fn mainWithArgs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const home_path = std.process.getEnvVarOwned(allocator, "HOME") catch
        try allocator.dupe(u8, "/");
    defer allocator.free(home_path);

    const local_home_path = try std.fs.path.join(allocator, &.{ home_path, ".local" });
    defer allocator.free(local_home_path);

    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();
    // try http_client.initDefaultProxies(arena);

    var diag = Diagnostics.init(allocator);
    defer diag.deinit();

    var progress = try Progress.init(.{
        .allocator = allocator,
        .maximum_node_name_len = 15,
    });
    defer progress.deinit(allocator);

    var running = std.atomic.Value(bool).init(true);
    const render_thread = std.Thread.spawn(
        .{},
        renderThread,
        .{ &progress, &running },
    ) catch |err| blk: {
        std.log.warn("failed to spawn rendering thread: {}", .{err});
        break :blk null;
    };

    var program = Program{
        .allocator = allocator,
        .http_client = &http_client,
        .progress = &progress,
        .diagnostics = &diag,
        .args = .{ .args = args },
        .options = .{
            .prefix = local_home_path,
        },
    };

    const res = program.run();

    if (render_thread) |t| {
        running.store(false, .unordered);
        t.join();
    }

    try program.diagnostics.reportToFile(std.io.getStdErr());
    return res;
}

fn renderThread(progress: *Progress, running: *std.atomic.Value(bool)) void {
    const fps = 15;
    const delay = std.time.ns_per_s / fps;
    const initial_delay = std.time.ns_per_s / 4;

    const stderr = std.io.getStdErr();
    if (!stderr.supportsAnsiEscapeCodes())
        return;

    std.time.sleep(initial_delay);
    while (running.load(.unordered)) {
        progress.renderToTty(stderr) catch {};
        std.time.sleep(delay);
    }

    progress.cleanupTty(stderr) catch {};
}

pub fn run(program: *Program) !void {
    while (!program.args.isDone()) {
        if (program.args.option(&.{ "-p", "--prefix" })) |prefix| {
            program.options.prefix = prefix;
        } else if (program.args.flag(&.{"install"})) {
            return program.install();
        } else if (program.args.flag(&.{"uninstall"})) {
            return program.uninstall();
        } else if (program.args.flag(&.{"update"})) {
            return program.update();
        } else if (program.args.flag(&.{"installed"})) {
            return program.installed();
        } else if (program.args.flag(&.{"packages"})) {
            return program.packages();
        } else if (program.args.flag(&.{"inifmt"})) {
            return program.inifmt();
        } else if (program.args.flag(&.{ "-h", "--help", "help" })) {
            return program.help();
        } else {
            try usageToFile(std.io.getStdErr());
            return error.InvalidArgument;
        }
    }

    try usageToFile(std.io.getStdErr());
    return error.InvalidArgument;
}

const Program = @This();

allocator: std.mem.Allocator,
http_client: *std.http.Client,
progress: *Progress,
diagnostics: *Diagnostics,

args: ArgParser,
options: struct {
    prefix: []const u8,
},

fn install(program: *Program) !void {
    var packages_to_install = std.StringArrayHashMap(void).init(program.allocator);
    defer packages_to_install.deinit();

    while (!program.args.isDone())
        try packages_to_install.put(program.args.eat(), {});

    var pkgs = try Packages.download(.{
        .allocator = program.allocator,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
        .download = .only_if_required,
    });
    defer pkgs.deinit();

    var pm = try PackageManager.init(.{
        .allocator = program.allocator,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
    });
    defer pm.deinit();

    try pm.installMany(pkgs, packages_to_install.keys());
    try pm.cleanup();
}

fn uninstall(program: *Program) !void {
    var packages_to_uninstall = std.StringArrayHashMap(void).init(program.allocator);
    defer packages_to_uninstall.deinit();

    while (!program.args.isDone())
        try packages_to_uninstall.put(program.args.eat(), {});

    var pm = try PackageManager.init(.{
        .allocator = program.allocator,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
    });
    defer pm.deinit();

    try pm.uninstallMany(packages_to_uninstall.keys());
    try pm.cleanup();
}

fn update(program: *Program) !void {
    var packages_to_update = std.StringArrayHashMap(void).init(program.allocator);
    defer packages_to_update.deinit();

    while (!program.args.isDone()) {
        try packages_to_update.put(program.args.eat(), {});
    }

    var pkgs = try Packages.download(.{
        .allocator = program.allocator,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
        .download = .always,
    });
    defer pkgs.deinit();

    var pm = try PackageManager.init(.{
        .allocator = program.allocator,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
    });
    defer pm.deinit();

    if (packages_to_update.count() == 0) {
        try pm.updateAll(pkgs);
    } else {
        try pm.updateMany(pkgs, packages_to_update.keys());
    }

    try pm.cleanup();
}

fn installed(program: *Program) !void {
    while (!program.args.isDone()) {
        return error.InvalidArgument;
    }

    var pm = try PackageManager.init(.{
        .allocator = program.allocator,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
    });
    defer pm.deinit();

    var stdout_buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = stdout_buffered.writer();

    for (
        pm.installed_file.data.packages.keys(),
        pm.installed_file.data.packages.values(),
    ) |package_name, package| {
        try writer.print("{s}\t{s}\n", .{ package_name, package.version });
    }

    try stdout_buffered.flush();
}

fn packages(program: *Program) !void {
    while (!program.args.isDone()) {
        return error.InvalidArgument;
    }

    var pkgs = try Packages.download(.{
        .allocator = program.allocator,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
        .download = .only_if_required,
    });
    defer pkgs.deinit();

    var stdout_buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = stdout_buffered.writer();

    for (pkgs.packages.keys(), pkgs.packages.values()) |package_name, package|
        try writer.print("{s}\t{s}\n", .{ package_name, package.info.version });

    try stdout_buffered.flush();
}

fn inifmt(program: *Program) !void {
    if (program.args.isDone())
        return inifmtFiles(program.allocator, std.io.getStdIn(), std.io.getStdOut());

    const cwd = std.fs.cwd();
    while (!program.args.isDone()) {
        const arg = program.args.eat();
        var out = try cwd.atomicFile(arg, .{});
        defer out.deinit();
        {
            const in = try cwd.openFile(arg, .{});
            defer in.close();
            try inifmtFiles(program.allocator, in, out.file);
        }
        try out.finish();
    }
}

fn inifmtFiles(allocator: std.mem.Allocator, file: std.fs.File, out: std.fs.File) !void {
    var buffered_writer = std.io.bufferedWriter(out.writer());
    try inifmtFile(allocator, file, buffered_writer.writer());
    try buffered_writer.flush();
}

fn inifmtFile(allocator: std.mem.Allocator, file: std.fs.File, writer: anytype) !void {
    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);
    return inifmtData(allocator, data, writer);
}

fn inifmtData(allocator: std.mem.Allocator, data: []const u8, writer: anytype) !void {
    // TODO: This does not preserve comments
    const i = try ini.Dynamic.parse(allocator, data, .{
        .allocate = ini.Dynamic.Allocate.none,
    });
    defer i.deinit();
    try i.write(writer);
}

fn help(program: *Program) !void {
    _ = program;
    return usageToFile(std.io.getStdOut());
}

fn usageToFile(file: std.fs.File) !void {
    var buffered = std.io.bufferedWriter(file.writer());
    try usageToWriter(buffered.writer());
    try buffered.flush();
}

fn usageToWriter(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: dipm [command] [args]
        \\
        \\Commands:
        \\  install [pkg]...    Install packages
        \\  uninstall [pkg]...  Uninstall packages
        \\  update [pkg]...     Update packages
        \\  update              Update all packages
        \\  installed           List installed packages
        \\  packages            List available packages
        \\  help                Display this message
        \\
        \\  inifmt [file]...    Format INI files
        \\  inifmt              Format INI from stdin and output to stdout
        \\
    );
}

test {
    _ = ArgParser;
    _ = Diagnostics;
    _ = PackageManager;
    _ = Packages;
    _ = Progress;

    _ = ini;
}

const ArgParser = @import("ArgParser.zig");
const Diagnostics = @import("Diagnostics.zig");
const PackageManager = @import("PackageManager.zig");
const Packages = @import("Packages.zig");
const Progress = @import("Progress.zig");

const builtin = @import("builtin");
const ini = @import("ini.zig");
const std = @import("std");
