gpa: std.mem.Allocator,
strs: Strings,
by_name: std.ArrayHashMapUnmanaged(Strings.Index, Package, void, true),

pub fn init(gpa: std.mem.Allocator) Packages {
    return .{
        .gpa = gpa,
        .strs = .empty,
        .by_name = .{},
    };
}

pub fn deinit(pkgs: *Packages) void {
    pkgs.by_name.deinit(pkgs.gpa);
    pkgs.strs.deinit(pkgs.gpa);
    pkgs.* = undefined;
}

pub const Download = enum {
    /// Always download the latest index
    always,

    /// Only download the index if it doesn't exist locally
    only_if_required,
};

const DownloadOptions = struct {
    gpa: std.mem.Allocator,

    http_client: ?*std.http.Client = null,

    /// Successes and failures are reported to the diagnostics. Set this for more details
    /// about failures.
    diagnostics: *Diagnostics,
    progress: *Progress,

    /// The prefix path where the package manager will work and install packages
    prefix: []const u8,

    /// The URI where the package manager will download the pkgs.ini
    pkgs_uri: []const u8,

    /// The download behavior of the index.
    download: Download,
};

pub fn download(options: DownloadOptions) !Packages {
    var pkgs = Packages.init(options.gpa);
    errdefer pkgs.deinit();

    const cwd = std.fs.cwd();
    var prefix_dir = try cwd.makeOpenPath(options.prefix, .{});
    defer prefix_dir.close();

    var own_data_dir = try prefix_dir.makeOpenPath(paths.own_data_subpath, .{});
    defer own_data_dir.close();

    const pkgs_file = try own_data_dir.createFile(paths.pkgs_file_name, .{
        .read = true,
        .truncate = false,
    });
    defer pkgs_file.close();

    const needs_download = switch (options.download) {
        .always => true,
        .only_if_required => (try pkgs_file.getEndPos()) == 0,
    };
    if (needs_download) {
        const download_node = options.progress.start("↓ pkgs.ini", 1);
        defer options.progress.end(download_node);

        const result = try @import("download.zig").download(pkgs_file.writer(), .{
            .client = options.http_client,
            .uri_str = options.pkgs_uri,
            .progress = download_node,
        });

        if (result.status != .ok)
            return error.DownloadGotNoneOkStatusCode; // TODO: Diagnostics

        try pkgs_file.setEndPos(try pkgs_file.getPos());
        try pkgs_file.seekTo(0);
    }

    const string = try pkgs_file.readToEndAlloc(options.gpa, std.math.maxInt(usize));
    defer options.gpa.free(string);

    try pkgs.parseInto(string);
    return pkgs;
}

pub fn parseFromPath(
    gpa: std.mem.Allocator,
    dir: std.fs.Dir,
    sub_path: []const u8,
) !Packages {
    const file = try dir.openFile(sub_path, .{});
    defer file.close();

    return parseFile(gpa, file);
}

pub fn parseFile(gpa: std.mem.Allocator, file: std.fs.File) !Packages {
    const string = try file.readToEndAlloc(gpa, std.math.maxInt(usize));
    defer gpa.free(string);

    return parse(gpa, string);
}

pub fn parse(gpa: std.mem.Allocator, string: []const u8) !Packages {
    var res = Packages.init(gpa);
    errdefer res.deinit();

    try res.parseInto(string);
    return res;
}

pub fn parseInto(pkgs: *Packages, string: []const u8) !void {
    var parser = ini.Parser.init(string);
    var parsed = parser.next();

    // Skip to the first section. If we hit a root level property it is an error.
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .end => return,
        .comment => {},
        .section => break,
        .property, .invalid => return error.InvalidPackagesIni,
    };

    while (parsed.kind != .end) {
        std.debug.assert(parsed.kind == .section);

        const section = parsed.section(string).?;
        const name, _ = splitScalar2(section.name, '.');

        const entry = try pkgs.by_name.getOrPutAdapted(pkgs.gpa, name, pkgs.strs.adapter());
        if (entry.found_existing)
            return error.InvalidPackagesIni;

        const next, const pkg = try pkgs.parsePackage(name, &parser, parsed);
        entry.key_ptr.* = try pkgs.putStr(name);
        entry.value_ptr.* = pkg;
        parsed = next;
    }
}

