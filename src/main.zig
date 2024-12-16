pub fn main() !u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    const args = std.process.argsAlloc(gpa) catch @panic("OOM");
    defer std.process.argsFree(gpa, args);

    mainFull(.{ .gpa = gpa, .args = args[1..] }) catch |err| switch (err) {
        DiagnosticsError.DiagnosticFailure => return 1,
        else => |e| {
            if (builtin.mode == .Debug)
                return e;

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

    var program = Program{
        .gpa = options.gpa,
        .arena = arena,
        .progress = &progress,
        .diagnostics = &diag,
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
    if (program.stderr.supportsAnsiEscapeCodes()) {
        _ = std.Thread.spawn(.{}, renderThread, .{&program}) catch |err| blk: {
            std.log.warn("failed to spawn rendering thread: {}", .{err});
            break :blk null;
        };
    }

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

pub fn mainCommand(program: *Program) !void {
    while (program.args.next()) {
        if (program.args.option(&.{ "-p", "--prefix" })) |p|
            program.options.prefix = p;
        if (program.args.flag(&.{"donate"}))
            return program.donateCommand();
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
progress: *Progress,
diagnostics: *Diagnostics,

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

fn prefix(program: Program) []const u8 {
    return program.options.forced_prefix orelse program.options.prefix;
}

fn pkgsUri(program: Program) []const u8 {
    return program.options.forced_pkgs_uri orelse program.options.pkgs_uri;
}

const donate_usage =
    \\Usage: dipm donate [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn donateCommand(program: *Program) !void {
    var packages_to_show_hm = std.StringArrayHashMap(void).init(program.arena);
    try packages_to_show_hm.ensureTotalCapacity(program.args.args.len);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(install_usage);
        if (program.args.positional()) |name|
            packages_to_show_hm.putAssumeCapacity(name, {});
    }

    var http_client = std.http.Client{ .allocator = program.gpa };
    defer http_client.deinit();

    var installed_packages = try InstalledPackages.open(.{
        .gpa = program.gpa,
        .prefix = program.prefix(),
    });
    defer installed_packages.deinit();

    var packages = try Packages.download(.{
        .gpa = program.gpa,
        .http_client = &http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.prefix(),
        .pkgs_uri = program.pkgsUri(),
        .download = .only_if_required,
    });
    defer packages.deinit();

    var packages_to_show = packages_to_show_hm.keys();
    if (packages_to_show.len == 0)
        packages_to_show = installed_packages.packages.keys();

    for (packages_to_show) |package_name| {
        const package = packages.packages.get(package_name) orelse {
            try program.diagnostics.notFound(.{ .name = package_name });
            continue;
        };
        if (package.info.donate.len == 0)
            continue;

        try program.diagnostics.donate(.{
            .name = package_name,
            .version = package.info.version,
            .donate = package.info.donate,
        });
    }
}

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

    var http_client = std.http.Client{ .allocator = program.gpa };
    defer http_client.deinit();

    var installed_packages = try InstalledPackages.open(.{
        .gpa = program.gpa,
        .prefix = program.prefix(),
    });
    defer installed_packages.deinit();

    var packages = try Packages.download(.{
        .gpa = program.gpa,
        .http_client = &http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.prefix(),
        .pkgs_uri = program.pkgsUri(),
        .download = .only_if_required,
    });
    defer packages.deinit();

    var pm = try PackageManager.init(.{
        .gpa = program.gpa,
        .http_client = &http_client,
        .packages = &packages,
        .installed_packages = &installed_packages,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.prefix(),
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

fn uninstallCommand(program: *Program) !void {
    var packages_to_uninstall = std.ArrayList([]const u8).init(program.arena);
    try packages_to_uninstall.ensureTotalCapacity(program.args.args.len);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(uninstall_usage);
        if (program.args.positional()) |name|
            packages_to_uninstall.appendAssumeCapacity(name);
    }

    var installed_packages = try InstalledPackages.open(.{
        .gpa = program.gpa,
        .prefix = program.prefix(),
    });
    defer installed_packages.deinit();

    // Uninstall does not need to download packages
    var packages = Packages.init(program.gpa);
    defer packages.deinit();

    var pm = try PackageManager.init(.{
        .gpa = program.gpa,
        .packages = &packages,
        .installed_packages = &installed_packages,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.prefix(),
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

fn updateCommand(program: *Program) !void {
    var force_update = false;
    var packages_to_update = std.ArrayList([]const u8).init(program.arena);
    try packages_to_update.ensureTotalCapacity(program.args.args.len);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-f", "--force" }))
            force_update = true;
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(update_usage);
        if (program.args.positional()) |name|
            packages_to_update.appendAssumeCapacity(name);
    }

    var http_client = std.http.Client{ .allocator = program.gpa };
    defer http_client.deinit();

    var installed_packages = try InstalledPackages.open(.{
        .gpa = program.gpa,
        .prefix = program.prefix(),
    });
    defer installed_packages.deinit();

    var packages = try Packages.download(.{
        .gpa = program.gpa,
        .http_client = &http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.prefix(),
        .pkgs_uri = program.pkgsUri(),
        .download = .always,
    });
    defer packages.deinit();

    var pm = try PackageManager.init(.{
        .gpa = program.gpa,
        .http_client = &http_client,
        .packages = &packages,
        .installed_packages = &installed_packages,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.prefix(),
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

    var installed_packages = try InstalledPackages.open(.{
        .gpa = program.gpa,
        .prefix = program.prefix(),
    });
    defer installed_packages.deinit();

    var stdout_buffered = std.io.bufferedWriter(program.stdout.writer());
    const writer = stdout_buffered.writer();

    for (
        installed_packages.packages.keys(),
        installed_packages.packages.values(),
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

    var http_client = std.http.Client{ .allocator = program.gpa };
    defer http_client.deinit();

    var pkgs = try Packages.download(.{
        .gpa = program.gpa,
        .http_client = &http_client,
        .diagnostics = program.diagnostics,
        .progress = program.progress,
        .prefix = program.prefix(),
        .pkgs_uri = program.pkgsUri(),
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
    \\  outdated            Check if any packages are outdated from upstream
    \\  help                Display this message
    \\
;

fn pkgsCommand(program: *Program) !void {
    if (builtin.is_test) {
        // `pkgs` subcommand is disabled in tests because there are no ways to avoid downloads
        // running these commands.
        try program.stderr.writeAll(pkgs_usage);
        return error.InvalidArgument;
    }

    while (program.args.next()) {
        if (program.args.flag(&.{"update"}))
            return program.pkgsUpdateCommand();
        if (program.args.flag(&.{"add"}))
            return program.pkgsAddCommand();
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
    \\  -f, --pkgs-file           Path to pkgs.ini (default: ./pkgs.ini)
    \\  -c, --commit              Commit each package updated to pkgs.ini
    \\  -d, --update-description  Also update the description of the package
    \\  -h, --help                Display this message
    \\
;

fn pkgsUpdateCommand(program: *Program) !void {
    var packages_to_update = std.StringArrayHashMap(void).init(program.arena);
    var options = PackagesAddOptions{
        .commit = false,
        .update_description = false,
        .pkgs_ini_path = "./pkgs.ini",
        .urls = undefined,
    };

    while (program.args.next()) {
        if (program.args.option(&.{ "-f", "--pkgs-file" })) |file|
            options.pkgs_ini_path = file;
        if (program.args.flag(&.{ "-c", "--commit" }))
            options.commit = true;
        if (program.args.flag(&.{ "-d", "--update-description" }))
            options.update_description = true;
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
    \\Usage: dipm pkgs add [options] [[name=]url]...
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
        .update_description = true,
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
            try urls.append(UrlAndName.fromString(url));
    }

    options.urls = urls.items;
    return program.pkgsAdd(options);
}

const PackagesAddOptions = struct {
    pkgs_ini_path: []const u8,
    commit: bool,
    update_description: bool,
    urls: []const UrlAndName,
};

const UrlAndName = struct {
    url: []const u8,
    name: ?[]const u8 = null,

    pub fn fromString(string: []const u8) UrlAndName {
        for (string, 0..) |c, i| switch (c) {
            '=' => return .{
                .name = string[0..i],
                .url = string[i + 1 ..],
            },
            'a'...'z', 'A'...'Z', '-' => {},
            else => break,
        };

        return .{ .url = string };
    }
};

fn testUrlAndNameFromString(string: []const u8, expected: UrlAndName) !void {
    const url_and_name = UrlAndName.fromString(string);
    try std.testing.expectEqualStrings(expected.url, url_and_name.url);
    if (expected.name) |name| {
        try std.testing.expect(url_and_name.name != null);
        try std.testing.expectEqualStrings(name, url_and_name.name.?);
    } else {
        try std.testing.expect(url_and_name.name == null);
    }
}

test "UrlAndName.fromString" {
    try testUrlAndNameFromString("https://github.com/oxc-project/oxc", .{
        .url = "https://github.com/oxc-project/oxc",
    });
    try testUrlAndNameFromString("oxlint=https://github.com/oxc-project/oxc", .{
        .name = "oxlint",
        .url = "https://github.com/oxc-project/oxc",
    });
}

fn pkgsAdd(program: *Program, options: PackagesAddOptions) !void {
    var http_client = std.http.Client{ .allocator = program.gpa };
    defer http_client.deinit();

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
        const progress = program.progress.start(url.name orelse url.url, 1);
        defer program.progress.end(progress);

        const package = Package.fromUrl(.{
            .gpa = packages.arena.allocator(),
            .tmp_gpa = program.gpa,
            .http_client = &http_client,
            .url = url.url,
            .name = url.name,
            .target = .{ .os = builtin.os.tag, .arch = builtin.target.cpu.arch },
        }) catch |err| {
            std.log.err("{s} {s}", .{ @errorName(err), url.url });
            continue;
        };

        const old_package = try packages.update(package, .{
            .description = options.update_description,
        });

        if (options.commit) {
            packages.sort();
            try packages.writeToFileOverride(pkgs_ini_file);
            try pkgs_ini_file.sync();

            const msg = try git.createCommitMessage(program.arena, package, old_package);
            try git.commitFile(program.gpa, pkgs_ini_dir, pkgs_ini_base_name, msg);
        }
    }

    if (!options.commit) {
        packages.sort();
        try packages.writeToFileOverride(pkgs_ini_file);
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
