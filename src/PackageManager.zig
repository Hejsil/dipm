gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,

http_client: ?*std.http.Client,
packages: *const Packages,
installed_packages: *InstalledPackages,

diagnostics: *Diagnostics,
progress: *Progress,

os: std.Target.Os.Tag,
arch: std.Target.Cpu.Arch,

prefix_path: []const u8,
prefix_dir: std.fs.Dir,
bin_dir: std.fs.Dir,
lib_dir: std.fs.Dir,
share_dir: std.fs.Dir,

own_tmp_dir: std.fs.Dir,

pub fn init(options: Options) !PackageManager {
    const allocator = options.allocator;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    const arena = arena_state.allocator();
    errdefer arena_state.deinit();

    const cwd = std.fs.cwd();
    var prefix_dir = try cwd.makeOpenPath(options.prefix, .{});
    errdefer prefix_dir.close();

    const prefix_path = try prefix_dir.realpathAlloc(arena, ".");

    var bin_dir = try prefix_dir.makeOpenPath(paths.bin_subpath, .{});
    errdefer bin_dir.close();

    var lib_dir = try prefix_dir.makeOpenPath(paths.lib_subpath, .{});
    errdefer lib_dir.close();

    var share_dir = try prefix_dir.makeOpenPath(paths.share_subpath, .{});
    errdefer share_dir.close();

    var own_tmp_dir = try prefix_dir.makeOpenPath(paths.own_tmp_subpath, .{
        .iterate = true,
    });
    errdefer own_tmp_dir.close();

    return PackageManager{
        .gpa = allocator,
        .arena = arena_state,
        .http_client = options.http_client,
        .diagnostics = options.diagnostics,
        .progress = options.progress,
        .os = options.os,
        .arch = options.arch,
        .prefix_path = prefix_path,
        .prefix_dir = prefix_dir,
        .bin_dir = bin_dir,
        .lib_dir = lib_dir,
        .share_dir = share_dir,
        .own_tmp_dir = own_tmp_dir,
        .packages = options.packages,
        .installed_packages = options.installed_packages,
    };
}

pub const Options = struct {
    allocator: std.mem.Allocator,
    http_client: ?*std.http.Client = null,
    packages: *const Packages,
    installed_packages: *InstalledPackages,

    /// Successes and failures are reported to the diagnostics. Set this for more details
    /// about failures.
    diagnostics: *Diagnostics,
    progress: *Progress,

    /// The prefix path where the package manager will work and install packages
    prefix: []const u8,

    arch: std.Target.Cpu.Arch = builtin.cpu.arch,
    os: std.Target.Os.Tag = builtin.os.tag,
};

pub fn cleanup(pm: PackageManager) !void {
    var iter = pm.own_tmp_dir.iterate();
    while (try iter.next()) |entry|
        try pm.own_tmp_dir.deleteTree(entry.name);
}

pub fn deinit(pm: *PackageManager) void {
    pm.bin_dir.close();
    pm.lib_dir.close();
    pm.prefix_dir.close();
    pm.share_dir.close();

    pm.arena.deinit();
}

pub fn isInstalled(pm: *const PackageManager, package_name: []const u8) bool {
    return pm.installed_packages.packages.contains(package_name);
}

pub fn installMany(pm: *PackageManager, package_names: []const []const u8) !void {
    var packages_to_install = try pm.packagesToInstall(package_names);
    defer packages_to_install.deinit();

    const len = packages_to_install.count();
    for (0..len) |i_forward| {
        const i_backwards = len - (i_forward + 1);
        const package = packages_to_install.values()[i_backwards];

        if (pm.isInstalled(package.name)) {
            try pm.diagnostics.alreadyInstalled(.{ .name = package.name });
            _ = packages_to_install.swapRemoveAt(i_backwards);
        }
    }

    var downloads = try DownloadAndExtractJobs.init(.{
        .allocator = pm.gpa,
        .dir = pm.own_tmp_dir,
        .packages = packages_to_install.values(),
    });
    defer downloads.deinit();

    // Step 1: Download the packages that needs to be installed. Can be done multithreaded.
    try downloads.run(pm);

    // Step 2: Install the new version.
    //         If this fails, packages can be left in a partially updated state
    for (downloads.jobs.items) |downloaded| {
        downloaded.result catch |err| switch (err) {
            DiagnosticError.DiagnosticsInvalidHash => continue,
            DiagnosticError.DiagnosticsDownloadFailed => continue,
            else => |e| return e,
        };

        const package = downloaded.package;
        const working_dir = downloaded.working_dir;
        try pm.installExtractedPackage(working_dir, package);

        try pm.diagnostics.installSucceeded(.{
            .name = package.name,
            .version = package.info.version,
        });
    }

    try pm.installed_packages.flush();
}