fn parsePackage(
    pkgs: *Packages,
    pkg_name: []const u8,
    parser: *ini.Parser,
    first: ini.Parser.Result,
) !struct { ini.Parser.Result, Package } {
    var parsed = first;

    var info: ?Package.Info = null;
    var update_field: ?Package.Update = null;
    var linux_x86_64: ?Package.Arch = null;

    while (parsed.kind != .end) {
        std.debug.assert(parsed.kind == .section);

        const section = parsed.section(parser.string).?;
        const name, const field = splitScalar2(section.name, '.');
        if (!std.mem.eql(u8, pkg_name, name))
            break;

        const PackageField = std.meta.FieldEnum(Package);
        switch (std.meta.stringToEnum(PackageField, field) orelse return error.InvalidPackagesIni) {
            .info => {
                parsed, info = try pkgs.parseInfo(parser);
            },
            .update => {
                parsed, update_field = try pkgs.parseUpdate(parser);
            },
            .linux_x86_64 => {
                parsed, linux_x86_64 = try pkgs.parseArch(parser);
            },
        }
    }

    return .{ parsed, .{
        .info = info orelse return error.InvalidPackagesIni,
        .update = update_field orelse .{},
        .linux_x86_64 = linux_x86_64 orelse return error.InvalidPackagesIni,
    } };
}

fn parseInfo(pkgs: *Packages, parser: *ini.Parser) !struct { ini.Parser.Result, Package.Info } {
    var parsed = parser.next();

    const off = pkgs.strs.putIndicesBegin();
    var version: Strings.Index.Optional = .null;
    var desc: Strings.Index.Optional = .null;

    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .end, .section => break,
        .invalid => return error.InvalidPackagesIni,
        .property => {
            const prop = parsed.property(parser.string).?;
            const InfoField = std.meta.FieldEnum(Package.Info);
            switch (std.meta.stringToEnum(InfoField, prop.name) orelse continue) {
                .version => version = .some(try pkgs.putStr(prop.value)),
                .description => desc = .some(try pkgs.putStr(prop.value)),
                .donate => _ = try pkgs.strs.putStrs(pkgs.gpa, &.{prop.value}),
            }
        },
    };

    const donate = pkgs.strs.putIndicesEnd(off);
    return .{ parsed, .{
        .version = version.unwrap() orelse return error.InvalidPackagesIni,
        .description = desc,
        .donate = donate,
    } };
}

fn parseUpdate(pkgs: *Packages, parser: *ini.Parser) !struct { ini.Parser.Result, Package.Update } {
    var parsed = parser.next();

    var res = Package.Update{};
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .end, .section => break,
        .invalid => return error.InvalidPackagesIni,
        .property => {
            const prop = parsed.property(parser.string).?;
            const UpdateField = std.meta.FieldEnum(Package.Update);
            switch (std.meta.stringToEnum(UpdateField, prop.name) orelse continue) {
                .version => res.version = .some(try pkgs.putStr(prop.value)),
                .download => res.download = .some(try pkgs.putStr(prop.value)),
            }
        },
    };

    return .{ parsed, res };
}

fn parseArch(pkgs: *Packages, parser: *ini.Parser) !struct { ini.Parser.Result, Package.Arch } {
    var arena_state = std.heap.ArenaAllocator.init(pkgs.gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    var install_bin = std.ArrayList([]const u8).init(arena);
    var install_lib = std.ArrayList([]const u8).init(arena);
    var install_share = std.ArrayList([]const u8).init(arena);

    var url: ?[]const u8 = null;
    var hash: ?[]const u8 = null;

    var parsed = parser.next();
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .end, .section => break,
        .invalid => return error.InvalidPackagesIni,
        .property => {
            const prop = parsed.property(parser.string).?;
            const ArchField = std.meta.FieldEnum(Package.Arch);
            switch (std.meta.stringToEnum(ArchField, prop.name) orelse continue) {
                .url => url = prop.value,
                .hash => hash = prop.value,
                .install_bin => try install_bin.append(prop.value),
                .install_lib => try install_lib.append(prop.value),
                .install_share => try install_share.append(prop.value),
            }
        },
    };

    return .{ parsed, .{
        .url = try pkgs.putStr(url orelse return error.InvalidPackagesIni),
        .hash = try pkgs.putStr(hash orelse return error.InvalidPackagesIni),
        .install_bin = try pkgs.putStrs(install_bin.items),
        .install_lib = try pkgs.putStrs(install_lib.items),
        .install_share = try pkgs.putStrs(install_share.items),
    } };
}

fn splitScalar2(string: []const u8, char: u8) [2][]const u8 {
    var it = std.mem.splitScalar(u8, string, char);
    return .{ it.first(), it.rest() };
}

