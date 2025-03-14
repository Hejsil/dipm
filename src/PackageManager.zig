gpa: std.mem.Allocator,

http_client: std.http.Client,
pkgs: Packages,
installed: InstalledPackages,

diag: *Diagnostics,
progress: *Progress,

target: Target,

lock: std.fs.File,

prefix_dir: std.fs.Dir,
bin_dir: std.fs.Dir,
lib_dir: std.fs.Dir,
share_dir: std.fs.Dir,

own_data_dir: std.fs.Dir,
own_tmp_dir: std.fs.Dir,

pub fn init(options: Options) !PackageManager {
    const cwd = std.fs.cwd();
    var prefix_dir = try cwd.makeOpenPath(options.prefix, .{});
    errdefer prefix_dir.close();

    var bin_dir = try prefix_dir.makeOpenPath(paths.bin_subpath, .{});
    errdefer bin_dir.close();

    var lib_dir = try prefix_dir.makeOpenPath(paths.lib_subpath, .{});
    errdefer lib_dir.close();

    var share_dir = try prefix_dir.makeOpenPath(paths.share_subpath, .{});
    errdefer share_dir.close();

    var own_data_dir = try prefix_dir.makeOpenPath(paths.own_data_subpath, .{});
    errdefer own_data_dir.close();

    var own_tmp_dir = try prefix_dir.makeOpenPath(paths.own_tmp_subpath, .{
        .iterate = true,
    });
    errdefer own_tmp_dir.close();

    var lock = try own_data_dir.createFile("lock", .{ .lock = .exclusive });
    errdefer lock.close();

    var http_client = std.http.Client{ .allocator = options.gpa };
    errdefer http_client.deinit();

    var installed = try InstalledPackages.open(.{
        .gpa = options.gpa,
        .prefix = options.prefix,
    });
    errdefer installed.deinit();

    var pkgs = try Packages.download(.{
        .gpa = options.gpa,
        .http_client = &http_client,
        .diagnostics = options.diag,
        .progress = options.progress,
        .prefix = options.prefix,
        .pkgs_uri = options.pkgs_uri,
        .download = options.download,
    });
    errdefer pkgs.deinit();

    return PackageManager{
        .gpa = options.gpa,
        .http_client = http_client,
        .diag = options.diag,
        .progress = options.progress,
        .target = options.target,
        .lock = lock,
        .prefix_dir = prefix_dir,
        .bin_dir = bin_dir,
        .lib_dir = lib_dir,
        .share_dir = share_dir,
        .own_data_dir = own_data_dir,
        .own_tmp_dir = own_tmp_dir,
        .pkgs = pkgs,
        .installed = installed,
    };
}

pub const Options = struct {
    gpa: std.mem.Allocator,

    /// Successes and failures are reported to the diag. Set this for more details
    /// about failures.
    diag: *Diagnostics,
    progress: *Progress,

    /// The prefix path where the package manager will work and install packages
    prefix: []const u8,
    pkgs_uri: []const u8,

    /// The download behavior of the index.
    download: Packages.Download,

    target: Target = .{
        .arch = builtin.cpu.arch,
        .os = builtin.os.tag,
    },
};

pub fn cleanup(pm: PackageManager) !void {
    var iter = pm.own_tmp_dir.iterate();
    while (try iter.next()) |entry|
        try pm.own_tmp_dir.deleteTree(entry.name);
}

pub fn deinit(pm: *PackageManager) void {
    pm.http_client.deinit();
    pm.pkgs.deinit();
    pm.installed.deinit();
    pm.lock.close();
    pm.prefix_dir.close();
    pm.bin_dir.close();
    pm.lib_dir.close();
    pm.share_dir.close();
    pm.own_data_dir.close();
    pm.own_tmp_dir.close();
}

fn isInstalled(pm: *const PackageManager, pkg_name: []const u8) bool {
    const adapter = Strings.ArrayHashMapAdapter{ .strings = &pm.installed.strings };
    return pm.installed.by_name.containsAdapted(pkg_name, adapter);
}

