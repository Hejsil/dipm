allocator: std.mem.Allocator,

pkgs_ini_path: []const u8,
pkgs_dir_path: []const u8,
packages: Packages,

pub fn init(options: Options) !TestingPackageRepository {
    const allocator = options.allocator;

    const prefix_path = try testing.tmpDirPath(allocator);
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

    if (std.fs.path.dirname(pkgs_ini_path)) |dir_name|
        try cwd.makePath(dir_name);
    const pkgs_ini_file = try cwd.createFile(pkgs_ini_path, .{ .exclusive = true });
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
        .prefix = prefix_path,
        .download = .only_if_required,

        // Will never download in tests
        .http_client = undefined,
        .pkgs_uri = undefined,
    });
    errdefer packages.deinit();

    return .{
        .allocator = allocator,
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
    _ = Packages;

    _ = paths;
    _ = testing;
}

const TestingPackageRepository = @This();

const Packages = @import("Packages.zig");

const paths = @import("paths.zig");
const std = @import("std");
const testing = @import("testing.zig");