pub fn putStr(pkgs: *Packages, string: []const u8) !Strings.Index {
    return pkgs.strs.putStr(pkgs.gpa, string);
}

pub fn putStrs(pkgs: *Packages, indices: []const []const u8) !Strings.Indices {
    return pkgs.strs.putStrs(pkgs.gpa, indices);
}

pub fn print(pkgs: *Packages, comptime format: []const u8, args: anytype) !Strings.Index {
    return pkgs.strs.print(pkgs.gpa, format, args);
}

pub fn writeToFileOverride(pkgs: Packages, file: std.fs.File) !void {
    try file.seekTo(0);
    try pkgs.writeToFile(file);
    try file.setEndPos(try file.getPos());
}

pub fn writeToFile(pkgs: Packages, file: std.fs.File) !void {
    var buffered_writer = std.io.bufferedWriter(file.writer());
    try pkgs.write(buffered_writer.writer());
    try buffered_writer.flush();
}

pub fn write(pkgs: Packages, writer: anytype) !void {
    for (pkgs.by_name.keys(), pkgs.by_name.values(), 0..) |pkg_name, pkg, i| {
        if (i != 0) try writer.writeAll("\n");
        try pkg.write(pkgs.strs, pkg_name.get(pkgs.strs), writer);
    }
}

fn expectWrite(pkgs: *Packages, string: []const u8) !void {
    var rendered = std.ArrayList(u8).init(std.testing.allocator);
    defer rendered.deinit();

    try pkgs.write(rendered.writer());
    try std.testing.expectEqualStrings(string, rendered.items);
}

fn expectTransform(from: []const u8, to: []const u8) !void {
    var pkgs = try parse(std.testing.allocator, from);
    defer pkgs.deinit();

    return expectWrite(&pkgs, to);
}

fn expectCanonical(string: []const u8) !void {
    return expectTransform(string, string);
}

test parse {
    try expectCanonical(
        \\[test.info]
        \\version = 0.0.0
        \\description = Test package 1
        \\donate = donate/link1
        \\
        \\[test.update]
        \\version = https://github.com/test/test
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
        \\description = Test package 2
        \\donate = donate/link2
        \\donate = donate/link3
        \\
        \\[test2.update]
        \\version = https://github.com/test2/test2
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
    try expectTransform(
        \\[test.info]
        \\version = 0.0.0
        \\description = Test package 1
        \\donate = donate/link1
        \\invalid_field = test
        \\
        \\[test.update]
        \\version = https://github.com/test/test
        \\
        \\[test.linux_x86_64]
        \\url = test
        \\hash = test
        \\
    ,
        \\[test.info]
        \\version = 0.0.0
        \\description = Test package 1
        \\donate = donate/link1
        \\
        \\[test.update]
        \\version = https://github.com/test/test
        \\
        \\[test.linux_x86_64]
        \\url = test
        \\hash = test
        \\
    );
}

fn parseAndWrite(gpa: std.mem.Allocator, string: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(gpa);
    defer out.deinit();

    var pkgs = try parse(gpa, string);
    defer pkgs.deinit();

    try pkgs.write(out.writer());
    return out.toOwnedSlice();
}

test "parse.fuzz" {
    try std.testing.fuzz({}, fuzz.fnFromParseAndWrite(parseAndWrite), .{});
}

pub fn sort(pkgs: *Packages) void {
    pkgs.by_name.sort(struct {
        strs: Strings,
        keys: []const Strings.Index,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return std.mem.lessThan(
                u8,
                ctx.keys[a_index].get(ctx.strs),
                ctx.keys[b_index].get(ctx.strs),
            );
        }
    }{ .strs = pkgs.strs, .keys = pkgs.by_name.keys() });
}