pub fn installMany(pm: *PackageManager, pkg_names: []const []const u8) !void {
    var pkgs_to_install = try pm.pkgsToInstall(pkg_names);
    defer pkgs_to_install.deinit();

    const len = pkgs_to_install.count();
    for (0..len) |i_forward| {
        const i_backwards = len - (i_forward + 1);
        const pkg = pkgs_to_install.values()[i_backwards];

        if (pm.isInstalled(pkg.name)) {
            try pm.diag.alreadyInstalled(.{ .name = try pm.diag.putStr(pkg.name) });
            _ = pkgs_to_install.swapRemoveAt(i_backwards);
        }
    }

    const global_progress = switch (pkgs_to_install.count()) {
        0, 1 => .none,
        else => pm.progress.start("progress", @intCast(pkgs_to_install.count())),
    };
    defer pm.progress.end(global_progress);

    var downloads = try DownloadAndExtractJobs.init(.{
        .gpa = pm.gpa,
        .dir = pm.own_tmp_dir,
        .progress = global_progress,
        .pkgs = pkgs_to_install.values(),
    });
    defer downloads.deinit();

    // Step 1: Download the packages that needs to be installed. Can be done multithreaded.
    try downloads.run(pm);

    // Step 2: Install the new version.
    //         If this fails, packages can be left in a partially updated state
    for (downloads.jobs.items) |downloaded| {
        downloaded.result catch |err| switch (err) {
            Diagnostics.Error.DiagnosticsReported => continue,
            else => |e| return e,
        };

        const pkg = downloaded.pkg;
        const working_dir = downloaded.working_dir;
        pm.installExtractedPackage(working_dir, pkg) catch |err| switch (err) {
            Diagnostics.Error.DiagnosticsReported => continue,
            else => |e| return e,
        };

        try pm.diag.installSucceeded(.{
            .name = try pm.diag.putStr(pkg.name),
            .version = try pm.diag.putStr(pkg.info.version),
        });
    }

    try pm.installed.flush();
}

fn pkgsToInstall(
    pm: *const PackageManager,
    pkg_names: []const []const u8,
) !std.StringArrayHashMap(Package.Specific) {
    var pkgs_to_install = std.StringArrayHashMap(Package.Specific).init(pm.gpa);
    errdefer pkgs_to_install.deinit();

    // First, deduplicate. The value is undefined and set later
    try pkgs_to_install.ensureTotalCapacity(pkg_names.len);
    for (pkg_names) |pkg_name|
        pkgs_to_install.putAssumeCapacity(pkg_name, undefined);

    // Now, populate. The packages that dont exist gets removed here.
    var i: usize = 0;
    while (i < pkgs_to_install.count()) {
        const pkg_name = pkgs_to_install.keys()[i];

        const pkg = pm.pkgs.pkgs.get(pkg_name) orelse {
            try pm.diag.notFound(.{ .name = try pm.diag.putStr(pkg_name) });
            pkgs_to_install.swapRemoveAt(i);
            continue;
        };

        const specific = pkg.specific(pkg_name, pm.target) orelse {
            try pm.diag.notFoundForTarget(.{
                .name = try pm.diag.putStr(pkg_name),
                .target = pm.target,
            });
            pkgs_to_install.swapRemoveAt(i);
            continue;
        };

        pkgs_to_install.values()[i] = specific;
        i += 1;
    }

    return pkgs_to_install;
}

const DownloadAndExtractReturnType =
    @typeInfo(@TypeOf(downloadAndExtractPackage)).@"fn".return_type.?;

