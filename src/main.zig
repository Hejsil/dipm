pub fn main() u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    const args = std.process.argsAlloc(gpa) catch @panic("OOM");
    defer std.process.argsFree(gpa, args);

    mainFull(.{
        .allocator = gpa,
        .args = args[1..],
    }) catch |err| switch (err) {
        DiagnosticsError.DiagnosticFailure => return 1,
        else => |e| {
            std.log.err("{s}", .{@errorName(e)});
            return 1;
        },
    };

    return 0;
}

pub const DiagnosticsError = error{
    DiagnosticFailure,
};

pub const MainOptions = struct {
    allocator: std.mem.Allocator,
    args: []const []const u8,

    stdin: std.fs.File = std.io.getStdIn(),
    stdout: std.fs.File = std.io.getStdOut(),
    stderr: std.fs.File = std.io.getStdErr(),
};

pub fn mainFull(options: MainOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(options.allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const home_path = std.process.getEnvVarOwned(arena, "HOME") catch "/";
    const local_home_path = try std.fs.path.join(arena, &.{ home_path, ".local" });

    var http_client = std.http.Client{ .allocator = options.allocator };
    defer http_client.deinit();
    try http_client.initDefaultProxies(arena);

    var diag = Diagnostics.init(options.allocator);
    defer diag.deinit();

    var progress = try Progress.init(.{
        .allocator = arena,
        .maximum_node_name_len = 15,
    });

    var program = Program{
        .gpa = options.allocator,
        .arena = arena,
        .http_client = &http_client,
        .progress = &progress,
        .diagnostics = &diag,
        .stdin = options.stdin,
        .stdout = options.stdout,
        .stderr = options.stderr,

        .args = .{ .args = options.args },
        .options = .{
            .prefix = local_home_path,
        },
    };

    // We don't really care to store the thread. Just let the os clean it up
    _ = std.Thread.spawn(.{}, renderThread, .{&program}) catch |err| blk: {
        std.log.warn("failed to spawn rendering thread: {}", .{err});
        break :blk null;
    };

    const res = program.mainCommand();

    // Stop `renderThread` from rendering by locking stderr for the rest of the programs execution.
    program.io_lock.lock();
    try progress.cleanupTty(program.stderr);
    try diag.reportToFile(program.stderr);

    if (diag.hasFailed())
        return DiagnosticsError.DiagnosticFailure;

    return res;
}

fn renderThread(program: *Program) void {
    const fps = 15;
    const delay = std.time.ns_per_s / fps;
    const initial_delay = std.time.ns_per_s / 4;

    if (!program.stderr.supportsAnsiEscapeCodes())
        return;

    std.time.sleep(initial_delay);
    while (true) {
        program.io_lock.lock();
        program.progress.renderToTty(program.stderr) catch {};
        program.io_lock.unlock();
        std.time.sleep(delay);
    }
}

const main_usage =
    \\Usage: dipm [options] [command]
    \\
    \\Commands:
    \\  install [pkg]...    Install packages
    \\  uninstall [pkg]...  Uninstall packages
    \\  update [pkg]...     Update packages
    \\  update              Update all packages
    \\  list                List packages
    \\  pkgs                Manipulate and work pkgs.ini file
    \\  help                Display this message
    \\
    \\Options:
    \\  -p, --prefix        Set the prefix dipm will work and install things in.
    \\                      The following folders will be created in the prefix:
    \\                        {prefix}/bin/
    \\                        {prefix}/lib/
    \\                        {prefix}/share/dipm/
    \\
    \\
;

pub fn mainCommand(program: *Program) !void {
    while (program.args.next()) {
        if (program.args.option(&.{ "-p", "--prefix" })) |prefix|
            program.options.prefix = prefix;
        if (program.args.flag(&.{"install"}))
            return program.installCommand();
        if (program.args.flag(&.{"uninstall"}))
            return program.uninstallCommand();
        if (program.args.flag(&.{"update"}))
            return program.updateCommand();
        if (program.args.flag(&.{"list"}))
            return program.listCommand();
        if (program.args.flag(&.{"pkgs"}))
            return program.pkgsCommand();
        if (program.args.flag(&.{ "-h", "--help", "help" }))
            return program.stdout.writeAll(main_usage);
        if (program.args.positional()) |_|
            break;
    }

    try program.stderr.writeAll(main_usage);
    return error.InvalidArgument;
}

const Program = @This();

gpa: std.mem.Allocator,
arena: std.mem.Allocator,
http_client: *std.http.Client,
progress: *Progress,
diagnostics: *Diagnostics,

io_lock: std.Thread.Mutex = .{},
stdin: std.fs.File,
stdout: std.fs.File,
stderr: std.fs.File,

args: ArgParser,
options: struct {
    prefix: []const u8,
},

const install_usage =
    \\Usage: dipm install [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn installCommand(program: *Program) !void {
    var packages_to_install = std.ArrayList([]const u8).init(program.arena);
    try packages_to_install.ensureTotalCapacity(program.args.args.len);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(install_usage);
        if (program.args.positional()) |name|
            packages_to_install.appendAssumeCapacity(name);
    }

    var pkgs = try Packages.download(.{
        .allocator = program.gpa,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
        .download = .only_if_required,
    });
    defer pkgs.deinit();

    var pm = try PackageManager.init(.{
        .allocator = program.gpa,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
    });
    defer pm.deinit();

    try pm.installMany(pkgs, packages_to_install.items);
    try pm.cleanup();
}

const uninstall_usage =
    \\Usage: dipm uninstall [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn uninstallCommand(program: *Program) !void {
    var packages_to_uninstall = std.ArrayList([]const u8).init(program.arena);
    try packages_to_uninstall.ensureTotalCapacity(program.args.args.len);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(uninstall_usage);
        if (program.args.positional()) |name|
            packages_to_uninstall.appendAssumeCapacity(name);
    }

    var pm = try PackageManager.init(.{
        .allocator = program.gpa,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
    });
    defer pm.deinit();

    try pm.uninstallMany(packages_to_uninstall.items);
    try pm.cleanup();
}

const update_usage =
    \\Usage:
    \\  dipm update [options] [pkg]...
    \\  dipm update [options]
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn updateCommand(program: *Program) !void {
    var packages_to_update = std.ArrayList([]const u8).init(program.arena);
    try packages_to_update.ensureTotalCapacity(program.args.args.len);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(update_usage);
        if (program.args.positional()) |name|
            packages_to_update.appendAssumeCapacity(name);
    }

    var pkgs = try Packages.download(.{
        .allocator = program.gpa,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
        .download = .always,
    });
    defer pkgs.deinit();

    var pm = try PackageManager.init(.{
        .allocator = program.gpa,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
    });
    defer pm.deinit();

    if (packages_to_update.items.len == 0) {
        try pm.updateAll(pkgs);
    } else {
        try pm.updateMany(pkgs, packages_to_update.items);
    }

    try pm.cleanup();
}

