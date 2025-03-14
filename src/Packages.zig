arena: std.heap.ArenaAllocator,
pkgs: std.StringArrayHashMapUnmanaged(Package),

pub fn init(gpa: std.mem.Allocator) Packages {
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .pkgs = .{},
    };
}

pub fn deinit(pkgs: *Packages) void {
    pkgs.pkgs.deinit(pkgs.arena.child_allocator);
    pkgs.arena.deinit();
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
    const gpa = pkgs.arena.child_allocator;
    const arena = pkgs.arena.allocator();

    var parser = ini.Parser.init(string);
    var parsed = parser.next();

    // Skip to the first section. If we hit a root level property it is an error.
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .end => return,
        .comment => {},
        .section => break,
        .property, .invalid => return error.InvalidPackagesIni,
    };

    const PackageField = std.meta.FieldEnum(Package);
    const InfoField = std.meta.FieldEnum(Package.Info);
    const UpdateField = std.meta.FieldEnum(Package.Update);
    const ArchField = std.meta.FieldEnum(Package.Arch);

    // Keep lists for all fields that can have multiple entries. When switching to parsing a new
    // package, put all the lists into the package and then switch.
    var donate = std.ArrayList([]const u8).init(arena);
    var install_bin = std.ArrayList([]const u8).init(arena);
    var install_lib = std.ArrayList([]const u8).init(arena);
    var install_share = std.ArrayList([]const u8).init(arena);

    // The first `parsed` will be a `section`, so `pkg` will be initialized in the first
    // iteration of this loop.
    var tmp_pkg: Package = .{};
    var pkg: *Package = &tmp_pkg;
    var pkg_field_invalid: bool = false;
    var pkg_field: PackageField = undefined;
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .invalid => return error.InvalidPackagesIni,
        .section => {
            const section = parsed.section(string).?;
            var it = std.mem.splitScalar(u8, section.name, '.');
            const pkg_name_str = it.first();
            const pkg_field_str = it.rest();
            pkg_field = std.meta.stringToEnum(PackageField, pkg_field_str) orelse {
                pkg_field_invalid = true;
                continue;
            };
            pkg_field_invalid = false;

            pkg.info.donate = try donate.toOwnedSlice();
            pkg.linux_x86_64.install_bin = try install_bin.toOwnedSlice();
            pkg.linux_x86_64.install_lib = try install_lib.toOwnedSlice();
            pkg.linux_x86_64.install_share = try install_share.toOwnedSlice();

            const entry = try pkgs.pkgs.getOrPutValue(gpa, pkg_name_str, .{});
            if (!entry.found_existing)
                entry.key_ptr.* = try arena.dupe(u8, pkg_name_str);

            pkg = entry.value_ptr;

            try donate.appendSlice(pkg.info.donate);
            try install_bin.appendSlice(pkg.linux_x86_64.install_bin);
            try install_lib.appendSlice(pkg.linux_x86_64.install_lib);
            try install_share.appendSlice(pkg.linux_x86_64.install_share);
        },
        .property => {
            if (pkg_field_invalid)
                continue;

            const prop = parsed.property(string).?;
            const value = try arena.dupe(u8, prop.value);
            switch (pkg_field) {
                .info => switch (std.meta.stringToEnum(InfoField, prop.name) orelse continue) {
                    .version => pkg.info.version = value,
                    .description => pkg.info.description = value,
                    .donate => try donate.append(value),
                },
                .update => switch (std.meta.stringToEnum(UpdateField, prop.name) orelse continue) {
                    .version => pkg.update.version = value,
                    .download => pkg.update.download = value,
                },
                .linux_x86_64 => switch (std.meta.stringToEnum(ArchField, prop.name) orelse continue) {
                    .url => pkg.linux_x86_64.url = value,
                    .hash => pkg.linux_x86_64.hash = value,
                    .install_bin => try install_bin.append(value),
                    .install_lib => try install_lib.append(value),
                    .install_share => try install_share.append(value),
                },
            }
        },
        .end => {
            pkg.info.donate = try donate.toOwnedSlice();
            pkg.linux_x86_64.install_bin = try install_bin.toOwnedSlice();
            pkg.linux_x86_64.install_lib = try install_lib.toOwnedSlice();
            pkg.linux_x86_64.install_share = try install_share.toOwnedSlice();
            return;
        },
    };
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
    for (pkgs.pkgs.keys(), pkgs.pkgs.values(), 0..) |pkg_name, pkg, i| {
        if (i != 0)
            try writer.writeAll("\n");

        try pkg.write(pkg_name, writer);
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
    try expectTransform(
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
        \\[test.invalid_section]
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
    pkgs.pkgs.sort(struct {
        keys: []const []const u8,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return std.mem.lessThan(u8, ctx.keys[a_index], ctx.keys[b_index]);
        }
    }{ .keys = pkgs.pkgs.keys() });
}

