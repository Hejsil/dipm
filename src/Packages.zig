arena: std.heap.ArenaAllocator,
packages: std.StringArrayHashMapUnmanaged(Package),

pub fn deinit(packages: *Packages) void {
    packages.arena.deinit();
    packages.* = undefined;
}

pub fn parse(allocator: std.mem.Allocator, string: []const u8) !Packages {
    // TODO: This is quite an inefficient implementation. It first parsers a dynamic ini and then
    //       extracts the fields. Instead, the parsing needs to be done manually, or a ini parser
    //       that can parse into T is needed.

    const dynamic = try ini.Dynamic.parse(allocator, string, .{
        .allocate = ini.Dynamic.Allocate.none,
    });
    defer dynamic.deinit();

    var package_names = std.StringArrayHashMapUnmanaged(void){};
    defer package_names.deinit(allocator);

    try package_names.ensureTotalCapacity(allocator, dynamic.sections.count());
    for (dynamic.sections.keys()) |section_name| {
        var name_split = std.mem.splitScalar(u8, section_name, '.');
        const package_name = name_split.first();
        package_names.putAssumeCapacity(package_name, {});
    }

    var tmp_buffer = std.ArrayList(u8).init(allocator);
    defer tmp_buffer.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var packages = std.StringArrayHashMapUnmanaged(Package){};
    for (package_names.keys()) |package_name_ref| {
        const package_name = try arena.dupe(u8, package_name_ref);

        tmp_buffer.shrinkRetainingCapacity(0);
        try tmp_buffer.writer().print("{s}.info", .{package_name});
        const info_section = dynamic.sections.get(tmp_buffer.items) orelse return error.NoInfoSectionFound;
        const info_version = info_section.get("version", .{}) orelse return error.NoInfoVersionFound;

        tmp_buffer.shrinkRetainingCapacity(0);
        try tmp_buffer.writer().print("{s}.update", .{package_name});
        const update_section = dynamic.sections.get(tmp_buffer.items) orelse return error.NoUpdateSectionFound;
        const update_github = update_section.get("github", .{}) orelse return error.NoUpdateGithubFound;

        tmp_buffer.shrinkRetainingCapacity(0);
        try tmp_buffer.writer().print("{s}.linux_x86_64", .{package_name});
        const linux_x86_64_section = dynamic.sections.get(tmp_buffer.items) orelse return error.NoLinuxAmd64SectionFound;
        const linux_x86_64_url = linux_x86_64_section.get("url", .{}) orelse return error.NoLinuxAmd64UrlFound;
        const linux_x86_64_hash = linux_x86_64_section.get("hash", .{}) orelse return error.NoLinuxAmd64HashFound;

        var linux_x86_64_install_bin = std.ArrayListUnmanaged([]const u8){};
        var linux_x86_64_install_lib = std.ArrayListUnmanaged([]const u8){};
        var linux_x86_64_install_share = std.ArrayListUnmanaged([]const u8){};

        for (linux_x86_64_section.properties.items) |property| {
            if (std.mem.eql(u8, property.name, "install_bin"))
                try linux_x86_64_install_bin.append(arena, try arena.dupe(u8, property.value));
            if (std.mem.eql(u8, property.name, "install_lib"))
                try linux_x86_64_install_lib.append(arena, try arena.dupe(u8, property.value));
            if (std.mem.eql(u8, property.name, "install_share"))
                try linux_x86_64_install_share.append(arena, try arena.dupe(u8, property.value));
        }

        try packages.putNoClobber(arena, package_name, .{
            .info = .{ .version = try arena.dupe(u8, info_version) },
            .update = .{ .github = try arena.dupe(u8, update_github) },
            .linux_x86_64 = .{
                .url = try arena.dupe(u8, linux_x86_64_url),
                .hash = try arena.dupe(u8, linux_x86_64_hash),
                .bin = try linux_x86_64_install_bin.toOwnedSlice(arena),
                .lib = try linux_x86_64_install_lib.toOwnedSlice(arena),
                .share = try linux_x86_64_install_share.toOwnedSlice(arena),
            },
        });
    }

    return .{
        .arena = arena_state,
        .packages = packages,
    };
}

pub fn write(packages: Packages, writer: anytype) !void {
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
        \\[test.info]
        \\version = 0.0.0
        \\
        \\[test.update]
        \\github = test/test
        \\
        \\[test.linux_x86_64]
        \\install_bin = test1
        \\install_bin = test2
        \\install_lib = test3
        \\install_share = test4
        \\url = test
        \\hash = test
        \\
        \\[test2.info]
        \\version = 0.0.0
        \\
        \\[test2.update]
        \\github = test2/test2
        \\
        \\[test2.linux_x86_64]
        \\install_bin = test21
        \\install_bin = test22
        \\install_lib = test23
        \\install_share = test24
        \\url = test2
        \\hash = test2
        \\
    );
}

const Packages = @This();

const Package = @import("Package.zig");
const ini = @import("ini.zig");
const std = @import("std");