fn downloadAndExtractPackage(
    pm: *PackageManager,
    dir: std.fs.Dir,
    pkg: Package.Specific,
) !void {
    const downloaded_file_name = std.fs.path.basename(pkg.install.url);
    const downloaded_file = try dir.createFile(downloaded_file_name, .{ .read = true });
    defer downloaded_file.close();

    // TODO: Get rid of this once we have support for bz2 compression
    var download_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const downloaded_path = try dir.realpath(downloaded_file_name, &download_path_buf);

    {
        const download_name = try std.fmt.allocPrint(pm.gpa, "↓ {s}", .{pkg.name});
        defer pm.gpa.free(download_name);

        const download_progress = pm.progress.start(download_name, 1);
        defer pm.progress.end(download_progress);

        const download_result = download.download(downloaded_file.writer(), .{
            .client = &pm.http_client,
            .uri_str = pkg.install.url,
            .progress = download_progress,
        }) catch |err| {
            try pm.diag.downloadFailed(.{
                .name = try pm.diag.putStr(pkg.name),
                .version = try pm.diag.putStr(pkg.info.version),
                .url = try pm.diag.putStr(pkg.install.url),
                .err = err,
            });
            return Diagnostics.Error.DiagnosticsReported;
        };
        if (download_result.status != .ok) {
            try pm.diag.downloadFailedWithStatus(.{
                .name = try pm.diag.putStr(pkg.name),
                .version = try pm.diag.putStr(pkg.info.version),
                .url = try pm.diag.putStr(pkg.install.url),
                .status = download_result.status,
            });
            return Diagnostics.Error.DiagnosticsReported;
        }

        const actual_hash = std.fmt.bytesToHex(download_result.hash, .lower);
        if (!std.mem.eql(u8, pkg.install.hash, &actual_hash)) {
            try pm.diag.hashMismatch(.{
                .name = try pm.diag.putStr(pkg.name),
                .version = try pm.diag.putStr(pkg.info.version),
                .expected_hash = try pm.diag.putStr(pkg.install.hash),
                .actual_hash = try pm.diag.putStr(&actual_hash),
            });
            return Diagnostics.Error.DiagnosticsReported;
        }
    }

    const extract_name = try std.fmt.allocPrint(pm.gpa, "⎋ {s}", .{pkg.name});
    defer pm.gpa.free(extract_name);

    const extract_progress = pm.progress.start(extract_name, 1);
    defer pm.progress.end(extract_progress);

    try downloaded_file.seekTo(0);
    try fs.extract(.{
        .gpa = pm.gpa,
        .node = extract_progress,
        .input_name = downloaded_path,
        .input_file = downloaded_file,
        .output_dir = dir,
    });
}

fn installExtractedPackage(
    pm: *PackageManager,
    from_dir: std.fs.Dir,
    pkg: Package.Specific,
) !void {
    var locations = std.ArrayList(Strings.Index).init(pm.gpa);
    defer locations.deinit();

    try locations.ensureUnusedCapacity(pkg.install.install_bin.len +
        pkg.install.install_lib.len +
        pkg.install.install_share.len);

    // Try to not leave files around if installation fails
    errdefer {
        for (locations.items) |location|
            pm.prefix_dir.deleteTree(location.get(pm.installed.strings)) catch {};
    }

    for (pkg.install.install_bin) |install_field| {
        const the_install = Package.Install.fromString(install_field);
        const path = try pm.installed.print("{}", .{std.fs.path.fmtJoin(&.{
            paths.bin_subpath,
            the_install.to,
        })});
        installBin(the_install, from_dir, pm.bin_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try pm.diag.pathAlreadyExists(.{
                    .name = try pm.diag.putStr(pkg.name),
                    .path = try pm.diag.putStr(path.get(pm.installed.strings)),
                });
                return Diagnostics.Error.DiagnosticsReported;
            },
            else => |e| return e,
        };
        locations.appendAssumeCapacity(path);
    }

    const GenericInstall = struct {
        dir: std.fs.Dir,
        path: []const u8,
        installs: []const []const u8,
    };

    const generic_installs = [_]GenericInstall{
        .{ .dir = pm.lib_dir, .path = paths.lib_subpath, .installs = pkg.install.install_lib },
        .{ .dir = pm.share_dir, .path = paths.share_subpath, .installs = pkg.install.install_share },
    };
    for (generic_installs) |install| {
        for (install.installs) |install_field| {
            const the_install = Package.Install.fromString(install_field);
            const path = try pm.installed.print("{}", .{std.fs.path.fmtJoin(&.{
                install.path,
                the_install.to,
            })});
            installGeneric(the_install, from_dir, install.dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    try pm.diag.pathAlreadyExists(.{
                        .name = try pm.diag.putStr(pkg.name),
                        .path = try pm.diag.putStr(path.get(pm.installed.strings)),
                    });
                    return Diagnostics.Error.DiagnosticsReported;
                },
                else => |e| return e,
            };
            locations.appendAssumeCapacity(path);
        }
    }

    const adapter = Strings.ArrayHashMapAdapter{ .strings = &pm.installed.strings };
    const entry = try pm.installed.by_name.getOrPutAdapted(pm.installed.gpa, pkg.name, adapter);
    std.debug.assert(!entry.found_existing); // Caller ensures that pkg is not installed

    entry.key_ptr.* = try pm.installed.putStr(pkg.name);
    entry.value_ptr.* = .{
        .version = try pm.installed.putStr(pkg.info.version),
        .location = try pm.installed.putIndices(locations.items),
    };
}