test sort {
    var pkgs = Packages.init(std.testing.allocator);
    defer pkgs.deinit();

    try std.testing.expect(try pkgs.update(.{
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
    try std.testing.expect(try pkgs.update(.{
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
pub fn update(pkgs: *Packages, pkg: Package.Named, options: UpdateOptions) !?Package {
    const gpa = pkgs.arena.child_allocator;
    const entry = try pkgs.pkgs.getOrPut(gpa, pkg.name);
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
                .install_bin = try updateInstall(.{
                    .arena = pkgs.arena.allocator(),
                    .tmp_gpa = pkgs.arena.child_allocator,
                    .old_version = old_pkg.info.version,
                    .old_installs = old_pkg.linux_x86_64.install_bin,
                    .new_version = pkg.pkg.info.version,
                    .new_installs = pkg.pkg.linux_x86_64.install_bin,
                }),
                .install_lib = try updateInstall(.{
                    .arena = pkgs.arena.allocator(),
                    .tmp_gpa = pkgs.arena.child_allocator,
                    .old_version = old_pkg.info.version,
                    .old_installs = old_pkg.linux_x86_64.install_lib,
                    .new_version = pkg.pkg.info.version,
                    .new_installs = pkg.pkg.linux_x86_64.install_lib,
                }),
                .install_share = try updateInstall(.{
                    .arena = pkgs.arena.allocator(),
                    .tmp_gpa = pkgs.arena.child_allocator,
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
        entry.value_ptr.* = pkg.pkg;
        return null;
    }
}

fn updateInstall(options: struct {
    arena: std.mem.Allocator,
    tmp_gpa: std.mem.Allocator,

    old_version: []const u8,
    old_installs: []const []const u8,
    new_version: []const u8,
    new_installs: []const []const u8,
}) ![]const []const u8 {
    var tmp_arena_state = std.heap.ArenaAllocator.init(options.tmp_gpa);
    const tmp_arena = tmp_arena_state.allocator();
    defer tmp_arena_state.deinit();

    var res = std.ArrayList([]const u8).init(options.arena);
    try res.ensureTotalCapacity(options.new_installs.len);

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
                tmp_arena,
                old_install_str,
                options.old_version,
                options.new_version,
            );
            const old_install_replaced = Package.Install.fromString(old_replaced_version);
            if (std.mem.eql(u8, old_install_replaced.from, new_install.from)) {
                // Old and new from location are the same after we replace old_version
                // with new version in the old install string:
                //   test:test-0.1.0, test-0.2.0 -> test:test-0.2.0
                const install = try std.fmt.allocPrint(options.arena, "{s}:{s}", .{
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

    return res.toOwnedSlice();
}

test update {
    var pkgs = Packages.init(std.testing.allocator);
    defer pkgs.deinit();

    try expectWrite(&pkgs, "");

    try std.testing.expect(try pkgs.update(.{
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
                .install_bin = &.{
                    "test-0.1.0/test",
                    "test2:test-0.1.0",
                },
                .install_lib = &.{},
                .install_share = &.{},
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
                .install_bin = &.{
                    "test-0.2.0/test",
                    "test-0.2.0",
                    "test3",
                },
                .install_lib = &.{},
                .install_share = &.{},
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
