arena_alloc: std.heap.ArenaAllocator,
by_name: std.StringArrayHashMapUnmanaged(Package),

pub fn init(gpa: std.mem.Allocator) Packages {
    return .{ .arena_alloc = .init(gpa), .by_name = .{} };
}

pub fn deinit(pkgs: *Packages) void {
    pkgs.by_name.deinit(pkgs.alloc());
    pkgs.arena_alloc.deinit();
    pkgs.* = undefined;
}

fn alloc(diag: *Packages) std.mem.Allocator {
    return diag.arena_alloc.child_allocator;
}

pub fn arena(diag: *Packages) std.mem.Allocator {
    return diag.arena_alloc.allocator();
}

pub const Download = enum {
    /// Always download the latest index
    always,

    /// Only download the index if it doesn't exist locally
    only_if_required,
};

const DownloadOptions = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

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
    const io = options.io;

    var pkgs = Packages.init(options.gpa);
    errdefer pkgs.deinit();

    const cwd = std.Io.Dir.cwd();
    var prefix_dir = try cwd.createDirPathOpen(io, options.prefix, .{});
    defer prefix_dir.close(io);

    var own_data_dir = try prefix_dir.createDirPathOpen(io, paths.own_data_subpath, .{});
    defer own_data_dir.close(io);

    const pkgs_file = try own_data_dir.createFile(io, paths.pkgs_file_name, .{
        .read = true,
        .truncate = false,
    });
    defer pkgs_file.close(io);

    const needs_download = switch (options.download) {
        .always => true,
        .only_if_required => (try pkgs_file.length(io)) == 0,
    };
    if (needs_download) {
        const download_node = options.progress.start("↓ pkgs.ini", 1);
        defer options.progress.end(download_node);

        var http_client = std.http.Client{
            .allocator = options.gpa,
            .io = options.io,
        };
        defer http_client.deinit();

        var pkgs_file_buf: [std.heap.page_size_min]u8 = undefined;
        var pkgs_file_writer = pkgs_file.writer(io, &pkgs_file_buf);
        const result = try @import("download.zig").download(.{
            .io = options.io,
            .writer = &pkgs_file_writer.interface,
            .client = &http_client,
            .uri_str = options.pkgs_uri,
            .progress = download_node,
        });

        if (result.status != .ok)
            return error.DownloadGotNoneOkStatusCode; // TODO: Diagnostics

        try pkgs_file_writer.end();
    }

    var pkgs_file_reader = pkgs_file.reader(options.io, &.{});
    const string = try pkgs_file_reader.interface.allocRemainingAlignedSentinel(pkgs.arena(), .unlimited, .of(u8), 0);
    try pkgs.parseInto(string);
    return pkgs;
}

pub fn parseFromPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) !Packages {
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);

    return parseFile(io, gpa, file);
}

pub fn parseFile(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) !Packages {
    var reader = file.reader(io, &.{});
    return parseReader(gpa, &reader.interface);
}

pub fn parseReader(gpa: std.mem.Allocator, reader: *std.Io.Reader) !Packages {
    var pkgs = Packages.init(gpa);
    errdefer pkgs.deinit();

    const str = try reader.allocRemainingAlignedSentinel(pkgs.arena(), .unlimited, .of(u8), 0);
    try pkgs.parseInto(str);
    return pkgs;
}

pub fn parse(gpa: std.mem.Allocator, string: [:0]const u8) !Packages {
    var pkgs = Packages.init(gpa);
    errdefer pkgs.deinit();

    try pkgs.parseInto(try pkgs.arena().dupeZ(u8, string));
    return pkgs;
}