test sort {
    var pkgs = Packages.init(std.testing.allocator);
    defer pkgs.deinit();

    try std.testing.expect(try pkgs.update(.{
        .name = try pkgs.putStr("btest"),
        .pkg = .{
            .info = .{ .version = try pkgs.putStr("0.2.0") },
            .update = .{ .version = .some(try pkgs.putStr("https://github.com/test/test")) },
            .linux_x86_64 = .{
                .hash = try pkgs.putStr("test_hash"),
                .url = try pkgs.putStr("test_url"),
            },
        },
    }, .{}) == null);
    try std.testing.expect(try pkgs.update(.{
        .name = try pkgs.putStr("atest"),
        .pkg = .{
            .info = .{ .version = try pkgs.putStr("0.2.0") },
            .update = .{ .version = .some(try pkgs.putStr("https://github.com/test/test")) },
            .linux_x86_64 = .{
                .hash = try pkgs.putStr("test_hash"),
                .url = try pkgs.putStr("test_url"),
            },
        },
    }, .{}) == null);
    try expectWrite(&pkgs,
        \\[btest.info]
        \\version = 0.2.0
        \\
        \\[btest.update]
        \\version = https://github.com/test/test
        \\
        \\[btest.linux_x86_64]
        \\url = test_url
        \\hash = test_hash
        \\
        \\[atest.info]
        \\version = 0.2.0
        \\
        \\[atest.update]
        \\version = https://github.com/test/test
        \\
        \\[atest.linux_x86_64]
        \\url = test_url
        \\hash = test_hash
        \\
    );

    pkgs.sort();
    try expectWrite(&pkgs,
        \\[atest.info]
        \\version = 0.2.0
        \\
        \\[atest.update]
        \\version = https://github.com/test/test
        \\
        \\[atest.linux_x86_64]
        \\url = test_url
        \\hash = test_hash
        \\
        \\[btest.info]
        \\version = 0.2.0
        \\
        \\[btest.update]
        \\version = https://github.com/test/test
        \\
        \\[btest.linux_x86_64]
        \\url = test_url
        \\hash = test_hash
        \\
    );
}

pub const UpdateOptions = struct {
    description: bool = false,
};

/// Update a package. If it doesn't exist it is added.
pub fn update(pkgs: *Packages, pkg: Package.Named, options: UpdateOptions) !?Package {
    const adapter = pkgs.strs.adapter();
    const entry = try pkgs.by_name.getOrPutAdapted(pkgs.gpa, pkg.name.get(pkgs.strs), adapter);
    if (entry.found_existing) {
        const old_pkg = entry.value_ptr.*;

        entry.value_ptr.* = .{
            .info = .{
                .version = pkg.pkg.info.version,
                .donate = pkg.pkg.info.donate,
                .description = old_pkg.info.description,
            },
            .update = .{
                .version = pkg.pkg.update.version,
                .download = pkg.pkg.update.download,
            },
            .linux_x86_64 = .{
                .url = pkg.pkg.linux_x86_64.url,
                .hash = pkg.pkg.linux_x86_64.hash,
                .install_bin = try pkgs.updateInstall(.{
                    .old_version = old_pkg.info.version,
                    .old_installs = old_pkg.linux_x86_64.install_bin,
                    .new_version = pkg.pkg.info.version,
                    .new_installs = pkg.pkg.linux_x86_64.install_bin,
                }),
                .install_lib = try pkgs.updateInstall(.{
                    .old_version = old_pkg.info.version,
                    .old_installs = old_pkg.linux_x86_64.install_lib,
                    .new_version = pkg.pkg.info.version,
                    .new_installs = pkg.pkg.linux_x86_64.install_lib,
                }),
                .install_share = try pkgs.updateInstall(.{
                    .old_version = old_pkg.info.version,
                    .old_installs = old_pkg.linux_x86_64.install_share,
                    .new_version = pkg.pkg.info.version,
                    .new_installs = pkg.pkg.linux_x86_64.install_share,
                }),
            },
        };

        if (options.description)
            entry.value_ptr.info.description = pkg.pkg.info.description;

        return old_pkg;
    } else {
        entry.key_ptr.* = pkg.name;
        entry.value_ptr.* = pkg.pkg;
        return null;
    }
}

