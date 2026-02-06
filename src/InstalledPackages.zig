arena_alloc: std.heap.ArenaAllocator,
by_name: std.StringArrayHashMapUnmanaged(InstalledPackage),

file: ?std.Io.File,

pub fn open(io: std.Io, gpa: std.mem.Allocator, prefix: []const u8) !InstalledPackages {
    const cwd = std.Io.Dir.cwd();
    var prefix_dir = try cwd.createDirPathOpen(io, prefix, .{});
    defer prefix_dir.close(io);

    var own_data_dir = try prefix_dir.createDirPathOpen(io, paths.own_data_subpath, .{});
    defer own_data_dir.close(io);

    const file = try own_data_dir.createFile(io, paths.installed_file_name, .{ .read = true, .truncate = false });
    errdefer file.close(io);

    return parseFile(io, gpa, file);
}

pub fn deinit(pkgs: *InstalledPackages, io: std.Io) void {
    if (pkgs.file) |f|
        f.close(io);

    pkgs.by_name.deinit(pkgs.alloc());
    pkgs.arena_alloc.deinit();
    pkgs.* = undefined;
}

fn alloc(diag: *InstalledPackages) std.mem.Allocator {
    return diag.arena_alloc.child_allocator;
}

pub fn arena(diag: *InstalledPackages) std.mem.Allocator {
    return diag.arena_alloc.allocator();
}

pub fn isInstalled(pkgs: *const InstalledPackages, pkg_name: []const u8) bool {
    return pkgs.by_name.contains(pkg_name);
}

pub fn parseFile(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) !InstalledPackages {
    var reader = file.reader(io, &.{});
    var res = try parseReader(io, gpa, &reader.interface);
    errdefer res.deinit();

    res.file = file;
    return res;
}

pub fn parseReader(io: std.Io, gpa: std.mem.Allocator, reader: *std.Io.Reader) !InstalledPackages {
    var pkgs = InstalledPackages{
        .arena_alloc = .init(gpa),
        .by_name = .{},
        .file = null,
    };
    errdefer pkgs.deinit(io);

    const str = try reader.allocRemainingAlignedSentinel(pkgs.arena(), .unlimited, .of(u8), 0);
    try pkgs.parseInto(str);
    return pkgs;
}

pub fn parse(io: std.Io, gpa: std.mem.Allocator, string: [:0]const u8) !InstalledPackages {
    var pkgs = InstalledPackages{
        .arena_alloc = .init(gpa),
        .by_name = .{},
        .file = null,
    };
    errdefer pkgs.deinit(io);

    try pkgs.parseInto(try pkgs.arena().dupeZ(u8, string));
    return pkgs;
}

pub fn parseInto(pkgs: *InstalledPackages, string: [:0]const u8) !void {
    const gpa = pkgs.alloc();
    var parser = ini.Parser.init(string);
    var parsed = parser.next();

    // Skip to the first section. If we hit a root level property it is an error.
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .section => break,
        .property, .invalid => return error.InvalidPackagesIni,
        .end => return,
    };

    // Use original string lengths as a heuristic for how much data to preallocate
    try pkgs.by_name.ensureUnusedCapacity(gpa, string.len / 64);

    // Use a debug build of `dipm list installed` to find the limits above using the code below
    // const indices_cap = pkgs.strs.indices.capacity;
    // defer std.debug.assert(pkgs.by_name.entries.capacity == by_name_cap);

    while (parsed.kind != .end) {
        std.debug.assert(parsed.kind == .section);

        const section = parsed.section(string).?;
        const entry = try pkgs.by_name.getOrPut(gpa, section.name);
        if (entry.found_existing)
            return error.InvalidPackagesIni;

        const next, const pkg = try pkgs.parsePackage(&parser);
        entry.value_ptr.* = pkg;
        parsed = next;
    }
}

fn parsePackage(pkgs: *InstalledPackages, parser: *ini.Parser) !struct {
    ini.Parser.Result,
    InstalledPackage,
} {
    const PackageField = std.meta.FieldEnum(InstalledPackage);

    var location = std.ArrayList([]const u8).empty;
    var version: ?[]const u8 = null;

    var parsed = parser.next();
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .end, .section => break,
        .invalid => return error.InvalidPackagesIni,
        .property => {
            const prop = parsed.property(parser.string).?;
            switch (std.meta.stringToEnum(PackageField, prop.name) orelse continue) {
                .version => version = prop.value,
                .location => try location.append(pkgs.arena(), prop.value),
            }
        },
    };

    return .{ parsed, .{
        .version = version orelse return error.InvalidPackagesIni,
        .location = try location.toOwnedSlice(pkgs.arena()),
    } };
}

pub fn flush(pkgs: InstalledPackages, io: std.Io) !void {
    const file = pkgs.file orelse return;

    var file_buf: [std.heap.page_size_min]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);
    try pkgs.writeTo(&file_writer.interface);
    try file_writer.end();
}

pub fn writeTo(pkgs: InstalledPackages, writer: *std.Io.Writer) !void {
    for (pkgs.by_name.keys(), pkgs.by_name.values(), 0..) |pkg_name, pkg, i| {
        if (i != 0) try writer.writeAll("\n");
        try pkg.write(pkg_name, writer);
    }
}

fn expectTransform(from: [:0]const u8, to: []const u8) !void {
    const io = std.testing.io;
    var pkgs = try parse(io, std.testing.allocator, from);
    defer pkgs.deinit(io);

    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();

    try pkgs.writeTo(&rendered.writer);
    try std.testing.expectEqualStrings(to, rendered.written());
}

fn expectCanonical(string: [:0]const u8) !void {
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

const ini = @import("ini.zig");
const paths = @import("paths.zig");
const std = @import("std");
