pub fn main(init: std.process.Init) !u8 {
    var io_lock = std.Thread.Mutex{};
    const progress = &Progress.global;

    var stdout_buf: [std.heap.page_size_min]u8 = undefined;
    var stderr_buf: [std.heap.page_size_min]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);

    // We don't really care to store the thread. Just let the os clean it up
    if (try stderr.file.supportsAnsiEscapeCodes(init.io)) blk: {
        const thread = std.Thread.spawn(.{}, renderThread, .{
            init.io,
            &stderr,
            progress,
            &io_lock,
        }) catch |err| {
            try stderr.interface.print("failed to spawn rendering thread: {}\n", .{err});
            break :blk;
        };
        thread.detach();
    }

    const res = mainFull(init, .{
        .io_lock = &io_lock,
        .stdout = &stdout,
        .stderr = &stderr,
        .progress = progress,
    });

    io_lock.lock();
    try progress.cleanupTty(init.io, &stderr);
    try stdout.end();
    try stderr.end();

    return if (res) |_| 0 else |err| switch (err) {
        Diagnostics.Error.DiagnosticsReported => 1,
        else => |e| e,
    };
}

fn renderThread(
    io: std.Io,
    stderr: *std.Io.File.Writer,
    progress: *Progress,
    io_lock: *std.Thread.Mutex,
) void {
    const fps = 15;
    const delay = std.Io.Duration.fromNanoseconds(std.time.ns_per_s / fps);
    const initial_delay = std.Io.Duration.fromNanoseconds(std.time.ns_per_s / 4);

    io.sleep(initial_delay, .awake) catch {};
    while (true) {
        io_lock.lock();
        progress.renderToTty(stderr) catch {};
        stderr.interface.flush() catch {};
        io_lock.unlock();
        io.sleep(delay, .awake) catch {};
    }
}

pub const MainOptions = struct {
    io_lock: *std.Thread.Mutex,
    stdout: *std.Io.File.Writer,
    stderr: *std.Io.File.Writer,

    forced_pkgs_uri: ?[]const u8 = null,
    progress: *Progress = &Progress.dummy,
};

