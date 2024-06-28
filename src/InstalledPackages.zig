arena: std.heap.ArenaAllocator,
packages: std.StringArrayHashMapUnmanaged(InstalledPackage),

pub fn deinit(packages: *InstalledPackages) void {
    packages.arena.deinit();
    packages.* = undefined;
}

pub fn parse(allocator: std.mem.Allocator, string: []const u8) !InstalledPackages {
    // TODO: This is quite an inefficient implementation. It first parsers a dynamic ini and then
    //       extracts the fields. Instead, the parsing needs to be done manually, or a ini parser
    //       that can parse into T is needed.

    const dynamic = try ini.Dynamic.parse(allocator, string, .{
        .allocate = ini.Dynamic.Allocate.none,
    });
    defer dynamic.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
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
    };
}

pub fn write(packages: InstalledPackages, writer: anytype) !void {
    for (packages.packages.keys(), packages.packages.values(), 0..) |package_name, package, i| {
        if (i != 0)
            try writer.writeAll("\n");

        try package.write(package_name, writer);
    }
}

fn expectCanonical(string: []const u8) !void {
    var packages = try parse(std.testing.allocator, string);
    defer packages.deinit();

    var rendered = std.ArrayList(u8).init(std.testing.allocator);
    defer rendered.deinit();

    try packages.write(rendered.writer());
    try std.testing.expectEqualStrings(string, rendered.items);
}

test {
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

const InstalledPackages = @This();

const InstalledPackage = @import("InstalledPackage.zig");
const ini = @import("ini.zig");
const std = @import("std");