const list_usage =
    \\Usage: dipm list [options] [command]
    \\
    \\Commands:
    \\  all                 List all known packages
    \\  installed           List installed packages
    \\  help                Display this message
    \\
;

fn listCommand(program: *Program) !void {
    while (program.args.next()) {
        if (program.args.flag(&.{"all"}))
            return program.listAllCommand();
        if (program.args.flag(&.{"installed"}))
            return program.listInstalledCommand();
        if (program.args.flag(&.{ "-h", "--help", "help" }))
            return program.stdout.writeAll(list_usage);
        if (program.args.positional()) |_|
            break;
    }

    try program.stderr.writeAll(list_usage);
    return error.InvalidArgument;
}

const list_installed_usage =
    \\Usage: dipm list installed [options]
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn listInstalledCommand(program: *Program) !void {
    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(list_installed_usage);
        if (program.args.positional()) |_| {
            try program.stderr.writeAll(list_installed_usage);
            return error.InvalidArgument;
        }
    }

    var pm = try PackageManager.init(.{
        .allocator = program.gpa,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
    });
    defer pm.deinit();

    var stdout_buffered = std.io.bufferedWriter(program.stdout.writer());
    const writer = stdout_buffered.writer();

    for (
        pm.installed_file.data.packages.keys(),
        pm.installed_file.data.packages.values(),
    ) |package_name, package| {
        try writer.print("{s}\t{s}\n", .{ package_name, package.version });
    }

    try stdout_buffered.flush();
}

const list_all_usage =
    \\Usage: dipm list all [options]
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn listAllCommand(program: *Program) !void {
    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(list_all_usage);
        if (program.args.positional()) |_| {
            try program.stderr.writeAll(list_all_usage);
            return error.InvalidArgument;
        }
    }

    var pkgs = try Packages.download(.{
        .allocator = program.gpa,
        .http_client = program.http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.options.prefix,
        .download = .only_if_required,
    });
    defer pkgs.deinit();

    var stdout_buffered = std.io.bufferedWriter(program.stdout.writer());
    const writer = stdout_buffered.writer();

    for (pkgs.packages.keys(), pkgs.packages.values()) |package_name, package|
        try writer.print("{s}\t{s}\n", .{ package_name, package.info.version });

    try stdout_buffered.flush();
}

