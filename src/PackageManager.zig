gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,

http_client: *std.http.Client,
installed_file: IniFile(InstalledPackages),

diagnostics: *Diagnostics,
progress: *Progress,

os: std.Target.Os.Tag,
arch: std.Target.Cpu.Arch,

prefix_path: []const u8,
prefix_dir: std.fs.Dir,
bin_dir: std.fs.Dir,
lib_dir: std.fs.Dir,
share_dir: std.fs.Dir,

own_data_dir: std.fs.Dir,
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

    var own_data_dir = try prefix_dir.makeOpenPath(paths.own_data_subpath, .{});
    errdefer own_data_dir.close();

    var own_tmp_dir = try prefix_dir.makeOpenPath(paths.own_tmp_subpath, .{
        .iterate = true,
    });
    errdefer own_tmp_dir.close();

    var installed_file = try IniFile(InstalledPackages).create(allocator, own_data_dir, paths.installed_file_name);
    errdefer installed_file.close();

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
        .own_data_dir = own_data_dir,
        .own_tmp_dir = own_tmp_dir,
        .installed_file = installed_file,
    };
}

pub const Options = struct {
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,

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
    pm.own_data_dir.close();
    pm.prefix_dir.close();
    pm.share_dir.close();

    pm.installed_file.close();

    pm.arena.deinit();
}

pub fn isInstalled(pm: *const PackageManager, package_name: []const u8) bool {
    return pm.installed_file.data.packages.contains(package_name);
}

pub fn installOne(pm: *PackageManager, packages: Packages, package_name: []const u8) !void {
    return pm.installMany(packages, &.{package_name});
}

pub fn installMany(pm: *PackageManager, packages: Packages, package_names: []const []const u8) !void {
    var packages_to_install = try pm.packagesToInstall(packages, package_names);
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

    try pm.installed_file.flush();
}

fn packagesToInstall(
    pm: *const PackageManager,
    packages: Packages,
    package_names: []const []const u8,
) !std.StringArrayHashMap(Package.Specific) {
    var packages_to_install = std.StringArrayHashMap(Package.Specific).init(pm.gpa);
    errdefer packages_to_install.deinit();

    // First, deduplicate. The value is undefined and set later
    try packages_to_install.ensureTotalCapacity(package_names.len);
    for (package_names) |package_name|
        packages_to_install.putAssumeCapacity(package_name, undefined);

    // Now, populate. The packages that dont exist gets removed here.
    for (packages_to_install.keys(), packages_to_install.values(), 0..) |package_name, *entry, i| {
        entry.* = blk: {
            const package = packages.packages.get(package_name) orelse break :blk null;
            break :blk package.specific(package_name, pm.os, pm.arch);
        } orelse {
            try pm.diagnostics.notFound(.{
                .name = package_name,
                .os = pm.os,
                .arch = pm.arch,
            });
            packages_to_install.swapRemoveAt(i);
            continue;
        };
    }

    return packages_to_install;
}

const DownloadAndExtractReturnType = @typeInfo(@TypeOf(downloadAndExtractPackage)).Fn.return_type.?;

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

    const download_result = download.download(
        pm.http_client,
        package.install.url,
        progress,
        downloaded_file.writer(),
    ) catch |err| {
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
    const installed_arena = pm.installed_file.data.arena.allocator();
    var locations = std.ArrayList([]const u8).init(installed_arena);
    defer locations.deinit();

    for (package.install.bin) |install_field| {
        const the_install = Install.fromString(install_field);
        try installBin(the_install, from_dir, pm.bin_dir);
        try locations.append(try std.fs.path.join(installed_arena, &.{
            pm.prefix_path,
            paths.bin_subpath,
            the_install.to,
        }));
    }
    for (package.install.lib) |install_field| {
        const the_install = Install.fromString(install_field);
        try installGeneric(the_install, from_dir, pm.lib_dir);
        try locations.append(try std.fs.path.join(installed_arena, &.{
            pm.prefix_path,
            paths.lib_subpath,
            the_install.to,
        }));
    }
    for (package.install.share) |install_field| {
        const the_install = Install.fromString(install_field);
        try installGeneric(the_install, from_dir, pm.share_dir);
        try locations.append(try std.fs.path.join(installed_arena, &.{
            pm.prefix_path,
            paths.share_subpath,
            the_install.to,
        }));
    }

    // Caller ensures that package is not installed
    const installed_key = try installed_arena.dupe(u8, package.name);
    try pm.installed_file.data.packages.putNoClobber(installed_arena, installed_key, .{
        .version = try installed_arena.dupe(u8, package.info.version),
        .locations = try locations.toOwnedSlice(),
    });
}

