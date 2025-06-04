pub fn main() !u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    const args = std.process.argsAlloc(gpa) catch @panic("OOM");
    defer std.process.argsFree(gpa, args);

    const progress = &Progress.global;
    const stderr = std.io.getStdErr();
    var io_lock = std.Thread.Mutex{};

    // We don't really care to store the thread. Just let the os clean it up
    if (stderr.supportsAnsiEscapeCodes()) blk: {
        const thread = std.Thread.spawn(.{}, renderThread, .{
            stderr,
            progress,
            &io_lock,
        }) catch |err| {
            std.log.warn("failed to spawn rendering thread: {}", .{err});
            break :blk;
        };
        thread.detach();
    }

    defer {
        io_lock.lock();
        progress.cleanupTty(stderr) catch {};
    }

    mainFull(.{
        .gpa = gpa,
        .args = args[1..],
        .io_lock = &io_lock,
        .stderr = stderr,
        .stdout = std.io.getStdOut(),
        .progress = progress,
    }) catch |err| switch (err) {
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

fn renderThread(stderr: std.fs.File, progress: *Progress, io_lock: *std.Thread.Mutex) void {
    const fps = 15;
    const delay = std.time.ns_per_s / fps;
    const initial_delay = std.time.ns_per_s / 4;

    std.time.sleep(initial_delay);
    while (true) {
        io_lock.lock();
        progress.renderToTty(stderr) catch {};
        io_lock.unlock();
        std.time.sleep(delay);
    }
}

pub const MainOptions = struct {
    gpa: std.mem.Allocator,
    args: []const []const u8,

    io_lock: *std.Thread.Mutex,
    stdout: std.fs.File,
    stderr: std.fs.File,

    forced_prefix: ?[]const u8 = null,
    forced_pkgs_uri: ?[]const u8 = null,
    progress: *Progress = &Progress.dummy,
};

pub fn mainFull(options: MainOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(options.gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const home_path = std.process.getEnvVarOwned(arena, "HOME") catch "/";
    const local_home_path = try std.fs.path.join(arena, &.{ home_path, ".local" });

    var diag = Diagnostics.init(options.gpa);
    defer diag.deinit();

    var prog = Program{
        .gpa = options.gpa,
        .arena = arena,
        .diag = &diag,
        .progress = options.progress,
        .io_lock = options.io_lock,
        .stdout = options.stdout,
        .stderr = options.stderr,

        .args = .{ .args = options.args },
        .options = .{
            .forced_prefix = options.forced_prefix,
            .prefix = local_home_path,
            .forced_pkgs_uri = options.forced_pkgs_uri,
        },
    };

    const res = prog.mainCommand();

    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    try diag.reportToFile(prog.stderr);
    if (diag.hasFailed())
        return Diagnostics.Error.DiagnosticsReported;

    return res;
}

const main_usage =
    \\A package manager for installing self contained linux programs
    \\
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
    \\  pkgs                Manipulate pkgs.ini
    \\  help                Display this message
    \\
    \\Options:
    \\  -h, --help
    \\          Display this message
    \\
    \\  -p, --prefix <path>
    \\          Set the prefix dipm will work and install things in.
    \\          The following folders will be created in the prefix:
    \\            {prefix}/bin/
    \\            {prefix}/lib/
    \\            {prefix}/share/dipm/
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
            return prog.stdoutWriteAllLocked(main_usage);
        if (prog.args.positional()) |_|
            break;
    }

    try prog.stderrWriteAllLocked(main_usage);
    return error.InvalidArgument;
}

const Program = @This();

gpa: std.mem.Allocator,
arena: std.mem.Allocator,
diag: *Diagnostics,
progress: *Progress,

// Ensures that only one thread can write to stdout/stderr at a time
io_lock: *std.Thread.Mutex,
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

fn stdoutWriteAllLocked(prog: Program, str: []const u8) !void {
    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    return prog.stdout.writeAll(str);
}

fn stderrWriteAllLocked(prog: Program, str: []const u8) !void {
    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    return prog.stderr.writeAll(str);
}

const donate_usage =
    \\Show donate links for packages
    \\
    \\Usage: dipm donate [options] [pkg]...
    \\       dipm donate [options]
    \\
    \\Options:
    \\  -h, --help
    \\          Display this message
    \\
;