const pkgs_usage =
    \\Usage: dipm pkgs [options] [command]
    \\
    \\Commands:
    \\  update              Update packages in pkgs.ini
    \\  add                 Make packages and add them to pkgs.ini
    \\  make                Make packages
    \\  check               Check packages for new versions
    \\  help                Display this message
    \\
;

fn pkgsCommand(program: *Program) !void {
    while (program.args.next()) {
        if (program.args.flag(&.{"update"}))
            return program.pkgsUpdateCommand();
        if (program.args.flag(&.{"add"}))
            return program.pkgsAddCommand();
        if (program.args.flag(&.{"make"}))
            return program.pkgsMakeCommand();
        if (program.args.flag(&.{"check"}))
            return program.pkgsCheckCommand();
        if (program.args.flag(&.{ "-h", "--help", "help" }))
            return program.stdout.writeAll(pkgs_usage);
        if (program.args.positional()) |_|
            break;
    }

    try program.stderr.writeAll(pkgs_usage);
    return error.InvalidArgument;
}

const pkgs_update_usage =
    \\Usage: dipm pkgs update [options] [url]...
    \\
    \\Options:
    \\  -f, --pkgs-file     Path to pkgs.ini (default: ./pkgs.ini)
    \\  -c, --commit        Commit each package updateed to pkgs.ini
    \\  -h, --help          Display this message
    \\
;

fn pkgsUpdateCommand(program: *Program) !void {
    var packages_to_update = std.StringArrayHashMap(void).init(program.arena);
    var options = PackagesAddOptions{
        .commit = false,
        .commit_prefix = "Update",
        .pkgs_ini_path = "./pkgs.ini",
        .urls = undefined,
    };

    while (program.args.next()) {
        if (program.args.option(&.{ "-f", "--pkgs-file" })) |file|
            options.pkgs_ini_path = file;
        if (program.args.flag(&.{ "-c", "--commit" }))
            options.commit = true;
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(pkgs_update_usage);
        if (program.args.positional()) |url|
            try packages_to_update.put(url, {});
    }

    const cwd = std.fs.cwd();
    var packages = try Packages.parseFromPath(program.gpa, cwd, options.pkgs_ini_path);
    defer packages.deinit();

    var urls = std.ArrayList(UrlAndName).init(program.arena);
    for (packages_to_update.keys()) |package_name| {
        const package = packages.packages.get(package_name) orelse {
            std.log.err("{s} not found", .{package_name});
            continue;
        };

        const url = try std.fmt.allocPrint(program.arena, "https://github.com/{s}", .{
            package.update.github,
        });
        try urls.append(.{
            .name = package_name,
            .url = url,
        });
    }

    options.urls = urls.items;
    return program.pkgsAdd(options);
}

const pkgs_add_usage =
    \\Usage: dipm pkgs add [options] [url]...
    \\
    \\Options:
    \\  -f, --pkgs-file     Path to pkgs.ini (default: ./pkgs.ini)
    \\  -c, --commit        Commit each package added to pkgs.ini
    \\  -h, --help          Display this message
    \\
;

fn pkgsAddCommand(program: *Program) !void {
    var urls = std.ArrayList(UrlAndName).init(program.arena);
    var options = PackagesAddOptions{
        .commit = false,
        .commit_prefix = "Add",
        .pkgs_ini_path = "./pkgs.ini",
        .urls = undefined,
    };

    while (program.args.next()) {
        if (program.args.option(&.{ "-f", "--pkgs-file" })) |file|
            options.pkgs_ini_path = file;
        if (program.args.flag(&.{ "-c", "--commit" }))
            options.commit = true;
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(pkgs_add_usage);
        if (program.args.positional()) |url|
            try urls.append(.{ .url = url, .name = null });
    }

    options.urls = urls.items;
    return program.pkgsAdd(options);
}

const PackagesAddOptions = struct {
    pkgs_ini_path: []const u8,
    commit: bool,
    commit_prefix: []const u8,
    urls: []const UrlAndName,
};

const UrlAndName = struct {
    url: []const u8,
    name: ?[]const u8,
};