pub fn parseInto(pkgs: *Packages, string: [:0]const u8) !void {
    const gpa = pkgs.alloc();
    var parser = ini.Parser.init(string);
    var parsed = parser.next();

    // Skip to the first section. If we hit a root level property it is an error.
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .end => return,
        .comment => {},
        .section => break,
        .property, .invalid => return error.InvalidPackagesIni,
    };

    // Use original string lengths as a heuristic for how much data to preallocate

    try pkgs.by_name.ensureUnusedCapacity(gpa, string.len / 512);

    // Use a debug build of `dipm list all` to find the limits above using the code below
    // const by_name_cap = pkgs.by_name.entries.capacity;
    // defer std.debug.assert(pkgs.by_name.entries.capacity == by_name_cap);

    while (parsed.kind != .end) {
        std.debug.assert(parsed.kind == .section);

        const section = parsed.section(string).?;
        const name, _ = splitScalar2(section.name, '.');

        const entry = try pkgs.by_name.getOrPut(gpa, name);
        if (entry.found_existing)
            return error.InvalidPackagesIni;

        const next, const pkg = try pkgs.parsePackage(name, &parser, parsed);
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
                parsed, update_field = try parseUpdate(parser);
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

fn parseInfo(pkgs: *Packages, parser: *ini.Parser) !struct {
    ini.Parser.Result,
    Package.Info,
} {
    var parsed = parser.next();

    var donate = std.ArrayList([]const u8){};
    var version: ?[]const u8 = null;
    var description: []const u8 = "";

    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .end, .section => break,
        .invalid => return error.InvalidPackagesIni,
        .property => {
            const prop = parsed.property(parser.string).?;
            const InfoField = std.meta.FieldEnum(Package.Info);
            switch (std.meta.stringToEnum(InfoField, prop.name) orelse continue) {
                .version => version = prop.value,
                .description => description = prop.value,
                .donate => _ = try donate.append(pkgs.arena(), prop.value),
            }
        },
    };

    return .{ parsed, .{
        .version = version orelse return error.InvalidPackagesIni,
        .description = description,
        .donate = try donate.toOwnedSlice(pkgs.arena()),
    } };
}

fn parseUpdate(parser: *ini.Parser) !struct {
    ini.Parser.Result,
    Package.Update,
} {
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
                .version => res.version = prop.value,
                .download => res.download = prop.value,
            }
        },
    };

    return .{ parsed, res };
}

fn parseArch(pkgs: *Packages, parser: *ini.Parser) !struct {
    ini.Parser.Result,
    Package.Arch,
} {
    var install_bin = std.ArrayList([]const u8).empty;
    var install_lib = std.ArrayList([]const u8).empty;
    var install_share = std.ArrayList([]const u8).empty;

    var url: ?[]const u8 = null;
    var hash: ?[]const u8 = null;

    const ArchField = std.meta.FieldEnum(Package.Arch);
    var parsed = parser.next();
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .end, .section => break,
        .invalid => return error.InvalidPackagesIni,
        .property => {
            const prop = parsed.property(parser.string).?;
            const field = std.meta.stringToEnum(ArchField, prop.name) orelse continue;
            switch (field) {
                .url => url = prop.value,
                .hash => hash = prop.value,
                .install_bin => try install_bin.append(pkgs.arena(), prop.value),
                .install_lib => try install_lib.append(pkgs.arena(), prop.value),
                .install_share => try install_share.append(pkgs.arena(), prop.value),
            }
        },
    };

    return .{ parsed, .{
        .url = url orelse return error.InvalidPackagesIni,
        .hash = hash orelse return error.InvalidPackagesIni,
        .install_bin = try install_bin.toOwnedSlice(pkgs.arena()),
        .install_lib = try install_lib.toOwnedSlice(pkgs.arena()),
        .install_share = try install_share.toOwnedSlice(pkgs.arena()),
    } };
}

fn splitScalar2(string: []const u8, char: u8) [2][]const u8 {
    var it = std.mem.splitScalar(u8, string, char);
    return .{ it.first(), it.rest() };
}

pub fn writeToFile(pkgs: Packages, io: std.Io, file: std.Io.File) !void {
    var file_writer_buf: [std.heap.page_size_min]u8 = undefined;
    var file_writer = file.writer(io, &file_writer_buf);
    try pkgs.write(&file_writer.interface);
    try file_writer.end();
}

pub fn write(pkgs: Packages, writer: *std.Io.Writer) !void {
    for (pkgs.by_name.keys(), pkgs.by_name.values(), 0..) |pkg_name, pkg, i| {
        if (i != 0) try writer.writeAll("\n");
        try pkg.write(pkg_name, writer);
    }
}

fn expectWrite(pkgs: *Packages, string: []const u8) !void {
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();

    try pkgs.write(&rendered.writer);
    try std.testing.expectEqualStrings(string, rendered.written());
}

fn expectTransform(from: [:0]const u8, to: []const u8) !void {
    var pkgs = try parse(std.testing.allocator, from);
    defer pkgs.deinit();

    return expectWrite(&pkgs, to);
}

fn expectCanonical(string: [:0]const u8) !void {
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
    const str_z = try gpa.dupeZ(u8, string);
    defer gpa.free(str_z);

    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();

    var pkgs = try parse(gpa, str_z);
    defer pkgs.deinit();

    try pkgs.write(&out.writer);
    return out.toOwnedSlice();
}

test "parse.fuzz" {
    try std.testing.fuzz({}, fuzz.fnFromParseAndWrite(parseAndWrite), .{});
}