fn packagesToInstall(
    pm: *const PackageManager,
    package_names: []const []const u8,
) !std.StringArrayHashMap(Package.Specific) {
    var packages_to_install = std.StringArrayHashMap(Package.Specific).init(pm.gpa);
    errdefer packages_to_install.deinit();

    // First, deduplicate. The value is undefined and set later
    try packages_to_install.ensureTotalCapacity(package_names.len);
    for (package_names) |package_name|
        packages_to_install.putAssumeCapacity(package_name, undefined);

    // Now, populate. The packages that dont exist gets removed here.
    var i: usize = 0;
    while (i < packages_to_install.count()) {
        const package_name = packages_to_install.keys()[i];

        const package = pm.packages.packages.get(package_name) orelse {
            try pm.diagnostics.notFound(.{ .name = package_name });
            packages_to_install.swapRemoveAt(i);
            continue;
        };

        const specific = package.specific(package_name, pm.os, pm.arch) orelse {
            try pm.diagnostics.notFoundForTarget(.{
                .name = package_name,
                .os = pm.os,
                .arch = pm.arch,
            });
            packages_to_install.swapRemoveAt(i);
            continue;
        };

        packages_to_install.values()[i] = specific;
        i += 1;
    }

    return packages_to_install;
}

const DownloadAndExtractReturnType =
    @typeInfo(@TypeOf(downloadAndExtractPackage)).@"fn".return_type.?;

fn downloadAndExtractPackage(
    pm: *const PackageManager,
    dir: std.fs.Dir,
    package: Package.Specific,
) !void {
    const progress = pm.progress.start(package.name, 1);
    defer pm.progress.end(progress);

    const downloaded_file_name = std.fs.path.basename(package.install.url);
    const downloaded_file = try dir.createFile(downloaded_file_name, .{ .read = true });
    defer downloaded_file.close();

    // TODO: Get rid of this once we have support for bz2 compression
    var download_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const downloaded_path = try dir.realpath(downloaded_file_name, &download_path_buf);

    const download_result = download.download(downloaded_file.writer(), .{
        .client = pm.http_client,
        .uri_str = package.install.url,
        .progress = progress,
    }) catch |err| {
        try pm.diagnostics.downloadFailed(.{
            .name = package.name,
            .version = package.info.version,
            .url = package.install.url,
            .err = err,
        });
        return DiagnosticError.DiagnosticsDownloadFailed;
    };
    if (download_result.status != .ok) {
        try pm.diagnostics.downloadFailedWithStatus(.{
            .name = package.name,
            .version = package.info.version,
            .url = package.install.url,
            .status = download_result.status,
        });
        return DiagnosticError.DiagnosticsDownloadFailed;
    }

    const actual_hash = std.fmt.bytesToHex(download_result.hash, .lower);
    if (!std.mem.eql(u8, package.install.hash, &actual_hash)) {
        try pm.diagnostics.hashMismatch(.{
            .name = package.name,
            .version = package.info.version,
            .expected_hash = package.install.hash,
            .actual_hash = &actual_hash,
        });
        return DiagnosticError.DiagnosticsInvalidHash;
    }

    try downloaded_file.seekTo(0);
    try fs.extract(.{
        .allocator = pm.gpa,
        .node = progress,
        .input_name = downloaded_path,
        .input_file = downloaded_file,
        .output_dir = dir,
    });
}

