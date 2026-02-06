io: std.Io,
gpa: std.mem.Allocator,

http_client: std.http.Client,
installed: InstalledPackages,

diag: *Diagnostics,
progress: *Progress,

target: Target,
prefix: []const u8,
pkgs_uri: []const u8,
pkgs_download_method: Packages.Download,

lock: std.Io.File,

prefix_dir: std.Io.Dir,

cache: struct {
    pkgs: ?Packages = null,
} = .{},

pub fn init(options: Options) !PackageManager {
    const io = options.io;
    const cwd = std.Io.Dir.cwd();

    var prefix_dir = try cwd.createDirPathOpen(io, options.prefix, .{});
    errdefer prefix_dir.close(io);

    var own_data_dir = try prefix_dir.createDirPathOpen(io, paths.own_data_subpath, .{});
    defer own_data_dir.close(io);

    var lock = try own_data_dir.createFile(io, "lock", .{ .lock = .exclusive });
    errdefer lock.close(io);

    var http_client = std.http.Client{
        .io = options.io,
        .allocator = options.gpa,
    };
    errdefer http_client.deinit();

    var installed = try InstalledPackages.open(options.io, options.gpa, options.prefix);
    errdefer installed.deinit(options.gpa);

    return PackageManager{
        .io = options.io,
        .gpa = options.gpa,
        .http_client = http_client,
        .diag = options.diag,
        .progress = options.progress,
        .target = options.target,
        .prefix = options.prefix,
        .pkgs_uri = options.pkgs_uri,
        .pkgs_download_method = options.download,
        .lock = lock,
        .prefix_dir = prefix_dir,
        .installed = installed,
    };
}

pub const Options = struct {
    io: std.Io,
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
    try pm.prefix_dir.deleteTree(pm.io, paths.own_tmp_subpath);
}

pub fn deinit(pm: *PackageManager) void {
    if (pm.cache.pkgs) |*p| p.deinit();

    pm.http_client.deinit();
    pm.installed.deinit(pm.io);
    pm.lock.close(pm.io);
    pm.prefix_dir.close(pm.io);
}

fn packages(pm: *PackageManager) !*const Packages {
    if (pm.cache.pkgs) |*res|
        return res;

    pm.cache.pkgs = try Packages.download(.{
        .io = pm.io,
        .gpa = pm.gpa,
        .diagnostics = pm.diag,
        .progress = pm.progress,
        .prefix = pm.prefix,
        .pkgs_uri = pm.pkgs_uri,
        .download = pm.pkgs_download_method,
    });
    return &pm.cache.pkgs.?;
}

pub fn installMany(pm: *PackageManager, pkg_names: []const []const u8) !void {
    var pkgs_not_installed = std.ArrayList([]const u8){};
    defer pkgs_not_installed.deinit(pm.gpa);

    try pkgs_not_installed.ensureTotalCapacity(pm.gpa, pkg_names.len);
    for (pkg_names) |pkg| {
        if (pm.installed.isInstalled(pkg)) {
            try pm.diag.alreadyInstalled(.{ .name = pkg });
        } else {
            pkgs_not_installed.appendAssumeCapacity(pkg);
        }
    }

    if (pkgs_not_installed.items.len == 0)
        return;

    var pkgs_to_install = try pm.pkgsToInstall(pkgs_not_installed.items);
    defer pkgs_to_install.deinit();

    const global_progress = switch (pkgs_to_install.count()) {
        0 => return,
        1 => .none,
        else => pm.progress.start("progress", @intCast(pkgs_to_install.count())),
    };
    defer pm.progress.end(global_progress);

    var tmp_dir = try pm.prefix_dir.createDirPathOpen(pm.io, paths.own_tmp_subpath, .{});
    defer tmp_dir.close(pm.io);

    const pkgs = try pm.packages();
    var downloads = try DownloadAndExtractJobs.init(.{
        .io = pm.io,
        .gpa = pm.gpa,
        .dir = tmp_dir,
        .progress = global_progress,
        .pkgs = pkgs,
        .pkgs_to_download = pkgs_to_install.values(),
    });
    defer downloads.deinit(pm.io, pm.gpa);

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

        try pm.diag.installSucceeded(.{ .name = pkg.name, .version = pkg.info.version });
    }

    try pm.installed.flush(pm.io);
}

const PkgsToInstall = std.StringArrayHashMap(Package.Specific);

