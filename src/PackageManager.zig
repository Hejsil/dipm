gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,

http_client: std.http.Client,

os: std.Target.Os.Tag,
arch: std.Target.Cpu.Arch,

prefix_path: []const u8,
prefix_dir: std.fs.Dir,
bin_dir: std.fs.Dir,
lib_dir: std.fs.Dir,
share_dir: std.fs.Dir,

own_data_dir: std.fs.Dir,
own_tmp_dir: std.fs.Dir,

pkgs_file: IniFile(Packages),
installed_file: IniFile(InstalledPackages),

diagnostics: ?*Diagnostics,

pub fn init(options: Options) !PackageManager {
    const allocator = options.allocator;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    const arena = arena_state.allocator();
    errdefer arena_state.deinit();

    const cwd = std.fs.cwd();
    var prefix_dir = try cwd.makeOpenPath(options.prefix, .{});
    errdefer prefix_dir.close();

    const prefix_path = try prefix_dir.realpathAlloc(arena, ".");

    var bin_dir = try prefix_dir.makeOpenPath(bin_subpath, .{});
    errdefer bin_dir.close();

    var lib_dir = try prefix_dir.makeOpenPath(lib_subpath, .{});
    errdefer lib_dir.close();

    var share_dir = try prefix_dir.makeOpenPath(share_subpath, .{});
    errdefer share_dir.close();

    var own_data_dir = try prefix_dir.makeOpenPath(own_data_subpath, .{});
    errdefer own_data_dir.close();

    var own_tmp_dir = try prefix_dir.makeOpenPath(own_tmp_subpath, .{});
    errdefer own_tmp_dir.close();

    var http_client = std.http.Client{ .allocator = allocator };
    errdefer http_client.deinit();

    try http_client.initDefaultProxies(allocator);

    if (try isPkgIniOutOfDate(own_data_dir, options.update_frequecy))
        try downloadPkgsIni(&http_client, own_data_dir, options.pkgs_uri);

    var pkgs_file = try IniFile(Packages).open(allocator, own_data_dir, pkgs_file_name);
    errdefer pkgs_file.close();

    var installed_file = try IniFile(InstalledPackages).create(allocator, own_data_dir, installed_file_name);
    errdefer installed_file.close();

    return PackageManager{
        .gpa = allocator,
        .arena = arena_state,
        .http_client = http_client,
        .os = options.os,
        .arch = options.arch,
        .prefix_path = prefix_path,
        .prefix_dir = prefix_dir,
        .bin_dir = bin_dir,
        .lib_dir = lib_dir,
        .share_dir = share_dir,
        .own_data_dir = own_data_dir,
        .own_tmp_dir = own_tmp_dir,
        .pkgs_file = pkgs_file,
        .installed_file = installed_file,
        .diagnostics = options.diagnostics,
    };
}

fn downloadPkgsIni(client: *std.http.Client, dir: std.fs.Dir, uri: []const u8) !void {
    const pkgs_file = try dir.createFile(pkgs_file_name, .{});
    defer pkgs_file.close();
    try download(client, uri, pkgs_file.writer());
}

fn isPkgIniOutOfDate(dir: std.fs.Dir, update_frequency: i128) !bool {
    const pkgs_file = dir.openFile(pkgs_file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => |e| return e,
    };
    defer pkgs_file.close();

    const metadata = try pkgs_file.metadata();
    const modified = metadata.modified();
    const now = std.time.nanoTimestamp();
    return modified + update_frequency < now;
}

pub fn isInstalled(pm: PackageManager, package_name: []const u8) bool {
    return pm.installed_file.data.packages.contains(package_name);
}

pub fn installOne(pm: *PackageManager, package_name: []const u8) !void {
    return pm.installMany(&.{package_name});
}

pub fn installMany(pm: *PackageManager, package_names: []const []const u8) !void {
    var packages_to_install = try pm.packagesToInstall(package_names);
    defer packages_to_install.deinit();

    const len = packages_to_install.count();
    for (0..len) |i_forward| {
        const i_backwards = len - (i_forward + 1);
        const package = packages_to_install.values()[i_backwards];

        if (pm.isInstalled(package.name)) {
            if (pm.diagnostics) |diag|
                try diag.alreadyInstalled(.{ .name = package.name });
            _ = packages_to_install.swapRemoveAt(i_backwards);
        }
    }

    for (packages_to_install.values()) |package| {
        pm.installOneUnchecked(package) catch |err| switch (err) {
            error.DiagnosticsInvalidHash => continue,
            error.DiagnosticsDownloadFailed => continue,
            else => |e| return e,
        };

        if (pm.diagnostics) |diag|
            try diag.installSucceeded(.{
                .name = package.name,
                .version = package.info.version,
            });
    }

    try pm.installed_file.flush();
}