fn donateCommand(prog: *Program) !void {
    var pkgs_to_show_hm = std.StringArrayHashMap(void).init(prog.arena);
    try pkgs_to_show_hm.ensureTotalCapacity(prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(install_usage);
        if (prog.args.positional()) |name|
            pkgs_to_show_hm.putAssumeCapacity(name, {});
    }

    var http_client = std.http.Client{ .allocator = prog.gpa };
    defer http_client.deinit();

    var pkgs = try Packages.download(.{
        .gpa = prog.gpa,
        .http_client = &http_client,
        .diagnostics = prog.diag,
        .prefix = prog.prefix(),
        .pkgs_uri = prog.pkgsUri(),
        .download = .only_if_required,
    });
    defer pkgs.deinit(prog.gpa);

    const pkgs_to_show = pkgs_to_show_hm.keys();
    for (pkgs_to_show) |pkg_name| {
        const pkg = pkgs.by_name.getAdapted(pkg_name, pkgs.strs.adapter()) orelse {
            try prog.diag.notFound(.{ .name = try prog.diag.putStr(pkg_name) });
            continue;
        };
        for (pkg.info.donate.get(pkgs.strs)) |donate| {
            try prog.diag.donate(.{
                .name = try prog.diag.putStr(pkg_name),
                .version = try prog.diag.putStr(pkg.info.version.get(pkgs.strs)),
                .donate = try prog.diag.putStr(donate.get(pkgs.strs)),
            });
        }
    }
    if (pkgs_to_show.len != 0)
        return;

    var installed_pkgs = try InstalledPackages.open(prog.gpa, prog.prefix());
    defer installed_pkgs.deinit(prog.gpa);

    for (installed_pkgs.by_name.keys()) |pkg_name_index| {
        const pkg_name = pkg_name_index.get(installed_pkgs.strs);
        const pkg = pkgs.by_name.getAdapted(pkg_name, pkgs.strs.adapter()) orelse {
            try prog.diag.notFound(.{ .name = try prog.diag.putStr(pkg_name) });
            continue;
        };
        for (pkg.info.donate.get(pkgs.strs)) |donate| {
            try prog.diag.donate(.{
                .name = try prog.diag.putStr(pkg_name),
                .version = try prog.diag.putStr(pkg.info.version.get(pkgs.strs)),
                .donate = try prog.diag.putStr(donate.get(pkgs.strs)),
            });
        }
    }
}