fn pkgsToInstall(pm: *PackageManager, pkg_names: []const []const u8) !PkgsToInstall {
    var pkgs_to_install = std.StringArrayHashMap(Package.Specific).init(pm.gpa);
    errdefer pkgs_to_install.deinit();

    // First, deduplicate. The value is undefined and set later
    try pkgs_to_install.ensureTotalCapacity(pkg_names.len);
    for (pkg_names) |pkg_name|
        pkgs_to_install.putAssumeCapacity(pkg_name, undefined);

    const pkgs = try pm.packages();

    // Now, populate. The packages that dont exist gets removed here.
    var i: usize = 0;
    while (i < pkgs_to_install.count()) {
        const pkg_name = pkgs_to_install.keys()[i];

        const pkg = pkgs.by_name.get(pkg_name) orelse {
            try pm.diag.notFound(.{ .name = pkg_name });
            pkgs_to_install.swapRemoveAt(i);
            continue;
        };

        const specific = pkg.specific(pkg_name, pm.target) orelse {
            try pm.diag.notFoundForTarget(.{ .name = pkg_name, .target = pm.target });
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
    dir: std.Io.Dir,
    pkg: Package.Specific,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(pm.gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const download_name = try std.fmt.allocPrint(arena, "↓ {s}", .{pkg.name});
    const extract_name = try std.fmt.allocPrint(arena, "⎋ {s}", .{pkg.name});

    const progress = pm.progress.start(download_name, 1);
    defer pm.progress.end(progress);

    const downloaded_file_name = std.fs.path.basename(pkg.install.url);
    const downloaded_file = try dir.createFile(pm.io, downloaded_file_name, .{ .read = true });
    defer downloaded_file.close(pm.io);

    var downloaded_file_buf: [std.heap.page_size_min]u8 = undefined;
    var downloaded_file_writer = downloaded_file.writer(pm.io, &downloaded_file_buf);

    // TODO: Get rid of this once we have support for bz2 compression
    const downloaded_path = try dir.realPathFileAlloc(pm.io, downloaded_file_name, arena);

    const download_result = download.download(.{
        .io = pm.io,
        .writer = &downloaded_file_writer.interface,
        .client = &pm.http_client,
        .uri_str = pkg.install.url,
        .progress = progress,
    }) catch |err| {
        try pm.diag.downloadFailed(.{
            .name = pkg.name,
            .version = pkg.info.version,
            .url = pkg.install.url,
            .err = err,
        });
        return Diagnostics.Error.DiagnosticsReported;
    };
    if (download_result.status != .ok) {
        try pm.diag.downloadFailedWithStatus(.{
            .name = pkg.name,
            .version = pkg.info.version,
            .url = pkg.install.url,
            .status = download_result.status,
        });
        return Diagnostics.Error.DiagnosticsReported;
    }

    const actual_hash = std.fmt.bytesToHex(download_result.hash, .lower);
    if (!std.mem.eql(u8, pkg.install.hash, &actual_hash)) {
        try pm.diag.hashMismatch(.{
            .name = pkg.name,
            .version = pkg.info.version,
            .expected_hash = pkg.install.hash,
            .actual_hash = &actual_hash,
        });
        return Diagnostics.Error.DiagnosticsReported;
    }

    try downloaded_file_writer.end();

    progress.set(.{ .max = 0, .curr = 0, .name = extract_name });
    try fs.extract(.{
        .io = pm.io,
        .gpa = pm.gpa,
        .node = progress,
        .input_name = downloaded_path,
        .input_file = downloaded_file,
        .output_dir = dir,
    });
}

fn installExtractedPackage(
    pm: *PackageManager,
    from_dir: std.Io.Dir,
    pkg: Package.Specific,
) !void {
    var locations = std.ArrayList([]const u8){};
    try locations.ensureUnusedCapacity(pm.installed.arena(), pkg.install.install_bin.len +
        pkg.install.install_lib.len +
        pkg.install.install_share.len);

    // Try to not leave files around if installation fails
    errdefer {
        for (locations.items) |location|
            pm.prefix_dir.deleteTree(pm.io, location) catch {};
    }

    var bin_dir = try pm.prefix_dir.createDirPathOpen(pm.io, paths.bin_subpath, .{});
    defer bin_dir.close(pm.io);

    for (pkg.install.install_bin) |install_field| {
        const the_install = Package.Install.fromString(install_field);
        const join_fmt = std.fs.path.fmtJoin(&.{ paths.bin_subpath, the_install.to });
        const path = try std.fmt.allocPrint(pm.installed.arena(), "{f}", .{join_fmt});
        installBin(pm.io, the_install, from_dir, bin_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try pm.diag.pathAlreadyExists(.{ .name = pkg.name, .path = path });
                return Diagnostics.Error.DiagnosticsReported;
            },
            else => |e| return e,
        };
        locations.appendAssumeCapacity(path);
    }

    var lib_dir = try pm.prefix_dir.createDirPathOpen(pm.io, paths.lib_subpath, .{});
    defer lib_dir.close(pm.io);

    var share_dir = try pm.prefix_dir.createDirPathOpen(pm.io, paths.share_subpath, .{});
    defer share_dir.close(pm.io);

    const GenericInstall = struct {
        dir: std.Io.Dir,
        path: []const u8,
        installs: []const []const u8,
    };

    const generic_installs = [_]GenericInstall{
        .{ .dir = lib_dir, .path = paths.lib_subpath, .installs = pkg.install.install_lib },
        .{ .dir = share_dir, .path = paths.share_subpath, .installs = pkg.install.install_share },
    };
    for (generic_installs) |install| {
        for (install.installs) |install_field| {
            const the_install = Package.Install.fromString(install_field);
            const join_fmt = std.fs.path.fmtJoin(&.{ install.path, the_install.to });
            const path = try std.fmt.allocPrint(pm.installed.arena(), "{f}", .{join_fmt});
            installGeneric(pm.io, the_install, from_dir, install.dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    try pm.diag.pathAlreadyExists(.{ .name = pkg.name, .path = path });
                    return Diagnostics.Error.DiagnosticsReported;
                },
                else => |e| return e,
            };
            locations.appendAssumeCapacity(path);
        }
    }

    const entry = try pm.installed.by_name.getOrPut(pm.gpa, pkg.name);
    std.debug.assert(!entry.found_existing); // Caller ensures that pkg is not installed

    entry.key_ptr.* = try pm.installed.arena().dupe(u8, pkg.name);
    entry.value_ptr.* = .{
        .version = try pm.installed.arena().dupe(u8, pkg.info.version),
        .location = try locations.toOwnedSlice(pm.installed.arena()),
    };
}

fn installBin(io: std.Io, the_install: Package.Install, from_dir: std.Io.Dir, to_dir: std.Io.Dir) !void {
    return installFile(io, the_install, from_dir, to_dir, .{ .executable = true });
}

fn installGeneric(io: std.Io, the_install: Package.Install, from_dir: std.Io.Dir, to_dir: std.Io.Dir) !void {
    const stat = try from_dir.statFile(io, the_install.from, .{});

    switch (stat.kind) {
        .directory => {
            var child_from_dir = try from_dir.openDir(io, the_install.from, .{ .iterate = true });
            defer child_from_dir.close(io);

            const install_base_name = std.fs.path.basename(the_install.to);
            const child_to_dir_path = std.fs.path.dirname(the_install.to) orelse ".";
            var child_to_dir = try to_dir.createDirPathOpen(io, child_to_dir_path, .{});
            defer child_to_dir.close(io);

            var tmp_dir = try fs.tmpDir(io, child_to_dir, .{});
            defer tmp_dir.deleteAndClose(io);

            try fs.copyTree(io, child_from_dir, tmp_dir.dir);

            if (fs.exists(io, child_to_dir, install_base_name))
                return error.PathAlreadyExists;

            // RACE: If something is fast enough, it could write to `the_install.to` before
            //       `rename` completes. In that case, their content will be overwritten. To
            //       prevent this, we would need to copy to a temp file, then `renameat2` with
            //       `RENAME_NOREPLACE`

            try child_to_dir.rename(&tmp_dir.name, child_to_dir, install_base_name, io);
        },
        .sym_link, .file => return installFile(io, the_install, from_dir, to_dir, .{}),
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
    io: std.Io,
    the_install: Package.Install,
    from_dir: std.Io.Dir,
    to_dir: std.Io.Dir,
    options: InstallFileOptions,
) !void {
    const install_base_name = std.fs.path.basename(the_install.to);
    const child_to_dir_path = std.fs.path.dirname(the_install.to) orelse ".";
    var child_to_dir = try to_dir.createDirPathOpen(io, child_to_dir_path, .{});
    defer child_to_dir.close(io);

    try from_dir.copyFile(the_install.from, child_to_dir, install_base_name, io, .{
        .permissions = if (options.executable) .executable_file else .default_file,
        .replace = false,
    });
}

pub fn uninstallMany(pm: *PackageManager, pkg_names: []const []const u8) !void {
    var pkgs_to_uninstall = try pm.pkgsToUninstall(pkg_names);
    defer pkgs_to_uninstall.deinit();

    for (pkgs_to_uninstall.keys(), pkgs_to_uninstall.values()) |pkg_name, pkg| {
        try pm.uninstallOneUnchecked(pkg_name, pkg);
        try pm.diag.uninstallSucceeded(.{ .name = pkg_name, .version = pkg.version });
    }

    try pm.installed.flush(pm.io);
}

fn pkgsToUninstall(
    pm: *PackageManager,
    pkg_names: []const []const u8,
) !std.StringArrayHashMap(InstalledPackage) {
    var pkgs_to_uninstall = std.StringArrayHashMap(InstalledPackage).init(pm.gpa);
    errdefer pkgs_to_uninstall.deinit();

    try pkgs_to_uninstall.ensureTotalCapacity(pkg_names.len);
    for (pkg_names) |pkg_name| {
        const pkg = pm.installed.by_name.get(pkg_name) orelse {
            try pm.diag.notInstalled((.{ .name = pkg_name }));
            continue;
        };

        pkgs_to_uninstall.putAssumeCapacity(pkg_name, .{
            .version = pkg.version,
            .location = pkg.location,
        });
    }

    return pkgs_to_uninstall;
}

fn uninstallOneUnchecked(pm: *PackageManager, pkg_name: []const u8, pkg: InstalledPackage) !void {
    for (pkg.location) |location|
        try pm.prefix_dir.deleteTree(pm.io, location);
    _ = pm.installed.by_name.orderedRemove(pkg_name);
}

pub const UpdateOptions = struct {
    force: bool = false,
};

pub fn updateAll(pm: *PackageManager, options: UpdateOptions) !void {
    // Do a complete clone of installed packages names as `pm.updatePackages` will modify
    // `pm.installed` which could invalidate pointers if we didn't do a complete clone.
    const pkgs_to_update = try pm.gpa.dupe([]const u8, pm.installed.by_name.keys());
    defer pm.gpa.free(pkgs_to_update);

    return pm.updatePackages(pkgs_to_update, .{
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
    var pkgs_to_uninstall = try pm.pkgsToUninstall(pkg_names);
    defer pkgs_to_uninstall.deinit();

    var pkgs_to_install = try pm.pkgsToInstall(pkgs_to_uninstall.keys());
    defer pkgs_to_install.deinit();

    const pkgs = try pm.packages();
    if (!options.force) {
        // Remove up to date packages from the list if we're not force updating
        for (pkgs_to_uninstall.keys(), pkgs_to_uninstall.values()) |pkg_name, installed_pkg| {
            const updated_pkg = pkgs_to_install.get(pkg_name) orelse continue;
            const updated_version = updated_pkg.info.version;
            const installed_version = installed_pkg.version;
            if (!std.mem.eql(u8, installed_version, updated_version))
                continue;

            _ = pkgs_to_install.swapRemove(pkg_name);
            if (options.up_to_date_diag)
                try pm.diag.upToDate(.{ .name = pkg_name, .version = installed_version });
        }
    }

    const global_progress = switch (pkgs_to_install.count()) {
        0 => return,
        1 => .none,
        else => pm.progress.start("progress", @intCast(pkgs_to_install.count())),
    };
    defer pm.progress.end(global_progress);

    var tmp_dir = try pm.prefix_dir.createDirPathOpen(pm.io, paths.own_tmp_subpath, .{});
    defer tmp_dir.close(pm.io);

    var downloads = try DownloadAndExtractJobs.init(.{
        .io = pm.io,
        .gpa = pm.gpa,
        .dir = tmp_dir,
        .progress = global_progress,
        .pkgs = pkgs,
        .pkgs_to_download = pkgs_to_install.values(),
    });
    defer downloads.deinit(pm.io, pm.gpa);

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
            .name = pkg.name,
            .from_version = installed_pkg.version,
            .to_version = pkg.info.version,
        });
    }

    try pm.installed.flush(pm.io);
}

const DownloadAndExtractJobs = struct {
    jobs: std.ArrayList(DownloadAndExtractJob) = .{},

    fn init(options: struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        dir: std.Io.Dir,
        progress: Progress.Node,
        pkgs: *const Packages,
        pkgs_to_download: []const Package.Specific,
    }) !DownloadAndExtractJobs {
        var res = DownloadAndExtractJobs{};
        errdefer res.deinit(options.io, options.gpa);

        try res.jobs.ensureTotalCapacity(options.gpa, options.pkgs_to_download.len);
        for (options.pkgs_to_download) |pkg| {
            var working_dir = try fs.tmpDir(options.io, options.dir, .{});
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
        var group = std.Io.Group.init;
        for (jobs.jobs.items) |*job|
            group.async(pm.io, DownloadAndExtractJob.run, .{ job, pm });
        try group.await(pm.io);
    }

    fn deinit(jobs: *DownloadAndExtractJobs, io: std.Io, gpa: std.mem.Allocator) void {
        for (jobs.jobs.items) |*job|
            job.working_dir.close(io);
        jobs.jobs.deinit(gpa);
    }
};

const DownloadAndExtractJob = struct {
    pkg: Package.Specific,
    progress: Progress.Node,
    working_dir: std.Io.Dir,
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
const Target = @import("Target.zig");

const builtin = @import("builtin");
const download = @import("download.zig");
const fs = @import("fs.zig");
const ini = @import("ini.zig");
const paths = @import("paths.zig");
const std = @import("std");
