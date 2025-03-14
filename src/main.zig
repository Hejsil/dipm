pub fn main() !u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    const args = std.process.argsAlloc(gpa) catch @panic("OOM");
    defer std.process.argsFree(gpa, args);

    mainFull(.{ .gpa = gpa, .args = args[1..] }) catch |err| switch (err) {
        Diagnostics.Error.DiagnosticsReported => return 1,
        else => |e| {
            if (builtin.mode == .Debug)
                return e;

            std.log.err("{s}", .{@errorName(e)});
            return 1;
        },
    };

    return 0;
}

pub const MainOptions = struct {
    gpa: std.mem.Allocator,
    args: []const []const u8,

    forced_prefix: ?[]const u8 = null,
    forced_pkgs_uri: ?[]const u8 = null,
    stdout: std.fs.File = std.io.getStdOut(),
    stderr: std.fs.File = std.io.getStdErr(),
};

pub fn mainFull(options: MainOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(options.gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const home_path = std.process.getEnvVarOwned(arena, "HOME") catch "/";
    const local_home_path = try std.fs.path.join(arena, &.{ home_path, ".local" });

    var diag = Diagnostics.init(options.gpa);
    defer diag.deinit();

    var progress = try Progress.init(.{
        .gpa = arena,
        .maximum_node_name_len = 15,
    });

    var prog = Program{
        .gpa = options.gpa,
        .arena = arena,
        .progress = &progress,
        .diag = &diag,
        .stdout = options.stdout,
        .stderr = options.stderr,

        .args = .{ .args = options.args },
        .options = .{
            .forced_prefix = options.forced_prefix,
            .prefix = local_home_path,
            .forced_pkgs_uri = options.forced_pkgs_uri,
        },
    };

    // We don't really care to store the thread. Just let the os clean it up
    if (prog.stderr.supportsAnsiEscapeCodes()) {
        _ = std.Thread.spawn(.{}, renderThread, .{&prog}) catch |err| blk: {
            std.log.warn("failed to spawn rendering thread: {}", .{err});
            break :blk null;
        };
    }

    const res = prog.mainCommand();

    // Stop `renderThread` from rendering by locking stderr for the rest of the progs execution.
    prog.io_lock.lock();
    try progress.cleanupTty(prog.stderr);
    try diag.reportToFile(prog.stderr);

    if (diag.hasFailed())
        return Diagnostics.Error.DiagnosticsReported;

    return res;
}

fn renderThread(prog: *Program) void {
    const fps = 15;
    const delay = std.time.ns_per_s / fps;
    const initial_delay = std.time.ns_per_s / 4;

    std.time.sleep(initial_delay);
    while (true) {
        prog.io_lock.lock();
        prog.progress.renderToTty(prog.stderr) catch {};
        prog.io_lock.unlock();
        std.time.sleep(delay);
    }
}

const main_usage =
    \\Usage: dipm [options] [command]
    \\
    \\Commands:
    \\  donate [pkg]...     Show donate links for packages
    \\  donate              Show donate links for installed packages
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

pub fn mainCommand(prog: *Program) !void {
    while (prog.args.next()) {
        if (prog.args.option(&.{ "-p", "--prefix" })) |p|
            prog.options.prefix = p;
        if (prog.args.flag(&.{"donate"}))
            return prog.donateCommand();
        if (prog.args.flag(&.{"install"}))
            return prog.installCommand();
        if (prog.args.flag(&.{"uninstall"}))
            return prog.uninstallCommand();
        if (prog.args.flag(&.{"update"}))
            return prog.updateCommand();
        if (prog.args.flag(&.{"list"}))
            return prog.listCommand();
        if (prog.args.flag(&.{"pkgs"}))
            return prog.pkgsCommand();
        if (prog.args.flag(&.{ "-h", "--help", "help" }))
            return prog.stdout.writeAll(main_usage);
        if (prog.args.positional()) |_|
            break;
    }

    try prog.stderr.writeAll(main_usage);
    return error.InvalidArgument;
}

const Program = @This();

gpa: std.mem.Allocator,
arena: std.mem.Allocator,
progress: *Progress,
diag: *Diagnostics,

io_lock: std.Thread.Mutex = .{},
stdout: std.fs.File,
stderr: std.fs.File,

args: ArgParser,
options: struct {
    /// If set, this prefix will be used instead of `prefix`. Unlike `prefix` this options cannot
    /// be set by command line arguments.
    forced_prefix: ?[]const u8 = null,
    prefix: []const u8,
    /// If set, this pkgs_uri will be used instead of `pkgs_uri`. Unlike `prefix` this options
    /// cannot be set by command line arguments.
    forced_pkgs_uri: ?[]const u8 = null,
    pkgs_uri: []const u8 = "https://github.com/Hejsil/dipm-pkgs/raw/master/pkgs.ini",
},

fn prefix(prog: Program) []const u8 {
    return prog.options.forced_prefix orelse prog.options.prefix;
}

fn pkgsUri(prog: Program) []const u8 {
    return prog.options.forced_pkgs_uri orelse prog.options.pkgs_uri;
}

const donate_usage =
    \\Usage: dipm donate [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn donateCommand(prog: *Program) !void {
    var packages_to_show_hm = std.StringArrayHashMap(void).init(prog.arena);
    try packages_to_show_hm.ensureTotalCapacity(prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdout.writeAll(install_usage);
        if (prog.args.positional()) |name|
            packages_to_show_hm.putAssumeCapacity(name, {});
    }

    var http_client = std.http.Client{ .allocator = prog.gpa };
    defer http_client.deinit();

    var packages = try Packages.download(.{
        .gpa = prog.gpa,
        .http_client = &http_client,
        .diagnostics = prog.diag,
        .progress = prog.progress,
        .prefix = prog.prefix(),
        .pkgs_uri = prog.pkgsUri(),
        .download = .only_if_required,
    });
    defer packages.deinit();

    const packages_to_show = packages_to_show_hm.keys();
    for (packages_to_show) |package_name| {
        const package = packages.packages.get(package_name) orelse {
            try prog.diag.notFound(.{ .name = try prog.diag.putStr(package_name) });
            continue;
        };
        for (package.info.donate) |donate| {
            try prog.diag.donate(.{
                .name = try prog.diag.putStr(package_name),
                .version = try prog.diag.putStr(package.info.version),
                .donate = try prog.diag.putStr(donate),
            });
        }
    }
    if (packages_to_show.len != 0)
        return;

    var installed_packages = try InstalledPackages.open(.{
        .gpa = prog.gpa,
        .prefix = prog.prefix(),
    });
    defer installed_packages.deinit();

    for (installed_packages.by_name.keys()) |package_name_index| {
        const package_name = package_name_index.get(installed_packages.strings);
        const package = packages.packages.get(package_name) orelse {
            try prog.diag.notFound(.{ .name = try prog.diag.putStr(package_name) });
            continue;
        };
        for (package.info.donate) |donate| {
            try prog.diag.donate(.{
                .name = try prog.diag.putStr(package_name),
                .version = try prog.diag.putStr(package.info.version),
                .donate = try prog.diag.putStr(donate),
            });
        }
    }
}

const install_usage =
    \\Usage: dipm install [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn installCommand(prog: *Program) !void {
    var packages_to_install = std.ArrayList([]const u8).init(prog.arena);
    try packages_to_install.ensureTotalCapacity(prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdout.writeAll(install_usage);
        if (prog.args.positional()) |name|
            packages_to_install.appendAssumeCapacity(name);
    }

    var pm = try PackageManager.init(.{
        .gpa = prog.gpa,
        .diag = prog.diag,
        .progress = prog.progress,
        .prefix = prog.prefix(),
        .pkgs_uri = prog.pkgsUri(),
        .download = .only_if_required,
    });
    defer pm.deinit();

    try pm.installMany(packages_to_install.items);
    try pm.cleanup();
}

const uninstall_usage =
    \\Usage: dipm uninstall [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn uninstallCommand(prog: *Program) !void {
    var packages_to_uninstall = std.ArrayList([]const u8).init(prog.arena);
    try packages_to_uninstall.ensureTotalCapacity(prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdout.writeAll(uninstall_usage);
        if (prog.args.positional()) |name|
            packages_to_uninstall.appendAssumeCapacity(name);
    }

    // Uninstall does not need to download packages
    var packages = Packages.init(prog.gpa);
    defer packages.deinit();

    var pm = try PackageManager.init(.{
        .gpa = prog.gpa,
        .diag = prog.diag,
        .progress = prog.progress,
        .prefix = prog.prefix(),
        .pkgs_uri = prog.pkgsUri(),
        .download = .only_if_required,
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
    \\  -f, --force         Force update of packages even if they're up to date
    \\  -h, --help          Display this message
    \\
;

fn updateCommand(prog: *Program) !void {
    var force_update = false;
    var packages_to_update = std.ArrayList([]const u8).init(prog.arena);
    try packages_to_update.ensureTotalCapacity(prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-f", "--force" }))
            force_update = true;
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdout.writeAll(update_usage);
        if (prog.args.positional()) |name|
            packages_to_update.appendAssumeCapacity(name);
    }

    var pm = try PackageManager.init(.{
        .gpa = prog.gpa,
        .diag = prog.diag,
        .progress = prog.progress,
        .prefix = prog.prefix(),
        .pkgs_uri = prog.pkgsUri(),
        .download = .always,
    });
    defer pm.deinit();

    if (packages_to_update.items.len == 0) {
        try pm.updateAll(.{ .force = force_update });
    } else {
        try pm.updateMany(packages_to_update.items, .{
            .force = force_update,
        });
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

fn listCommand(prog: *Program) !void {
    while (prog.args.next()) {
        if (prog.args.flag(&.{"all"}))
            return prog.listAllCommand();
        if (prog.args.flag(&.{"installed"}))
            return prog.listInstalledCommand();
        if (prog.args.flag(&.{ "-h", "--help", "help" }))
            return prog.stdout.writeAll(list_usage);
        if (prog.args.positional()) |_|
            break;
    }

    try prog.stderr.writeAll(list_usage);
    return error.InvalidArgument;
}

const list_installed_usage =
    \\Usage: dipm list installed [options]
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn listInstalledCommand(prog: *Program) !void {
    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdout.writeAll(list_installed_usage);
        if (prog.args.positional()) |_| {
            try prog.stderr.writeAll(list_installed_usage);
            return error.InvalidArgument;
        }
    }

    var installed = try InstalledPackages.open(.{
        .gpa = prog.gpa,
        .prefix = prog.prefix(),
    });
    defer installed.deinit();

    var stdout_buffered = std.io.bufferedWriter(prog.stdout.writer());
    const writer = stdout_buffered.writer();

    for (installed.by_name.keys(), installed.by_name.values()) |name, package|
        try writer.print("{s}\t{s}\n", .{
            name.get(installed.strings),
            package.version.get(installed.strings),
        });
    try stdout_buffered.flush();
}

const list_all_usage =
    \\Usage: dipm list all [options]
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn listAllCommand(prog: *Program) !void {
    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdout.writeAll(list_all_usage);
        if (prog.args.positional()) |_| {
            try prog.stderr.writeAll(list_all_usage);
            return error.InvalidArgument;
        }
    }

    var http_client = std.http.Client{ .allocator = prog.gpa };
    defer http_client.deinit();

    var pkgs = try Packages.download(.{
        .gpa = prog.gpa,
        .http_client = &http_client,
        .diagnostics = prog.diag,
        .progress = prog.progress,
        .prefix = prog.prefix(),
        .pkgs_uri = prog.pkgsUri(),
        .download = .only_if_required,
    });
    defer pkgs.deinit();

    var stdout_buffered = std.io.bufferedWriter(prog.stdout.writer());
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
    \\  outdated            Check if any packages are outdated from upstream
    \\  help                Display this message
    \\
;

fn pkgsCommand(prog: *Program) !void {
    if (builtin.is_test) {
        // `pkgs` subcommand is disabled in tests because there are no ways to avoid downloads
        // running these commands.
        try prog.stderr.writeAll(pkgs_usage);
        return error.InvalidArgument;
    }

    while (prog.args.next()) {
        if (prog.args.flag(&.{"update"}))
            return prog.pkgsUpdateCommand();
        if (prog.args.flag(&.{"add"}))
            return prog.pkgsAddCommand();
        if (prog.args.flag(&.{ "-h", "--help", "help" }))
            return prog.stdout.writeAll(pkgs_usage);
        if (prog.args.positional()) |_|
            break;
    }

    try prog.stderr.writeAll(pkgs_usage);
    return error.InvalidArgument;
}

const pkgs_update_usage =
    \\Usage: dipm pkgs update [options] [url]...
    \\
    \\Options:
    \\  -f, --pkgs-file           Path to pkgs.ini (default: ./pkgs.ini)
    \\  -c, --commit              Commit each package updated to pkgs.ini
    \\  -d, --update-description  Also update the description of the package
    \\  -h, --help                Display this message
    \\
;

fn pkgsUpdateCommand(prog: *Program) !void {
    var packages_to_update = std.StringArrayHashMap(void).init(prog.arena);
    var all: bool = false;
    var options = PackagesAddOptions{
        .update_description = false,
        .add_packages = undefined,
    };

    while (prog.args.next()) {
        if (prog.args.option(&.{ "-f", "--pkgs-file" })) |file|
            options.pkgs_ini_path = file;
        if (prog.args.option(&.{"--delay"})) |delay|
            options.delay = try prog.parseDuration(delay);
        if (prog.args.flag(&.{ "-a", "--all" }))
            all = true;
        if (prog.args.flag(&.{ "-c", "--commit" }))
            options.commit = true;
        if (prog.args.flag(&.{ "-d", "--update-description" }))
            options.update_description = true;
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdout.writeAll(pkgs_update_usage);
        if (prog.args.positional()) |url|
            try packages_to_update.put(url, {});
    }

    const cwd = std.fs.cwd();
    var packages = try Packages.parseFromPath(prog.gpa, cwd, options.pkgs_ini_path);
    defer packages.deinit();

    var add_packages = std.ArrayList(AddPackage).init(prog.arena);
    for (packages_to_update.keys()) |package_name| {
        const package = packages.packages.get(package_name) orelse {
            try prog.diag.notFound(.{ .name = try prog.diag.putStr(package_name) });
            continue;
        };

        try add_packages.append(.{
            .name = package_name,
            .version = package.update.version,
            .download = if (package.update.download.len == 0) null else package.update.download,
        });
    }
    if (all) for (packages.packages.keys(), packages.packages.values()) |package_name, package| {
        try add_packages.append(.{
            .name = package_name,
            .version = package.update.version,
            .download = if (package.update.download.len == 0) null else package.update.download,
        });
    };

    options.add_packages = add_packages.items;
    return prog.pkgsAdd(options);
}

const pkgs_add_usage =
    \\Usage: dipm pkgs add [options] [[name=]url]...
    \\
    \\Options:
    \\  -f, --pkgs-file     Path to pkgs.ini (default: ./pkgs.ini)
    \\  -c, --commit        Commit each package added to pkgs.ini
    \\  -h, --help          Display this message
    \\
;

fn pkgsAddCommand(prog: *Program) !void {
    var version: ?[]const u8 = null;
    var down: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var options = PackagesAddOptions{
        .update_description = true,
        .add_packages = undefined,
    };

    while (prog.args.next()) {
        if (prog.args.option(&.{ "-f", "--pkgs-file" })) |file|
            options.pkgs_ini_path = file;
        if (prog.args.option(&.{ "-n", "--name" })) |n|
            name = n;
        if (prog.args.option(&.{ "-d", "--download" })) |i|
            down = i;
        if (prog.args.flag(&.{ "-c", "--commit" }))
            options.commit = true;
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdout.writeAll(pkgs_add_usage);
        if (prog.args.positional()) |url|
            version = url;
    }

    options.add_packages = &.{.{
        .version = version orelse return,
        .download = down,
        .name = name,
    }};
    return prog.pkgsAdd(options);
}

const PackagesAddOptions = struct {
    pkgs_ini_path: []const u8 = "./pkgs.ini",
    commit: bool = false,
    update_description: bool,
    delay: u64 = 0,
    add_packages: []const AddPackage,
};

const AddPackage = struct {
    version: []const u8,
    download: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

fn pkgsAdd(prog: *Program, options: PackagesAddOptions) !void {
    var http_client = std.http.Client{ .allocator = prog.gpa };
    defer http_client.deinit();

    const cwd = std.fs.cwd();
    const pkgs_ini_base_name = std.fs.path.basename(options.pkgs_ini_path);

    var pkgs_ini_dir, const pkgs_ini_file = try fs.openDirAndFile(cwd, options.pkgs_ini_path, .{
        .file = .{ .mode = .read_write },
    });
    defer pkgs_ini_dir.close();
    defer pkgs_ini_file.close();

    var packages = try Packages.parseFile(prog.gpa, pkgs_ini_file);
    defer packages.deinit();

    const global_progress = switch (options.add_packages.len) {
        0, 1 => .none,
        else => prog.progress.start("progress", @intCast(options.add_packages.len)),
    };
    defer prog.progress.end(global_progress);

    for (options.add_packages, 0..) |add_package, i| {
        defer global_progress.advance(1);

        if (i != 0 and options.delay != 0)
            std.Thread.sleep(options.delay);

        const progress = prog.progress.start(add_package.name orelse add_package.version, 1);
        defer prog.progress.end(progress);

        const package = Package.fromUrl(.{
            .arena = packages.arena.allocator(),
            .tmp_gpa = prog.gpa,
            .http_client = &http_client,
            .name = add_package.name,
            .version_uri = add_package.version,
            .download_uri = add_package.download,
            .target = .{ .os = builtin.os.tag, .arch = builtin.target.cpu.arch },
        }) catch |err| {
            try prog.diag.genericError(.{
                .id = try prog.diag.putStr(add_package.version),
                .msg = try prog.diag.putStr("Failed to create package from url"),
                .err = err,
            });
            continue;
        };

        const old_package = try packages.update(package, .{
            .description = options.update_description,
        });

        if (options.commit) {
            packages.sort();
            try packages.writeToFileOverride(pkgs_ini_file);
            try pkgs_ini_file.sync();

            const msg = try git.createCommitMessage(prog.arena, package, old_package, .{
                .description = options.update_description,
            });
            try git.commitFile(prog.gpa, pkgs_ini_dir, pkgs_ini_base_name, msg);
        }
    }

    if (!options.commit) {
        packages.sort();
        try packages.writeToFileOverride(pkgs_ini_file);
    }
}

fn parseDuration(prog: *Program, str: []const u8) !u64 {
    _ = prog;

    const Suffix = struct {
        str: []const u8,
        mult: u64,
    };

    const suffixes = [_]Suffix{
        .{ .str = "s", .mult = std.time.ns_per_s },
        .{ .str = "m", .mult = std.time.ns_per_min },
        .{ .str = "h", .mult = std.time.ns_per_hour },
        .{ .str = "d", .mult = std.time.ns_per_day },
    };
    const trimmed, const mult = for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, str, suffix.str)) {
            break .{ str[0 .. str.len - suffix.str.len], suffix.mult };
        }
    } else .{ str, std.time.ns_per_s };

    return (try std.fmt.parseUnsigned(u8, trimmed, 10)) * mult;
}

test {
    _ = ArgParser;
    _ = Diagnostics;
    _ = InstalledPackages;
    _ = Package;
    _ = PackageManager;
    _ = Packages;
    _ = Progress;

    _ = download;
    _ = fs;
    _ = git;

    _ = @import("testing.zig");
}

const ArgParser = @import("ArgParser.zig");
const Diagnostics = @import("Diagnostics.zig");
const InstalledPackages = @import("InstalledPackages.zig");
const PackageManager = @import("PackageManager.zig");
const Packages = @import("Packages.zig");
const Package = @import("Package.zig");
const Progress = @import("Progress.zig");

const builtin = @import("builtin");
const download = @import("download.zig");
const fs = @import("fs.zig");
const git = @import("git.zig");
const std = @import("std");