const install_usage =
    \\Install packages
    \\
    \\Usage: dipm install [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help
    \\          Display this message
    \\
;

fn installCommand(prog: *Program) !void {
    var pkgs_to_install = std.ArrayList([]const u8).init(prog.arena);
    try pkgs_to_install.ensureTotalCapacity(prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(install_usage);
        if (prog.args.positional()) |name|
            pkgs_to_install.appendAssumeCapacity(name);
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

    try pm.installMany(pkgs_to_install.items);
    try pm.cleanup();
}

const uninstall_usage =
    \\Uninstall packages
    \\
    \\Usage: dipm uninstall [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help
    \\          Display this message
    \\
;

fn uninstallCommand(prog: *Program) !void {
    var pkgs_to_uninstall = std.ArrayList([]const u8).init(prog.arena);
    try pkgs_to_uninstall.ensureTotalCapacity(prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(uninstall_usage);
        if (prog.args.positional()) |name|
            pkgs_to_uninstall.appendAssumeCapacity(name);
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

    try pm.uninstallMany(pkgs_to_uninstall.items);
    try pm.cleanup();
}

const update_usage =
    \\Update packages
    \\
    \\Usage: dipm update [options] [pkg]...
    \\       dipm update [options]
    \\
    \\Options:
    \\  -f, --force
    \\          Force update of pkgs even if they're up to date
    \\
    \\  -h, --help
    \\          Display this message
    \\
;

fn updateCommand(prog: *Program) !void {
    var force_update = false;
    var pkgs_to_update = std.ArrayList([]const u8).init(prog.arena);
    try pkgs_to_update.ensureTotalCapacity(prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-f", "--force" }))
            force_update = true;
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(update_usage);
        if (prog.args.positional()) |name|
            pkgs_to_update.appendAssumeCapacity(name);
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

    if (pkgs_to_update.items.len == 0) {
        try pm.updateAll(.{ .force = force_update });
    } else {
        try pm.updateMany(pkgs_to_update.items, .{
            .force = force_update,
        });
    }

    try pm.cleanup();
}

const list_usage =
    \\List packages
    \\
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
            return prog.stdoutWriteAllLocked(list_usage);
        if (prog.args.positional()) |_|
            break;
    }

    try prog.stderrWriteAllLocked(list_usage);
    return error.InvalidArgument;
}

const list_installed_usage =
    \\List installed packages
    \\
    \\Usage: dipm list installed [options]
    \\
    \\Options:
    \\  -h, --help
    \\          Display this message
    \\
;

fn listInstalledCommand(prog: *Program) !void {
    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(list_installed_usage);
        if (prog.args.positional()) |_| {
            try prog.stderrWriteAllLocked(list_installed_usage);
            return error.InvalidArgument;
        }
    }

    var installed = try InstalledPackages.open(prog.gpa, prog.prefix());
    defer installed.deinit(prog.gpa);

    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    var stdout_buffered = std.io.bufferedWriter(prog.stdout.writer());
    const writer = stdout_buffered.writer();

    for (installed.by_name.keys(), installed.by_name.values()) |name, pkg|
        try writer.print("{s}\t{s}\n", .{
            name.get(installed.strs),
            pkg.version.get(installed.strs),
        });
    try stdout_buffered.flush();
}

const list_all_usage =
    \\List all packages
    \\
    \\Usage: dipm list all [options]
    \\
    \\Options:
    \\  -h, --help
    \\          Display this message
    \\
;

fn listAllCommand(prog: *Program) !void {
    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(list_all_usage);
        if (prog.args.positional()) |_| {
            try prog.stderrWriteAllLocked(list_all_usage);
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
    defer pkgs.deinit(prog.gpa);

    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    var stdout_buffered = std.io.bufferedWriter(prog.stdout.writer());
    const writer = stdout_buffered.writer();

    for (pkgs.by_name.keys(), pkgs.by_name.values()) |pkg_name, pkg| {
        try writer.print("{s}\t{s}\n", .{
            pkg_name.get(pkgs.strs),
            pkg.info.version.get(pkgs.strs),
        });
    }

    try stdout_buffered.flush();
}

const pkgs_usage =
    \\Manipulate pkgs.ini
    \\
    \\Usage: dipm pkgs [options] [command]
    \\
    \\Commands:
    \\  update [pkg]...     Update packages in pkgs.ini
    \\  update              Update all packages in pkgs.ini
    \\  add                 Add new package to pkgs.ini
    \\  help                Display this message
    \\
    \\Options:
    \\  -h, --help
    \\          Display this message
    \\
;

fn pkgsCommand(prog: *Program) !void {
    if (builtin.is_test) {
        // `pkgs` subcommand is disabled in tests because there are no ways to avoid downloads
        // running these commands.
        try prog.stderrWriteAllLocked(pkgs_usage);
        return error.InvalidArgument;
    }

    while (prog.args.next()) {
        if (prog.args.flag(&.{"update"}))
            return prog.pkgsUpdateCommand();
        if (prog.args.flag(&.{"add"}))
            return prog.pkgsAddCommand();
        if (prog.args.flag(&.{ "-h", "--help", "help" }))
            return prog.stdoutWriteAllLocked(pkgs_usage);
        if (prog.args.positional()) |_|
            break;
    }

    try prog.stderrWriteAllLocked(pkgs_usage);
    return error.InvalidArgument;
}

const pkgs_update_usage =
    \\Update packages in pkgs.ini
    \\
    \\Usage: dipm pkgs update [options] [pkg]...
    \\       dipm pkgs update [options]
    \\
    \\Options:
    \\  -c, --commit
    \\          Commit each pkg updated to pkgs.ini
    \\
    \\  -d, --update-description
    \\          Also update the description of the pkg
    \\
    \\      --delay <duration>
    \\          Sleep for the specified delay between updates
    \\
    \\  -f, --pkgs-file <path>
    \\          Path to pkgs.ini (default: ./pkgs.ini)
    \\
    \\  -h, --help
    \\          Display this message
    \\
;

fn pkgsUpdateCommand(prog: *Program) !void {
    var pkgs_to_update = std.StringArrayHashMap(void).init(prog.arena);
    var delay: u64 = 0;
    var options = PackagesAddOptions{
        .update_description = false,
    };

    while (prog.args.next()) {
        if (prog.args.option(&.{ "-f", "--pkgs-file" })) |file|
            options.pkgs_ini_path = file;
        if (prog.args.option(&.{"--delay"})) |d|
            delay = try fmt.parseDuration(d);
        if (prog.args.flag(&.{ "-c", "--commit" }))
            options.commit = true;
        if (prog.args.flag(&.{ "-d", "--update-description" }))
            options.update_description = true;
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(pkgs_update_usage);
        if (prog.args.positional()) |url|
            try pkgs_to_update.put(url, {});
    }

    const cwd = std.fs.cwd();
    var pkgs = try Packages.parseFromPath(prog.gpa, cwd, options.pkgs_ini_path);
    defer pkgs.deinit(prog.gpa);

    const update_all = pkgs_to_update.count() == 0;
    const num = if (update_all) pkgs.by_name.count() else pkgs_to_update.count();
    const progress = switch (num) {
        0, 1 => .none,
        else => prog.progress.start("progress", @intCast(num)),
    };
    defer prog.progress.end(progress);

    if (update_all) {
        for (pkgs.by_name.keys(), pkgs.by_name.values(), 0..) |pkg_name, pkg, i| {
            defer progress.advance(1);
            if (i != 0 and delay != 0)
                std.Thread.sleep(delay);

            try prog.pkgsAdd(.{
                .name = pkg_name.get(pkgs.strs),
                .version = pkg.update.version.get(pkgs.strs) orelse "",
                .download = pkg.update.download.get(pkgs.strs),
            }, options);
        }
    } else {
        for (pkgs_to_update.keys(), 0..) |pkg_name, i| {
            defer progress.advance(1);
            if (i != 0 and delay != 0)
                std.Thread.sleep(delay);

            const pkg = pkgs.by_name.getAdapted(pkg_name, pkgs.strs.adapter()) orelse {
                try prog.diag.notFound(.{ .name = try prog.diag.putStr(pkg_name) });
                continue;
            };

            try prog.pkgsAdd(.{
                .name = pkg_name,
                .version = pkg.update.version.get(pkgs.strs) orelse "",
                .download = pkg.update.download.get(pkgs.strs),
            }, options);
        }
    }
}

const pkgs_add_usage =
    \\Manipulate pkgs.ini
    \\
    \\Usage: dipm pkgs add [options] [url]
    \\
    \\Options:
    \\  -c, --commit
    \\          Commit pkgs.ini after adding the package
    \\
    \\  -d, --download <url>
    \\          Link to where the download url for the package can be located
    \\
    \\  -f, --pkgs-file <path>
    \\          Path to pkgs.ini (default: ./pkgs.ini)
    \\
    \\  -h, --help
    \\          Display this message
    \\
    \\  -n, --name <name>
    \\          The name of the package
    \\
;

fn pkgsAddCommand(prog: *Program) !void {
    var version: ?[]const u8 = null;
    var down: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var options = PackagesAddOptions{
        .update_description = true,
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
            return prog.stdoutWriteAllLocked(pkgs_add_usage);
        if (prog.args.positional()) |url|
            version = url;
    }

    return prog.pkgsAdd(.{
        .version = version orelse return,
        .download = down,
        .name = name,
    }, options);
}

const PackagesAddOptions = struct {
    pkgs_ini_path: []const u8 = "./pkgs.ini",
    commit: bool = false,
    update_description: bool,
};

const AddPackage = struct {
    version: []const u8,
    download: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

fn pkgsAdd(prog: *Program, add_pkg: AddPackage, options: PackagesAddOptions) !void {
    var http_client = std.http.Client{ .allocator = prog.gpa };
    defer http_client.deinit();

    const cwd = std.fs.cwd();
    const pkgs_ini_base_name = std.fs.path.basename(options.pkgs_ini_path);

    var pkgs_ini_dir, const pkgs_ini_file = try fs.openDirAndFile(cwd, options.pkgs_ini_path, .{
        .file = .{ .mode = .read_write },
    });
    defer pkgs_ini_dir.close();
    defer pkgs_ini_file.close();

    var pkgs = try Packages.parseFile(prog.gpa, pkgs_ini_file);
    defer pkgs.deinit(prog.gpa);

    const progress = prog.progress.start(add_pkg.name orelse add_pkg.version, 1);
    defer prog.progress.end(progress);

    const pkg = Package.fromUrl(.{
        .gpa = prog.gpa,
        .strs = &pkgs.strs,
        .http_client = &http_client,
        .name = add_pkg.name,
        .version_uri = add_pkg.version,
        .download_uri = add_pkg.download,
        .target = .{ .os = builtin.os.tag, .arch = builtin.target.cpu.arch },
    }) catch |err| {
        try prog.diag.genericError(.{
            .id = try prog.diag.putStr(add_pkg.version),
            .msg = try prog.diag.putStr("Failed to create pkg from url"),
            .err = err,
        });
        return;
    };

    const old_pkg = try pkgs.update(prog.gpa, pkg, .{
        .description = options.update_description,
    });

    pkgs.sort();
    try pkgs.writeToFileOverride(pkgs_ini_file);
    try pkgs_ini_file.sync();
    if (options.commit) {
        const msg = try git.createCommitMessage(prog.arena, &pkgs, pkg, old_pkg, .{
            .description = options.update_description,
        });
        try git.commitFile(prog.gpa, pkgs_ini_dir, pkgs_ini_base_name, msg);
    }
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
    _ = fmt;
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
const fmt = @import("fmt.zig");
const fs = @import("fs.zig");
const git = @import("git.zig");
const std = @import("std");