fn installBin(the_install: Package.Install, from_dir: std.fs.Dir, to_dir: std.fs.Dir) !void {
    return installFile(the_install, from_dir, to_dir, .{ .executable = true });
}

fn installGeneric(the_install: Package.Install, from_dir: std.fs.Dir, to_dir: std.fs.Dir) !void {
    const stat = try from_dir.statFile(the_install.from);

    switch (stat.kind) {
        .directory => {
            var child_from_dir = try from_dir.openDir(the_install.from, .{ .iterate = true });
            defer child_from_dir.close();

            const install_base_name = std.fs.path.basename(the_install.to);
            const child_to_dir_path = std.fs.path.dirname(the_install.to) orelse ".";
            var child_to_dir = try to_dir.makeOpenPath(child_to_dir_path, .{});
            defer child_to_dir.close();

            var tmp_dir = try fs.tmpDir(child_to_dir, .{});
            defer tmp_dir.deleteAndClose();

            try fs.copyTree(child_from_dir, tmp_dir.dir);

            if (fs.exists(child_to_dir, install_base_name))
                return error.PathAlreadyExists;

            // RACE: If something is fast enough, it could write to `the_install.to` before
            //       `rename` completes. In that case, their content will be overwritten. To
            //       prevent this, we would need to copy to a temp file, then `renameat2` with
            //       `RENAME_NOREPLACE`

            try child_to_dir.rename(&tmp_dir.name, install_base_name);
        },
        .sym_link, .file => return installFile(the_install, from_dir, to_dir, .{}),
        .block_device,
        .character_device,
        .named_pipe,
        .unix_domain_socket,
        .whiteout,
        .door,
        .event_port,
        .unknown,
        => return error.CouldNotCopyEntireTree,
    }
}

const InstallFileOptions = struct {
    executable: bool = false,
};

fn installFile(
    the_install: Package.Install,
    from_dir: std.fs.Dir,
    to_dir: std.fs.Dir,
    options: InstallFileOptions,
) !void {
    const install_base_name = std.fs.path.basename(the_install.to);
    const child_to_dir_path = std.fs.path.dirname(the_install.to) orelse ".";
    var child_to_dir = try to_dir.makeOpenPath(child_to_dir_path, .{});
    defer child_to_dir.close();

    var from_file = try from_dir.openFile(the_install.from, .{});
    defer from_file.close();

    var to_file = try child_to_dir.atomicFile(install_base_name, .{});
    defer to_file.deinit();

    _ = try from_file.copyRangeAll(0, to_file.file, 0, std.math.maxInt(u64));

    if (options.executable) {
        const metadata = try to_file.file.metadata();
        var permissions = metadata.permissions();
        permissions.inner.unixSet(.user, .{ .execute = true });
        try to_file.file.setPermissions(permissions);
    }

    if (fs.exists(child_to_dir, install_base_name))
        return error.PathAlreadyExists;

    // RACE: If something is fast enough, it could write to `the_install.to` before `finish`
    //       completes the rename. In that case, their content will be overwritten. To prevent
    //       this, we would need to copy to a temp file, then `renameat2` with `RENAME_NOREPLACE`

    try to_file.finish();
}

pub fn uninstallMany(pm: *PackageManager, pkg_names: []const []const u8) !void {
    var pkgs_to_uninstall = try pm.pkgsToUninstall(pkg_names);
    defer pkgs_to_uninstall.deinit();

    for (pkgs_to_uninstall.keys(), pkgs_to_uninstall.values()) |pkg_name, pkg| {
        try pm.uninstallOneUnchecked(pkg_name, pkg);
        try pm.diag.uninstallSucceeded(.{
            .name = try pm.diag.putStr(pkg_name),
            .version = try pm.diag.putStr(pkg.version.get(pm.installed.strings)),
        });
    }

    try pm.installed.flush();
}

