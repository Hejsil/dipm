arena: std.heap.ArenaAllocator,
packages: std.StringArrayHashMapUnmanaged(Package),

pub fn init(gpa: std.mem.Allocator) Packages {
    return .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .packages = .{},
    };
}

pub fn deinit(packages: *Packages) void {
    packages.packages.deinit(packages.arena.child_allocator);
    packages.arena.deinit();
    packages.* = undefined;
}

const DownloadOptions = struct {
    gpa: std.mem.Allocator,

    http_client: *std.http.Client,

    /// Successes and failures are reported to the diagnostics. Set this for more details
    /// about failures.
    diagnostics: *Diagnostics,
    progress: *Progress,

    /// The prefix path where the package manager will work and install packages
    prefix: []const u8,

    /// The URI where the package manager will download the pkgs.ini
    pkgs_uri: []const u8,

    /// The download behavior of the index.
    download: enum {
        /// Always download the latest index
        always,

        /// Only download the index if it doesn't exist locally
        only_if_required,
    },
};

pub fn download(options: DownloadOptions) !Packages {
    var packages = Packages.init(options.gpa);
    errdefer packages.deinit();

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

    try packages.parseInto(string);
    return packages;
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

pub fn parseInto(packages: *Packages, string: []const u8) !void {
    const gpa = packages.arena.child_allocator;
    const arena = packages.arena.allocator();

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

    // The first `parsed` will be a `section`, so `package` will be initialized in the first
    // iteration of this loop.
    var tmp_package: Package = .{};
    var package: *Package = &tmp_package;
    var package_field: PackageField = undefined;
    while (true) : (parsed = parser.next()) switch (parsed.kind) {
        .comment => {},
        .invalid => return error.InvalidPackagesIni,
        .section => {
            package.info.donate = try donate.toOwnedSlice();
            package.linux_x86_64.install_bin = try install_bin.toOwnedSlice();
            package.linux_x86_64.install_lib = try install_lib.toOwnedSlice();
            package.linux_x86_64.install_share = try install_share.toOwnedSlice();

            const section = parsed.section(string).?;
            var it = std.mem.splitScalar(u8, section.name, '.');
            const package_name_str = it.first();
            const package_field_str = it.rest();

            const entry = try packages.packages.getOrPutValue(gpa, package_name_str, .{});
            if (!entry.found_existing)
                entry.key_ptr.* = try arena.dupe(u8, package_name_str);

            package = entry.value_ptr;
            package_field = try stringToEnum(PackageField, package_field_str);

            try donate.appendSlice(package.info.donate);
            try install_bin.appendSlice(package.linux_x86_64.install_bin);
            try install_lib.appendSlice(package.linux_x86_64.install_lib);
            try install_share.appendSlice(package.linux_x86_64.install_share);
        },
        .property => {
            const prop = parsed.property(string).?;
            const value = try arena.dupe(u8, prop.value);
            switch (package_field) {
                .info => switch (try stringToEnum(InfoField, prop.name)) {
                    .version => package.info.version = value,
                    .description => package.info.description = value,
                    .donate => try donate.append(value),
                },
                .update => switch (try stringToEnum(UpdateField, prop.name)) {
                    .github => package.update.github = value,
                },
                .linux_x86_64 => switch (try stringToEnum(ArchField, prop.name)) {
                    .url => package.linux_x86_64.url = value,
                    .hash => package.linux_x86_64.hash = value,
                    .install_bin => try install_bin.append(value),
                    .install_lib => try install_lib.append(value),
                    .install_share => try install_share.append(value),
                },
            }
        },
        .end => {
            package.info.donate = try donate.toOwnedSlice();
            package.linux_x86_64.install_bin = try install_bin.toOwnedSlice();
            package.linux_x86_64.install_lib = try install_lib.toOwnedSlice();
            package.linux_x86_64.install_share = try install_share.toOwnedSlice();
            return;
        },
    };
}

fn stringToEnum(comptime T: type, str: []const u8) !T {
    return std.meta.stringToEnum(T, str) orelse error.InvalidPackagesIni;
}

pub fn writeToFileOverride(packages: Packages, file: std.fs.File) !void {
    try file.seekTo(0);
    try packages.writeToFile(file);
    try file.setEndPos(try file.getPos());
}

pub fn writeToFile(packages: Packages, file: std.fs.File) !void {
    var buffered_writer = std.io.bufferedWriter(file.writer());
    try packages.write(buffered_writer.writer());
    try buffered_writer.flush();
}

pub fn write(packages: Packages, writer: anytype) !void {
    for (packages.packages.keys(), packages.packages.values(), 0..) |package_name, package, i| {
        if (i != 0)
            try writer.writeAll("\n");

        try package.write(package_name, writer);
    }
}

fn expectWrite(packages: *Packages, string: []const u8) !void {
    var rendered = std.ArrayList(u8).init(std.testing.allocator);
    defer rendered.deinit();

    try packages.write(rendered.writer());
    try std.testing.expectEqualStrings(string, rendered.items);
}

fn expectCanonical(string: []const u8) !void {
    var packages = try parse(std.testing.allocator, string);
    defer packages.deinit();

    return expectWrite(&packages, string);
}

test "parse" {
    try expectCanonical(
        \\[test.info]
        \\version = 0.0.0
        \\description = Test package 1
        \\donate = donate/link1
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
        \\description = Test package 2
        \\donate = donate/link2
        \\donate = donate/link3
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

fn parseAndWrite(gpa: std.mem.Allocator, string: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(gpa);
    defer out.deinit();

    var packages = try parse(gpa, string);
    defer packages.deinit();

    try packages.write(out.writer());
    return out.toOwnedSlice();
}

test "parse.fuzz" {
    try std.testing.fuzz(fuzz.fnFromParseAndWrite(parseAndWrite), .{});
}

pub fn sort(packages: *Packages) void {
    packages.packages.sort(struct {
        keys: []const []const u8,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return std.mem.lessThan(u8, ctx.keys[a_index], ctx.keys[b_index]);
        }
    }{ .keys = packages.packages.keys() });
}

test sort {
    var packages = Packages.init(std.testing.allocator);
    defer packages.deinit();

    try std.testing.expect(try packages.update(.{
        .name = "btest",
        .package = .{
            .info = .{ .version = "0.2.0" },
            .update = .{ .github = "test/test" },
            .linux_x86_64 = .{
                .hash = "test_hash",
                .url = "test_url",
            },
        },
    }, .{}) == null);
    try std.testing.expect(try packages.update(.{
        .name = "atest",
        .package = .{
            .info = .{ .version = "0.2.0" },
            .update = .{ .github = "test/test" },
            .linux_x86_64 = .{
                .hash = "test_hash",
                .url = "test_url",
            },
        },
    }, .{}) == null);
    try expectWrite(&packages,
        \\[btest.info]
        \\version = 0.2.0
        \\
        \\[btest.update]
        \\github = test/test
        \\
        \\[btest.linux_x86_64]
        \\url = test_url
        \\hash = test_hash
        \\
        \\[atest.info]
        \\version = 0.2.0
        \\
        \\[atest.update]
        \\github = test/test
        \\
        \\[atest.linux_x86_64]
        \\url = test_url
        \\hash = test_hash
        \\
    );

    packages.sort();
    try expectWrite(&packages,
        \\[atest.info]
        \\version = 0.2.0
        \\
        \\[atest.update]
        \\github = test/test
        \\
        \\[atest.linux_x86_64]
        \\url = test_url
        \\hash = test_hash
        \\
        \\[btest.info]
        \\version = 0.2.0
        \\
        \\[btest.update]
        \\github = test/test
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
pub fn update(packages: *Packages, package: Package.Named, options: UpdateOptions) !?Package {
    const gpa = packages.arena.child_allocator;
    const entry = try packages.packages.getOrPut(gpa, package.name);
    if (entry.found_existing) {
        const old_package = entry.value_ptr.*;
        entry.value_ptr.linux_x86_64.install_bin = try updateInstall(.{
            .arena = packages.arena.allocator(),
            .tmp_gpa = packages.arena.child_allocator,
            .old_version = entry.value_ptr.*.info.version,
            .old_installs = entry.value_ptr.*.linux_x86_64.install_bin,
            .new_version = package.package.info.version,
            .new_installs = package.package.linux_x86_64.install_bin,
        });
        entry.value_ptr.linux_x86_64.install_lib = try updateInstall(.{
            .arena = packages.arena.allocator(),
            .tmp_gpa = packages.arena.child_allocator,
            .old_version = entry.value_ptr.*.info.version,
            .old_installs = entry.value_ptr.*.linux_x86_64.install_lib,
            .new_version = package.package.info.version,
            .new_installs = package.package.linux_x86_64.install_lib,
        });
        entry.value_ptr.linux_x86_64.install_share = try updateInstall(.{
            .arena = packages.arena.allocator(),
            .tmp_gpa = packages.arena.child_allocator,
            .old_version = entry.value_ptr.*.info.version,
            .old_installs = entry.value_ptr.*.linux_x86_64.install_share,
            .new_version = package.package.info.version,
            .new_installs = package.package.linux_x86_64.install_share,
        });

        entry.value_ptr.info.version = package.package.info.version;
        entry.value_ptr.info.donate = package.package.info.donate;
        entry.value_ptr.linux_x86_64.url = package.package.linux_x86_64.url;
        entry.value_ptr.linux_x86_64.hash = package.package.linux_x86_64.hash;

        if (options.description)
            entry.value_ptr.info.description = package.package.info.description;

        return old_package;
    } else {
        entry.value_ptr.* = package.package;
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
    var packages = Packages.init(std.testing.allocator);
    defer packages.deinit();

    try expectWrite(&packages, "");

    try std.testing.expect(try packages.update(.{
        .name = "test",
        .package = .{
            .info = .{
                .version = "0.1.0",
                .description = "Test package",
                .donate = &.{ "donate-link", "donate-link" },
            },
            .update = .{ .github = "test/test" },
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
    try expectWrite(&packages,
        \\[test.info]
        \\version = 0.1.0
        \\description = Test package
        \\donate = donate-link
        \\donate = donate-link
        \\
        \\[test.update]
        \\github = test/test
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
        .package = .{
            .info = .{ .version = "0.2.0" },
            .update = .{ .github = "test/test" },
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
    try std.testing.expect(try packages.update(new_version, .{}) != null);
    try expectWrite(&packages,
        \\[test.info]
        \\version = 0.2.0
        \\description = Test package
        \\
        \\[test.update]
        \\github = test/test
        \\
        \\[test.linux_x86_64]
        \\install_bin = test-0.2.0/test
        \\install_bin = test2:test-0.2.0
        \\install_bin = test3
        \\url = test_url2
        \\hash = test_hash2
        \\
    );

    try std.testing.expect(try packages.update(new_version, .{
        .description = true,
    }) != null);
    try expectWrite(&packages,
        \\[test.info]
        \\version = 0.2.0
        \\
        \\[test.update]
        \\github = test/test
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