pub fn mainFull(init: std.process.Init, options: MainOptions) !void {
    var diag = Diagnostics.init(init.gpa);
    defer diag.deinit();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var prog = Program{
        .init = init,
        .diag = &diag,
        .progress = options.progress,
        .io_lock = options.io_lock,
        .stdout = options.stdout,
        .stderr = options.stderr,

        .args = .initSlice(args[1..]),
        .options = .{
            .forced_pkgs_uri = options.forced_pkgs_uri,
        },
    };

    const res = prog.mainCommand();

    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    try prog.progress.cleanupTty(init.io, prog.stderr);
    try diag.reportToFile(prog.stderr);
    try prog.stderr.end();
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

init: std.process.Init,
diag: *Diagnostics,
progress: *Progress,

// Ensures that only one thread can write to stdout/stderr at a time
io_lock: *std.Thread.Mutex,
stdout: *std.Io.File.Writer,
stderr: *std.Io.File.Writer,

args: spaghet.Args,
options: struct {
    prefix: ?[]const u8 = null,
    /// If set, this pkgs_uri will be used instead of `pkgs_uri`. Unlike `prefix` this options
    /// cannot be set by command line arguments.
    forced_pkgs_uri: ?[]const u8 = null,
    pkgs_uri: []const u8 = "https://github.com/Hejsil/dipm-pkgs/raw/0.31.3/pkgs.ini",
},

fn prefix(prog: *Program) ![]const u8 {
    if (prog.options.prefix == null) {
        const arena = prog.init.arena.allocator();
        const home_path = prog.init.environ_map.get("HOME") orelse "/";
        prog.options.prefix = try std.fs.path.join(arena, &.{ home_path, ".local" });
    }

    return prog.options.prefix.?;
}

fn pkgsUri(prog: Program) []const u8 {
    return prog.options.forced_pkgs_uri orelse prog.options.pkgs_uri;
}

fn packageManager(prog: *Program, d: Packages.Download) !PackageManager {
    return PackageManager.init(.{
        .io = prog.init.io,
        .gpa = prog.init.gpa,
        .diag = prog.diag,
        .progress = prog.progress,
        .prefix = try prog.prefix(),
        .pkgs_uri = prog.pkgsUri(),
        .download = d,
    });
}

fn packages(prog: *Program) !Packages {
    return Packages.download(.{
        .io = prog.init.io,
        .gpa = prog.init.gpa,
        .diagnostics = prog.diag,
        .progress = prog.progress,
        .prefix = try prog.prefix(),
        .pkgs_uri = prog.pkgsUri(),
        .download = .only_if_required,
    });
}

fn stdoutWriteAllLocked(prog: Program, str: []const u8) !void {
    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    return prog.stdout.interface.writeAll(str);
}

fn stderrWriteAllLocked(prog: Program, str: []const u8) !void {
    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    return prog.stderr.interface.writeAll(str);
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
    var pkgs_to_show_hm = std.StringArrayHashMap(void).init(prog.init.arena.allocator());
    try pkgs_to_show_hm.ensureTotalCapacity(prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(install_usage);
        if (prog.args.positional()) |name|
            pkgs_to_show_hm.putAssumeCapacity(name, {});
    }

    var pkgs = try prog.packages();
    defer pkgs.deinit();

    const pkgs_to_show = pkgs_to_show_hm.keys();
    for (pkgs_to_show) |pkg_name| {
        const pkg = pkgs.by_name.get(pkg_name) orelse {
            try prog.diag.notFound(.{ .name = pkg_name });
            continue;
        };
        for (pkg.info.donate) |donate| {
            try prog.diag.donate(.{
                .name = pkg_name,
                .version = pkg.info.version,
                .donate = donate,
            });
        }
    }
    if (pkgs_to_show.len != 0)
        return;

    var installed_pkgs = try InstalledPackages.open(prog.init.io, prog.init.gpa, try prog.prefix());
    defer installed_pkgs.deinit(prog.init.io);

    for (installed_pkgs.by_name.keys()) |pkg_name| {
        const pkg = pkgs.by_name.get(pkg_name) orelse {
            try prog.diag.notFound(.{ .name = pkg_name });
            continue;
        };
        for (pkg.info.donate) |donate| {
            try prog.diag.donate(.{
                .name = pkg_name,
                .version = pkg.info.version,
                .donate = donate,
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
    var pkgs_to_install = std.ArrayList([]const u8){};
    try pkgs_to_install.ensureTotalCapacity(prog.init.arena.allocator(), prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(install_usage);
        if (prog.args.positional()) |name|
            pkgs_to_install.appendAssumeCapacity(name);
    }

    var pm = try prog.packageManager(.only_if_required);
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
    var pkgs_to_uninstall = std.ArrayList([]const u8){};
    try pkgs_to_uninstall.ensureTotalCapacity(prog.init.arena.allocator(), prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(uninstall_usage);
        if (prog.args.positional()) |name|
            pkgs_to_uninstall.appendAssumeCapacity(name);
    }

    var pm = try prog.packageManager(.only_if_required);
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
    var pkgs_to_update = std.ArrayList([]const u8){};
    try pkgs_to_update.ensureTotalCapacity(prog.init.arena.allocator(), prog.args.args.len);

    while (prog.args.next()) {
        if (prog.args.flag(&.{ "-f", "--force" }))
            force_update = true;
        if (prog.args.flag(&.{ "-h", "--help" }))
            return prog.stdoutWriteAllLocked(update_usage);
        if (prog.args.positional()) |name|
            pkgs_to_update.appendAssumeCapacity(name);
    }

    var pm = try prog.packageManager(.always);
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

    var installed = try InstalledPackages.open(prog.init.io, prog.init.gpa, try prog.prefix());
    defer installed.deinit(prog.init.io);

    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    for (installed.by_name.keys(), installed.by_name.values()) |name, pkg|
        try prog.stdout.interface.print("{s}\t{s}\n", .{ name, pkg.version });
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

    var pkgs = try prog.packages();
    defer pkgs.deinit();

    prog.io_lock.lock();
    defer prog.io_lock.unlock();

    for (pkgs.by_name.keys(), pkgs.by_name.values()) |pkg_name, pkg|
        try prog.stdout.interface.print("{s}\t{s}\n", .{ pkg_name, pkg.info.version });
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
    var pkgs_to_update = std.StringArrayHashMap(void).init(prog.init.arena.allocator());
    var delay = std.Io.Duration.fromSeconds(0);
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

    const cwd = std.Io.Dir.cwd();
    var pkgs = try Packages.parseFromPath(prog.init.gpa, prog.init.io, cwd, options.pkgs_ini_path);
    defer pkgs.deinit();

    const update_all = pkgs_to_update.count() == 0;
    const num = if (update_all) pkgs.by_name.count() else pkgs_to_update.count();
    const progress = switch (num) {
        0, 1 => .none,
        else => prog.progress.start("progress", @intCast(num)),
    };
    defer prog.progress.end(progress);

    for (0..num) |i| {
        defer progress.advance(1);
        if (i != 0 and delay.nanoseconds != 0)
            try prog.init.io.sleep(delay, .awake);

        const pkg_name = if (update_all) pkgs.by_name.keys()[i] else pkgs_to_update.keys()[i];
        const pkg = pkgs.by_name.get(pkg_name) orelse {
            try prog.diag.notFound(.{ .name = pkg_name });
            continue;
        };

        try prog.pkgsAdd(.{
            .name = pkg_name,
            .version = pkg.update.version,
            .download = if (pkg.update.download.len != 0) pkg.update.download else null,
        }, options);
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
    prog.pkgsAddInner(add_pkg, options) catch |err| {
        try prog.diag.genericError(.{
            .id = add_pkg.version,
            .msg = "Failed to create pkg from url",
            .err = err,
        });
    };
}

fn pkgsAddInner(prog: *Program, add_pkg: AddPackage, options: PackagesAddOptions) !void {
    const io = prog.init.io;
    var http_client = std.http.Client{
        .io = prog.init.io,
        .allocator = prog.init.gpa,
    };
    defer http_client.deinit();

    const cwd = std.Io.Dir.cwd();
    const pkgs_ini_base_name = std.fs.path.basename(options.pkgs_ini_path);

    var pkgs_ini_dir, const pkgs_ini_file = try fs.openDirAndFile(io, cwd, options.pkgs_ini_path, .{
        .file = .{ .mode = .read_write },
    });
    defer pkgs_ini_dir.close(io);
    defer pkgs_ini_file.close(io);

    var pkgs = try Packages.parseFile(prog.init.io, prog.init.gpa, pkgs_ini_file);
    defer pkgs.deinit();

    const progress = prog.progress.start(add_pkg.name orelse add_pkg.version, 1);
    defer prog.progress.end(progress);

    const pkg = try Package.fromUrl(.{
        .io = prog.init.io,
        .gpa = prog.init.gpa,
        .arena = pkgs.arena(),
        .http_client = &http_client,
        .name = add_pkg.name,
        .version_uri = add_pkg.version,
        .download_uri = add_pkg.download,
        .target = .{ .os = builtin.os.tag, .arch = builtin.target.cpu.arch },
    });
    const old_pkg = try pkgs.update(prog.init.gpa, pkg, .{
        .description = options.update_description,
    });

    pkgs.sort();
    try pkgs.writeToFile(io, pkgs_ini_file);
    try pkgs_ini_file.sync(io);
    if (options.commit) {
        const msg = try git.createCommitMessage(prog.init.arena.allocator(), pkg, old_pkg, .{
            .description = options.update_description,
        });
        try git.commitFile(prog.init.io, pkgs_ini_dir, pkgs_ini_base_name, msg);
    }
}

test {
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
const spaghet = @import("spaghet");
const std = @import("std");
