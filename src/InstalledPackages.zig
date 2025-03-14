gpa: std.mem.Allocator,
strings: Strings,
by_name: std.ArrayHashMapUnmanaged(Strings.Index, InstalledPackage, void, true),

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

pub fn deinit(pkgs: *InstalledPackages) void {
    if (pkgs.file) |f|
        f.close();

    pkgs.strings.deinit(pkgs.gpa);
    pkgs.by_name.deinit(pkgs.gpa);
    pkgs.* = undefined;
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
    var pkgs = InstalledPackages{
        .gpa = gpa,
        .strings = .empty,
        .by_name = .{},
        .file = null,
    };
    errdefer pkgs.deinit();

    try pkgs.parseInto(string);
    return pkgs;
}

pub fn parseInto(pkgs: *InstalledPackages, string: []const u8) !void {
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

    // Use original string lengths as a heuristic for how much data to preallocate
    try pkgs.strings.data.ensureUnusedCapacity(pkgs.gpa, string.len);
    try pkgs.strings.indices.ensureUnusedCapacity(pkgs.gpa, string.len / 32);
    try pkgs.by_name.ensureUnusedCapacity(pkgs.gpa, string.len / 64);

    // Use a debug build of `dipm list installed` to find the limits above using the code below
    // const indices_cap = pkgs.strings.indices.capacity;
    // const data_cap = pkgs.strings.data.capacity;
    // const by_name_cap = pkgs.by_name.entries.capacity;
    // defer std.debug.assert(pkgs.strings.data.capacity == data_cap);
    // defer std.debug.assert(pkgs.strings.indices.capacity == indices_cap);
    // defer std.debug.assert(pkgs.by_name.entries.capacity == by_name_cap);

    while (parsed.kind != .end) {
        std.debug.assert(parsed.kind == .section);

        const section = parsed.section(string).?;
        const adapter = Strings.ArrayHashMapAdapter{ .strings = &pkgs.strings };
        const entry = try pkgs.by_name.getOrPutAdapted(pkgs.gpa, section.name, adapter);
        if (entry.found_existing)
            return error.InvalidPackagesIni;

        var opt_version: ?[]const u8 = null;
        const off = pkgs.strings.putIndicesBegin();

        parsed = parser.next();
        while (true) : (parsed = parser.next()) switch (parsed.kind) {
            .comment => {},
            .end, .section => break,
            .invalid => return error.InvalidPackagesIni,
            .property => {
                const prop = parsed.property(string).?;
                switch (std.meta.stringToEnum(PackageField, prop.name) orelse continue) {
                    .version => opt_version = prop.value,
                    .location => {
                        const location = try pkgs.putStr(prop.value);
                        try pkgs.strings.indices.append(pkgs.gpa, location);
                    },
                }
            },
        };

        const version = opt_version orelse return error.InvalidPackagesIni;
        const location = pkgs.strings.putIndicesEnd(off);

        entry.key_ptr.* = try pkgs.putStr(section.name);
        entry.value_ptr.* = .{
            .version = try pkgs.putStr(version),
            .location = location,
        };
    }
}

pub fn putStr(pkgs: *InstalledPackages, string: []const u8) !Strings.Index {
    return pkgs.strings.putStr(pkgs.gpa, string);
}

pub fn putIndices(pkgs: *InstalledPackages, indices: []const Strings.Index) !Strings.Indices {
    return pkgs.strings.putIndices(pkgs.gpa, indices);
}

pub fn print(
    pkgs: *InstalledPackages,
    comptime format: []const u8,
    args: anytype,
) !Strings.Index {
    return pkgs.strings.print(pkgs.gpa, format, args);
}

pub fn flush(pkgs: InstalledPackages) !void {
    const file = pkgs.file orelse return;

    try file.seekTo(0);

    var buffered_writer = std.io.bufferedWriter(file.writer());
    try pkgs.writeTo(buffered_writer.writer());
    try buffered_writer.flush();

    try file.setEndPos(try file.getPos());
}

pub fn writeTo(pkgs: InstalledPackages, writer: anytype) !void {
    for (pkgs.by_name.keys(), pkgs.by_name.values(), 0..) |pkg_name, pkg, i| {
        if (i != 0)
            try writer.writeAll("\n");

        try pkg.write(pkgs.strings, pkg_name.get(pkgs.strings), writer);
    }
}

fn expectTransform(from: []const u8, to: []const u8) !void {
    var pkgs = try parse(std.testing.allocator, from);
    defer pkgs.deinit();

    var rendered = std.ArrayList(u8).init(std.testing.allocator);
    defer rendered.deinit();

    try pkgs.writeTo(rendered.writer());
    try std.testing.expectEqualStrings(to, rendered.items);
}

fn expectCanonical(string: []const u8) !void {
    return expectTransform(string, string);
}

test parse {
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
const Strings = @import("Strings.zig");

const ini = @import("ini.zig");
const paths = @import("paths.zig");
const std = @import("std");
