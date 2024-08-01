pm: PackageManager,
diag: *Diagnostics,

pub fn init(options: Options) !TestingPackageManager {
    const allocator = options.allocator;

    const random_prefix_path = try fs.zigCacheTmpDirPath(allocator);
    defer allocator.free(random_prefix_path);

    const diag = try allocator.create(Diagnostics);
    errdefer allocator.destroy(diag);
    diag.* = Diagnostics.init(allocator);

    const cwd = std.fs.cwd();
    const prefix = if (options.prefix) |prefix| prefix else random_prefix_path;
    if (options.installed_file_data) |installed_file_data| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const installed_path = try std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{
            prefix,
            paths.own_data_subpath,
            paths.installed_file_name,
        });

        try cwd.makePath(std.fs.path.dirname(installed_path) orelse ".");
        try cwd.writeFile(.{
            .sub_path = installed_path,
            .data = installed_file_data,
        });
    }

    const installed_pkgs = try allocator.create(InstalledPackages);
    errdefer allocator.destroy(installed_pkgs);

    installed_pkgs.* = try InstalledPackages.open(.{
        .allocator = allocator,
        .tmp_allocator = allocator,
        .prefix = prefix,
    });
    errdefer installed_pkgs.deinit();

    var pm = try PackageManager.init(.{
        .allocator = allocator,
        .packages = options.packages,
        .installed_packages = installed_pkgs,
        .diagnostics = diag,
        .progress = &Progress.dummy,
        .prefix = prefix,
        .arch = .x86_64,
        .os = .linux,
    });
    errdefer pm.deinit();

    return .{
        .pm = pm,
        .diag = diag,
    };
}

pub const Options = struct {
    packages: *const Packages,

    allocator: std.mem.Allocator = std.testing.allocator,
    prefix: ?[]const u8 = null,
    installed_file_data: ?[]const u8 = null,
};

pub fn deinit(pm: *TestingPackageManager) void {
    const allocator = pm.pm.gpa;
    pm.pm.installed_packages.deinit();
    allocator.destroy(pm.pm.installed_packages);

    pm.diag.deinit();
    allocator.destroy(pm.diag);

    pm.pm.deinit();

    pm.* = undefined;
}

pub fn cleanup(pm: *TestingPackageManager) !void {
    try std.fs.cwd().deleteTree(pm.pm.prefix_path);
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

pub fn expectEmptyDir(pm: TestingPackageManager, path: []const u8) !void {
    var dir = pm.pm.prefix_dir.openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close();

    var it = dir.iterate();
    try std.testing.expect((try it.next()) == null);
}

pub fn expectDiagnostics(pm: TestingPackageManager, expected: []const u8) !void {
    var actual = std.ArrayList(u8).init(std.testing.allocator);
    defer actual.deinit();

    try pm.diag.report(actual.writer(), .{
        .escapes = .{
            .green = "<g>",
            .yellow = "<y>",
            .red = "<r>",
            .bold = "<B>",
            .reset = "<R>",
        },
    });
    try std.testing.expectEqualStrings(expected, actual.items);
}

test {
    _ = Diagnostics;
    _ = InstalledPackages;
    _ = PackageManager;
    _ = Packages;
    _ = Progress;

    _ = fs;
    _ = paths;
}

const TestingPackageManager = @This();

const Diagnostics = @import("Diagnostics.zig");
const InstalledPackages = @import("InstalledPackages.zig");
const PackageManager = @import("PackageManager.zig");
const Packages = @import("Packages.zig");
const Progress = @import("Progress.zig");

const fs = @import("fs.zig");
const paths = @import("paths.zig");
const std = @import("std");
