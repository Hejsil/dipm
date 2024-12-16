arena: std.heap.ArenaAllocator,
packages: std.StringArrayHashMapUnmanaged(InstalledPackage),

file: ?std.fs.File,

pub fn open(options: struct {
    gpa: std.mem.Allocator,
    tmp_gpa: ?std.mem.Allocator = null,
    prefix: []const u8,
}) !InstalledPackages {
    const cwd = std.fs.cwd();
    var prefix_dir = try cwd.makeOpenPath(options.prefix, .{});
    defer prefix_dir.close();

    var own_data_dir = try prefix_dir.makeOpenPath(paths.own_data_subpath, .{});
    defer own_data_dir.close();

    const file = try own_data_dir.createFile(paths.installed_file_name, .{ .read = true, .truncate = false });
    errdefer file.close();

    return parseFromFile(.{
        .gpa = options.gpa,
        .tmp_gpa = options.tmp_gpa,
        .file = file,
    });
}

pub fn deinit(packages: *InstalledPackages) void {
    if (packages.file) |f|
        f.close();

    packages.arena.deinit();
    packages.* = undefined;
}

pub fn parseFromFile(options: struct {
    gpa: std.mem.Allocator,
    tmp_gpa: ?std.mem.Allocator = null,
    file: std.fs.File,
}) !InstalledPackages {
    const tmp_gpa = options.tmp_gpa orelse options.gpa;
    const data_str = try options.file.readToEndAlloc(tmp_gpa, std.math.maxInt(usize));
    defer tmp_gpa.free(data_str);

    var res = try parse(.{
        .gpa = options.gpa,
        .tmp_gpa = options.tmp_gpa,
        .string = data_str,
    });
    errdefer res.deinit();

    res.file = options.file;
    return res;
}

pub fn parse(options: struct {
    gpa: std.mem.Allocator,
    tmp_gpa: ?std.mem.Allocator = null,
    string: []const u8,
}) !InstalledPackages {
    // TODO: This is quite an inefficient implementation. It first parsers a dynamic ini and then
    //       extracts the fields. Instead, the parsing needs to be done manually, or a ini parser
    //       that can parse into T is needed.
    const tmp_gpa = options.tmp_gpa orelse options.gpa;
    const dynamic = try ini.Dynamic.parse(tmp_gpa, options.string, .{
        .allocate = ini.Dynamic.Allocate.none,
    });
    defer dynamic.deinit();

    var arena_state = std.heap.ArenaAllocator.init(options.gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var packages = std.StringArrayHashMapUnmanaged(InstalledPackage){};
    for (dynamic.sections.keys(), dynamic.sections.values()) |package_name, package_section| {
        const version = package_section.get("version", .{}) orelse return error.NoVersionFound;

        var locations = std.ArrayListUnmanaged([]const u8){};
        for (package_section.properties.items) |property| {
            if (std.mem.eql(u8, property.name, "location"))
                try locations.append(arena, try arena.dupe(u8, property.value));
        }

        const entry = try packages.getOrPut(arena, package_name);
        if (entry.found_existing)
            return error.DuplicatePackage;

        entry.key_ptr.* = try arena.dupe(u8, package_name);
        entry.value_ptr.* = .{
            .version = try arena.dupe(u8, version),
            .locations = try locations.toOwnedSlice(arena),
        };
    }

    return .{
        .arena = arena_state,
        .packages = packages,
        .file = null,
    };
}

pub fn flush(packages: InstalledPackages) !void {
    const file = packages.file orelse return;

    try file.seekTo(0);

    var buffered_writer = std.io.bufferedWriter(file.writer());
    try packages.writeTo(buffered_writer.writer());
    try buffered_writer.flush();

    try file.setEndPos(try file.getPos());
}

pub fn writeTo(packages: InstalledPackages, writer: anytype) !void {
    for (packages.packages.keys(), packages.packages.values(), 0..) |package_name, package, i| {
        if (i != 0)
            try writer.writeAll("\n");

        try package.write(package_name, writer);
    }
}

fn expectCanonical(string: []const u8) !void {
    var packages = try parse(.{
        .gpa = std.testing.allocator,
        .tmp_gpa = std.testing.allocator,
        .string = string,
    });
    defer packages.deinit();

    var rendered = std.ArrayList(u8).init(std.testing.allocator);
    defer rendered.deinit();

    try packages.writeTo(rendered.writer());
    try std.testing.expectEqualStrings(string, rendered.items);
}

test "parse" {
    try expectCanonical(
        \\[test]
        \\version = 0.0.0
        \\location = path
        \\
        \\[test2]
        \\version = 0.0.0
        \\location = path1
        \\location = path2
        \\location = path3
        \\
    );
}

test {
    _ = InstalledPackage;

    _ = ini;
    _ = paths;
}

const InstalledPackages = @This();

const InstalledPackage = @import("InstalledPackage.zig");

const ini = @import("ini.zig");
const paths = @import("paths.zig");
const std = @import("std");