fn installExtractedPackage(
    pm: *PackageManager,
    from_dir: std.fs.Dir,
    package: Package.Specific,
) !void {
    const installed_arena = pm.installed_packages.arena.allocator();
    var locations = std.ArrayList([]const u8).init(installed_arena);
    defer locations.deinit();

    for (package.install.bin) |install_field| {
        const the_install = Package.Install.fromString(install_field);
        try installBin(the_install, from_dir, pm.bin_dir);
        try locations.append(try std.fs.path.join(installed_arena, &.{
            pm.prefix_path,
            paths.bin_subpath,
            the_install.to,
        }));
    }
    for (package.install.lib) |install_field| {
        const the_install = Package.Install.fromString(install_field);
        try installGeneric(the_install, from_dir, pm.lib_dir);
        try locations.append(try std.fs.path.join(installed_arena, &.{
            pm.prefix_path,
            paths.lib_subpath,
            the_install.to,
        }));
    }
    for (package.install.share) |install_field| {
        const the_install = Package.Install.fromString(install_field);
        try installGeneric(the_install, from_dir, pm.share_dir);
        try locations.append(try std.fs.path.join(installed_arena, &.{
            pm.prefix_path,
            paths.share_subpath,
            the_install.to,
        }));
    }

    // Caller ensures that package is not installed
    const installed_key = try installed_arena.dupe(u8, package.name);
    try pm.installed_packages.packages.putNoClobber(installed_arena, installed_key, .{
        .version = try installed_arena.dupe(u8, package.info.version),
        .locations = try locations.toOwnedSlice(),
    });
}

fn installBin(the_install: Package.Install, from_dir: std.fs.Dir, to_dir: std.fs.Dir) !void {
    try from_dir.copyFile(the_install.from, to_dir, the_install.to, .{});

    const installed_file = try to_dir.openFile(the_install.to, .{});
    defer installed_file.close();

    const metadata = try installed_file.metadata();
    var permissions = metadata.permissions();
    permissions.inner.unixSet(.user, .{ .execute = true });
    try installed_file.setPermissions(permissions);
}

