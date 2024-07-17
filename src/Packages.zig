arena: std.heap.ArenaAllocator,
packages: std.StringArrayHashMapUnmanaged(Package),

pub fn init(allocator: std.mem.Allocator) Packages {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .packages = .{},
    };
}

const DownloadOptions = struct {
    allocator: std.mem.Allocator,

    http_client: *std.http.Client,

    /// Successes and failures are reported to the diagnostics. Set this for more details
    /// about failures.
    diagnostics: *Diagnostics,
    progress: *Progress,

    /// The prefix path where the package manager will work and install packages
    prefix: []const u8,

    /// The URI where the package manager will download the pkgs.ini
    pkgs_uri: []const u8 = "https://github.com/Hejsil/dipm-pkgs/raw/master/pkgs.ini",

    /// The download behavior of the index.
    download: enum {
        /// Always download the latest index
        always,

        /// Only download the index if it doesn't exist locally
        only_if_required,
    },
};

pub fn download(options: DownloadOptions) !Packages {
    var packages = Packages.init(options.allocator);
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
        const download_node = options.progress.start("pkgs.ini", 1);
        defer options.progress.end(download_node);

        const result = try @import("download.zig").download(
            options.http_client,
            options.pkgs_uri,
            download_node,
            pkgs_file.writer(),
        );

        if (result.status != .ok)
            return error.DownloadGotNoneOkStatusCode; // TODO: Diagnostics

        try pkgs_file.setEndPos(try pkgs_file.getEndPos());
        try pkgs_file.seekTo(0);
    }

    const string = try pkgs_file.readToEndAlloc(options.allocator, std.math.maxInt(usize));
    defer options.allocator.free(string);

    try packages.parseInto(options.allocator, string);
    return packages;
}

pub fn deinit(packages: *Packages) void {
    packages.packages.deinit(packages.arena.child_allocator);
    packages.arena.deinit();
    packages.* = undefined;
}

pub fn parseFromPath(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    sub_path: []const u8,
) !Packages {
    const file = try dir.openFile(sub_path, .{});
    defer file.close();

    return parseFile(allocator, file);
}

pub fn parseFile(allocator: std.mem.Allocator, file: std.fs.File) !Packages {
    const string = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(string);

    return parse(allocator, string);
}

pub fn parse(allocator: std.mem.Allocator, string: []const u8) !Packages {
    var res = Packages.init(allocator);
    errdefer res.deinit();

    try res.parseInto(allocator, string);
    return res;
}

pub fn parseInto(packages: *Packages, tmp_allocator: std.mem.Allocator, string: []const u8) !void {
    const gpa = packages.arena.child_allocator;
    const arena = packages.arena.allocator();

    // TODO: This is quite an inefficient implementation. It first parsers a dynamic ini and then
    //       extracts the fields. Instead, the parsing needs to be done manually, or a ini parser
    //       that can parse into T is needed.

    const dynamic = try ini.Dynamic.parse(tmp_allocator, string, .{
        .allocate = ini.Dynamic.Allocate.none,
    });
    defer dynamic.deinit();

    var package_names = std.StringArrayHashMapUnmanaged(void){};
    defer package_names.deinit(tmp_allocator);

    try package_names.ensureTotalCapacity(tmp_allocator, dynamic.sections.count());
    for (dynamic.sections.keys()) |section_name| {
        var name_split = std.mem.splitScalar(u8, section_name, '.');
        const package_name = name_split.first();
        package_names.putAssumeCapacity(package_name, {});
    }

    var tmp_buffer = std.ArrayList(u8).init(tmp_allocator);
    defer tmp_buffer.deinit();

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

        try packages.packages.putNoClobber(gpa, package_name, .{
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

/// Update a package. If it doesn't exist it is added.
pub fn update(packages: *Packages, package: Package.Named) !void {
    const gpa = packages.arena.child_allocator;
    const entry = try packages.packages.getOrPut(gpa, package.name);
    if (entry.found_existing) {
        // TODO: Update the install_bin/lib/share somehow
        entry.value_ptr.*.info.version = package.package.info.version;
        entry.value_ptr.*.linux_x86_64.url = package.package.linux_x86_64.url;
        entry.value_ptr.*.linux_x86_64.hash = package.package.linux_x86_64.hash;
    } else {
        entry.value_ptr.* = package.package;
    }
}

test update {
    var packages = Packages.init(std.testing.allocator);
    defer packages.deinit();

    try expectWrite(&packages, "");

    try packages.update(.{
        .name = "test",
        .package = .{
            .info = .{ .version = "0.1.0" },
            .update = .{ .github = "test/test" },
            .linux_x86_64 = .{
                .bin = &.{"test:test/test"},
                .lib = &.{},
                .share = &.{},
                .hash = "test_hash1",
                .url = "test_url1",
            },
        },
    });
    try expectWrite(&packages,
        \\[test.info]
        \\version = 0.1.0
        \\
        \\[test.update]
        \\github = test/test
        \\
        \\[test.linux_x86_64]
        \\install_bin = test:test/test
        \\url = test_url1
        \\hash = test_hash1
        \\
    );

    try packages.update(.{
        .name = "test",
        .package = .{
            .info = .{ .version = "0.2.0" },
            .update = .{ .github = "test/test" },
            .linux_x86_64 = .{
                .bin = &.{"test:test/test"},
                .lib = &.{},
                .share = &.{},
                .hash = "test_hash2",
                .url = "test_url2",
            },
        },
    });
    try expectWrite(&packages,
        \\[test.info]
        \\version = 0.2.0
        \\
        \\[test.update]
        \\github = test/test
        \\
        \\[test.linux_x86_64]
        \\install_bin = test:test/test
        \\url = test_url2
        \\hash = test_hash2
        \\
    );
}

test {
    _ = Diagnostics;
    _ = Package;
    _ = Progress;

    _ = ini;
    _ = paths;
}

const Packages = @This();

const Diagnostics = @import("Diagnostics.zig");
const Package = @import("Package.zig");
const Progress = @import("Progress.zig");

const ini = @import("ini.zig");
const paths = @import("paths.zig");
const std = @import("std");
