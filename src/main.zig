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

    // We don't really care to store the thread. Just let the os clean it up
    _ = std.Thread.spawn(.{}, renderThread, .{&progress}) catch |err| blk: {
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

    const res = program.mainCommand();

    // Stop `renderThread` from rendering by locking stderr for the rest of the programs execution.
    std.debug.lockStdErr();
    const stderr = std.io.getStdErr();
    try progress.cleanupTty(stderr);
    try diag.reportToFile(stderr);
    return res;
}

fn renderThread(progress: *Progress) void {
    const fps = 15;
    const delay = std.time.ns_per_s / fps;
    const initial_delay = std.time.ns_per_s / 4;

    const stderr = std.io.getStdErr();
    if (!stderr.supportsAnsiEscapeCodes())
        return;

    std.time.sleep(initial_delay);
    while (true) {
        std.debug.lockStdErr();
        progress.renderToTty(stderr) catch {};
        std.debug.unlockStdErr();
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
;

pub fn mainCommand(program: *Program) !void {
    while (!program.args.isDone()) {
        if (program.args.flag(&.{"install"})) {
            return program.installCommand();
        } else if (program.args.flag(&.{"uninstall"})) {
            return program.uninstallCommand();
        } else if (program.args.flag(&.{"update"})) {
            return program.updateCommand();
        } else if (program.args.flag(&.{"list"})) {
            return program.listCommand();
        } else if (program.args.flag(&.{"pkgs"})) {
            return program.pkgsCommand();
        } else if (program.args.flag(&.{ "-h", "--help", "help" })) {
            return std.io.getStdOut().writeAll(main_usage);
        } else if (program.args.option(&.{ "-p", "--prefix" })) |prefix| {
            program.options.prefix = prefix;
        } else {
            break;
        }
    }

    try std.io.getStdErr().writeAll(main_usage);
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

const install_usage =
    \\Usage: dipm install [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn installCommand(program: *Program) !void {
    var packages_to_install = std.StringArrayHashMap(void).init(program.allocator);
    defer packages_to_install.deinit();

    while (!program.args.isDone()) {
        if (program.args.flag(&.{ "-h", "--help" })) {
            return std.io.getStdOut().writeAll(install_usage);
        } else {
            try packages_to_install.put(program.args.eat(), {});
        }
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

const uninstall_usage =
    \\Usage: dipm uninstall [options] [pkg]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn uninstallCommand(program: *Program) !void {
    var packages_to_uninstall = std.StringArrayHashMap(void).init(program.allocator);
    defer packages_to_uninstall.deinit();

    while (!program.args.isDone()) {
        if (program.args.flag(&.{ "-h", "--help" })) {
            return std.io.getStdOut().writeAll(uninstall_usage);
        } else {
            try packages_to_uninstall.put(program.args.eat(), {});
        }
    }

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
    var packages_to_update = std.StringArrayHashMap(void).init(program.allocator);
    defer packages_to_update.deinit();

    while (!program.args.isDone()) {
        if (program.args.flag(&.{ "-h", "--help" })) {
            return std.io.getStdOut().writeAll(update_usage);
        } else {
            try packages_to_update.put(program.args.eat(), {});
        }
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
    while (!program.args.isDone()) {
        if (program.args.flag(&.{"all"})) {
            return program.listAllCommand();
        } else if (program.args.flag(&.{"installed"})) {
            return program.listInstalledCommand();
        } else if (program.args.flag(&.{ "-h", "--help", "help" })) {
            return std.io.getStdOut().writeAll(list_usage);
        } else {
            break;
        }
    }

    try std.io.getStdErr().writeAll(list_usage);
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
    while (!program.args.isDone()) {
        if (program.args.flag(&.{ "-h", "--help" })) {
            return std.io.getStdOut().writeAll(list_installed_usage);
        } else {
            try std.io.getStdErr().writeAll(list_installed_usage);
            return error.InvalidArgument;
        }
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

const list_all_usage =
    \\Usage: dipm list all [options]
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn listAllCommand(program: *Program) !void {
    while (!program.args.isDone()) {
        if (program.args.flag(&.{ "-h", "--help" })) {
            return std.io.getStdOut().writeAll(list_all_usage);
        } else {
            try std.io.getStdErr().writeAll(list_all_usage);
            return error.InvalidArgument;
        }
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

const pkgs_usage =
    \\Usage: dipm pkgs [options] [command]
    \\
    \\Commands:
    \\  add                 Make packages and add them to pkgs.ini
    \\  make                Make packages
    \\  check               Check packages for new versions
    \\  fmt                 Format pkgs file
    \\  help                Display this message
    \\
;

fn pkgsCommand(program: *Program) !void {
    while (!program.args.isDone()) {
        if (program.args.flag(&.{"add"})) {
            return program.pkgsAddCommand();
        } else if (program.args.flag(&.{"make"})) {
            return program.pkgsMakeCommand();
        } else if (program.args.flag(&.{"fmt"})) {
            return program.pkgsInifmtCommand();
        } else if (program.args.flag(&.{ "-h", "--help", "help" })) {
            return std.io.getStdOut().writeAll(pkgs_usage);
        } else {
            break;
        }
    }

    try std.io.getStdErr().writeAll(pkgs_usage);
    return error.InvalidArgument;
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
    var commit = false;
    var pkgs_ini_path: []const u8 = "./pkgs.ini";
    var urls = std.StringArrayHashMap(void).init(program.allocator);
    defer urls.deinit();

    while (!program.args.isDone()) {
        if (program.args.option(&.{ "-f", "--file" })) |file| {
            pkgs_ini_path = file;
        } else if (program.args.flag(&.{ "-c", "--commit" })) {
            commit = true;
        } else if (program.args.flag(&.{ "-h", "--help" })) {
            return std.io.getStdOut().writeAll(pkgs_add_usage);
        } else {
            try urls.put(program.args.eat(), {});
        }
    }

    const cwd = std.fs.cwd();
    const pkgs_ini_base_name = std.fs.path.basename(pkgs_ini_path);
    const pkgs_ini_dir_path = std.fs.path.dirname(pkgs_ini_path) orelse ".";
    var pkgs_ini_dir = try cwd.openDir(pkgs_ini_dir_path, .{});
    defer pkgs_ini_dir.close();

    const pkgs_ini_file = try cwd.createFile(pkgs_ini_path, .{
        .truncate = false,
        .read = true,
    });
    defer pkgs_ini_file.close();

    try pkgs_ini_file.seekFromEnd(0);

    var file_buffered = std.io.bufferedWriter(pkgs_ini_file.writer());
    const writer = file_buffered.writer();

    for (urls.keys()) |url| {
        const package = try program.makePkgFromUrl(url, writer);
        defer package.deinit(program.allocator);

        if (commit) {
            try file_buffered.flush();
            try pkgs_ini_file.sync();

            const msg = try std.fmt.allocPrint(program.allocator, "{s}: Add {s}", .{
                package.name,
                package.version,
            });
            defer program.allocator.free(msg);

            var child = std.process.Child.init(
                &.{ "git", "commit", "-i", pkgs_ini_base_name, "-m", msg },
                program.allocator,
            );
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            child.cwd_dir = pkgs_ini_dir;

            try child.spawn();
            _ = try child.wait();
        }
    }

    try file_buffered.flush();

    try pkgs_ini_file.seekTo(0);
    try inifmtFiles(program.allocator, pkgs_ini_file, pkgs_ini_file);
}

const pkgs_make_usage =
    \\Usage: dipm pkgs make [options] [url]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn pkgsMakeCommand(program: *Program) !void {
    var urls = std.StringArrayHashMap(void).init(program.allocator);
    defer urls.deinit();

    while (!program.args.isDone()) {
        if (program.args.flag(&.{ "-h", "--help" })) {
            return std.io.getStdOut().writeAll(pkgs_make_usage);
        } else {
            try urls.put(program.args.eat(), {});
        }
    }

    var stdout_buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = stdout_buffered.writer();

    for (urls.keys()) |url| {
        const package = try program.makePkgFromUrl(url, writer);
        defer package.deinit(program.allocator);
    }

    try stdout_buffered.flush();
}

const NameAndVersion = struct {
    name: []const u8,
    version: []const u8,

    pub fn deinit(nv: NameAndVersion, allocator: std.mem.Allocator) void {
        allocator.free(nv.name);
        allocator.free(nv.version);
    }
};

fn makePkgFromUrl(program: *Program, url: []const u8, writer: anytype) !NameAndVersion {
    const github_url = "https://github.com/";
    if (std.mem.startsWith(u8, url, github_url)) {
        const repo = url[github_url.len..];
        var repo_split = std.mem.splitScalar(u8, repo, '/');
        return program.makePkgFromGithubRepo(
            repo_split.first(),
            repo_split.next() orelse "",
            writer,
        );
    } else {
        return error.InvalidUrl;
    }
}

fn makePkgFromGithubRepo(
    program: *Program,
    user: []const u8,
    repo: []const u8,
    writer: anytype,
) !NameAndVersion {
    const latest_release_url = try std.fmt.allocPrint(
        program.allocator,
        "https://api.github.com/repos/{s}/{s}/releases/latest",
        .{ user, repo },
    );
    defer program.allocator.free(latest_release_url);

    var latest_release_json = std.ArrayList(u8).init(program.allocator);
    defer latest_release_json.deinit();

    const release_download_result = try download.download(
        program.http_client,
        latest_release_url,
        null,
        latest_release_json.writer(),
    );
    if (release_download_result.status != .ok)
        return error.DownloadFailed;

    const latest_release_value = try std.json.parseFromSlice(
        LatestRelease,
        program.allocator,
        latest_release_json.items,
        .{ .ignore_unknown_fields = true },
    );
    const latest_release = latest_release_value.value;
    defer latest_release_value.deinit();

    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    const download_url = try findDownloadUrl(
        program.allocator,
        latest_release,
        repo,
        os,
        arch,
    );

    var global_tmp_dir = try std.fs.cwd().makeOpenPath("/tmp/dipm/", .{});
    defer global_tmp_dir.close();

    var tmp_dir = try fs.tmpDir(global_tmp_dir, .{});
    defer tmp_dir.close();

    const downloaded_file_name = std.fs.path.basename(download_url);
    const downloaded_file = try tmp_dir.createFile(downloaded_file_name, .{ .read = true });
    defer downloaded_file.close();

    const package_download_result = try download.download(
        program.http_client,
        download_url,
        null,
        downloaded_file.writer(),
    );
    if (package_download_result.status != .ok)
        return error.DownloadFailed;

    try downloaded_file.seekTo(0);
    try fs.extract(.{
        .allocator = program.allocator,
        .input_name = downloaded_file_name,
        .input_file = downloaded_file,
        .output_dir = tmp_dir,
    });

    // TODO: Can this be ported to pure zig easily?
    const static_files_result = try std.process.Child.run(.{
        .allocator = program.allocator,
        .argv = &.{
            "sh", "-c",
            \\find -type f -exec file '{}' '+' |
            \\    grep -E 'statically linked|static-pie linked' |
            \\    cut -d: -f1 |
            \\    sed "s#^./#install_bin = #" |
            \\    sort
            \\
        },
        .cwd_dir = tmp_dir,
    });
    defer program.allocator.free(static_files_result.stdout);
    defer program.allocator.free(static_files_result.stderr);

    if (static_files_result.stdout.len < "install_bin".len)
        return error.NoStaticallyLinkedFiles;

    try writer.print("[{s}.info]\n", .{repo});
    try writer.print("version = {s}\n", .{latest_release.version()});
    try writer.print("\n", .{});
    try writer.print("[{s}.update]\n", .{repo});
    try writer.print("github = {s}/{s}\n", .{ user, repo });
    try writer.print("\n", .{});
    try writer.print("[{s}.{s}_{s}]\n", .{ repo, @tagName(os), @tagName(arch) });
    try writer.print("{s}", .{static_files_result.stdout});
    try writer.print("url = {s}\n", .{download_url});
    try writer.print("hash = {s}\n", .{&std.fmt.bytesToHex(package_download_result.hash, .lower)});
    try writer.print("\n", .{});

    const name = try program.allocator.dupe(u8, repo);
    errdefer program.allocator.free(name);

    const version = try program.allocator.dupe(u8, latest_release.version());
    errdefer program.allocator.free(version);

    return .{ .name = name, .version = version };
}

const LatestRelease = struct {
    tag_name: []const u8,
    assets: []const struct {
        browser_download_url: []const u8,
    },

    fn version(release: LatestRelease) []const u8 {
        return std.mem.trimLeft(u8, release.tag_name, "v");
    }
};

fn findDownloadUrl(
    allocator: std.mem.Allocator,
    release: LatestRelease,
    name: []const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
) ![]const u8 {
    // To find the download url, a trim list is constructed. It contains only things that are
    // expected to be in file name. Each url is the continuesly trimmed until either:
    // * `/` is reach. This means it is the download url
    // * Nothing was trimmed. The file name contains something unwanted

    var trim_list = std.ArrayList([]const u8).init(allocator);
    defer trim_list.deinit();

    try trim_list.append("_");
    try trim_list.append("-");
    try trim_list.append("unknown");
    try trim_list.append("musl");
    try trim_list.append("static");
    try trim_list.append(release.tag_name);
    try trim_list.append(release.version());
    try trim_list.append(name);
    try trim_list.append(@tagName(arch));
    try trim_list.append(@tagName(os));

    switch (arch) {
        .x86_64 => try trim_list.append("amd64"),
        else => {},
    }

    for (fs.FileType.extensions) |ext| {
        if (ext.ext.len == 0)
            continue;
        try trim_list.append(ext.ext);
    }

    std.sort.insertion([]const u8, trim_list.items, {}, struct {
        fn lenGt(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.lenGt);

    outer: for (release.assets) |asset| {
        var download_url = asset.browser_download_url;
        inner: while (!std.mem.endsWith(u8, download_url, "/")) {
            for (trim_list.items) |trim| {
                std.debug.assert(trim.len != 0);
                if (std.ascii.endsWithIgnoreCase(download_url, trim)) {
                    download_url.len -= trim.len;
                    continue :inner;
                }
            }

            continue :outer;
        }

        return asset.browser_download_url;
    }

    return error.DownloadUrlNotFound;
}

const pkgs_inifmt_usage =
    \\Usage: dipm pkgs fmt [options] [file]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn pkgsInifmtCommand(program: *Program) !void {
    var files_to_format = std.StringArrayHashMap(void).init(program.allocator);
    defer files_to_format.deinit();

    while (!program.args.isDone()) {
        if (program.args.flag(&.{ "-h", "--help" })) {
            return std.io.getStdOut().writeAll(pkgs_inifmt_usage);
        } else {
            try files_to_format.put(program.args.eat(), {});
        }
    }

    if (files_to_format.count() == 0)
        return inifmtFiles(program.allocator, std.io.getStdIn(), std.io.getStdOut());

    const cwd = std.fs.cwd();
    for (files_to_format.keys()) |file| {
        var out = try cwd.atomicFile(file, .{});
        defer out.deinit();
        {
            const in = try cwd.openFile(file, .{});
            defer in.close();
            try inifmtFiles(program.allocator, in, out.file);
        }
        try out.finish();
    }
}

fn inifmtFiles(allocator: std.mem.Allocator, file: std.fs.File, out: std.fs.File) !void {
    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    try out.seekTo(0);
    var buffered_writer = std.io.bufferedWriter(out.writer());
    try inifmtData(allocator, data, buffered_writer.writer());

    try buffered_writer.flush();
    try out.setEndPos(try out.getPos());
}

fn inifmtData(allocator: std.mem.Allocator, data: []const u8, writer: anytype) !void {
    // TODO: This does not preserve comments
    const i = try ini.Dynamic.parse(allocator, data, .{
        .allocate = ini.Dynamic.Allocate.none,
    });
    defer i.deinit();
    try i.write(writer);
}

test {
    _ = ArgParser;
    _ = Diagnostics;
    _ = PackageManager;
    _ = Packages;
    _ = Progress;

    _ = download;
    _ = fs;
    _ = ini;
}

const ArgParser = @import("ArgParser.zig");
const Diagnostics = @import("Diagnostics.zig");
const PackageManager = @import("PackageManager.zig");
const Packages = @import("Packages.zig");
const Progress = @import("Progress.zig");

const builtin = @import("builtin");
const download = @import("download.zig");
const fs = @import("fs.zig");
const ini = @import("ini.zig");
const std = @import("std");