fn installBin(the_install: Install, from_dir: std.fs.Dir, to_dir: std.fs.Dir) !void {
    try from_dir.copyFile(the_install.from, to_dir, the_install.to, .{});

    const installed_file = try to_dir.openFile(the_install.to, .{});
    defer installed_file.close();

    const metadata = try installed_file.metadata();
    var permissions = metadata.permissions();
    permissions.inner.unixSet(.user, .{ .execute = true });
    try installed_file.setPermissions(permissions);
}

fn installGeneric(the_install: Install, from_dir: std.fs.Dir, to_dir: std.fs.Dir) !void {
    const stat = try from_dir.statFile(the_install.from);

    switch (stat.kind) {
        .directory => {
            try to_dir.makeDir(the_install.to);

            var child_from_dir = try from_dir.openDir(the_install.from, .{ .iterate = true });
            defer child_from_dir.close();
            var child_to_dir = try to_dir.openDir(the_install.to, .{});
            defer child_to_dir.close();

            try copyTree(child_from_dir, child_to_dir);
        },
        .sym_link, .file => try from_dir.copyFile(the_install.from, to_dir, the_install.to, .{}),

        .block_device,
        .character_device,
        .named_pipe,
        .unix_domain_socket,
        .whiteout,
        .door,
        .event_port,
        .unknown,
        => return error.Unknown,
    }
}

fn copyTree(from_dir: std.fs.Dir, to_dir: std.fs.Dir) !void {
    var iter = from_dir.iterate();
    while (try iter.next()) |entry| switch (entry.kind) {
        .directory => {
            try to_dir.makeDir(entry.name);

            var child_from_dir = try from_dir.openDir(entry.name, .{ .iterate = true });
            defer child_from_dir.close();
            var child_to_dir = try to_dir.openDir(entry.name, .{});
            defer child_to_dir.close();

            try copyTree(child_from_dir, child_to_dir);
        },
        .file => try from_dir.copyFile(entry.name, to_dir, entry.name, .{}),

        .sym_link,
        .block_device,
        .character_device,
        .named_pipe,
        .unix_domain_socket,
        .whiteout,
        .door,
        .event_port,
        .unknown,
        => return error.Unknown,
    };
}

const Install = struct {
    from: []const u8,
    to: []const u8,

    pub fn fromString(string: []const u8) Install {
        if (std.mem.indexOfScalar(u8, string, ':')) |colon_index| {
            return .{
                .to = string[0..colon_index],
                .from = string[colon_index + 1 ..],
            };
        } else {
            return .{
                .to = std.fs.path.basename(string),
                .from = string,
            };
        }
    }
};

pub fn uninstallOne(pm: *PackageManager, package_name: []const u8) !void {
    return pm.uninstallMany(&.{package_name});
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

    try pm.installed_file.flush();
}

