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

    // The original strings length is a good indicator for the maximum number of bytes we're gonna
    // store in strings
    try pkgs.strings.data.ensureUnusedCapacity(pkgs.gpa, string.len);

    // The first `parsed` will be a `section`, so `package` will be initialized in the first
    // iteration of this loop.
    const empty_index = try pkgs.putStr("");
    var location_off = pkgs.strings.putIndicesBegin();
    var tmp_package: InstalledPackage = .{
        .version = empty_index,
        .location = .empty,
    };
    var package: *InstalledPackage = &tmp_package;
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .invalid => return error.InvalidPackagesIni,
        .section => {
            package.location = pkgs.strings.putIndicesEnd(location_off);

            const section = parsed.section(string).?;
            const adapter = Strings.ArrayHashMapAdapter{ .strings = &pkgs.strings };
            const entry = try pkgs.by_name.getOrPutAdapted(pkgs.gpa, section.name, adapter);
            package = entry.value_ptr;

            if (!entry.found_existing) {
                entry.key_ptr.* = try pkgs.putStr(section.name);
                entry.value_ptr.* = .{
                    .version = empty_index,
                    .location = .empty,
                };
                location_off = pkgs.strings.putIndicesBegin();
            } else {
                location_off = pkgs.strings.putIndicesBegin();
                try pkgs.strings.indices.appendSlice(pkgs.gpa, pkgs.getIndices(package.location));
            }
        },
        .property => {
            const prop = parsed.property(string).?;
            const value = try pkgs.putStr(prop.value);
            switch (std.meta.stringToEnum(PackageField, prop.name) orelse continue) {
                .version => package.version = value,
                .location => try pkgs.strings.indices.append(pkgs.gpa, value),
            }
        },
        .end => {
            package.location = pkgs.strings.putIndicesEnd(location_off);
            return;
        },
    };
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

pub fn getStr(pkgs: InstalledPackages, string: Strings.Index) [:0]const u8 {
    return pkgs.strings.getStr(string);
}

pub fn getIndices(pkgs: InstalledPackages, indices: Strings.Indices) []const Strings.Index {
    return pkgs.strings.getIndices(indices);
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
    for (pkgs.by_name.keys(), pkgs.by_name.values(), 0..) |package_name, package, i| {
        if (i != 0)
            try writer.writeAll("\n");

        try package.write(pkgs.strings, pkgs.getStr(package_name), writer);
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
    try expectTransform(
        \\[test]
        \\version = 0.0.0
        \\location = path
        \\
        \\[test]
        \\version = 0.0.0
        \\location = path
        \\
    ,
        \\[test]
        \\version = 0.0.0
        \\location = path
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