fn pkgsToUninstall(
    pm: *PackageManager,
    pkg_names: []const []const u8,
) !std.StringArrayHashMap(InstalledPackage) {
    var pkgs_to_uninstall = std.StringArrayHashMap(InstalledPackage).init(pm.gpa);
    errdefer pkgs_to_uninstall.deinit();

    try pkgs_to_uninstall.ensureTotalCapacity(pkg_names.len);
    for (pkg_names) |pkg_name| {
        const adapter = Strings.ArrayHashMapAdapter{ .strings = &pm.installed.strings };
        const pkg = pm.installed.by_name.getAdapted(pkg_name, adapter) orelse {
            try pm.diag.notInstalled((.{ .name = try pm.diag.putStr(pkg_name) }));
            continue;
        };

        pkgs_to_uninstall.putAssumeCapacity(pkg_name, .{
            .version = pkg.version,
            .location = pkg.location,
        });
    }

    return pkgs_to_uninstall;
}

fn uninstallOneUnchecked(
    pm: *PackageManager,
    pkg_name: []const u8,
    pkg: InstalledPackage,
) !void {
    for (pkg.location.get(pm.installed.strings)) |location|
        try pm.prefix_dir.deleteTree(location.get(pm.installed.strings));

    const adapter = Strings.ArrayHashMapAdapter{ .strings = &pm.installed.strings };
    _ = pm.installed.by_name.orderedRemoveAdapted(pkg_name, adapter);
}

pub const UpdateOptions = struct {
    force: bool = false,
};

