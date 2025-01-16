gpa: std.mem.Allocator,

http_client: std.http.Client,
packages: Packages,
installed_packages: InstalledPackages,

diagnostics: *Diagnostics,
progress: *Progress,

target: Target,

prefix_dir: std.fs.Dir,
bin_dir: std.fs.Dir,
lib_dir: std.fs.Dir,
share_dir: std.fs.Dir,

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

    var own_tmp_dir = try prefix_dir.makeOpenPath(paths.own_tmp_subpath, .{
        .iterate = true,
    });
    errdefer own_tmp_dir.close();

    var http_client = std.http.Client{ .allocator = options.gpa };
    errdefer http_client.deinit();

    var installed_packages = try InstalledPackages.open(.{
        .gpa = options.gpa,
        .prefix = options.prefix,
    });
    errdefer installed_packages.deinit();

    var packages = try Packages.download(.{
        .gpa = options.gpa,
        .http_client = &http_client,
        .diagnostics = options.diagnostics,
        .progress = options.progress,
        .prefix = options.prefix,
        .pkgs_uri = options.pkgs_uri,
        .download = options.download,
    });
    errdefer packages.deinit();

    return PackageManager{
        .gpa = options.gpa,
        .http_client = http_client,
        .diagnostics = options.diagnostics,
        .progress = options.progress,
        .target = options.target,
        .prefix_dir = prefix_dir,
        .bin_dir = bin_dir,
        .lib_dir = lib_dir,
        .share_dir = share_dir,
        .own_tmp_dir = own_tmp_dir,
        .packages = packages,
        .installed_packages = installed_packages,
    };
}

pub const Options = struct {
    gpa: std.mem.Allocator,

    /// Successes and failures are reported to the diagnostics. Set this for more details
    /// about failures.
    diagnostics: *Diagnostics,
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
    pm.packages.deinit();
    pm.installed_packages.deinit();
    pm.bin_dir.close();
    pm.lib_dir.close();
    pm.prefix_dir.close();
    pm.share_dir.close();
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
        .gpa = pm.gpa,
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

        const specific = package.specific(package_name, pm.target) orelse {
            try pm.diagnostics.notFoundForTarget(.{
                .name = package_name,
                .target = pm.target,
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
    pm: *PackageManager,
    dir: std.fs.Dir,
    package: Package.Specific,
) !void {
    const downloaded_file_name = std.fs.path.basename(package.install.url);
    const downloaded_file = try dir.createFile(downloaded_file_name, .{ .read = true });
    defer downloaded_file.close();

    // TODO: Get rid of this once we have support for bz2 compression
    var download_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const downloaded_path = try dir.realpath(downloaded_file_name, &download_path_buf);

    {
        const download_name = try std.fmt.allocPrint(pm.gpa, "↓ {s}", .{package.name});
        defer pm.gpa.free(download_name);

        const download_progress = pm.progress.start(download_name, 1);
        defer pm.progress.end(download_progress);

        const download_result = download.download(downloaded_file.writer(), .{
            .client = &pm.http_client,
            .uri_str = package.install.url,
            .progress = download_progress,
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
    }

    const extract_name = try std.fmt.allocPrint(pm.gpa, "⎋ {s}", .{package.name});
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
    package: Package.Specific,
) !void {
    const gpa = pm.installed_packages.arena.child_allocator;
    const arena = pm.installed_packages.arena.allocator();
    var locations = std.ArrayList([]const u8).init(arena);
    defer locations.deinit();

    try locations.ensureUnusedCapacity(package.install.install_bin.len +
        package.install.install_lib.len +
        package.install.install_share.len);

    // Try to not leave files around if installation fails
    errdefer {
        for (locations.items) |location|
            pm.prefix_dir.deleteTree(location) catch {};
    }

    for (package.install.install_bin) |install_field| {
        const the_install = Package.Install.fromString(install_field);
        const path = try std.fs.path.join(arena, &.{ paths.bin_subpath, the_install.to });
        try installBin(the_install, from_dir, pm.bin_dir);
        locations.appendAssumeCapacity(path);
    }
    for (package.install.install_lib) |install_field| {
        const the_install = Package.Install.fromString(install_field);
        const path = try std.fs.path.join(arena, &.{ paths.lib_subpath, the_install.to });
        try installGeneric(the_install, from_dir, pm.lib_dir);
        locations.appendAssumeCapacity(path);
    }
    for (package.install.install_share) |install_field| {
        const the_install = Package.Install.fromString(install_field);
        const path = try std.fs.path.join(arena, &.{ paths.share_subpath, the_install.to });
        try installGeneric(the_install, from_dir, pm.share_dir);
        locations.appendAssumeCapacity(path);
    }

    // Caller ensures that package is not installed
    const installed_key = try arena.dupe(u8, package.name);
    try pm.installed_packages.packages.putNoClobber(gpa, installed_key, .{
        .version = try arena.dupe(u8, package.info.version),
        .location = try locations.toOwnedSlice(),
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
            .location = package.location,
        });
    }

    return packages_to_uninstall;
}

fn uninstallOneUnchecked(
    pm: *PackageManager,
    package_name: []const u8,
    package: InstalledPackage,
) !void {
    for (package.location) |location|
        try pm.prefix_dir.deleteTree(location);

    _ = pm.installed_packages.packages.orderedRemove(package_name);
}

pub const UpdateOptions = struct {
    force: bool = false,
};

pub fn updateAll(pm: *PackageManager, options: UpdateOptions) !void {
    const installed_packages = pm.installed_packages.packages.keys();
    const packages_to_update = try pm.gpa.dupe([]const u8, installed_packages);
    defer pm.gpa.free(packages_to_update);

    return pm.updatePackages(packages_to_update, .{
        .up_to_date_diag = false,
        .force = options.force,
    });
}

pub fn updateMany(
    pm: *PackageManager,
    package_names: []const []const u8,
    options: UpdateOptions,
) !void {
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
        .gpa = pm.gpa,
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
        gpa: std.mem.Allocator,
        dir: std.fs.Dir,
        packages: []const Package.Specific,
    }) !DownloadAndExtractJobs {
        var res = DownloadAndExtractJobs{
            .jobs = std.ArrayList(DownloadAndExtractJob).init(options.gpa),
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