fn packagesToUninstall(
    pm: *PackageManager,
    package_names: []const []const u8,
) !std.StringArrayHashMap(InstalledPackage) {
    var packages_to_uninstall = std.StringArrayHashMap(InstalledPackage).init(pm.gpa);
    errdefer packages_to_uninstall.deinit();

    try packages_to_uninstall.ensureTotalCapacity(package_names.len);
    for (package_names) |package_name| {
        const package = pm.installed_file.data.packages.get(package_name) orelse {
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

    _ = pm.installed_file.data.packages.orderedRemove(package_name);
}

pub fn updateAll(pm: *PackageManager, packages: Packages) !void {
    const installed_packages = pm.installed_file.data.packages.keys();
    const packages_to_update = try pm.gpa.dupe([]const u8, installed_packages);
    defer pm.gpa.free(packages_to_update);

    return pm.updatePackages(packages, packages_to_update, .{
        .up_to_date_diag = false,
    });
}

pub fn updateOne(pm: *PackageManager, packages: Packages, package_name: []const u8) !void {
    return pm.updateMany(packages, &.{package_name});
}

pub fn updateMany(pm: *PackageManager, packages: Packages, package_names: []const []const u8) !void {
    return pm.updatePackages(packages, package_names, .{
        .up_to_date_diag = true,
    });
}

const UpdatePackagesOptions = struct {
    up_to_date_diag: bool,
};

fn updatePackages(
    pm: *PackageManager,
    packages: Packages,
    package_names: []const []const u8,
    opt: UpdatePackagesOptions,
) !void {
    if (package_names.len == 0)
        return;

    var packages_to_uninstall = try pm.packagesToUninstall(package_names);
    defer packages_to_uninstall.deinit();

    var packages_to_install = try pm.packagesToInstall(packages, packages_to_uninstall.keys());
    defer packages_to_install.deinit();

    // Remove up to date packages from the list
    for (
        packages_to_uninstall.keys(),
        packages_to_uninstall.values(),
    ) |package_name, installed_package| {
        const updated_package = packages_to_install.get(package_name) orelse continue;
        if (!std.mem.eql(u8, installed_package.version, updated_package.info.version))
            continue;

        _ = packages_to_install.swapRemove(package_name);
        if (opt.up_to_date_diag)
            try pm.diagnostics.upToDate(.{
                .name = package_name,
                .version = installed_package.version,
            });
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

    try pm.installed_file.flush();
}

const DownloadAndExtractJobs = struct {
    jobs: std.ArrayList(DownloadAndExtractJob),

    fn init(args: struct {
        allocator: std.mem.Allocator,
        dir: std.fs.Dir,
        packages: []const Package.Specific,
    }) !DownloadAndExtractJobs {
        var res = DownloadAndExtractJobs{
            .jobs = std.ArrayList(DownloadAndExtractJob).init(args.allocator),
        };
        errdefer res.deinit();

        try res.jobs.ensureTotalCapacity(args.packages.len);
        for (args.packages) |package| {
            var working_dir = try fs.tmpDir(args.dir, .{});
            errdefer working_dir.close();

            res.jobs.appendAssumeCapacity(.{
                .working_dir = working_dir,
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

pub fn IniFile(comptime T: type) type {
    return struct {
        file: std.fs.File,
        data: T,

        pub fn open(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !@This() {
            const file = try dir.openFile(name, .{});
            errdefer file.close();

            return fromFile(allocator, file);
        }

        pub fn create(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !@This() {
            const file = try dir.createFile(name, .{ .read = true, .truncate = false });
            errdefer file.close();

            return fromFile(allocator, file);
        }

        pub fn fromFile(allocator: std.mem.Allocator, file: std.fs.File) !@This() {
            const data_str = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(data_str);

            const data = try T.parse(allocator, data_str);
            errdefer data.deinit();

            return @This(){ .file = file, .data = data };
        }

        pub fn flush(file: @This()) !void {
            try file.file.seekTo(0);

            var buffered_file = std.io.bufferedWriter(file.file.writer());
            try file.data.write(buffered_file.writer());
            try buffered_file.flush();

            try file.file.setEndPos(try file.file.getPos());
        }

        pub fn close(file: *@This()) void {
            file.file.close();
            file.data.deinit();
        }
    };
}

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

    _ = @import("PackageManager.tests.zig");
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