pub fn updateAll(pm: *PackageManager, options: UpdateOptions) !void {
    // Do a complete clone of installed packages names as `pm.updatePackages` will modify
    // `pm.installed` which could invalidate pointers if we didn't do a complete clone.
    var arena_state = std.heap.ArenaAllocator.init(pm.gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const installed = pm.installed.by_name.keys();
    var pkgs_to_update = std.ArrayList([]const u8).init(arena);
    try pkgs_to_update.ensureTotalCapacity(installed.len);

    for (installed) |pkg_name_index| {
        const pkg_name = pkg_name_index.get(pm.installed.strings);
        pkgs_to_update.appendAssumeCapacity(try arena.dupe(u8, pkg_name));
    }

    return pm.updatePackages(pkgs_to_update.items, .{
        .up_to_date_diag = false,
        .force = options.force,
    });
}

pub fn updateMany(
    pm: *PackageManager,
    pkg_names: []const []const u8,
    options: UpdateOptions,
) !void {
    return pm.updatePackages(pkg_names, .{
        .up_to_date_diag = true,
        .force = options.force,
    });
}

fn updatePackages(pm: *PackageManager, pkg_names: []const []const u8, options: struct {
    up_to_date_diag: bool,
    force: bool,
}) !void {
    if (pkg_names.len == 0)
        return;

    var pkgs_to_uninstall = try pm.pkgsToUninstall(pkg_names);
    defer pkgs_to_uninstall.deinit();

    var pkgs_to_install = try pm.pkgsToInstall(pkgs_to_uninstall.keys());
    defer pkgs_to_install.deinit();

    if (!options.force) {
        // Remove up to date packages from the list if we're not force updating
        for (pkgs_to_uninstall.keys(), pkgs_to_uninstall.values()) |pkg_name, installed_pkg| {
            const updated_pkg = pkgs_to_install.get(pkg_name) orelse continue;
            const installed_version = installed_pkg.version.get(pm.installed.strings);
            if (!std.mem.eql(u8, installed_version, updated_pkg.info.version))
                continue;

            _ = pkgs_to_install.swapRemove(pkg_name);
            if (options.up_to_date_diag)
                try pm.diag.upToDate(.{
                    .name = try pm.diag.putStr(pkg_name),
                    .version = try pm.diag.putStr(installed_version),
                });
        }
    }

    const global_progress = switch (pkgs_to_install.count()) {
        0, 1 => .none,
        else => pm.progress.start("progress", @intCast(pkgs_to_install.count())),
    };
    defer pm.progress.end(global_progress);

    var downloads = try DownloadAndExtractJobs.init(.{
        .gpa = pm.gpa,
        .dir = pm.own_tmp_dir,
        .progress = global_progress,
        .pkgs = pkgs_to_install.values(),
    });
    defer downloads.deinit();

    // Step 1: Download the packages that needs updating. Can be done multithreaded.
    try downloads.run(pm);

    // Step 2: Uninstall the already installed packages.
    //         If this fails, packages can be left in a partially updated state
    for (downloads.jobs.items) |downloaded| {
        downloaded.result catch |err| switch (err) {
            Diagnostics.Error.DiagnosticsReported => continue,
            else => |e| return e,
        };

        const pkg = downloaded.pkg;
        const installed_pkg = pkgs_to_uninstall.get(pkg.name).?;
        try pm.uninstallOneUnchecked(pkg.name, installed_pkg);
    }

    // Step 3: Install the new version.
    //         If this fails, packages can be left in a partially updated state
    for (downloads.jobs.items) |downloaded| {
        downloaded.result catch continue;

        const pkg = downloaded.pkg;
        const working_dir = downloaded.working_dir;
        pm.installExtractedPackage(working_dir, pkg) catch |err| switch (err) {
            Diagnostics.Error.DiagnosticsReported => continue,
            else => |e| return e,
        };

        const installed_pkg = pkgs_to_uninstall.get(pkg.name).?;
        try pm.diag.updateSucceeded(.{
            .name = try pm.diag.putStr(pkg.name),
            .from_version = try pm.diag.putStr(installed_pkg.version.get(pm.installed.strings)),
            .to_version = try pm.diag.putStr(pkg.info.version),
        });
    }

    try pm.installed.flush();
}

const DownloadAndExtractJobs = struct {
    jobs: std.ArrayList(DownloadAndExtractJob),

    fn init(options: struct {
        gpa: std.mem.Allocator,
        dir: std.fs.Dir,
        progress: Progress.Node,
        pkgs: []const Package.Specific,
    }) !DownloadAndExtractJobs {
        var res = DownloadAndExtractJobs{
            .jobs = std.ArrayList(DownloadAndExtractJob).init(options.gpa),
        };
        errdefer res.deinit();

        try res.jobs.ensureTotalCapacity(options.pkgs.len);
        for (options.pkgs) |pkg| {
            var working_dir = try fs.tmpDir(options.dir, .{});
            errdefer working_dir.close();

            res.jobs.appendAssumeCapacity(.{
                .working_dir = working_dir.dir,
                .progress = options.progress,
                .pkg = pkg,
                .result = {},
            });
        }

        return res;
    }

    fn run(jobs: DownloadAndExtractJobs, pm: *PackageManager) !void {
        var thread_pool: std.Thread.Pool = undefined;
        try thread_pool.init(.{ .allocator = pm.gpa });
        defer thread_pool.deinit();

        for (jobs.jobs.items) |*job|
            try thread_pool.spawn(DownloadAndExtractJob.run, .{ job, pm });
    }

    fn deinit(jobs: DownloadAndExtractJobs) void {
        for (jobs.jobs.items) |*job|
            job.working_dir.close();
        jobs.jobs.deinit();
    }
};

const DownloadAndExtractJob = struct {
    pkg: Package.Specific,
    progress: Progress.Node,
    working_dir: std.fs.Dir,
    result: DownloadAndExtractReturnType,

    fn run(job: *DownloadAndExtractJob, pm: *PackageManager) void {
        job.result = pm.downloadAndExtractPackage(job.working_dir, job.pkg);
        job.progress.advance(1);
    }
};

test {
    _ = Diagnostics;
    _ = InstalledPackage;
    _ = InstalledPackages;
    _ = Package;
    _ = Packages;
    _ = Progress;
    _ = Strings;
    _ = Target;

    _ = download;
    _ = ini;
    _ = paths;
}

const PackageManager = @This();

const Diagnostics = @import("Diagnostics.zig");
const InstalledPackage = @import("InstalledPackage.zig");
const InstalledPackages = @import("InstalledPackages.zig");
const Package = @import("Package.zig");
const Packages = @import("Packages.zig");
const Progress = @import("Progress.zig");
const Strings = @import("Strings.zig");
const Target = @import("Target.zig");

const builtin = @import("builtin");
const download = @import("download.zig");
const fs = @import("fs.zig");
const ini = @import("ini.zig");
const paths = @import("paths.zig");
const std = @import("std");
