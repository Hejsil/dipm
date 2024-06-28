pm: PackageManager,

pub fn init(options: Options) !TestingPackageManager {
    const allocator = options.allocator;

    const pkgs_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{options.pkgs_ini_path});
    defer allocator.free(pkgs_uri);

    const random_prefix_path = try testing.tmpDirPath(allocator);
    defer allocator.free(random_prefix_path);

    var pm = try PackageManager.init(.{
        .allocator = allocator,
        .prefix = if (options.prefix) |prefix| prefix else random_prefix_path,
        .arch = .x86_64,
        .os = .linux,
        .pkgs_uri = pkgs_uri,
        .update_frequecy = 0,
    });
    errdefer pm.deinit();

    return .{ .pm = pm };
}

pub fn expectFile(pm: TestingPackageManager, path: []const u8, expected_content: []const u8) !void {
    const content = try pm.pm.prefix_dir.readFileAlloc(std.testing.allocator, path, std.math.maxInt(usize));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings(expected_content, content);
}

pub fn expectNoFile(pm: TestingPackageManager, path: []const u8) !void {
    const err_file = pm.pm.prefix_dir.openFile(path, .{});
    defer if (err_file) |file| file.close() else |_| {};

    try std.testing.expectError(error.FileNotFound, err_file);
}

pub fn expectDir(pm: TestingPackageManager, path: []const u8) !void {
    var dir = try pm.pm.prefix_dir.openDir(path, .{});
    defer dir.close();
}

pub fn expectNoDir(pm: TestingPackageManager, path: []const u8) !void {
    var err_dir = pm.pm.prefix_dir.openDir(path, .{});
    defer if (err_dir) |*dir| dir.close() else |_| {};

    try std.testing.expectError(error.FileNotFound, err_dir);
}

pub fn cleanup(pm: *TestingPackageManager) !void {
    try std.fs.cwd().deleteTree(pm.pm.prefix_path);
}

pub fn deinit(pm: *TestingPackageManager) void {
    pm.pm.deinit();
    pm.* = undefined;
}

const Options = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    pkgs_ini_path: []const u8,
    prefix: ?[]const u8 = null,
};

const TestingPackageManager = @This();

const PackageManager = @import("PackageManager.zig");
const std = @import("std");
const testing = @import("testing.zig");
