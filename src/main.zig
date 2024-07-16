pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    return mainFull(.{
        .allocator = gpa,
        .args = args[1..],
    });
}

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

    // Don't render progress bar in tests
    // TODO: This should be behind a flag
    if (!builtin.is_test) {
        // We don't really care to store the thread. Just let the os clean it up
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
    var packages_to_install = std.StringArrayHashMap(void).init(program.arena);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(install_usage);
        if (program.args.positional()) |name|
            try packages_to_install.put(name, {});
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
    var packages_to_uninstall = std.StringArrayHashMap(void).init(program.arena);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(uninstall_usage);
        if (program.args.positional()) |name|
            try packages_to_uninstall.put(name, {});
    }

    var pm = try PackageManager.init(.{
        .allocator = program.gpa,
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
    var packages_to_update = std.StringArrayHashMap(void).init(program.arena);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(update_usage);
        if (program.args.positional()) |name|
            try packages_to_update.put(name, {});
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
    \\  fmt                 Format pkgs file
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
        if (program.args.flag(&.{"fmt"}))
            return program.pkgsInifmtCommand();
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
    const pkgs_ini_file = try cwd.openFile(options.pkgs_ini_path, .{});
    defer pkgs_ini_file.close();

    const pkgs_ini_data = try pkgs_ini_file.readToEndAlloc(
        program.arena,
        std.math.maxInt(usize),
    );

    var packages = try Packages.parse(program.gpa, pkgs_ini_data);
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
    const pkgs_ini_dir_path = std.fs.path.dirname(options.pkgs_ini_path) orelse ".";

    var pkgs_ini_dir = try cwd.openDir(pkgs_ini_dir_path, .{});
    defer pkgs_ini_dir.close();

    const pkgs_ini_file = try pkgs_ini_dir.openFile(pkgs_ini_base_name, .{
        .mode = .read_write,
    });
    defer pkgs_ini_file.close();

    const pkgs_ini_data = try pkgs_ini_file.readToEndAlloc(
        program.arena,
        std.math.maxInt(usize),
    );

    var packages = try Packages.parse(program.gpa, pkgs_ini_data);
    defer packages.deinit();

    for (options.urls) |url| {
        const name, const package = program.makePkgFromUrl(url) catch |err| {
            std.log.err("{s} {s}", .{ @errorName(err), url.url });
            continue;
        };

        try packages.packages.put(packages.arena.allocator(), name, package);

        if (options.commit) {
            try packages.writeToFileOverride(pkgs_ini_file);
            try pkgs_ini_file.sync();

            const msg = try std.fmt.allocPrint(program.arena, "{s}: {s} {s}", .{
                name,
                options.commit_prefix,
                package.info.version,
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
        const name, const package = try program.makePkgFromUrl(.{
            .url = url,
            .name = null,
        });
        try package.write(name, writer);
    }

    try stdout_buffered.flush();
}

const NameAndVersion = struct {
    name: []const u8,
    version: []const u8,
};

fn makePkgFromUrl(
    program: *Program,
    url: UrlAndName,
) !struct { []const u8, Package } {
    const github_url = "https://github.com/";
    if (std.mem.startsWith(u8, url.url, github_url)) {
        const repo = url.url[github_url.len..];
        var repo_split = std.mem.splitScalar(u8, repo, '/');

        const repo_user = repo_split.first();
        const repo_name = repo_split.next() orelse "";
        return program.makePkgFromGithubRepo(.{
            .name = url.name orelse repo_name,
            .user = repo_user,
            .repo = repo_name,
        });
    } else {
        return error.InvalidUrl;
    }
}

const GithubRepo = struct {
    name: []const u8,
    user: []const u8,
    repo: []const u8,
};

fn makePkgFromGithubRepo(
    program: *Program,
    repo: GithubRepo,
) !struct { []const u8, Package } {
    var latest_release_json = std.ArrayList(u8).init(program.arena);
    const latest_release_url = try std.fmt.allocPrint(
        program.arena,
        "https://api.github.com/repos/{s}/{s}/releases/latest",
        .{ repo.user, repo.repo },
    );

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
        program.gpa,
        latest_release_json.items,
        .{ .ignore_unknown_fields = true },
    );
    const latest_release = latest_release_value.value;
    defer latest_release_value.deinit();

    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    const download_url = try findDownloadUrl(
        program.gpa,
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
        .allocator = program.gpa,
        .input_name = downloaded_file_name,
        .input_file = downloaded_file,
        .output_dir = tmp_dir,
    });

    // TODO: Can this be ported to pure zig easily?
    const static_files_result = try std.process.Child.run(.{
        .allocator = program.arena,
        .argv = &.{
            "sh", "-c",
            \\find -type f -exec file '{}' '+' |
            \\    grep -E 'statically linked|static-pie linked' |
            \\    cut -d: -f1 |
            \\    sed 's#^./##' |
            \\    sort
            \\
        },
        .cwd_dir = tmp_dir,
    });

    if (static_files_result.stdout.len < 1)
        return error.NoStaticallyLinkedFiles;

    var bins = std.ArrayList([]const u8).init(program.arena);
    var static_files_lines = std.mem.tokenizeScalar(u8, static_files_result.stdout, '\n');
    while (static_files_lines.next()) |static_bin|
        try bins.append(static_bin);

    const hash = std.fmt.bytesToHex(package_download_result.hash, .lower);
    return .{
        repo.name,
        .{
            .info = .{ .version = latest_release.version() },
            .update = .{
                .github = try std.fmt.allocPrint(program.arena, "{s}/{s}", .{
                    repo.user,
                    repo.repo,
                }),
            },
            .linux_x86_64 = .{
                .bin = bins.items,
                .lib = &.{},
                .share = &.{},
                .url = download_url,
                .hash = try program.arena.dupe(u8, &hash),
            },
        },
    };
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
    repo: GithubRepo,
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
    try trim_list.append(repo.name);
    try trim_list.append(repo.user);
    try trim_list.append(repo.repo);
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
    const pkgs_ini_data = cwd.readFileAlloc(
        program.arena,
        pkgs_ini_path,
        std.math.maxInt(usize),
    ) catch "";

    var packages = try Packages.parse(program.gpa, pkgs_ini_data);
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
        if (package.update.github.len != 0) {
            program.checkGithubPackageVersion(
                package_name,
                package.info.version,
                package.update.github,
                writer,
            ) catch |err| {
                std.log.err("{s} failed to check version: {}", .{ package_name, err });
                continue;
            };
            try stdout_buffered.flush();
        }
    }
    try stdout_buffered.flush();
}

fn checkGithubPackageVersion(
    program: *Program,
    name: []const u8,
    version: []const u8,
    repo: []const u8,
    writer: anytype,
) !void {
    var atom_data = std.ArrayList(u8).init(program.arena);
    const atom_url = try std.fmt.allocPrint(
        program.arena,
        "https://github.com/{s}/releases.atom",
        .{repo},
    );

    const release_download_result = try download.download(
        program.http_client,
        atom_url,
        null,
        atom_data.writer(),
    );
    if (release_download_result.status != .ok)
        return error.DownloadFailed;

    const end_id = "</id>";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, atom_data.items, pos, end_id)) |end| : (pos = end + end_id.len) {
        var start = end;
        while (0 < start) : (start -= 1) switch (atom_data.items[start - 1]) {
            '0'...'9', '.' => {},
            else => break,
        };

        const new_version = atom_data.items[start..end];
        if (std.mem.count(u8, new_version, ".") == 0)
            continue;
        if (std.mem.startsWith(u8, new_version, "."))
            continue;
        if (std.mem.endsWith(u8, new_version, "."))
            continue;
        if (!std.mem.eql(u8, version, new_version))
            try writer.print("{s} {s} -> {s}\n", .{ name, version, new_version });
        return;
    }

    return error.NoVersionFound;
}

const pkgs_inifmt_usage =
    \\Usage: dipm pkgs fmt [options] [file]...
    \\
    \\Options:
    \\  -h, --help          Display this message
    \\
;

fn pkgsInifmtCommand(program: *Program) !void {
    var files_to_format = std.StringArrayHashMap(void).init(program.arena);

    while (program.args.next()) {
        if (program.args.flag(&.{ "-h", "--help" }))
            return program.stdout.writeAll(pkgs_inifmt_usage);
        if (program.args.positional()) |file|
            try files_to_format.put(file, {});
    }

    if (files_to_format.count() == 0)
        return inifmtFiles(program.gpa, program.stdin, program.stdout);

    const cwd = std.fs.cwd();
    for (files_to_format.keys()) |file| {
        var out = try cwd.atomicFile(file, .{});
        defer out.deinit();
        {
            const in = try cwd.openFile(file, .{});
            defer in.close();
            try inifmtFiles(program.gpa, in, out.file);
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
    _ = Package;
    _ = Progress;

    _ = download;
    _ = fs;
    _ = ini;
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
const ini = @import("ini.zig");
const std = @import("std");