fn packagesToInstall(
    pm: *PackageManager,
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
            const package = pm.pkgs_file.data.packages.get(package_name) orelse break :blk null;
            break :blk package.specific(package_name, pm.os, pm.arch);
        } orelse {
            if (pm.diagnostics) |diag|
                try diag.notFound(.{
                    .name = package_name,
                    .os = pm.os,
                    .arch = pm.arch,
                });
            packages_to_install.swapRemoveAt(i);
            continue;
        };
    }

    // TODO: Check package.install.hash conflicts

    return packages_to_install;
}

fn installOneUnchecked(pm: *PackageManager, package: Package.Specific) !void {
    var working_dir = try pm.own_tmp_dir.makeOpenPath(package.install.hash, .{});
    defer working_dir.close();

    try pm.downloadAndExtractPackage(working_dir, package);
    try pm.installExtractedPackage(working_dir, package);
}

fn downloadAndExtractPackage(pm: *PackageManager, dir: std.fs.Dir, package: Package.Specific) !void {
    const downloaded_file_name = std.fs.path.basename(package.install.url);

    const downloaded_file = try dir.createFile(downloaded_file_name, .{
        .read = true,
    });
    defer downloaded_file.close();

    // TODO: Get rid of this once we have support for bz2 compression
    const downloaded_path = try dir.realpathAlloc(pm.gpa, downloaded_file_name);
    defer pm.gpa.free(downloaded_path);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var hashing_writer = std.compress.hashedWriter(downloaded_file.writer(), &hasher);
    download(&pm.http_client, package.install.url, hashing_writer.writer()) catch |err| {
        if (pm.diagnostics) |diag| try diag.downloadFailed(.{
            .name = package.name,
            .version = package.info.version,
            .url = package.install.url,
            .err = err,
        });
        return error.DiagnosticsDownloadFailed;
    };

    const digest_length = std.crypto.hash.sha2.Sha256.digest_length;
    var actual_hash_bytes: [digest_length]u8 = undefined;
    hasher.final(&actual_hash_bytes);

    const actual_hash = std.fmt.bytesToHex(actual_hash_bytes, .lower);

    if (!std.mem.eql(u8, package.install.hash, &actual_hash)) {
        if (pm.diagnostics) |diag| try diag.hashMismatch(.{
            .name = package.name,
            .version = package.info.version,
            .expected_hash = package.install.hash,
            .actual_hash = &actual_hash,
        });
        return error.DiagnosticsInvalidHash;
    }

    const file_type = FileType.fromPath(downloaded_file_name);
    if (file_type != .binary) {
        try downloaded_file.seekTo(0);

        const output_path = FileType.stripPath(downloaded_file_name);
        try extract(pm.gpa, downloaded_path, downloaded_file, file_type, dir, output_path);
    }
}