fn installGeneric(the_install: Package.Install, from_dir: std.fs.Dir, to_dir: std.fs.Dir) !void {
    const stat = try from_dir.statFile(the_install.from);

    switch (stat.kind) {
        .directory => {
            var child_from_dir = try from_dir.openDir(the_install.from, .{ .iterate = true });
            defer child_from_dir.close();
            var child_to_dir = try to_dir.makeOpenPath(the_install.to, .{});
            defer child_to_dir.close();

            try fs.copyTree(child_from_dir, child_to_dir);
        },
        .sym_link, .file => {
            const install_base_name = std.fs.path.basename(the_install.to);
            const child_to_dir_path = std.fs.path.dirname(the_install.to) orelse ".";
            var child_to_dir = try to_dir.makeOpenPath(child_to_dir_path, .{});
            defer child_to_dir.close();

            try from_dir.copyFile(the_install.from, child_to_dir, install_base_name, .{});
        },

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

pub fn uninstallMany(pm: *PackageManager, package_names: []const []const u8) !void {
    var packages_to_uninstall = try pm.packagesToUninstall(package_names);
    defer packages_to_uninstall.deinit();

    for (packages_to_uninstall.keys(), packages_to_uninstall.values()) |package_name, package| {
        try pm.uninstallOneUnchecked(package_name, package);
        try pm.diagnostics.uninstallSucceeded(.{
            .name = package_name,
            .version = package.version,
        });
    }

    try pm.installed_packages.flush();
}

fn packagesToUninstall(
    pm: *PackageManager,
    package_names: []const []const u8,
) !std.StringArrayHashMap(InstalledPackage) {
    var packages_to_uninstall = std.StringArrayHashMap(InstalledPackage).init(pm.gpa);
    errdefer packages_to_uninstall.deinit();

    try packages_to_uninstall.ensureTotalCapacity(package_names.len);
    for (package_names) |package_name| {
        const package = pm.installed_packages.packages.get(package_name) orelse {
            try pm.diagnostics.notInstalled((.{
                .name = package_name,
            }));
            continue;
        };

        packages_to_uninstall.putAssumeCapacity(package_name, .{
            .version = package.version,
            .locations = package.locations,
        });
    }

    return packages_to_uninstall;
}

fn uninstallOneUnchecked(
    pm: *PackageManager,
    package_name: []const u8,
    package: InstalledPackage,
) !void {
    const cwd = std.fs.cwd();
    for (package.locations) |location|
        try cwd.deleteTree(location);

    _ = pm.installed_packages.packages.orderedRemove(package_name);
}

pub fn updateAll(pm: *PackageManager, options: struct {
    force: bool = false,
}) !void {
    const installed_packages = pm.installed_packages.packages.keys();
    const packages_to_update = try pm.gpa.dupe([]const u8, installed_packages);
    defer pm.gpa.free(packages_to_update);

    return pm.updatePackages(packages_to_update, .{
        .up_to_date_diag = false,
        .force = options.force,
    });
}

pub fn updateMany(pm: *PackageManager, package_names: []const []const u8, options: struct {
    force: bool = false,
}) !void {
    return pm.updatePackages(package_names, .{
        .up_to_date_diag = true,
        .force = options.force,
    });
}

fn updatePackages(pm: *PackageManager, package_names: []const []const u8, options: struct {
    up_to_date_diag: bool,
    force: bool,
}) !void {
    if (package_names.len == 0)
        return;

    var packages_to_uninstall = try pm.packagesToUninstall(package_names);
    defer packages_to_uninstall.deinit();

    var packages_to_install = try pm.packagesToInstall(packages_to_uninstall.keys());
    defer packages_to_install.deinit();

    if (!options.force) {
        // Remove up to date packages from the list if we're not force updating
        for (packages_to_uninstall.keys(), packages_to_uninstall.values()) |package_name, installed_package| {
            const updated_package = packages_to_install.get(package_name) orelse continue;
            if (!std.mem.eql(u8, installed_package.version, updated_package.info.version))
                continue;

            _ = packages_to_install.swapRemove(package_name);
            if (options.up_to_date_diag)
                try pm.diagnostics.upToDate(.{
                    .name = package_name,
                    .version = installed_package.version,
                });
        }
    }

    var downloads = try DownloadAndExtractJobs.init(.{
        .allocator = pm.gpa,
        .dir = pm.own_tmp_dir,
        .packages = packages_to_install.values(),
    });
    defer downloads.deinit();

    // Step 1: Download the packages that needs updating. Can be done multithreaded.
    try downloads.run(pm);

    // Step 2: Uninstall the already installed packages.
    //         If this fails, packages can be left in a partially updated state
    for (downloads.jobs.items) |downloaded| {
        downloaded.result catch |err| switch (err) {
            DiagnosticError.DiagnosticsInvalidHash => continue,
            DiagnosticError.DiagnosticsDownloadFailed => continue,
            else => |e| return e,
        };

        const package = downloaded.package;
        const installed_package = packages_to_uninstall.get(package.name).?;
        try pm.uninstallOneUnchecked(package.name, installed_package);
    }

    // Step 3: Install the new version.
    //         If this fails, packages can be left in a partially updated state
    for (downloads.jobs.items) |downloaded| {
        downloaded.result catch continue;

        const package = downloaded.package;
        const working_dir = downloaded.working_dir;
        try pm.installExtractedPackage(working_dir, package);

        const installed_package = packages_to_uninstall.get(package.name).?;
        try pm.diagnostics.updateSucceeded(.{
            .name = package.name,
            .from_version = installed_package.version,
            .to_version = package.info.version,
        });
    }

    try pm.installed_packages.flush();
}

const DownloadAndExtractJobs = struct {
    jobs: std.ArrayList(DownloadAndExtractJob),

    fn init(options: struct {
        allocator: std.mem.Allocator,
        dir: std.fs.Dir,
        packages: []const Package.Specific,
    }) !DownloadAndExtractJobs {
        var res = DownloadAndExtractJobs{
            .jobs = std.ArrayList(DownloadAndExtractJob).init(options.allocator),
        };
        errdefer res.deinit();

        try res.jobs.ensureTotalCapacity(options.packages.len);
        for (options.packages) |package| {
            var working_dir = try fs.tmpDir(options.dir, .{});
            errdefer working_dir.close();

            res.jobs.appendAssumeCapacity(.{
                .working_dir = working_dir.dir,
                .package = package,
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
    package: Package.Specific,
    working_dir: std.fs.Dir,
    result: DownloadAndExtractReturnType,

    fn run(job: *DownloadAndExtractJob, pm: *PackageManager) void {
        job.result = pm.downloadAndExtractPackage(job.working_dir, job.package);
    }
};

const DiagnosticError = error{
    DiagnosticsDownloadFailed,
    DiagnosticsInvalidHash,
};

test {
    _ = Diagnostics;
    _ = InstalledPackage;
    _ = InstalledPackages;
    _ = Package;
    _ = Packages;
    _ = Progress;

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

const builtin = @import("builtin");
const download = @import("download.zig");
const fs = @import("fs.zig");
const ini = @import("ini.zig");
const paths = @import("paths.zig");
const std = @import("std");
