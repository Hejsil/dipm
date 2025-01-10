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

    packages.packages.deinit(packages.arena.child_allocator);
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

    var res = try parse(options.gpa, data_str);
    errdefer res.deinit();

    res.file = options.file;
    return res;
}

pub fn parse(gpa: std.mem.Allocator, string: []const u8) !InstalledPackages {
    var packages = InstalledPackages{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .packages = std.StringArrayHashMapUnmanaged(InstalledPackage){},
        .file = null,
    };
    errdefer packages.deinit();

    try packages.parseInto(string);
    return packages;
}

pub fn parseInto(packages: *InstalledPackages, string: []const u8) !void {
    const gpa = packages.arena.child_allocator;
    const arena = packages.arena.allocator();

    var parser = ini.Parser.init(string);
    var parsed = parser.next();

    // Skip to the first section. If we hit a root level property it is an error.
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .section => break,
        .property, .invalid => return error.InvalidPackagesIni,
        .end => return,
    };

    const PackageField = std.meta.FieldEnum(InstalledPackage);

    // Keep lists for all fields that can have multiple entries. When switching to parsing a new
    // package, put all the lists into the package and then switch.
    var location = std.ArrayList([]const u8).init(arena);

    // The first `parsed` will be a `section`, so `package` will be initialized in the first
    // iteration of this loop.
    var tmp_package: InstalledPackage = .{};
    var package: *InstalledPackage = &tmp_package;
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .invalid => return error.InvalidPackagesIni,
        .section => {
            package.location = try location.toOwnedSlice();

            const section = parsed.section(string).?;
            const entry = try packages.packages.getOrPutValue(gpa, section.name, .{});
            if (!entry.found_existing)
                entry.key_ptr.* = try arena.dupe(u8, section.name);

            package = entry.value_ptr;
            try location.appendSlice(package.location);
        },
        .property => {
            const prop = parsed.property(string).?;
            const value = try arena.dupe(u8, prop.value);
            switch (std.meta.stringToEnum(PackageField, prop.name) orelse continue) {
                .version => package.version = value,
                .location => try location.append(value),
            }
        },
        .end => {
            package.location = try location.toOwnedSlice();
            return;
        },
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

fn expectTransform(from: []const u8, to: []const u8) !void {
    var packages = try parse(std.testing.allocator, from);
    defer packages.deinit();

    var rendered = std.ArrayList(u8).init(std.testing.allocator);
    defer rendered.deinit();

    try packages.writeTo(rendered.writer());
    try std.testing.expectEqualStrings(to, rendered.items);
}

fn expectCanonical(string: []const u8) !void {
    return expectTransform(string, string);
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
    try expectTransform(
        \\[test]
        \\version = 0.0.0
        \\location = path
        \\invalid_field = test
        \\
    ,
        \\[test]
        \\version = 0.0.0
        \\location = path
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
