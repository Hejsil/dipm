pm: PackageManager,
diag: *Diagnostics,

pub fn init(options: Options) !TestingPackageManager {
    const allocator = options.allocator;

    const random_prefix_path = try testing.tmpDirPath(allocator);
    defer allocator.free(random_prefix_path);

    const diag = try allocator.create(Diagnostics);
    errdefer allocator.destroy(diag);
    diag.* = Diagnostics.init(allocator);

    const prefix = if (options.prefix) |prefix| prefix else random_prefix_path;
    if (options.installed_file_data) |installed_file_data| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const installed_path = try std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{
            prefix,
            paths.own_data_subpath,
            paths.installed_file_name,
        });

        try std.fs.cwd().makePath(std.fs.path.dirname(installed_path) orelse ".");
        try std.fs.cwd().writeFile(.{
            .sub_path = installed_path,
            .data = installed_file_data,
        });
    }

    var pm = try PackageManager.init(.{
        .allocator = allocator,
        .diagnostics = diag,
        .prefix = prefix,
        .arch = .x86_64,
        .os = .linux,
        .packages = options.packages,

        // Will never download in tests
        .http_client = undefined,
    });
    errdefer pm.deinit();

    return .{
        .pm = pm,
        .diag = diag,
    };
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

pub fn cleanup(pm: *TestingPackageManager) !void {
    try std.fs.cwd().deleteTree(pm.pm.prefix_path);
}

pub fn deinit(pm: *TestingPackageManager) void {
    const allocator = pm.pm.gpa;
    pm.diag.deinit();
    pm.pm.deinit();
    allocator.destroy(pm.diag);
    pm.* = undefined;
}

const Options = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    prefix: ?[]const u8 = null,
    installed_file_data: ?[]const u8 = null,
    packages: *const Packages,
};

test {
    _ = Diagnostics;
    _ = PackageManager;
    _ = Packages;

    _ = paths;
    _ = testing;
}

const TestingPackageManager = @This();

const Diagnostics = @import("Diagnostics.zig");
const PackageManager = @import("PackageManager.zig");
const Packages = @import("Packages.zig");

const paths = @import("paths.zig");
const std = @import("std");
const testing = @import("testing.zig");