fn installExtractedPackage(pm: *PackageManager, from_dir: std.fs.Dir, package: Package.Specific) !void {
    const installed_arena = pm.installed_file.data.arena.allocator();
    var locations = std.ArrayList([]const u8).init(installed_arena);
    defer locations.deinit();

    for (package.install.bin) |install_field| {
        const the_install = Install.fromString(install_field);
        try installBin(the_install, from_dir, pm.bin_dir);
        try locations.append(try std.fs.path.join(installed_arena, &.{
            pm.prefix_path,
            bin_subpath,
            the_install.to,
        }));
    }
    for (package.install.lib) |install_field| {
        const the_install = Install.fromString(install_field);
        try installGeneric(the_install, from_dir, pm.lib_dir);
        try locations.append(try std.fs.path.join(installed_arena, &.{
            pm.prefix_path,
            lib_subpath,
            the_install.to,
        }));
    }
    for (package.install.share) |install_field| {
        const the_install = Install.fromString(install_field);
        try installGeneric(the_install, from_dir, pm.share_dir);
        try locations.append(try std.fs.path.join(installed_arena, &.{
            pm.prefix_path,
            share_subpath,
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

fn extract(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    file: std.fs.File,
    file_type: FileType,
    out_dir: std.fs.Dir,
    out_name: []const u8,
) !void {
    const tar_pipe_options = std.tar.PipeOptions{ .exclude_empty_directories = true };
    switch (file_type) {
        .tar_bz2 => {
            // TODO: For now we bail out to an external program for tar.bz2 files.
            //       This makes dipm not self contained, which kinda defeats the points
            const out_path = try out_dir.realpathAlloc(allocator, ".");
            defer allocator.free(out_path);

            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "tar", "-xvf", file_path, "-C", out_path },
            });
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        },
        .tar_gz => {
            var buffered_reader = std.io.bufferedReader(file.reader());
            var decomp = std.compress.gzip.decompressor(buffered_reader.reader());
            try std.tar.pipeToFileSystem(out_dir, decomp.reader(), tar_pipe_options);
        },
        .tar_zst => {
            var buffered_reader = std.io.bufferedReader(file.reader());
            var window_buffer: [std.compress.zstd.DecompressorOptions.default_window_buffer_len]u8 = undefined;
            var decomp = std.compress.zstd.decompressor(buffered_reader.reader(), .{
                .window_buffer = &window_buffer,
            });
            try std.tar.pipeToFileSystem(out_dir, decomp.reader(), tar_pipe_options);
        },
        .tar_xz => {
            var buffered_reader = std.io.bufferedReader(file.reader());
            var decomp = try std.compress.xz.decompress(allocator, buffered_reader.reader());
            defer decomp.deinit();
            try std.tar.pipeToFileSystem(out_dir, decomp.reader(), tar_pipe_options);
        },
        .gz => {
            const out_file = try out_dir.createFile(out_name, .{});
            defer out_file.close();

            var buffered_reader = std.io.bufferedReader(file.reader());
            var decomp = std.compress.gzip.decompressor(buffered_reader.reader());
            var buf: [std.mem.page_size]u8 = undefined;
            while (true) {
                const len = try decomp.reader().read(&buf);
                if (len == 0)
                    break;
                try out_file.writeAll(buf[0..len]);
            }
        },
        .tar => {
            var buffered_reader = std.io.bufferedReader(file.reader());
            try std.tar.pipeToFileSystem(out_dir, buffered_reader.reader(), tar_pipe_options);
        },
        .zip => {
            try std.zip.extract(out_dir, file.seekableStream(), .{});
        },
        .binary => {},
    }
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
        if (pm.diagnostics) |diag|
            try diag.uninstallSucceeded(.{
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
            if (pm.diagnostics) |diag| try diag.notInstalled((.{
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

pub fn updateAll(pm: *PackageManager) !void {
    const installed_packages = pm.installed_file.data.packages.keys();
    const packages_to_update = try pm.gpa.dupe([]const u8, installed_packages);
    defer pm.gpa.free(packages_to_update);

    return pm.updateMany(packages_to_update);
}

pub fn updateOne(pm: *PackageManager, package_name: []const u8) !void {
    return pm.updateMany(&.{package_name});
}

pub fn updateMany(pm: *PackageManager, package_names: []const []const u8) !void {
    var packages_to_uninstall = try pm.packagesToUninstall(package_names);
    defer packages_to_uninstall.deinit();

    var packages_to_install = try pm.packagesToInstall(packages_to_uninstall.keys());
    defer packages_to_install.deinit();

    // TODO: Only update out of date packages

    // TODO: The steps for this should be
    //       * Download and extract packages to install
    //       * Uninstall installed packages
    //       * Install the updated packages

    var successfull_uninstalls = std.ArrayList(Package.Specific).init(pm.gpa);
    defer successfull_uninstalls.deinit();

    try successfull_uninstalls.ensureTotalCapacity(packages_to_install.count());
    for (packages_to_install.values()) |package| {
        const installed_package = packages_to_uninstall.get(package.name).?;
        try pm.uninstallOneUnchecked(package.name, installed_package);
        successfull_uninstalls.appendAssumeCapacity(package);
    }

    for (successfull_uninstalls.items) |package| {
        pm.installOneUnchecked(package) catch |err| switch (err) {
            error.DiagnosticsInvalidHash => continue,
            error.DiagnosticsDownloadFailed => continue,
            else => |e| return e,
        };

        if (pm.diagnostics) |diag| {
            const installed_package = packages_to_uninstall.get(package.name).?;
            try diag.updateSucceeded(.{
                .name = package.name,
                .from_version = installed_package.version,
                .to_version = package.info.version,
            });
        }
    }

    try pm.installed_file.flush();
}

pub fn cleanup(pm: PackageManager) !void {
    try pm.prefix_dir.deleteTree(own_tmp_subpath);
}

pub fn deinit(pm: *PackageManager) void {
    pm.bin_dir.close();
    pm.lib_dir.close();
    pm.share_dir.close();
    pm.own_data_dir.close();

    pm.pkgs_file.close();
    pm.installed_file.close();

    pm.prefix_dir.close();

    pm.http_client.deinit();
    pm.arena.deinit();
}

fn download(client: *std.http.Client, uri_str: []const u8, writer: anytype) !void {
    const uri = try std.Uri.parse(uri_str);
    if (std.mem.eql(u8, uri.scheme, "file")) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{raw}", .{uri.path});
        const file = try std.fs.cwd().openFile(path, .{});
        return pipe(file.reader(), writer);
    }

    var header_buffer: [std.mem.page_size]u8 = undefined;
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
    });
    defer request.deinit();

    try request.send();
    try request.wait();

    if (request.response.status != .ok)
        return error.HttpServerRepliedWithUnsucessfulResponse;

    return pipe(request.reader(), writer);
}

fn pipe(reader: anytype, writer: anytype) !void {
    var buf: [std.mem.page_size]u8 = undefined;
    while (true) {
        const len = try reader.read(&buf);
        if (len == 0)
            break;

        try writer.writeAll(buf[0..len]);
    }
}

const Options = struct {
    allocator: std.mem.Allocator,

    /// Successes and failures are reported to the diagnostics. Set this for more details
    /// about failures.
    diagnostics: ?*Diagnostics = null,

    /// The prefix path where the package manager will work and install packages
    prefix: []const u8,

    arch: std.Target.Cpu.Arch = builtin.cpu.arch,
    os: std.Target.Os.Tag = builtin.os.tag,

    /// The URI where the package manager will download the pkgs.ini
    pkgs_uri: []const u8 = "https://github.com/Hejsil/dipm-pkgs/raw/master/pkgs.ini",
    update_frequecy: i128 = std.time.ns_per_day,
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

const FileType = enum {
    tar_bz2,
    tar_gz,
    tar_xz,
    tar_zst,
    gz,
    tar,
    zip,
    binary,

    pub const extension_filetype_map = [_]struct { ext: []const u8, file_type: FileType }{
        .{ .ext = ".tar.bz2", .file_type = .tar_bz2 },
        .{ .ext = ".tar.gz", .file_type = .tar_gz },
        .{ .ext = ".tar.xz", .file_type = .tar_xz },
        .{ .ext = ".tar.zst", .file_type = .tar_zst },
        .{ .ext = ".tbz", .file_type = .tar_bz2 },
        .{ .ext = ".tgz", .file_type = .tar_gz },
        .{ .ext = ".tar", .file_type = .tar },
        .{ .ext = ".zip", .file_type = .zip },
        .{ .ext = ".gz", .file_type = .gz },
    };

    pub fn fromPath(path: []const u8) FileType {
        for (extension_filetype_map) |entry| {
            if (std.mem.endsWith(u8, path, entry.ext))
                return entry.file_type;
        }

        return .binary;
    }

    pub fn stripPath(path: []const u8) []const u8 {
        for (extension_filetype_map) |entry| {
            if (std.mem.endsWith(u8, path, entry.ext))
                return path[0 .. path.len - entry.ext.len];
        }

        return path;
    }
};

const bin_subpath = "bin";
const lib_subpath = "lib";
const own_data_subpath = "share/dipm";
const own_tmp_subpath = "share/dipm/tmp";
const share_subpath = "share";

const installed_file_name = "installed.ini";
const pkgs_file_name = "pkgs.ini";

test {
    _ = Diagnostics;
    _ = InstalledPackage;
    _ = InstalledPackages;
    _ = Package;
    _ = Packages;

    _ = ini;

    _ = @import("PackageManager.tests.zig");
}

const PackageManager = @This();

const Diagnostics = @import("Diagnostics.zig");
const InstalledPackage = @import("InstalledPackage.zig");
const InstalledPackages = @import("InstalledPackages.zig");
const Package = @import("Package.zig");
const Packages = @import("Packages.zig");

const builtin = @import("builtin");
const ini = @import("ini.zig");
const std = @import("std");