pub fn sort(pkgs: *Packages) void {
    pkgs.by_name.sort(struct {
        keys: []const []const u8,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return std.mem.lessThan(u8, ctx.keys[a_index], ctx.keys[b_index]);
        }
    }{ .keys = pkgs.by_name.keys() });
}

test sort {
    const gpa = std.testing.allocator;
    var pkgs = Packages.init(gpa);
    defer pkgs.deinit();

    try std.testing.expect(try pkgs.update(gpa, .{
        .name = "btest",
        .pkg = .{
            .info = .{ .version = "0.2.0" },
            .update = .{ .version = "https://github.com/test/test" },
            .linux_x86_64 = .{
                .hash = "test_hash",
                .url = "test_url",
            },
        },
    }, .{}) == null);
    try std.testing.expect(try pkgs.update(gpa, .{
        .name = "atest",
        .pkg = .{
            .info = .{ .version = "0.2.0" },
            .update = .{ .version = "https://github.com/test/test" },
            .linux_x86_64 = .{
                .hash = "test_hash",
                .url = "test_url",
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
pub fn update(
    pkgs: *Packages,
    gpa: std.mem.Allocator,
    pkg: Package.Named,
    options: UpdateOptions,
) !?Package {
    const entry = try pkgs.by_name.getOrPut(gpa, pkg.name);
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
    old_version: []const u8,
    old_installs: []const []const u8,
    new_version: []const u8,
    new_installs: []const []const u8,
}) ![]const []const u8 {
    var res = std.ArrayList([]const u8).empty;
    try res.ensureUnusedCapacity(pkgs.arena(), options.new_installs.len);

    outer: for (options.new_installs) |new_install_str| {
        const new_install = Package.Install.fromString(new_install_str);

        for (options.old_installs) |old_install_str| {
            const old_install = Package.Install.fromString(old_install_str);
            if (std.mem.eql(u8, old_install.to, new_install.to)) {
                // Old and new installs the same file. This happens when the path changes, but
                // the file name stays the same:
                //   test-0.1.0/test, test-0.2.0/test -> test-0.2.0/test
                res.appendAssumeCapacity(new_install_str);
                continue :outer;
            }

            const old_replaced_version = try std.mem.replaceOwned(
                u8,
                pkgs.arena(),
                old_install_str,
                options.old_version,
                options.new_version,
            );
            const old_install_replaced = Package.Install.fromString(old_replaced_version);
            if (std.mem.eql(u8, old_install_replaced.from, new_install.from)) {
                // Old and new from location are the same after we replace old_version
                // with new version in the old install string:
                //   test:test-0.1.0, test-0.2.0 -> test:test-0.2.0
                const install = try std.fmt.allocPrint(pkgs.arena(), "{s}:{s}", .{
                    old_install_replaced.to,
                    new_install.from,
                });
                res.appendAssumeCapacity(install);
                continue :outer;
            }
        }

        // Seems like this new install does not match any of the old installs. Just add it.
        res.appendAssumeCapacity(new_install_str);
    }

    return res.toOwnedSlice(pkgs.arena());
}

test update {
    const gpa = std.testing.allocator;
    var pkgs = Packages.init(gpa);
    defer pkgs.deinit();

    try expectWrite(&pkgs, "");

    try std.testing.expect(try pkgs.update(gpa, .{
        .name = "test",
        .pkg = .{
            .info = .{
                .version = "0.1.0",
                .description = "Test package",
                .donate = &.{ "donate-link", "donate-link" },
            },
            .update = .{ .version = "https://github.com/test/test" },
            .linux_x86_64 = .{
                .hash = "test_hash1",
                .url = "test_url1",
                .install_bin = &.{ "test-0.1.0/test", "test2:test-0.1.0" },
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
        .name = "test",
        .pkg = .{
            .info = .{ .version = "0.2.0" },
            .update = .{
                .version = "https://github.com/test/test",
                .download = "https://download.com",
            },
            .linux_x86_64 = .{
                .hash = "test_hash2",
                .url = "test_url2",
                .install_bin = &.{ "test-0.2.0/test", "test-0.2.0", "test3" },
            },
        },
    };
    try std.testing.expect(try pkgs.update(gpa, new_version, .{}) != null);
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

    try std.testing.expect(try pkgs.update(gpa, new_version, .{
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

    _ = fuzz;
    _ = ini;
    _ = paths;
}

const Packages = @This();

const Diagnostics = @import("Diagnostics.zig");
const Package = @import("Package.zig");
const Progress = @import("Progress.zig");

const fuzz = @import("fuzz.zig");
const ini = @import("ini.zig");
const paths = @import("paths.zig");
const std = @import("std");
