allocator: std.mem.Allocator,
diag: *Diagnostics,
progress: *Progress,

pkgs_ini_path: []const u8,
pkgs_dir_path: []const u8,
packages: Packages,

pub fn init(options: Options) !TestingPackageRepository {
    const allocator = options.allocator;

    const diag = try allocator.create(Diagnostics);
    errdefer allocator.destroy(diag);
    diag.* = Diagnostics.init(allocator);

    // Progress is required, but these tests don't test it. Just set maximum_node to 0, so that
    // nothing is allocatated or progressed on.
    const progress = try allocator.create(Progress);
    errdefer allocator.destroy(progress);
    progress.* = try Progress.init(.{
        .allocator = allocator,
        .maximum_node_name_len = 0,
        .maximum_nodes = 0,
    });

    const prefix_path = try fs.zigCacheTmpDirPath(allocator);
    defer allocator.free(prefix_path);

    const pkgs_ini_path = try std.fs.path.join(allocator, &.{
        prefix_path,
        paths.own_data_subpath,
        paths.pkgs_file_name,
    });
    errdefer allocator.free(pkgs_ini_path);

    const pkgs_dir_path = try std.fs.path.join(allocator, &.{ prefix_path, "pkgs" });
    errdefer allocator.free(pkgs_dir_path);

    const cwd = std.fs.cwd();
    var pkgs_dir = try cwd.makeOpenPath(pkgs_dir_path, .{});
    defer pkgs_dir.close();

    var pkgs_ini_dir, const pkgs_ini_file = fs.createDirAndFile(cwd, pkgs_ini_path, .{
        .file = .{ .exclusive = true },
    });
    defer pkgs_ini_dir.close();
    defer pkgs_ini_file.close();

    var buffered_pkg_ini_file = std.io.bufferedWriter(pkgs_ini_file.writer());
    const pkgs_ini_writer = buffered_pkg_ini_file.writer();

    for (options.packages, 0..) |package, i| {
        if (package.file.content) |content|
            try pkgs_dir.writeFile(.{
                .sub_path = package.file.name,
                .data = content,
                .flags = .{ .exclusive = true },
            });

        if (i != 0) try pkgs_ini_writer.writeAll("\n");

        try pkgs_ini_writer.print("[{s}.info]\n", .{package.name});
        try pkgs_ini_writer.print("version = {s}\n\n", .{package.version});

        try pkgs_ini_writer.print("[{s}.update]\n", .{package.name});
        try pkgs_ini_writer.print("github = {s}\n\n", .{package.github_update});

        try pkgs_ini_writer.print("[{s}.linux_x86_64]\n", .{package.name});

        for (package.install_bin) |install_bin|
            try pkgs_ini_writer.print("install_bin = {s}\n", .{install_bin});
        for (package.install_lib) |install_lib|
            try pkgs_ini_writer.print("install_lib = {s}\n", .{install_lib});
        for (package.install_share) |install_share|
            try pkgs_ini_writer.print("install_share = {s}\n", .{install_share});

        try pkgs_ini_writer.print("url = file://{s}/{s}\n", .{ pkgs_dir_path, package.file.name });
        try pkgs_ini_writer.print("hash = {s}\n", .{package.file.hash});
    }

    try buffered_pkg_ini_file.flush();

    var packages = try Packages.download(.{
        .allocator = allocator,
        .diagnostics = diag,
        .progress = progress,
        .prefix = prefix_path,
        .download = .only_if_required,

        // Will never download in tests
        .http_client = undefined,
        .pkgs_uri = undefined,
    });
    errdefer packages.deinit();

    return .{
        .allocator = allocator,
        .diag = diag,
        .progress = progress,
        .pkgs_ini_path = pkgs_ini_path,
        .pkgs_dir_path = pkgs_dir_path,
        .packages = packages,
    };
}

pub const Options = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    packages: []const Package,
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    github_update: []const u8,
    file: File,
    install_bin: []const []const u8 = &.{},
    install_lib: []const []const u8 = &.{},
    install_share: []const []const u8 = &.{},

    const File = struct {
        name: []const u8,
        hash: []const u8,
        content: ?[]const u8,
    };
};

test {
    _ = Diagnostics;
    _ = Packages;
    _ = Progress;

    _ = fs;
    _ = paths;
}

const TestingPackageRepository = @This();

const Diagnostics = @import("Diagnostics.zig");
const Packages = @import("Packages.zig");
const Progress = @import("Progress.zig");

const fs = @import("fs.zig");
const paths = @import("paths.zig");
const std = @import("std");