fn pkgsAdd(program: *Program, options: PackagesAddOptions) !void {
    const cwd = std.fs.cwd();
    const pkgs_ini_base_name = std.fs.path.basename(options.pkgs_ini_path);

    var pkgs_ini_dir, const pkgs_ini_file = try fs.openDirAndFile(cwd, options.pkgs_ini_path, .{
        .file = .{ .mode = .read_write },
    });
    defer pkgs_ini_dir.close();
    defer pkgs_ini_file.close();

    var packages = try Packages.parseFile(program.gpa, pkgs_ini_file);
    defer packages.deinit();

    for (options.urls) |url| {
        const package = Package.fromUrl(.{
            .allocator = packages.arena.allocator(),
            .tmp_allocator = program.gpa,
            .http_client = program.http_client,
            .url = url.url,
            .name = url.name,
            .os = builtin.os.tag,
            .arch = builtin.target.cpu.arch,
        }) catch |err| {
            std.log.err("{s} {s}", .{ @errorName(err), url.url });
            continue;
        };

        try packages.update(package);

        if (options.commit) {
            try packages.writeToFileOverride(pkgs_ini_file);
            try pkgs_ini_file.sync();

            const msg = try std.fmt.allocPrint(program.arena, "{s}: {s} {s}", .{
                package.name,
                options.commit_prefix,
                package.package.info.version,
            });

            var child = std.process.Child.init(
                &.{ "git", "commit", "-i", pkgs_ini_base_name, "-m", msg },
                program.gpa,
            );
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            child.cwd_dir = pkgs_ini_dir;

            try child.spawn();
            _ = try child.wait();
        }
    }

    try packages.writeToFileOverride(pkgs_ini_file);
}

const pkgs_make_usage =
    \\Usage: dipm pkgs make [options] [url]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn pkgsMakeCommand(program: *Program) !void {
    var urls = std.StringArrayHashMap(void).init(program.arena);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(pkgs_make_usage);
        if (program.args.positional()) |url|
            try urls.put(url, {});
    }

    var stdout_buffered = std.io.bufferedWriter(program.stdout.writer());
    const writer = stdout_buffered.writer();

    for (urls.keys()) |url| {
        const package = Package.fromUrl(.{
            .allocator = program.arena,
            .tmp_allocator = program.gpa,
            .http_client = program.http_client,
            .url = url,
            .os = builtin.os.tag,
            .arch = builtin.target.cpu.arch,
        }) catch |err| {
            std.log.err("{s} {s}", .{ @errorName(err), url });
            continue;
        };

        try package.package.write(package.name, writer);
    }

    try stdout_buffered.flush();
}

const pkgs_check_usage =
    \\Usage: dipm pkgs check [options] [url]...
    \\
    \\Options:
    \\  -f, --pkgs-file     Path to pkgs.ini (default: ./pkgs.ini)
    \\  -h, --help          Display this message
    \\
;

fn pkgsCheckCommand(program: *Program) !void {
    var pkgs_ini_path: []const u8 = "./pkgs.ini";
    var packages_to_check_map = std.StringArrayHashMap(void).init(program.arena);

    while (program.args.next()) {
        if (program.args.option(&.{ "-f", "--pkgs-file" })) |file|
            pkgs_ini_path = file;
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(pkgs_check_usage);
        if (program.args.positional()) |package|
            try packages_to_check_map.put(package, {});
    }

    const cwd = std.fs.cwd();
    var packages = try Packages.parseFromPath(program.gpa, cwd, pkgs_ini_path);
    defer packages.deinit();

    var packages_to_check = packages_to_check_map.keys();
    if (packages_to_check.len == 0)
        packages_to_check = packages.packages.keys();

    var stdout_buffered = std.io.bufferedWriter(program.stdout.writer());
    const writer = stdout_buffered.writer();

    for (packages_to_check) |package_name| {
        const package = packages.packages.get(package_name) orelse {
            std.log.err("{s} not found", .{package_name});
            continue;
        };

        const version = package.newestUpstreamVersion(.{
            .allocator = program.arena,
            .tmp_allocator = program.gpa,
            .http_client = program.http_client,
        }) catch |err| {
            std.log.err("{s} failed to check version: {}", .{ package_name, err });
            continue;
        };

        if (!std.mem.eql(u8, package.info.version, version)) {
            try writer.print("{s} {s} -> {s}\n", .{
                package_name,
                package.info.version,
                version,
            });
            try stdout_buffered.flush();
        }
    }
    try stdout_buffered.flush();
}





    }
}

test {
    _ = ArgParser;
    _ = Diagnostics;
    _ = Package;
    _ = PackageManager;
    _ = Packages;
    _ = Progress;

    _ = download;
    _ = fs;
}

const ArgParser = @import("ArgParser.zig");
const Diagnostics = @import("Diagnostics.zig");
const PackageManager = @import("PackageManager.zig");
const Packages = @import("Packages.zig");
const Package = @import("Package.zig");
const Progress = @import("Progress.zig");

const builtin = @import("builtin");
const download = @import("download.zig");
const fs = @import("fs.zig");
const std = @import("std");