fn updateInstall(pkgs: *Packages, options: struct {
    old_version: Strings.Index,
    old_installs: Strings.Indices,
    new_version: Strings.Index,
    new_installs: Strings.Indices,
}) !Strings.Indices {
    var arena_state = std.heap.ArenaAllocator.init(pkgs.gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const off = pkgs.strs.putIndicesBegin();
    outer: for (options.new_installs.get(pkgs.strs)) |new_install_idx| {
        const new_install = Package.Install.fromString(new_install_idx.get(pkgs.strs));

        for (options.old_installs.get(pkgs.strs)) |old_install_idx| {
            const old_install = Package.Install.fromString(old_install_idx.get(pkgs.strs));
            if (std.mem.eql(u8, old_install.to, new_install.to)) {
                // Old and new installs the same file. This happens when the path changes, but
                // the file name stays the same:
                //   test-0.1.0/test, test-0.2.0/test -> test-0.2.0/test
                try pkgs.strs.indices.append(pkgs.gpa, new_install_idx);
                continue :outer;
            }

            const old_replaced_version = try std.mem.replaceOwned(
                u8,
                arena,
                old_install_idx.get(pkgs.strs),
                options.old_version.get(pkgs.strs),
                options.new_version.get(pkgs.strs),
            );
            const old_install_replaced = Package.Install.fromString(old_replaced_version);
            if (std.mem.eql(u8, old_install_replaced.from, new_install.from)) {
                // Old and new from location are the same after we replace old_version
                // with new version in the old install string:
                //   test:test-0.1.0, test-0.2.0 -> test:test-0.2.0
                const install = try pkgs.print("{s}:{s}", .{
                    old_install_replaced.to,
                    new_install.from,
                });
                try pkgs.strs.indices.append(pkgs.gpa, install);
                continue :outer;
            }
        }

        // Seems like this new install does not match any of the old installs. Just add it.
        try pkgs.strs.indices.append(pkgs.gpa, new_install_idx);
    }

    return pkgs.strs.putIndicesEnd(off);
}

test update {
    var pkgs = Packages.init(std.testing.allocator);
    defer pkgs.deinit();

    try expectWrite(&pkgs, "");

    try std.testing.expect(try pkgs.update(.{
        .name = try pkgs.putStr("test"),
        .pkg = .{
            .info = .{
                .version = try pkgs.putStr("0.1.0"),
                .description = .some(try pkgs.putStr("Test package")),
                .donate = try pkgs.putStrs(&.{ "donate-link", "donate-link" }),
            },
            .update = .{ .version = .some(try pkgs.putStr("https://github.com/test/test")) },
            .linux_x86_64 = .{
                .hash = try pkgs.putStr("test_hash1"),
                .url = try pkgs.putStr("test_url1"),
                .install_bin = try pkgs.putStrs(&.{
                    "test-0.1.0/test",
                    "test2:test-0.1.0",
                }),
            },
        },
    }, .{}) == null);
    try expectWrite(&pkgs,
        \\[test.info]
        \\version = 0.1.0
        \\description = Test package
        \\donate = donate-link
        \\donate = donate-link
        \\
        \\[test.update]
        \\version = https://github.com/test/test
        \\
        \\[test.linux_x86_64]
        \\install_bin = test-0.1.0/test
        \\install_bin = test2:test-0.1.0
        \\url = test_url1
        \\hash = test_hash1
        \\
    );

    const new_version = Package.Named{
        .name = try pkgs.putStr("test"),
        .pkg = .{
            .info = .{ .version = try pkgs.putStr("0.2.0") },
            .update = .{
                .version = .some(try pkgs.putStr("https://github.com/test/test")),
                .download = .some(try pkgs.putStr("https://download.com")),
            },
            .linux_x86_64 = .{
                .hash = try pkgs.putStr("test_hash2"),
                .url = try pkgs.putStr("test_url2"),
                .install_bin = try pkgs.putStrs(&.{
                    "test-0.2.0/test",
                    "test-0.2.0",
                    "test3",
                }),
            },
        },
    };
    try std.testing.expect(try pkgs.update(new_version, .{}) != null);
    try expectWrite(&pkgs,
        \\[test.info]
        \\version = 0.2.0
        \\description = Test package
        \\
        \\[test.update]
        \\version = https://github.com/test/test
        \\download = https://download.com
        \\
        \\[test.linux_x86_64]
        \\install_bin = test-0.2.0/test
        \\install_bin = test2:test-0.2.0
        \\install_bin = test3
        \\url = test_url2
        \\hash = test_hash2
        \\
    );

    try std.testing.expect(try pkgs.update(new_version, .{
        .description = true,
    }) != null);
    try expectWrite(&pkgs,
        \\[test.info]
        \\version = 0.2.0
        \\
        \\[test.update]
        \\version = https://github.com/test/test
        \\download = https://download.com
        \\
        \\[test.linux_x86_64]
        \\install_bin = test-0.2.0/test
        \\install_bin = test2:test-0.2.0
        \\install_bin = test3
        \\url = test_url2
        \\hash = test_hash2
        \\
    );
}

test {
    _ = Diagnostics;
    _ = Package;
    _ = Progress;
    _ = Strings;

    _ = fuzz;
    _ = ini;
    _ = paths;
}

const Packages = @This();

const Diagnostics = @import("Diagnostics.zig");
const Package = @import("Package.zig");
const Progress = @import("Progress.zig");
const Strings = @import("Strings.zig");

const fuzz = @import("fuzz.zig");
const ini = @import("ini.zig");
const paths = @import("paths.zig");
const std = @import("std");
