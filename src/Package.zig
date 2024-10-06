info: Info,
update: Update,
linux_x86_64: InstallArch,

const Info = struct {
    version: []const u8,
    donate: []const []const u8 = &.{},
};

const Update = struct {
    github: []const u8,
};

const InstallArch = struct {
    url: []const u8,
    hash: []const u8,
    bin: []const []const u8,
    lib: []const []const u8,
    share: []const []const u8,
};

pub const Install = struct {
    from: []const u8,
    to: []const u8,

    pub fn fromString(string: []const u8) Install {
        if (std.mem.indexOfScalar(u8, string, ':')) |colon_index| {
            return .{
                .to = string[0..colon_index],
                .from = string[colon_index + 1 ..],
            };
        } else {
            return .{
                .to = std.fs.path.basename(string),
                .from = string,
            };
        }
    }
};

pub const Named = struct {
    name: []const u8,
    package: Package,

    pub fn deinit(package: Named, allocator: std.mem.Allocator) void {
        allocator.free(package.name);
        package.package.deinit(allocator);
    }
};

pub fn deinit(package: Package, allocator: std.mem.Allocator) void {
    heap.freeItems(allocator, package.linux_x86_64.bin);
    heap.freeItems(allocator, package.linux_x86_64.lib);
    heap.freeItems(allocator, package.linux_x86_64.share);

    allocator.free(package.info.version);
    allocator.free(package.update.github);
    allocator.free(package.linux_x86_64.url);
    allocator.free(package.linux_x86_64.hash);
    allocator.free(package.linux_x86_64.bin);
    allocator.free(package.linux_x86_64.lib);
    allocator.free(package.linux_x86_64.share);
}

pub const Specific = struct {
    name: []const u8,
    info: Info,
    update: Update,
    install: InstallArch,
};

pub fn specific(
    package: Package,
    name: []const u8,
    target: Target,
) ?Specific {
    const install = switch (target.os) {
        .linux => switch (target.arch) {
            .x86_64 => package.linux_x86_64,
            else => return null,
        },
        else => return null,
    };

    if (install.url.len == 0 or install.hash.len == 0)
        return null;

    return .{
        .name = name,
        .info = package.info,
        .update = package.update,
        .install = install,
    };
}

pub fn write(package: Package, name: []const u8, writer: anytype) !void {
    try writer.print("[{s}.info]\n", .{name});
    try writer.print("version = {s}\n", .{package.info.version});

    for (package.info.donate) |donate|
        try writer.print("donate = {s}\n", .{donate});
    try writer.writeAll("\n");

    if (package.update.github.len != 0) {
        try writer.print("[{s}.update]\n", .{name});
        try writer.print("github = {s}\n\n", .{package.update.github});
    }

    try writer.print("[{s}.linux_x86_64]\n", .{name});
    for (package.linux_x86_64.bin) |install|
        try writer.print("install_bin = {s}\n", .{install});
    for (package.linux_x86_64.lib) |install|
        try writer.print("install_lib = {s}\n", .{install});
    for (package.linux_x86_64.share) |install|
        try writer.print("install_share = {s}\n", .{install});

    try writer.print("url = {s}\n", .{package.linux_x86_64.url});
    try writer.print("hash = {s}\n", .{package.linux_x86_64.hash});
}

/// Creates a package from a url. This function will use different methods for creating the
/// package based on the domain. See:
/// * fromGithub
pub fn fromUrl(options: struct {
    /// Allocator used for the result
    allocator: std.mem.Allocator,

    /// Allocator used for internal allocations. None of the allocations made with this
    /// allocator will be returned.
    tmp_allocator: ?std.mem.Allocator = null,

    http_client: *std.http.Client,
    progress: Progress.Node = .none,

    /// Name of the package. `null` means it should be inferred
    name: ?[]const u8 = null,
    url: []const u8,

    target: Target,
}) !Named {
    const github_url = "https://github.com/";
    if (std.mem.startsWith(u8, options.url, github_url)) {
        const repo = options.url[github_url.len..];
        var repo_split = std.mem.splitScalar(u8, repo, '/');

        const repo_user = repo_split.first();
        const repo_name = repo_split.next() orelse "";
        return fromGithub(.{
            .allocator = options.allocator,
            .tmp_allocator = options.tmp_allocator,
            .http_client = options.http_client,
            .progress = options.progress,
            .name = options.name,
            .user = repo_user,
            .repo = repo_name,
            .target = options.target,
        });
    } else {
        return error.InvalidUrl;
    }
}

/// Creates a package a Github repository. Will query the github API to figure out the
/// latest release of the repository and look for suitable download links for that release.
pub fn fromGithub(options: struct {
    /// Allocator used for the result
    allocator: std.mem.Allocator,

    /// Allocator used for internal allocations. None of the allocations made with this
    /// allocator will be returned.
    tmp_allocator: ?std.mem.Allocator = null,

    http_client: *std.http.Client,
    progress: Progress.Node = .none,

    /// Name of the package. `null` means it should be inferred
    name: ?[]const u8 = null,
    user: []const u8,
    repo: []const u8,

    /// Use this uri to download the latest release json. If `null` then this uri will be used:
    /// https://api.github.com/repos/<user>/<repo>/releases/latest
    latest_release_uri: ?[]const u8 = null,

    target: Target,
}) !Named {
    const tmp_allocator = options.tmp_allocator orelse options.allocator;
    var arena_state = std.heap.ArenaAllocator.init(tmp_allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const api_uri_prefix = "https://api.github.com/";
    const latest_release_uri = options.latest_release_uri orelse try std.fmt.allocPrint(
        arena,
        "{s}repos/{s}/{s}/releases/latest",
        .{ api_uri_prefix, options.user, options.repo },
    );

    var latest_release_json = std.ArrayList(u8).init(arena);
    const release_download_result = try download.download(latest_release_json.writer(), .{
        .client = options.http_client,
        .uri_str = latest_release_uri,
        .progress = options.progress,
    });
    if (release_download_result.status != .ok)
        return error.LatestReleaseDownloadFailed;

    const LatestRelease = struct {
        tag_name: []const u8,
        assets: []const struct {
            browser_download_url: []const u8,
        },
    };

    const latest_release_value = try std.json.parseFromSlice(
        LatestRelease,
        arena,
        latest_release_json.items,
        .{ .ignore_unknown_fields = true },
    );
    const latest_release = latest_release_value.value;

    const name = try options.allocator.dupe(u8, options.name orelse options.repo);
    errdefer options.allocator.free(name);

    const version = try options.allocator.dupe(u8, versionFromTag(latest_release.tag_name));
    errdefer options.allocator.free(version);

    const download_url = try findDownloadUrl(.{
        .target = options.target,
        .extra_strings = &.{
            name,

            // Pick `sccache-v0.8.1` over `sccache-dist-v0.8.1`
            try std.fmt.allocPrint(arena, "{s}-{s}", .{ name, version }),
            try std.fmt.allocPrint(arena, "{s}_{s}", .{ name, version }),
            try std.fmt.allocPrint(arena, "{s}-{s}", .{ name, latest_release.tag_name }),
            try std.fmt.allocPrint(arena, "{s}_{s}", .{ name, latest_release.tag_name }),
        },
        // This is only save because `assets` only have the field `browser_download_url`
        .urls = @ptrCast(latest_release.assets),
    });

    var global_tmp_dir = try std.fs.cwd().makeOpenPath("/tmp/dipm/", .{});
    defer global_tmp_dir.close();

    var tmp_dir = try fs.tmpDir(global_tmp_dir, .{ .iterate = true });
    defer tmp_dir.deleteAndClose();

    const downloaded_file_name = std.fs.path.basename(download_url);
    const downloaded_file = try tmp_dir.dir.createFile(downloaded_file_name, .{ .read = true });
    defer downloaded_file.close();

    const package_download_result = try download.download(downloaded_file.writer(), .{
        .client = options.http_client,
        .uri_str = download_url,
        .progress = options.progress,
    });
    if (package_download_result.status != .ok)
        return error.FileDownloadFailed;

    // TODO: Get rid of this once we have support for bz2 compression
    var download_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const downloaded_path = try tmp_dir.dir.realpath(downloaded_file_name, &download_path_buf);

    try downloaded_file.seekTo(0);
    try fs.extract(.{
        .allocator = arena,
        .input_name = downloaded_path,
        .input_file = downloaded_file,
        .output_dir = tmp_dir.dir,
    });

    const man_pages = try findManPages(.{
        .allocator = options.allocator,
        .tmp_allocator = tmp_allocator,
        .dir = tmp_dir.dir,
    });
    errdefer {
        heap.freeItems(options.allocator, man_pages);
        options.allocator.free(man_pages);
    }

    const binaries = try findStaticallyLinkedBinaries(.{
        .allocator = options.allocator,
        .tmp_allocator = tmp_allocator,
        .arch = options.target.arch,
        .dir = tmp_dir.dir,
    });
    errdefer {
        heap.freeItems(options.allocator, binaries);
        options.allocator.free(binaries);
    }

    const hash = std.fmt.bytesToHex(package_download_result.hash, .lower);
    const hash_duped = try options.allocator.dupe(u8, &hash);
    errdefer options.allocator.free(hash_duped);

    const download_url_duped = try options.allocator.dupe(u8, download_url);
    errdefer options.allocator.free(download_url_duped);

    const github = try std.fmt.allocPrint(options.allocator, "{s}/{s}", .{
        options.user,
        options.repo,
    });
    errdefer options.allocator.free(github);

    return .{
        .name = name,
        .package = .{
            .info = .{ .version = version },
            .update = .{ .github = github },
            .linux_x86_64 = .{
                .bin = binaries,
                .lib = &.{},
                .share = man_pages,
                .url = download_url_duped,
                .hash = hash_duped,
            },
        },
    };
}

// Small static binary produced with:
//   echo 'pub export fn _start() callconv(.C) noreturn {unreachable;}' > test.zig
//   zig build-exe test.zig -OReleaseFast -fstrip -target x86_64-linux-musl
//   sstrip -z test
//   xxd -i test
const testing_static_x86_64_binary = [_]u8{
    0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x3e, 0x00, 0x01, 0x00, 0x00, 0x00, 0xb0, 0x11, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x38, 0x00, 0x04, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x06, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x40, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x18, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x92, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xa4, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x50, 0xe5, 0x74, 0x64, 0x04, 0x00, 0x00, 0x00, 0x58, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x58, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x58, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x51, 0xe5, 0x74, 0x64, 0x06, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x1b, 0x03, 0x3b, 0x14, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x58, 0x10, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x7a, 0x52, 0x00, 0x01, 0x78, 0x10, 0x01,
    0x1b, 0x0c, 0x07, 0x08, 0x90, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00,
    0x20, 0x10,
};

// Small static binary produced with:
//   echo 'pub export fn _start() callconv(.C) noreturn {unreachable;}' > test.zig
//   zig build-exe test.zig -OReleaseFast -fstrip -target arm-linux-musl
//   sstrip -z test
//   xxd -i test
const testing_static_arm_binary = [_]u8{
    0x7f, 0x45, 0x4c, 0x46, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x28, 0x00, 0x01, 0x00, 0x00, 0x00, 0xe4, 0x00, 0x02, 0x00, 0x34, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x05, 0x34, 0x00, 0x20, 0x00, 0x05, 0x00, 0x28, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x34, 0x00, 0x00, 0x00, 0x34, 0x00, 0x01, 0x00,
    0x34, 0x00, 0x01, 0x00, 0xa0, 0x00, 0x00, 0x00, 0xa0, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x01, 0x00, 0xe4, 0x00, 0x00, 0x00, 0xe4, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0xe4, 0x00, 0x00, 0x00, 0xe4, 0x00, 0x02, 0x00,
    0xe4, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x51, 0xe5, 0x74, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x06, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x70, 0xd4, 0x00, 0x00, 0x00, 0xd4, 0x00, 0x01, 0x00,
    0xd4, 0x00, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x10, 0x00, 0x01, 0x00, 0xb0, 0xb0, 0xb0, 0x80, 0x0c, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x1e, 0xff, 0x2f, 0xe1, 0x41, 0x35, 0x00, 0x00, 0x00, 0x61, 0x65, 0x61,
    0x62, 0x69, 0x00, 0x01, 0x2b, 0x00, 0x00, 0x00, 0x43, 0x32, 0x2e, 0x30, 0x39, 0x00, 0x06, 0x0a,
    0x07, 0x41, 0x08, 0x01, 0x09, 0x02, 0x0a, 0x03, 0x0c, 0x01, 0x0e, 0x00, 0x11, 0x01, 0x14, 0x01,
    0x15, 0x00, 0x17, 0x03, 0x18, 0x01, 0x19, 0x01, 0x1c, 0x01, 0x22, 0x01, 0x26, 0x01, 0x4c, 0x69,
    0x6e, 0x6b, 0x65, 0x72, 0x3a, 0x20, 0x4c, 0x4c, 0x44, 0x20, 0x31, 0x38, 0x2e, 0x31, 0x2e, 0x38,
    0x00, 0x00, 0x2e, 0x41, 0x52, 0x4d, 0x2e, 0x65, 0x78, 0x69, 0x64, 0x78, 0x00, 0x2e, 0x74, 0x65,
    0x78, 0x74, 0x00, 0x2e, 0x41, 0x52, 0x4d, 0x2e, 0x61, 0x74, 0x74, 0x72,
};

fn testFromGithub(options: struct {
    /// Name of the package. `null` means it should be inferred
    name: ?[]const u8 = null,
    user: []const u8,
    repo: []const u8,
    tag_name: []const u8,
    target: Target,
    expect: []const u8,
}) !void {
    const allocator = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    var tmp_dir = try fs.zigCacheTmpDir(.{});
    defer tmp_dir.deleteAndClose();

    const tmp_dir_path = try tmp_dir.path(arena);
    const static_binary_name = try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{
        options.user,
        options.repo,
        options.tag_name,
    });
    const static_binary_path = try std.fs.path.join(arena, &.{
        tmp_dir_path,
        static_binary_name,
    });

    const cwd = std.fs.cwd();
    try cwd.writeFile(.{
        .sub_path = static_binary_path,
        .data = switch (options.target.arch) {
            .x86_64 => &testing_static_x86_64_binary,
            .arm => &testing_static_arm_binary,
            else => unreachable, // Unsupported currently
        },
    });
    const static_binary_uri = try std.fmt.allocPrint(
        arena,
        "file://{s}",
        .{static_binary_path},
    );

    const latest_release_file_path = try std.fs.path.join(arena, &.{
        tmp_dir_path,
        "latest_release.json",
    });
    try cwd.writeFile(.{
        .sub_path = latest_release_file_path,
        .data = try std.fmt.allocPrint(arena,
            \\{{
            \\  "tag_name": "{s}",
            \\  "assets": [
            \\    {{"browser_download_url": "{s}"}}
            \\  ]
            \\}}
            \\
        , .{ options.tag_name, static_binary_uri }),
    });

    const latest_release_file_uri = try std.fmt.allocPrint(
        arena,
        "file://{s}",
        .{latest_release_file_path},
    );
    const package = try fromGithub(.{
        .allocator = allocator,
        .tmp_allocator = allocator,
        .http_client = undefined, // Not used when downloading from file:// uris
        .user = options.user,
        .repo = options.repo,
        .latest_release_uri = latest_release_file_uri,
        .target = options.target,
    });
    defer package.deinit(allocator);

    const expected = try std.mem.replaceOwned(
        u8,
        arena,
        options.expect,
        "<url>",
        static_binary_uri,
    );

    var actual = std.ArrayList(u8).init(arena);
    try package.package.write(package.name, actual.writer());
    try std.testing.expectEqualStrings(expected, actual.items);
}

test fromGithub {
    try testFromGithub(.{
        .user = "junegunn",
        .repo = "fzf",
        .tag_name = "v0.54.0",
        .target = .{ .os = .linux, .arch = .x86_64 },
        .expect =
        \\[fzf.info]
        \\version = 0.54.0
        \\
        \\[fzf.update]
        \\github = junegunn/fzf
        \\
        \\[fzf.linux_x86_64]
        \\install_bin = junegunn-fzf-v0.54.0
        \\url = <url>
        \\hash = 86e9fa65b9f0f0f6949ac09c6692d78db54443bf9a69cc8ba366c5ab281b26cf
        \\
        ,
    });
    try testFromGithub(.{
        .user = "googlefonts",
        .repo = "fontc",
        .tag_name = "fontc-v0.0.1",
        .target = .{ .os = .linux, .arch = .x86_64 },
        .expect =
        \\[fontc.info]
        \\version = 0.0.1
        \\
        \\[fontc.update]
        \\github = googlefonts/fontc
        \\
        \\[fontc.linux_x86_64]
        \\install_bin = googlefonts-fontc-fontc-v0.0.1
        \\url = <url>
        \\hash = 86e9fa65b9f0f0f6949ac09c6692d78db54443bf9a69cc8ba366c5ab281b26cf
        \\
        ,
    });
}

fn findStaticallyLinkedBinaries(options: struct {
    allocator: std.mem.Allocator,
    tmp_allocator: std.mem.Allocator,
    arch: std.Target.Cpu.Arch,
    dir: std.fs.Dir,
}) ![]const []const u8 {
    var arena_state = std.heap.ArenaAllocator.init(options.tmp_allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const arch_str = switch (options.arch) {
        .x86_64 => "x86-64",
        .arm => "ARM",
        else => unreachable, // Unsupported
    };
    const shell_script = try std.fmt.allocPrint(
        arena,
        \\find -type f -exec file '{{}}' '+' |
        \\    grep -E '{s}.*(statically linked|static-pie linked)' |
        \\    cut -d: -f1 |
        \\    sed 's#^./##' |
        \\    sort
        \\
    ,
        .{arch_str},
    );

    const static_files_result = try std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ "sh", "-c", shell_script },
        .cwd_dir = options.dir,
    });

    if (static_files_result.stdout.len < 1)
        return error.NoStaticallyLinkedFiles;

    var bins_list = std.ArrayList([]const u8).init(options.allocator);
    defer {
        for (bins_list.items) |item|
            options.allocator.free(item);
        bins_list.deinit();
    }

    var static_files_lines = std.mem.tokenizeScalar(u8, static_files_result.stdout, '\n');
    while (static_files_lines.next()) |static_bin| {
        const bin = try options.allocator.dupe(u8, static_bin);
        errdefer options.allocator.free(bin);

        try bins_list.append(bin);
    }

    return bins_list.toOwnedSlice();
}

fn testFindStaticallyLinkedBinaries(options: struct {
    arch: std.Target.Cpu.Arch,
    files: []const std.fs.Dir.WriteFileOptions,
    expected: []const []const u8,
}) !void {
    var tmp_dir = try fs.zigCacheTmpDir(.{});
    defer tmp_dir.deleteAndClose();

    for (options.files) |file_options| {
        try tmp_dir.dir.makePath(std.fs.path.dirname(file_options.sub_path) orelse ".");
        try tmp_dir.dir.writeFile(file_options);
    }

    const allocator = std.testing.allocator;
    const result = try findStaticallyLinkedBinaries(.{
        .allocator = allocator,
        .tmp_allocator = allocator,
        .arch = options.arch,
        .dir = tmp_dir.dir,
    });
    defer {
        heap.freeItems(allocator, result);
        allocator.free(result);
    }

    const len = @min(options.expected.len, result.len);
    for (options.expected[0..len], result[0..len]) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(options.expected.len, result.len);
}

test findStaticallyLinkedBinaries {
    try testFindStaticallyLinkedBinaries(.{
        .arch = .x86_64,
        .files = &.{
            .{ .sub_path = "binary_x86_64", .data = &testing_static_x86_64_binary },
            .{ .sub_path = "binary_arm", .data = &testing_static_arm_binary },
            .{ .sub_path = "text", .data = "Text" },
            .{ .sub_path = "subdir/binary_x86_64", .data = &testing_static_x86_64_binary },
            .{ .sub_path = "subdir/binary_arm", .data = &testing_static_arm_binary },
            .{ .sub_path = "subdir/text", .data = "Text" },
        },
        .expected = &.{
            "binary_x86_64",
            "subdir/binary_x86_64",
        },
    });
    try testFindStaticallyLinkedBinaries(.{
        .arch = .arm,
        .files = &.{
            .{ .sub_path = "binary_x86_64", .data = &testing_static_x86_64_binary },
            .{ .sub_path = "binary_arm", .data = &testing_static_arm_binary },
            .{ .sub_path = "text", .data = "Text" },
            .{ .sub_path = "subdir/binary_x86_64", .data = &testing_static_x86_64_binary },
            .{ .sub_path = "subdir/binary_arm", .data = &testing_static_arm_binary },
            .{ .sub_path = "subdir/text", .data = "Text" },
        },
        .expected = &.{
            "binary_arm",
            "subdir/binary_arm",
        },
    });
}

fn findManPages(options: struct {
    allocator: std.mem.Allocator,
    tmp_allocator: std.mem.Allocator,
    dir: std.fs.Dir,
}) ![][]const u8 {
    var walker = try options.dir.walk(options.tmp_allocator);
    defer walker.deinit();

    var result = std.ArrayList([]const u8).init(options.allocator);
    defer {
        heap.freeItems(options.allocator, result.items);
        result.deinit();
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file)
            continue;
        if (std.mem.startsWith(u8, entry.basename, "."))
            continue;
        if (!isManPage(entry.basename))
            continue;

        const duped = try options.allocator.dupe(u8, entry.path);
        errdefer options.allocator.free(duped);

        try result.append(duped);
    }

    std.mem.sort([]const u8, result.items, {}, mem.sortLessThan(u8));
    return result.toOwnedSlice();
}

fn isManPage(filename: []const u8) bool {
    var basename = filename;
    if (std.mem.endsWith(u8, basename, ".gz"))
        basename = basename[0 .. basename.len - ".gz".len];

    var state: enum {
        start,
        number,
        end,
    } = .start;

    for (0..basename.len) |i_forward| {
        const i_backward = (basename.len - i_forward) - 1;
        const c = basename[i_backward];
        switch (state) {
            .start => switch (c) {
                '0'...'9' => state = .number,
                else => return false,
            },
            .number => switch (c) {
                '0'...'9' => {},
                '.' => state = .end,
                else => return false,
            },
            .end => switch (c) {
                // This seems like a binary ending with a version number, like fzf-0.2.2
                '0'...'9' => return false,
                else => return true,
            },
        }
    }

    return false;
}

fn testfindManPages(options: struct {
    files: []const std.fs.Dir.WriteFileOptions,
    expected: []const []const u8,
}) !void {
    var tmp_dir = try fs.zigCacheTmpDir(.{ .iterate = true });
    defer tmp_dir.deleteAndClose();

    for (options.files) |file_options| {
        try tmp_dir.dir.makePath(std.fs.path.dirname(file_options.sub_path) orelse ".");
        try tmp_dir.dir.writeFile(file_options);
    }

    const allocator = std.testing.allocator;
    const result = try findManPages(.{
        .allocator = allocator,
        .tmp_allocator = allocator,
        .dir = tmp_dir.dir,
    });
    defer {
        heap.freeItems(allocator, result);
        allocator.free(result);
    }

    const len = @min(options.expected.len, result.len);
    for (options.expected[0..len], result[0..len]) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(options.expected.len, result.len);
}

test findManPages {
    try testfindManPages(.{
        .files = &.{
            .{ .sub_path = "text", .data = "" },
            .{ .sub_path = "1", .data = "" },
            .{ .sub_path = "1.gz", .data = "" },
            .{ .sub_path = "text.1", .data = "" },
            .{ .sub_path = "text.1.gz", .data = "" },
            .{ .sub_path = ".text.1.gz", .data = "" },
            .{ .sub_path = "text.10", .data = "" },
            .{ .sub_path = "text.10.gz", .data = "" },
            .{ .sub_path = ".text.10.gz", .data = "" },
            .{ .sub_path = "text-0.2.0", .data = "" },
            .{ .sub_path = "subdir/text", .data = "" },
            .{ .sub_path = "subdir/1", .data = "" },
            .{ .sub_path = "subdir/1.gz", .data = "" },
            .{ .sub_path = "subdir/text.1", .data = "" },
            .{ .sub_path = "subdir/text.1.gz", .data = "" },
            .{ .sub_path = "subdir/.text.1.gz", .data = "" },
            .{ .sub_path = "subdir/text.10", .data = "" },
            .{ .sub_path = "subdir/text.10.gz", .data = "" },
            .{ .sub_path = "subdir/.text.10.gz", .data = "" },
            .{ .sub_path = "subdir/text-0.2.0", .data = "" },
        },
        .expected = &.{
            "subdir/text.1",
            "subdir/text.1.gz",
            "subdir/text.10",
            "subdir/text.10.gz",
            "text.1",
            "text.1.gz",
            "text.10",
            "text.10.gz",
        },
    });
}

fn findDownloadUrl(options: struct {
    target: Target,
    extra_strings: []const []const u8 = &.{},
    urls: []const []const u8,
}) ![]const u8 {
    if (options.urls.len == 0)
        return error.DownloadUrlNotFound;

    var best_score: usize = 0;
    var best_index: usize = 0;

    for (options.urls, 0..) |url, i| {
        const basename = std.fs.path.basename(url);
        var this_score: usize = 0;

        this_score += std.mem.count(u8, basename, @tagName(options.target.arch));
        this_score += std.mem.count(u8, basename, @tagName(options.target.os));

        switch (options.target.os) {
            .linux => {
                this_score += std.mem.count(u8, basename, "Linux");

                // Targeting musl abi or the alpine distro tends mean the executable is statically
                // linked
                this_score += std.mem.count(u8, basename, "alpine");
                this_score += std.mem.count(u8, basename, "musl");
                this_score += std.mem.count(u8, basename, "static");
            },
            else => {},
        }

        switch (options.target.arch) {
            .x86_64 => {
                this_score += std.mem.count(u8, basename, "64bit");
                this_score += std.mem.count(u8, basename, "amd64");
                this_score += std.mem.count(u8, basename, "x64");
                this_score += std.mem.count(u8, basename, "x86-64");

                switch (options.target.os) {
                    .linux => {
                        this_score += std.mem.count(u8, basename, "linux64");
                    },
                    else => {},
                }
            },
            .x86 => {
                this_score += std.mem.count(u8, basename, "32bit");
            },
            else => {},
        }

        // The above rules are the most important
        this_score *= 10;

        var buf: [std.mem.page_size]u8 = undefined;
        for (options.extra_strings) |string| {
            this_score += std.mem.count(u8, basename, string);
            // We wonna pick `tau` instead of `taucorder`. Most of the time, these names are
            // separated with `_` or `-`
            this_score += std.mem.count(u8, basename, try std.fmt.bufPrint(&buf, "{s}_", .{string}));
            this_score += std.mem.count(u8, basename, try std.fmt.bufPrint(&buf, "{s}-", .{string}));
            this_score += std.mem.count(u8, basename, try std.fmt.bufPrint(&buf, "_{s}", .{string}));
            this_score += std.mem.count(u8, basename, try std.fmt.bufPrint(&buf, "-{s}", .{string}));
            this_score += std.mem.count(u8, basename, try std.fmt.bufPrint(&buf, "_{s}_", .{string}));
            this_score += std.mem.count(u8, basename, try std.fmt.bufPrint(&buf, "-{s}-", .{string}));
        }

        // Certain extensions indicate means the link downloads a signature, deb package or other
        // none useful resources to `dipm`
        const deprioritized_extensions = [_][]const u8{
            ".asc",
            ".b3",
            ".deb",
            ".json",
            ".pem",
            ".proof",
            ".pub",
            ".rpm",
            ".sbom",
            ".sha",
            ".sha256",
            ".sha256sum",
            ".sha512",
            ".sha512sum",
            ".sig",
        };
        for (deprioritized_extensions) |ext|
            this_score -|= @as(usize, @intFromBool(std.mem.endsWith(u8, basename, ext))) * 1000;

        // Avoid debug builds of binaries
        this_score -|= std.mem.count(u8, basename, "debug");

        switch (options.target.os) {
            .linux => {
                // Targeting the gnu abi tends to not be statically linked
                this_score -|= std.mem.count(u8, basename, "gnu");
            },
            else => {},
        }

        if (this_score > best_score) {
            best_score = this_score;
            best_index = i;
        }

        // If scores are equal, use the length of the url as a tiebreaker
        if (this_score == best_score and url.len > options.urls[best_index].len) {
            best_score = this_score;
            best_index = i;
        }
    }

    return options.urls[best_index];
}

test findDownloadUrl {
    try std.testing.expectEqualStrings("/fzf-0.54.0-linux_amd64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"fzf"},
        .urls = &.{
            "/fzf-0.54.0-darwin_amd64.zip",
            "/fzf-0.54.0-darwin_arm64.zip",
            "/fzf-0.54.0-freebsd_amd64.tar.gz",
            "/fzf-0.54.0-linux_amd64.tar.gz",
            "/fzf-0.54.0-linux_arm64.tar.gz",
            "/fzf-0.54.0-linux_armv5.tar.gz",
            "/fzf-0.54.0-linux_armv6.tar.gz",
            "/fzf-0.54.0-linux_armv7.tar.gz",
            "/fzf-0.54.0-linux_loong64.tar.gz",
            "/fzf-0.54.0-linux_ppc64le.tar.gz",
            "/fzf-0.54.0-linux_s390x.tar.gz",
            "/fzf-0.54.0-openbsd_amd64.tar.gz",
            "/fzf-0.54.0-windows_amd64.zip",
            "/fzf-0.54.0-windows_arm64.zip",
            "/fzf-0.54.0-windows_armv5.zip",
            "/fzf-0.54.0-windows_armv6.zip",
            "/fzf-0.54.0-windows_armv7.zip",
            "/fzf_0.54.0_checksums.txt",
        },
    }));
    try std.testing.expectEqualStrings("/fzf-0.54.0-windows_amd64.zip", try findDownloadUrl(.{
        .target = .{ .os = .windows, .arch = .x86_64 },
        .extra_strings = &.{"fzf"},
        .urls = &.{
            "/fzf-0.54.0-darwin_amd64.zip",
            "/fzf-0.54.0-darwin_arm64.zip",
            "/fzf-0.54.0-freebsd_amd64.tar.gz",
            "/fzf-0.54.0-linux_amd64.tar.gz",
            "/fzf-0.54.0-linux_arm64.tar.gz",
            "/fzf-0.54.0-linux_armv5.tar.gz",
            "/fzf-0.54.0-linux_armv6.tar.gz",
            "/fzf-0.54.0-linux_armv7.tar.gz",
            "/fzf-0.54.0-linux_loong64.tar.gz",
            "/fzf-0.54.0-linux_ppc64le.tar.gz",
            "/fzf-0.54.0-linux_s390x.tar.gz",
            "/fzf-0.54.0-openbsd_amd64.tar.gz",
            "/fzf-0.54.0-windows_amd64.zip",
            "/fzf-0.54.0-windows_arm64.zip",
            "/fzf-0.54.0-windows_armv5.zip",
            "/fzf-0.54.0-windows_armv6.zip",
            "/fzf-0.54.0-windows_armv7.zip",
            "/fzf_0.54.0_checksums.txt",
        },
    }));
    try std.testing.expectEqualStrings("/gophish-v0.12.1-linux-64bit.zip", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"gophish"},
        .urls = &.{
            "/gophish-v0.12.1-linux-32bit.zip",
            "/gophish-v0.12.1-linux-64bit.zip",
            "/gophish-v0.12.1-osx-64bit.zip",
            "/gophish-v0.12.1-windows-64bit.zip",
        },
    }));
    try std.testing.expectEqualStrings("/gophish-v0.12.1-windows-64bit.zip", try findDownloadUrl(.{
        .target = .{ .os = .windows, .arch = .x86_64 },
        .extra_strings = &.{"gophish"},
        .urls = &.{
            "/gophish-v0.12.1-linux-32bit.zip",
            "/gophish-v0.12.1-linux-64bit.zip",
            "/gophish-v0.12.1-osx-64bit.zip",
            "/gophish-v0.12.1-windows-64bit.zip",
        },
    }));
    try std.testing.expectEqualStrings("/gophish-v0.12.1-linux-32bit.zip", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86 },
        .extra_strings = &.{"gophish"},
        .urls = &.{
            "/gophish-v0.12.1-linux-32bit.zip",
            "/gophish-v0.12.1-linux-64bit.zip",
            "/gophish-v0.12.1-osx-64bit.zip",
            "/gophish-v0.12.1-windows-64bit.zip",
        },
    }));
    try std.testing.expectEqualStrings("/wasmer-linux-musl-amd64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"wasmer"},
        .urls = &.{
            "/wasmer-darwin-amd64.tar.gz",
            "/wasmer-darwin-arm64.tar.gz",
            "/wasmer-linux-aarch64.tar.gz",
            "/wasmer-linux-amd64.tar.gz",
            "/wasmer-linux-musl-amd64.tar.gz",
            "/wasmer-linux-riscv64.tar.gz",
            "/wasmer-windows-amd64.tar.gz",
            "/wasmer-windows-gnu64.tar.gz",
            "/wasmer-windows.exe",
        },
    }));
    try std.testing.expectEqualStrings("/mise-v2024.7.4-linux-x64-musl.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"mise"},
        .urls = &.{
            "/mise-v2024.7.4-linux-arm64",
            "/mise-v2024.7.4-linux-arm64-musl",
            "/mise-v2024.7.4-linux-arm64-musl.tar.gz",
            "/mise-v2024.7.4-linux-arm64-musl.tar.xz",
            "/mise-v2024.7.4-linux-arm64.tar.gz",
            "/mise-v2024.7.4-linux-arm64.tar.xz",
            "/mise-v2024.7.4-linux-armv7",
            "/mise-v2024.7.4-linux-armv7-musl",
            "/mise-v2024.7.4-linux-armv7-musl.tar.gz",
            "/mise-v2024.7.4-linux-armv7-musl.tar.xz",
            "/mise-v2024.7.4-linux-armv7.tar.gz",
            "/mise-v2024.7.4-linux-armv7.tar.xz",
            "/mise-v2024.7.4-linux-x64",
            "/mise-v2024.7.4-linux-x64-musl",
            "/mise-v2024.7.4-linux-x64-musl.tar.gz",
            "/mise-v2024.7.4-linux-x64-musl.tar.xz",
            "/mise-v2024.7.4-linux-x64.tar.gz",
            "/mise-v2024.7.4-linux-x64.tar.xz",
            "/mise-v2024.7.4-macos-arm64",
            "/mise-v2024.7.4-macos-arm64.tar.gz",
            "/mise-v2024.7.4-macos-arm64.tar.xz",
            "/mise-v2024.7.4-macos-x64",
            "/mise-v2024.7.4-macos-x64.tar.gz",
            "/mise-v2024.7.4-macos-x64.tar.xz",
            "/mise-v2024.7.4-win-arm64.zip",
            "/mise-v2024.7.4-win-x64.zip",
        },
    }));
    try std.testing.expectEqualStrings("/shadowsocks-v1.20.3.x86_64-unknown-linux-musl.tar.xz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"shadowsocks"},
        .urls = &.{
            "/shadowsocks-v1.20.3.aarch64-apple-darwin.tar.xz",
            "/shadowsocks-v1.20.3.aarch64-apple-darwin.tar.xz.sha256",
            "/shadowsocks-v1.20.3.aarch64-unknown-linux-gnu.tar.xz",
            "/shadowsocks-v1.20.3.aarch64-unknown-linux-gnu.tar.xz.sha256",
            "/shadowsocks-v1.20.3.aarch64-unknown-linux-musl.tar.xz",
            "/shadowsocks-v1.20.3.aarch64-unknown-linux-musl.tar.xz.sha256",
            "/shadowsocks-v1.20.3.arm-unknown-linux-gnueabi.tar.xz",
            "/shadowsocks-v1.20.3.arm-unknown-linux-gnueabi.tar.xz.sha256",
            "/shadowsocks-v1.20.3.arm-unknown-linux-gnueabihf.tar.xz",
            "/shadowsocks-v1.20.3.arm-unknown-linux-gnueabihf.tar.xz.sha256",
            "/shadowsocks-v1.20.3.arm-unknown-linux-musleabi.tar.xz",
            "/shadowsocks-v1.20.3.arm-unknown-linux-musleabi.tar.xz.sha256",
            "/shadowsocks-v1.20.3.arm-unknown-linux-musleabihf.tar.xz",
            "/shadowsocks-v1.20.3.arm-unknown-linux-musleabihf.tar.xz.sha256",
            "/shadowsocks-v1.20.3.armv7-unknown-linux-gnueabihf.tar.xz",
            "/shadowsocks-v1.20.3.armv7-unknown-linux-gnueabihf.tar.xz.sha256",
            "/shadowsocks-v1.20.3.armv7-unknown-linux-musleabihf.tar.xz",
            "/shadowsocks-v1.20.3.armv7-unknown-linux-musleabihf.tar.xz.sha256",
            "/shadowsocks-v1.20.3.i686-unknown-linux-musl.tar.xz",
            "/shadowsocks-v1.20.3.i686-unknown-linux-musl.tar.xz.sha256",
            "/shadowsocks-v1.20.3.x86_64-apple-darwin.tar.xz",
            "/shadowsocks-v1.20.3.x86_64-apple-darwin.tar.xz.sha256",
            "/shadowsocks-v1.20.3.x86_64-pc-windows-gnu.zip",
            "/shadowsocks-v1.20.3.x86_64-pc-windows-gnu.zip.sha256",
            "/shadowsocks-v1.20.3.x86_64-pc-windows-msvc.zip",
            "/shadowsocks-v1.20.3.x86_64-pc-windows-msvc.zip.sha256",
            "/shadowsocks-v1.20.3.x86_64-unknown-linux-gnu.tar.xz",
            "/shadowsocks-v1.20.3.x86_64-unknown-linux-gnu.tar.xz.sha256",
            "/shadowsocks-v1.20.3.x86_64-unknown-linux-musl.tar.xz",
            "/shadowsocks-v1.20.3.x86_64-unknown-linux-musl.tar.xz.sha256",
        },
    }));
    try std.testing.expectEqualStrings("/sigrs-x86_64-unknown-linux-musl.tar.xz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"sigrs"},
        .urls = &.{
            "/dist-manifest.json",
            "/sigrs-aarch64-apple-darwin.tar.xz",
            "/sigrs-aarch64-apple-darwin.tar.xz.sha256",
            "/sigrs-x86_64-apple-darwin.tar.xz",
            "/sigrs-x86_64-apple-darwin.tar.xz.sha256",
            "/sigrs-x86_64-pc-windows-msvc.zip",
            "/sigrs-x86_64-pc-windows-msvc.zip.sha256",
            "/sigrs-x86_64-unknown-linux-gnu.tar.xz",
            "/sigrs-x86_64-unknown-linux-gnu.tar.xz.sha256",
            "/sigrs-x86_64-unknown-linux-musl.tar.xz",
            "/sigrs-x86_64-unknown-linux-musl.tar.xz.sha256",
            "/sigrs.rb",
            "/source.tar.gz",
            "/source.tar.gz.sha256",
        },
    }));
    try std.testing.expectEqualStrings("/dockerc_x86-64", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"dockerc"},
        .urls = &.{
            "/dockerc_aarch64",
            "/dockerc_x86-64",
            "/dockerc_x86-64-gnu",
        },
    }));
    try std.testing.expectEqualStrings("/micro-2.0.14-linux64-static.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"micro"},
        .urls = &.{
            "/micro-2.0.14-linux64-static.tar.gz",
            "/micro-2.0.14-linux64.tar.gz",
        },
    }));
    try std.testing.expectEqualStrings("/jq-linux64", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"jq"},
        .urls = &.{
            "/jq-1.7.1.tar.gz",
            "/jq-1.7.1.zip",
            "/jq-linux-amd64",
            "/jq-linux-arm64",
            "/jq-linux-armel",
            "/jq-linux-armhf",
            "/jq-linux-i386",
            "/jq-linux-mips",
            "/jq-linux-mips64",
            "/jq-linux-mips64el",
            "/jq-linux-mips64r6",
            "/jq-linux-mips64r6el",
            "/jq-linux-mipsel",
            "/jq-linux-mipsr6",
            "/jq-linux-mipsr6el",
            "/jq-linux-powerpc",
            "/jq-linux-ppc64el",
            "/jq-linux-riscv64",
            "/jq-linux-s390x",
            "/jq-linux64",
            "/jq-macos-amd64",
            "/jq-macos-arm64",
            "/jq-osx-amd64",
            "/jq-win64.exe",
            "/jq-windows-amd64.exe",
            "/jq-windows-i386.exe",
            "/sha256sum.txt",
            "/jq-1.7.1.tar.gz",
        },
    }));
    try std.testing.expectEqualStrings("/act_Linux_x86_64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"act"},
        .urls = &.{
            "/act_Darwin_arm64.tar.gz",
            "/act_Darwin_x86_64.tar.gz",
            "/act_Linux_arm64.tar.gz",
            "/act_Linux_armv6.tar.gz",
            "/act_Linux_armv7.tar.gz",
            "/act_Linux_i386.tar.gz",
            "/act_Linux_riscv64.tar.gz",
            "/act_Linux_x86_64.tar.gz",
            "/act_Windows_arm64.zip",
            "/act_Windows_armv7.zip",
            "/act_Windows_i386.zip",
            "/act_Windows_x86_64.zip",
            "/checksums.txt",
        },
    }));
    try std.testing.expectEqualStrings("/age-v1.2.0-linux-amd64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"age"},
        .urls = &.{
            "/age-v1.2.0-darwin-amd64.tar.gz",
            "/age-v1.2.0-darwin-amd64.tar.gz.proof",
            "/age-v1.2.0-darwin-arm64.tar.gz",
            "/age-v1.2.0-darwin-arm64.tar.gz.proof",
            "/age-v1.2.0-freebsd-amd64.tar.gz",
            "/age-v1.2.0-freebsd-amd64.tar.gz.proof",
            "/age-v1.2.0-linux-amd64.tar.gz",
            "/age-v1.2.0-linux-amd64.tar.gz.proof",
            "/age-v1.2.0-linux-arm.tar.gz",
            "/age-v1.2.0-linux-arm.tar.gz.proof",
            "/age-v1.2.0-linux-arm64.tar.gz",
            "/age-v1.2.0-linux-arm64.tar.gz.proof",
            "/age-v1.2.0-windows-amd64.zip",
            "/age-v1.2.0-windows-amd64.zip.proof",
        },
    }));
    try std.testing.expectEqualStrings("/caddy_2.8.4_linux_amd64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"caddy"},
        .urls = &.{
            "/caddy_2.8.4_buildable-artifact.pem",
            "/caddy_2.8.4_buildable-artifact.tar.gz",
            "/caddy_2.8.4_buildable-artifact.tar.gz.sig",
            "/caddy_2.8.4_checksums.txt",
            "/caddy_2.8.4_checksums.txt.pem",
            "/caddy_2.8.4_checksums.txt.sig",
            "/caddy_2.8.4_freebsd_amd64.pem",
            "/caddy_2.8.4_freebsd_amd64.sbom",
            "/caddy_2.8.4_freebsd_amd64.sbom.pem",
            "/caddy_2.8.4_freebsd_amd64.sbom.sig",
            "/caddy_2.8.4_freebsd_amd64.tar.gz",
            "/caddy_2.8.4_freebsd_amd64.tar.gz.sig",
            "/caddy_2.8.4_freebsd_arm64.pem",
            "/caddy_2.8.4_freebsd_arm64.sbom",
            "/caddy_2.8.4_freebsd_arm64.sbom.pem",
            "/caddy_2.8.4_freebsd_arm64.sbom.sig",
            "/caddy_2.8.4_freebsd_arm64.tar.gz",
            "/caddy_2.8.4_freebsd_arm64.tar.gz.sig",
            "/caddy_2.8.4_freebsd_armv6.pem",
            "/caddy_2.8.4_freebsd_armv6.sbom",
            "/caddy_2.8.4_freebsd_armv6.sbom.pem",
            "/caddy_2.8.4_freebsd_armv6.sbom.sig",
            "/caddy_2.8.4_freebsd_armv6.tar.gz",
            "/caddy_2.8.4_freebsd_armv6.tar.gz.sig",
            "/caddy_2.8.4_freebsd_armv7.pem",
            "/caddy_2.8.4_freebsd_armv7.sbom",
            "/caddy_2.8.4_freebsd_armv7.sbom.pem",
            "/caddy_2.8.4_freebsd_armv7.sbom.sig",
            "/caddy_2.8.4_freebsd_armv7.tar.gz",
            "/caddy_2.8.4_freebsd_armv7.tar.gz.sig",
            "/caddy_2.8.4_linux_amd64.deb",
            "/caddy_2.8.4_linux_amd64.deb.pem",
            "/caddy_2.8.4_linux_amd64.deb.sig",
            "/caddy_2.8.4_linux_amd64.pem",
            "/caddy_2.8.4_linux_amd64.sbom",
            "/caddy_2.8.4_linux_amd64.sbom.pem",
            "/caddy_2.8.4_linux_amd64.sbom.sig",
            "/caddy_2.8.4_linux_amd64.tar.gz",
            "/caddy_2.8.4_linux_amd64.tar.gz.sig",
            "/caddy_2.8.4_linux_arm64.deb",
            "/caddy_2.8.4_linux_arm64.deb.pem",
            "/caddy_2.8.4_linux_arm64.deb.sig",
            "/caddy_2.8.4_linux_arm64.pem",
            "/caddy_2.8.4_linux_arm64.sbom",
            "/caddy_2.8.4_linux_arm64.sbom.pem",
            "/caddy_2.8.4_linux_arm64.sbom.sig",
            "/caddy_2.8.4_linux_arm64.tar.gz",
            "/caddy_2.8.4_linux_arm64.tar.gz.sig",
            "/caddy_2.8.4_linux_armv5.deb",
            "/caddy_2.8.4_linux_armv5.deb.pem",
            "/caddy_2.8.4_linux_armv5.deb.sig",
            "/caddy_2.8.4_linux_armv5.pem",
            "/caddy_2.8.4_linux_armv5.sbom",
            "/caddy_2.8.4_linux_armv5.sbom.pem",
            "/caddy_2.8.4_linux_armv5.sbom.sig",
            "/caddy_2.8.4_linux_armv5.tar.gz",
            "/caddy_2.8.4_linux_armv5.tar.gz.sig",
            "/caddy_2.8.4_linux_armv6.deb",
            "/caddy_2.8.4_linux_armv6.deb.pem",
            "/caddy_2.8.4_linux_armv6.deb.sig",
            "/caddy_2.8.4_linux_armv6.pem",
            "/caddy_2.8.4_linux_armv6.sbom",
            "/caddy_2.8.4_linux_armv6.sbom.pem",
            "/caddy_2.8.4_linux_armv6.sbom.sig",
            "/caddy_2.8.4_linux_armv6.tar.gz",
            "/caddy_2.8.4_linux_armv6.tar.gz.sig",
            "/caddy_2.8.4_linux_armv7.deb",
            "/caddy_2.8.4_linux_armv7.deb.pem",
            "/caddy_2.8.4_linux_armv7.deb.sig",
            "/caddy_2.8.4_linux_armv7.pem",
            "/caddy_2.8.4_linux_armv7.sbom",
            "/caddy_2.8.4_linux_armv7.sbom.pem",
            "/caddy_2.8.4_linux_armv7.sbom.sig",
            "/caddy_2.8.4_linux_armv7.tar.gz",
            "/caddy_2.8.4_linux_armv7.tar.gz.sig",
            "/caddy_2.8.4_linux_ppc64le.deb",
            "/caddy_2.8.4_linux_ppc64le.deb.pem",
            "/caddy_2.8.4_linux_ppc64le.deb.sig",
            "/caddy_2.8.4_linux_ppc64le.pem",
            "/caddy_2.8.4_linux_ppc64le.sbom",
            "/caddy_2.8.4_linux_ppc64le.sbom.pem",
            "/caddy_2.8.4_linux_ppc64le.sbom.sig",
            "/caddy_2.8.4_linux_ppc64le.tar.gz",
            "/caddy_2.8.4_linux_ppc64le.tar.gz.sig",
            "/caddy_2.8.4_linux_riscv64.deb",
            "/caddy_2.8.4_linux_riscv64.deb.pem",
            "/caddy_2.8.4_linux_riscv64.deb.sig",
            "/caddy_2.8.4_linux_riscv64.pem",
            "/caddy_2.8.4_linux_riscv64.sbom",
            "/caddy_2.8.4_linux_riscv64.sbom.pem",
            "/caddy_2.8.4_linux_riscv64.sbom.sig",
            "/caddy_2.8.4_linux_riscv64.tar.gz",
            "/caddy_2.8.4_linux_riscv64.tar.gz.sig",
            "/caddy_2.8.4_linux_s390x.deb",
            "/caddy_2.8.4_linux_s390x.deb.pem",
            "/caddy_2.8.4_linux_s390x.deb.sig",
            "/caddy_2.8.4_linux_s390x.pem",
            "/caddy_2.8.4_linux_s390x.sbom",
            "/caddy_2.8.4_linux_s390x.sbom.pem",
            "/caddy_2.8.4_linux_s390x.sbom.sig",
            "/caddy_2.8.4_linux_s390x.tar.gz",
            "/caddy_2.8.4_linux_s390x.tar.gz.sig",
            "/caddy_2.8.4_mac_amd64.pem",
            "/caddy_2.8.4_mac_amd64.sbom",
            "/caddy_2.8.4_mac_amd64.sbom.pem",
            "/caddy_2.8.4_mac_amd64.sbom.sig",
            "/caddy_2.8.4_mac_amd64.tar.gz",
            "/caddy_2.8.4_mac_amd64.tar.gz.sig",
            "/caddy_2.8.4_mac_arm64.pem",
            "/caddy_2.8.4_mac_arm64.sbom",
            "/caddy_2.8.4_mac_arm64.sbom.pem",
            "/caddy_2.8.4_mac_arm64.sbom.sig",
            "/caddy_2.8.4_mac_arm64.tar.gz",
            "/caddy_2.8.4_mac_arm64.tar.gz.sig",
            "/caddy_2.8.4_src.pem",
            "/caddy_2.8.4_src.tar.gz",
            "/caddy_2.8.4_src.tar.gz.sig",
            "/caddy_2.8.4_windows_amd64.pem",
            "/caddy_2.8.4_windows_amd64.sbom",
            "/caddy_2.8.4_windows_amd64.sbom.pem",
            "/caddy_2.8.4_windows_amd64.sbom.sig",
            "/caddy_2.8.4_windows_amd64.zip",
            "/caddy_2.8.4_windows_amd64.zip.sig",
            "/caddy_2.8.4_windows_arm64.pem",
            "/caddy_2.8.4_windows_arm64.sbom",
            "/caddy_2.8.4_windows_arm64.sbom.pem",
            "/caddy_2.8.4_windows_arm64.sbom.sig",
            "/caddy_2.8.4_windows_arm64.zip",
            "/caddy_2.8.4_windows_arm64.zip.sig",
            "/caddy_2.8.4_windows_armv5.pem",
            "/caddy_2.8.4_windows_armv5.sbom",
            "/caddy_2.8.4_windows_armv5.sbom.pem",
            "/caddy_2.8.4_windows_armv5.sbom.sig",
            "/caddy_2.8.4_windows_armv5.zip",
            "/caddy_2.8.4_windows_armv5.zip.sig",
            "/caddy_2.8.4_windows_armv6.pem",
            "/caddy_2.8.4_windows_armv6.sbom",
            "/caddy_2.8.4_windows_armv6.sbom.pem",
            "/caddy_2.8.4_windows_armv6.sbom.sig",
            "/caddy_2.8.4_windows_armv6.zip",
            "/caddy_2.8.4_windows_armv6.zip.sig",
            "/caddy_2.8.4_windows_armv7.pem",
            "/caddy_2.8.4_windows_armv7.sbom",
            "/caddy_2.8.4_windows_armv7.sbom.pem",
            "/caddy_2.8.4_windows_armv7.sbom.sig",
            "/caddy_2.8.4_windows_armv7.zip",
            "/caddy_2.8.4_windows_armv7.zip.sig",
        },
    }));
    try std.testing.expectEqualStrings("/glow_2.0.0_Linux_x86_64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"glow"},
        .urls = &.{
            "/checksums.txt",
            "/checksums.txt.pem",
            "/checksums.txt.sig",
            "/glow-2.0.0-1.aarch64.rpm",
            "/glow-2.0.0-1.armv7hl.rpm",
            "/glow-2.0.0-1.i386.rpm",
            "/glow-2.0.0-1.x86_64.rpm",
            "/glow-2.0.0.tar.gz",
            "/glow-2.0.0.tar.gz.sbom.json",
            "/glow_2.0.0_aarch64.apk",
            "/glow_2.0.0_amd64.deb",
            "/glow_2.0.0_arm64.deb",
            "/glow_2.0.0_armhf.deb",
            "/glow_2.0.0_armv7.apk",
            "/glow_2.0.0_Darwin_arm64.tar.gz",
            "/glow_2.0.0_Darwin_arm64.tar.gz.sbom.json",
            "/glow_2.0.0_Darwin_x86_64.tar.gz",
            "/glow_2.0.0_Darwin_x86_64.tar.gz.sbom.json",
            "/glow_2.0.0_Freebsd_arm.tar.gz",
            "/glow_2.0.0_Freebsd_arm.tar.gz.sbom.json",
            "/glow_2.0.0_Freebsd_arm64.tar.gz",
            "/glow_2.0.0_Freebsd_arm64.tar.gz.sbom.json",
            "/glow_2.0.0_Freebsd_i386.tar.gz",
            "/glow_2.0.0_Freebsd_i386.tar.gz.sbom.json",
            "/glow_2.0.0_Freebsd_x86_64.tar.gz",
            "/glow_2.0.0_Freebsd_x86_64.tar.gz.sbom.json",
            "/glow_2.0.0_i386.deb",
            "/glow_2.0.0_Linux_arm.tar.gz",
            "/glow_2.0.0_Linux_arm.tar.gz.sbom.json",
            "/glow_2.0.0_Linux_arm64.tar.gz",
            "/glow_2.0.0_Linux_arm64.tar.gz.sbom.json",
            "/glow_2.0.0_Linux_i386.tar.gz",
            "/glow_2.0.0_Linux_i386.tar.gz.sbom.json",
            "/glow_2.0.0_Linux_x86_64.tar.gz",
            "/glow_2.0.0_Linux_x86_64.tar.gz.sbom.json",
            "/glow_2.0.0_Netbsd_arm.tar.gz",
            "/glow_2.0.0_Netbsd_arm.tar.gz.sbom.json",
            "/glow_2.0.0_Netbsd_arm64.tar.gz",
            "/glow_2.0.0_Netbsd_arm64.tar.gz.sbom.json",
            "/glow_2.0.0_Netbsd_i386.tar.gz",
            "/glow_2.0.0_Netbsd_i386.tar.gz.sbom.json",
            "/glow_2.0.0_Netbsd_x86_64.tar.gz",
            "/glow_2.0.0_Netbsd_x86_64.tar.gz.sbom.json",
            "/glow_2.0.0_Openbsd_arm.tar.gz",
            "/glow_2.0.0_Openbsd_arm.tar.gz.sbom.json",
            "/glow_2.0.0_Openbsd_arm64.tar.gz",
            "/glow_2.0.0_Openbsd_arm64.tar.gz.sbom.json",
            "/glow_2.0.0_Openbsd_i386.tar.gz",
            "/glow_2.0.0_Openbsd_i386.tar.gz.sbom.json",
            "/glow_2.0.0_Openbsd_x86_64.tar.gz",
            "/glow_2.0.0_Openbsd_x86_64.tar.gz.sbom.json",
            "/glow_2.0.0_Windows_i386.zip",
            "/glow_2.0.0_Windows_i386.zip.sbom.json",
            "/glow_2.0.0_Windows_x86_64.zip",
            "/glow_2.0.0_Windows_x86_64.zip.sbom.json",
            "/glow_2.0.0_x86.apk",
            "/glow_2.0.0_x86_64.apk",
        },
    }));
    try std.testing.expectEqualStrings("/iamb-x86_64-unknown-linux-musl.tgz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"iamb"},
        .urls = &.{
            "/iamb-aarch64-apple-darwin.tgz",
            "/iamb-aarch64-unknown-linux-gnu.deb",
            "/iamb-aarch64-unknown-linux-gnu.rpm",
            "/iamb-aarch64-unknown-linux-gnu.tgz",
            "/iamb-x86_64-apple-darwin.tgz",
            "/iamb-x86_64-pc-windows-msvc.zip",
            "/iamb-x86_64-unknown-linux-musl.deb",
            "/iamb-x86_64-unknown-linux-musl.rpm",
            "/iamb-x86_64-unknown-linux-musl.tgz",
        },
    }));
    try std.testing.expectEqualStrings("/linutil", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"linutil"},
        .urls = &.{
            "/linutil",
            "/start.sh",
            "/startdev.sh",
        },
    }));
    try std.testing.expectEqualStrings("/ownserver_v0.6.0_x86_64-unknown-linux-musl.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"ownserver"},
        .urls = &.{
            "/ownserver_v0.6.0_x86_64-apple-darwin.zip",
            "/ownserver_v0.6.0_x86_64-apple-darwin.zip.sha256sum",
            "/ownserver_v0.6.0_x86_64-pc-windows-gnu.zip",
            "/ownserver_v0.6.0_x86_64-pc-windows-gnu.zip.sha256sum",
            "/ownserver_v0.6.0_x86_64-unknown-linux-musl.tar.gz",
            "/ownserver_v0.6.0_x86_64-unknown-linux-musl.tar.gz.sha256sum",
            "/ownserver_v0.6.0_x86_64-unknown-linux-musl.tar.xz",
            "/ownserver_v0.6.0_x86_64-unknown-linux-musl.tar.xz.sha256sum",
        },
    }));
    try std.testing.expectEqualStrings("/presenterm-0.8.0-x86_64-unknown-linux-musl.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"presenterm"},
        .urls = &.{
            "/presenterm-0.8.0-aarch64-apple-darwin.tar.gz",
            "/presenterm-0.8.0-aarch64-apple-darwin.tar.gz.sha512",
            "/presenterm-0.8.0-aarch64-unknown-linux-gnu.tar.gz",
            "/presenterm-0.8.0-aarch64-unknown-linux-gnu.tar.gz.sha512",
            "/presenterm-0.8.0-aarch64-unknown-linux-musl.tar.gz",
            "/presenterm-0.8.0-aarch64-unknown-linux-musl.tar.gz.sha512",
            "/presenterm-0.8.0-armv5te-unknown-linux-gnueabi.tar.gz",
            "/presenterm-0.8.0-armv5te-unknown-linux-gnueabi.tar.gz.sha512",
            "/presenterm-0.8.0-armv7-unknown-linux-gnueabihf.tar.gz",
            "/presenterm-0.8.0-armv7-unknown-linux-gnueabihf.tar.gz.sha512",
            "/presenterm-0.8.0-i686-pc-windows-msvc.zip",
            "/presenterm-0.8.0-i686-pc-windows-msvc.zip.sha512",
            "/presenterm-0.8.0-i686-unknown-linux-gnu.tar.gz",
            "/presenterm-0.8.0-i686-unknown-linux-gnu.tar.gz.sha512",
            "/presenterm-0.8.0-i686-unknown-linux-musl.tar.gz",
            "/presenterm-0.8.0-i686-unknown-linux-musl.tar.gz.sha512",
            "/presenterm-0.8.0-x86_64-apple-darwin.tar.gz",
            "/presenterm-0.8.0-x86_64-apple-darwin.tar.gz.sha512",
            "/presenterm-0.8.0-x86_64-pc-windows-msvc.zip",
            "/presenterm-0.8.0-x86_64-pc-windows-msvc.zip.sha512",
            "/presenterm-0.8.0-x86_64-unknown-linux-gnu.tar.gz",
            "/presenterm-0.8.0-x86_64-unknown-linux-gnu.tar.gz.sha512",
            "/presenterm-0.8.0-x86_64-unknown-linux-musl.tar.gz",
            "/presenterm-0.8.0-x86_64-unknown-linux-musl.tar.gz.sha512",
        },
    }));
    try std.testing.expectEqualStrings("/rustic-v0.8.0-x86_64-unknown-linux-musl.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"rustic"},
        .urls = &.{
            "/rustic-v0.8.0-aarch64-apple-darwin.tar.gz",
            "/rustic-v0.8.0-aarch64-apple-darwin.tar.gz.asc",
            "/rustic-v0.8.0-aarch64-apple-darwin.tar.gz.sha256",
            "/rustic-v0.8.0-aarch64-apple-darwin.tar.gz.sig",
            "/rustic-v0.8.0-aarch64-unknown-linux-gnu.tar.gz",
            "/rustic-v0.8.0-aarch64-unknown-linux-gnu.tar.gz.asc",
            "/rustic-v0.8.0-aarch64-unknown-linux-gnu.tar.gz.sha256",
            "/rustic-v0.8.0-aarch64-unknown-linux-gnu.tar.gz.sig",
            "/rustic-v0.8.0-armv7-unknown-linux-gnueabihf.tar.gz",
            "/rustic-v0.8.0-armv7-unknown-linux-gnueabihf.tar.gz.asc",
            "/rustic-v0.8.0-armv7-unknown-linux-gnueabihf.tar.gz.sha256",
            "/rustic-v0.8.0-armv7-unknown-linux-gnueabihf.tar.gz.sig",
            "/rustic-v0.8.0-i686-unknown-linux-gnu.tar.gz",
            "/rustic-v0.8.0-i686-unknown-linux-gnu.tar.gz.asc",
            "/rustic-v0.8.0-i686-unknown-linux-gnu.tar.gz.sha256",
            "/rustic-v0.8.0-i686-unknown-linux-gnu.tar.gz.sig",
            "/rustic-v0.8.0-x86_64-apple-darwin.tar.gz",
            "/rustic-v0.8.0-x86_64-apple-darwin.tar.gz.asc",
            "/rustic-v0.8.0-x86_64-apple-darwin.tar.gz.sha256",
            "/rustic-v0.8.0-x86_64-apple-darwin.tar.gz.sig",
            "/rustic-v0.8.0-x86_64-pc-windows-gnu.tar.gz",
            "/rustic-v0.8.0-x86_64-pc-windows-gnu.tar.gz.asc",
            "/rustic-v0.8.0-x86_64-pc-windows-gnu.tar.gz.sha256",
            "/rustic-v0.8.0-x86_64-pc-windows-gnu.tar.gz.sig",
            "/rustic-v0.8.0-x86_64-pc-windows-msvc.tar.gz",
            "/rustic-v0.8.0-x86_64-pc-windows-msvc.tar.gz.asc",
            "/rustic-v0.8.0-x86_64-pc-windows-msvc.tar.gz.sha256",
            "/rustic-v0.8.0-x86_64-pc-windows-msvc.tar.gz.sig",
            "/rustic-v0.8.0-x86_64-unknown-linux-gnu.tar.gz",
            "/rustic-v0.8.0-x86_64-unknown-linux-gnu.tar.gz.asc",
            "/rustic-v0.8.0-x86_64-unknown-linux-gnu.tar.gz.sha256",
            "/rustic-v0.8.0-x86_64-unknown-linux-gnu.tar.gz.sig",
            "/rustic-v0.8.0-x86_64-unknown-linux-musl.tar.gz",
            "/rustic-v0.8.0-x86_64-unknown-linux-musl.tar.gz.asc",
            "/rustic-v0.8.0-x86_64-unknown-linux-musl.tar.gz.sha256",
            "/rustic-v0.8.0-x86_64-unknown-linux-musl.tar.gz.sig",
        },
    }));
    try std.testing.expectEqualStrings("/watchexec-2.1.2-x86_64-unknown-linux-musl.tar.xz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"watchexec"},
        .urls = &.{
            "/B3SUMS",
            "/dist-manifest.json",
            "/SHA256SUMS",
            "/SHA512SUMS",
            "/watchexec-2.1.2-aarch64-apple-darwin.tar.xz",
            "/watchexec-2.1.2-aarch64-apple-darwin.tar.xz.b3",
            "/watchexec-2.1.2-aarch64-apple-darwin.tar.xz.sha256",
            "/watchexec-2.1.2-aarch64-apple-darwin.tar.xz.sha512",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.deb",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.deb.b3",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.deb.sha256",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.deb.sha512",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.rpm",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.rpm.b3",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.rpm.sha256",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.rpm.sha512",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.tar.xz",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.tar.xz.b3",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.tar.xz.sha256",
            "/watchexec-2.1.2-aarch64-unknown-linux-gnu.tar.xz.sha512",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.deb",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.deb.b3",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.deb.sha256",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.deb.sha512",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.rpm",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.rpm.b3",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.rpm.sha256",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.rpm.sha512",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.tar.xz",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.tar.xz.b3",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.tar.xz.sha256",
            "/watchexec-2.1.2-aarch64-unknown-linux-musl.tar.xz.sha512",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.deb",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.deb.b3",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.deb.sha256",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.deb.sha512",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.rpm",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.rpm.b3",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.rpm.sha256",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.rpm.sha512",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.tar.xz",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.tar.xz.b3",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.tar.xz.sha256",
            "/watchexec-2.1.2-armv7-unknown-linux-gnueabihf.tar.xz.sha512",
            "/watchexec-2.1.2-i686-unknown-linux-musl.deb",
            "/watchexec-2.1.2-i686-unknown-linux-musl.deb.b3",
            "/watchexec-2.1.2-i686-unknown-linux-musl.deb.sha256",
            "/watchexec-2.1.2-i686-unknown-linux-musl.deb.sha512",
            "/watchexec-2.1.2-i686-unknown-linux-musl.rpm",
            "/watchexec-2.1.2-i686-unknown-linux-musl.rpm.b3",
            "/watchexec-2.1.2-i686-unknown-linux-musl.rpm.sha256",
            "/watchexec-2.1.2-i686-unknown-linux-musl.rpm.sha512",
            "/watchexec-2.1.2-i686-unknown-linux-musl.tar.xz",
            "/watchexec-2.1.2-i686-unknown-linux-musl.tar.xz.b3",
            "/watchexec-2.1.2-i686-unknown-linux-musl.tar.xz.sha256",
            "/watchexec-2.1.2-i686-unknown-linux-musl.tar.xz.sha512",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.deb",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.deb.b3",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.deb.sha256",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.deb.sha512",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.rpm",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.rpm.b3",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.rpm.sha256",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.rpm.sha512",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.tar.xz",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.tar.xz.b3",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.tar.xz.sha256",
            "/watchexec-2.1.2-powerpc64le-unknown-linux-gnu.tar.xz.sha512",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.deb",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.deb.b3",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.deb.sha256",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.deb.sha512",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.rpm",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.rpm.b3",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.rpm.sha256",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.rpm.sha512",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.tar.xz",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.tar.xz.b3",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.tar.xz.sha256",
            "/watchexec-2.1.2-s390x-unknown-linux-gnu.tar.xz.sha512",
            "/watchexec-2.1.2-x86_64-apple-darwin.tar.xz",
            "/watchexec-2.1.2-x86_64-apple-darwin.tar.xz.b3",
            "/watchexec-2.1.2-x86_64-apple-darwin.tar.xz.sha256",
            "/watchexec-2.1.2-x86_64-apple-darwin.tar.xz.sha512",
            "/watchexec-2.1.2-x86_64-pc-windows-msvc.zip",
            "/watchexec-2.1.2-x86_64-pc-windows-msvc.zip.b3",
            "/watchexec-2.1.2-x86_64-pc-windows-msvc.zip.sha256",
            "/watchexec-2.1.2-x86_64-pc-windows-msvc.zip.sha512",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.deb",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.deb.b3",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.deb.sha256",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.deb.sha512",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.rpm",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.rpm.b3",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.rpm.sha256",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.rpm.sha512",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.tar.xz",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.tar.xz.b3",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.tar.xz.sha256",
            "/watchexec-2.1.2-x86_64-unknown-linux-gnu.tar.xz.sha512",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.deb",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.deb.b3",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.deb.sha256",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.deb.sha512",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.rpm",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.rpm.b3",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.rpm.sha256",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.rpm.sha512",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.tar.xz",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.tar.xz.b3",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.tar.xz.sha256",
            "/watchexec-2.1.2-x86_64-unknown-linux-musl.tar.xz.sha512",
        },
    }));
    try std.testing.expectEqualStrings("/tigerbeetle-x86_64-linux.zip", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"tigerbeetle"},
        .urls = &.{
            "/tigerbeetle-aarch64-linux-debug.zip",
            "/tigerbeetle-aarch64-linux.zip",
            "/tigerbeetle-universal-macos-debug.zip",
            "/tigerbeetle-universal-macos.zip",
            "/tigerbeetle-x86_64-linux-debug.zip",
            "/tigerbeetle-x86_64-linux.zip",
            "/tigerbeetle-x86_64-windows-debug.zip",
            "/tigerbeetle-x86_64-windows.zip",
        },
    }));
    try std.testing.expectEqualStrings("/tau_1.1.5_linux_amd64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"tau"},
        .urls = &.{
            "/dream_1.1.5_darwin_amd64.tar.gz",
            "/dream_1.1.5_darwin_arm64.tar.gz",
            "/dream_1.1.5_linux_amd64.tar.gz",
            "/dream_1.1.5_linux_arm64.tar.gz",
            "/dream_1.1.5_windows_amd64.tar.gz",
            "/taucorder_1.1.5_darwin_amd64.tar.gz",
            "/taucorder_1.1.5_darwin_arm64.tar.gz",
            "/taucorder_1.1.5_linux_amd64.tar.gz",
            "/taucorder_1.1.5_linux_arm64.tar.gz",
            "/taucorder_1.1.5_windows_amd64.tar.gz",
            "/tau_1.1.5_darwin_amd64.tar.gz",
            "/tau_1.1.5_darwin_arm64.tar.gz",
            "/tau_1.1.5_linux_amd64.tar.gz",
            "/tau_1.1.5_linux_arm64.tar.gz",
            "/tau_1.1.5_windows_amd64.tar.gz",
        },
    }));
    try std.testing.expectEqualStrings("/sccache-dist-v0.8.1-x86_64-unknown-linux-musl.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"sccache"},
        .urls = &.{
            "/sccache-dist-v0.8.1-x86_64-unknown-linux-musl.tar.gz",
            "/sccache-dist-v0.8.1-x86_64-unknown-linux-musl.tar.gz.sha256",
            "/sccache-v0.8.1-aarch64-apple-darwin.tar.gz",
            "/sccache-v0.8.1-aarch64-apple-darwin.tar.gz.sha256",
            "/sccache-v0.8.1-aarch64-unknown-linux-musl.tar.gz",
            "/sccache-v0.8.1-aarch64-unknown-linux-musl.tar.gz.sha256",
            "/sccache-v0.8.1-armv7-unknown-linux-musleabi.tar.gz",
            "/sccache-v0.8.1-armv7-unknown-linux-musleabi.tar.gz.sha256",
            "/sccache-v0.8.1-i686-unknown-linux-musl.tar.gz",
            "/sccache-v0.8.1-i686-unknown-linux-musl.tar.gz.sha256",
            "/sccache-v0.8.1-x86_64-apple-darwin.tar.gz",
            "/sccache-v0.8.1-x86_64-apple-darwin.tar.gz.sha256",
            "/sccache-v0.8.1-x86_64-pc-windows-msvc.tar.gz",
            "/sccache-v0.8.1-x86_64-pc-windows-msvc.tar.gz.sha256",
            "/sccache-v0.8.1-x86_64-pc-windows-msvc.zip",
            "/sccache-v0.8.1-x86_64-pc-windows-msvc.zip.sha256",
            "/sccache-v0.8.1-x86_64-unknown-linux-musl.tar.gz",
            "/sccache-v0.8.1-x86_64-unknown-linux-musl.tar.gz.sha256",
        },
    }));
    try std.testing.expectEqualStrings("/sccache-v0.8.1-x86_64-unknown-linux-musl.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{ "sccache", "sccache-v0.8.1" },
        .urls = &.{
            "/sccache-dist-v0.8.1-x86_64-unknown-linux-musl.tar.gz",
            "/sccache-dist-v0.8.1-x86_64-unknown-linux-musl.tar.gz.sha256",
            "/sccache-v0.8.1-aarch64-apple-darwin.tar.gz",
            "/sccache-v0.8.1-aarch64-apple-darwin.tar.gz.sha256",
            "/sccache-v0.8.1-aarch64-unknown-linux-musl.tar.gz",
            "/sccache-v0.8.1-aarch64-unknown-linux-musl.tar.gz.sha256",
            "/sccache-v0.8.1-armv7-unknown-linux-musleabi.tar.gz",
            "/sccache-v0.8.1-armv7-unknown-linux-musleabi.tar.gz.sha256",
            "/sccache-v0.8.1-i686-unknown-linux-musl.tar.gz",
            "/sccache-v0.8.1-i686-unknown-linux-musl.tar.gz.sha256",
            "/sccache-v0.8.1-x86_64-apple-darwin.tar.gz",
            "/sccache-v0.8.1-x86_64-apple-darwin.tar.gz.sha256",
            "/sccache-v0.8.1-x86_64-pc-windows-msvc.tar.gz",
            "/sccache-v0.8.1-x86_64-pc-windows-msvc.tar.gz.sha256",
            "/sccache-v0.8.1-x86_64-pc-windows-msvc.zip",
            "/sccache-v0.8.1-x86_64-pc-windows-msvc.zip.sha256",
            "/sccache-v0.8.1-x86_64-unknown-linux-musl.tar.gz",
            "/sccache-v0.8.1-x86_64-unknown-linux-musl.tar.gz.sha256",
        },
    }));
    try std.testing.expectEqualStrings("/dns53_0.11.0_linux-x86_64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"dns53"},
        .urls = &.{
            "/checksums.txt",
            "/checksums.txt.pem",
            "/checksums.txt.sig",
            "/dns53-0.11.0-1.aarch64.rpm",
            "/dns53-0.11.0-1.armv7hl.rpm",
            "/dns53-0.11.0-1.i386.rpm",
            "/dns53-0.11.0-1.x86_64.rpm",
            "/dns53_0.11.0_aarch64.apk",
            "/dns53_0.11.0_amd64.deb",
            "/dns53_0.11.0_arm64.deb",
            "/dns53_0.11.0_armhf.deb",
            "/dns53_0.11.0_armv7.apk",
            "/dns53_0.11.0_darwin-arm64.tar.gz",
            "/dns53_0.11.0_darwin-arm64.tar.gz.sbom",
            "/dns53_0.11.0_darwin-x86_64.tar.gz",
            "/dns53_0.11.0_darwin-x86_64.tar.gz.sbom",
            "/dns53_0.11.0_i386.deb",
            "/dns53_0.11.0_linux-386.tar.gz",
            "/dns53_0.11.0_linux-386.tar.gz.sbom",
            "/dns53_0.11.0_linux-arm64.tar.gz",
            "/dns53_0.11.0_linux-arm64.tar.gz.sbom",
            "/dns53_0.11.0_linux-armv7.tar.gz",
            "/dns53_0.11.0_linux-armv7.tar.gz.sbom",
            "/dns53_0.11.0_linux-x86_64.tar.gz",
            "/dns53_0.11.0_linux-x86_64.tar.gz.sbom",
            "/dns53_0.11.0_windows-386.zip",
            "/dns53_0.11.0_windows-386.zip.sbom",
            "/dns53_0.11.0_windows-arm64.zip",
            "/dns53_0.11.0_windows-arm64.zip.sbom",
            "/dns53_0.11.0_windows-armv7.zip",
            "/dns53_0.11.0_windows-armv7.zip.sbom",
            "/dns53_0.11.0_windows-x86_64.zip",
            "/dns53_0.11.0_windows-x86_64.zip.sbom",
            "/dns53_0.11.0_x86.apk",
            "/dns53_0.11.0_x86_64.apk",
        },
    }));
    try std.testing.expectEqualStrings("/dotenv-linter-alpine-x86_64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"dotenv-linter"},
        .urls = &.{
            "/dotenv-linter-alpine-aarch64.tar.gz",
            "/dotenv-linter-alpine-x86_64.tar.gz",
            "/dotenv-linter-darwin-arm64.tar.gz",
            "/dotenv-linter-darwin-x86_64.tar.gz",
            "/dotenv-linter-linux-aarch64.tar.gz",
            "/dotenv-linter-linux-x86_64.tar.gz",
            "/dotenv-linter-win-aarch64.zip",
            "/dotenv-linter-win-x64.zip",
        },
    }));
    try std.testing.expectEqualStrings("/micro-2.0.14-linux64-static.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"micro"},
        .urls = &.{
            "/micro-2.0.14-freebsd32.tar.gz",
            "/micro-2.0.14-freebsd32.tar.gz.sha",
            "/micro-2.0.14-freebsd32.tgz",
            "/micro-2.0.14-freebsd32.tgz.sha",
            "/micro-2.0.14-freebsd64.tar.gz",
            "/micro-2.0.14-freebsd64.tar.gz.sha",
            "/micro-2.0.14-freebsd64.tgz",
            "/micro-2.0.14-freebsd64.tgz.sha",
            "/micro-2.0.14-linux-arm.tar.gz",
            "/micro-2.0.14-linux-arm.tar.gz.sha",
            "/micro-2.0.14-linux-arm.tgz",
            "/micro-2.0.14-linux-arm.tgz.sha",
            "/micro-2.0.14-linux-arm64.tar.gz",
            "/micro-2.0.14-linux-arm64.tar.gz.sha",
            "/micro-2.0.14-linux-arm64.tgz",
            "/micro-2.0.14-linux-arm64.tgz.sha",
            "/micro-2.0.14-linux32.tar.gz",
            "/micro-2.0.14-linux32.tar.gz.sha",
            "/micro-2.0.14-linux32.tgz",
            "/micro-2.0.14-linux32.tgz.sha",
            "/micro-2.0.14-linux64-static.tar.gz",
            "/micro-2.0.14-linux64-static.tar.gz.sha",
            "/micro-2.0.14-linux64-static.tgz",
            "/micro-2.0.14-linux64-static.tgz.sha",
            "/micro-2.0.14-linux64.tar.gz",
            "/micro-2.0.14-linux64.tar.gz.sha",
            "/micro-2.0.14-linux64.tgz",
            "/micro-2.0.14-linux64.tgz.sha",
            "/micro-2.0.14-macos-arm64.tar.gz",
            "/micro-2.0.14-macos-arm64.tar.gz.sha",
            "/micro-2.0.14-macos-arm64.tgz",
            "/micro-2.0.14-macos-arm64.tgz.sha",
            "/micro-2.0.14-netbsd32.tar.gz",
            "/micro-2.0.14-netbsd32.tar.gz.sha",
            "/micro-2.0.14-netbsd32.tgz",
            "/micro-2.0.14-netbsd32.tgz.sha",
            "/micro-2.0.14-netbsd64.tar.gz",
            "/micro-2.0.14-netbsd64.tar.gz.sha",
            "/micro-2.0.14-netbsd64.tgz",
            "/micro-2.0.14-netbsd64.tgz.sha",
            "/micro-2.0.14-openbsd32.tar.gz",
            "/micro-2.0.14-openbsd32.tar.gz.sha",
            "/micro-2.0.14-openbsd32.tgz",
            "/micro-2.0.14-openbsd32.tgz.sha",
            "/micro-2.0.14-openbsd64.tar.gz",
            "/micro-2.0.14-openbsd64.tar.gz.sha",
            "/micro-2.0.14-openbsd64.tgz",
            "/micro-2.0.14-openbsd64.tgz.sha",
            "/micro-2.0.14-osx.tar.gz",
            "/micro-2.0.14-osx.tar.gz.sha",
            "/micro-2.0.14-osx.tgz",
            "/micro-2.0.14-osx.tgz.sha",
            "/micro-2.0.14-win32.zip",
            "/micro-2.0.14-win32.zip.sha",
            "/micro-2.0.14-win64.zip",
            "/micro-2.0.14-win64.zip.sha",
        },
    }));
    try std.testing.expectEqualStrings("/usql_static-0.19.3-linux-amd64.tar.bz2", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{ "usql", "usql-0.19.3" },
        .urls = &.{
            "/usql-0.19.3-darwin-amd64.tar.bz2",
            "/usql-0.19.3-darwin-arm64.tar.bz2",
            "/usql-0.19.3-darwin-universal.tar.bz2",
            "/usql-0.19.3-linux-amd64.tar.bz2",
            "/usql-0.19.3-linux-arm.tar.bz2",
            "/usql-0.19.3-linux-arm64.tar.bz2",
            "/usql-0.19.3-windows-amd64.zip",
            "/usql_static-0.19.3-linux-amd64.tar.bz2",
            "/usql_static-0.19.3-linux-arm64.tar.bz2",
        },
    }));
    try std.testing.expectEqualStrings("/uctags-2024.10.02-linux-x86_64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strings = &.{"uctags"},
        .urls = &.{
            "/uctags-2024.10.02-1-x86_64.pkg.tar.xz",
            "/uctags-2024.10.02-1.fc40.x86_64.rpm",
            "/uctags-2024.10.02-android-aarch64.tar.xz",
            "/uctags-2024.10.02-android-armv7a.tar.xz",
            "/uctags-2024.10.02-android-i686.tar.xz",
            "/uctags-2024.10.02-android-x86_64.tar.xz",
            "/uctags-2024.10.02-freebsd-13.0-amd64.tar.gz",
            "/uctags-2024.10.02-freebsd-13.0-amd64.tar.xz",
            "/uctags-2024.10.02-freebsd-13.1-amd64.tar.gz",
            "/uctags-2024.10.02-freebsd-13.1-amd64.tar.xz",
            "/uctags-2024.10.02-freebsd-13.2-amd64.tar.gz",
            "/uctags-2024.10.02-freebsd-13.2-amd64.tar.xz",
            "/uctags-2024.10.02-freebsd-13.3-amd64.tar.gz",
            "/uctags-2024.10.02-freebsd-13.3-amd64.tar.xz",
            "/uctags-2024.10.02-freebsd-14.0-amd64.tar.gz",
            "/uctags-2024.10.02-freebsd-14.0-amd64.tar.xz",
            "/uctags-2024.10.02-freebsd-14.1-amd64.tar.gz",
            "/uctags-2024.10.02-freebsd-14.1-amd64.tar.xz",
            "/uctags-2024.10.02-linux-aarch64.apk",
            "/uctags-2024.10.02-linux-aarch64.apk.rsa.pub",
            "/uctags-2024.10.02-linux-aarch64.deb",
            "/uctags-2024.10.02-linux-aarch64.tar.gz",
            "/uctags-2024.10.02-linux-aarch64.tar.xz",
            "/uctags-2024.10.02-linux-x86_64.apk",
            "/uctags-2024.10.02-linux-x86_64.apk.rsa.pub",
            "/uctags-2024.10.02-linux-x86_64.deb",
            "/uctags-2024.10.02-linux-x86_64.tar.gz",
            "/uctags-2024.10.02-linux-x86_64.tar.xz",
            "/uctags-2024.10.02-macos-10.15-arm64.tar.gz",
            "/uctags-2024.10.02-macos-10.15-arm64.tar.xz",
            "/uctags-2024.10.02-macos-10.15-x86_64.tar.gz",
            "/uctags-2024.10.02-macos-10.15-x86_64.tar.xz",
            "/uctags-2024.10.02-macos-11.0-arm64.tar.gz",
            "/uctags-2024.10.02-macos-11.0-arm64.tar.xz",
            "/uctags-2024.10.02-macos-11.0-x86_64.tar.gz",
            "/uctags-2024.10.02-macos-11.0-x86_64.tar.xz",
            "/uctags-2024.10.02-macos-12.0-arm64.tar.gz",
            "/uctags-2024.10.02-macos-12.0-arm64.tar.xz",
            "/uctags-2024.10.02-macos-12.0-x86_64.tar.gz",
            "/uctags-2024.10.02-macos-12.0-x86_64.tar.xz",
            "/uctags-2024.10.02-macos-13.0-arm64.tar.gz",
            "/uctags-2024.10.02-macos-13.0-arm64.tar.xz",
            "/uctags-2024.10.02-macos-13.0-x86_64.tar.gz",
            "/uctags-2024.10.02-macos-13.0-x86_64.tar.xz",
            "/uctags-2024.10.02-macos-14.0-arm64.tar.gz",
            "/uctags-2024.10.02-macos-14.0-arm64.tar.xz",
            "/uctags-2024.10.02-macos-14.0-x86_64.tar.gz",
            "/uctags-2024.10.02-macos-14.0-x86_64.tar.xz",
            "/uctags-2024.10.02-netbsd-10.0-amd64.tar.gz",
            "/uctags-2024.10.02-netbsd-10.0-amd64.tar.xz",
            "/uctags-2024.10.02-netbsd-9.2-amd64.tar.gz",
            "/uctags-2024.10.02-netbsd-9.2-amd64.tar.xz",
            "/uctags-2024.10.02-netbsd-9.3-amd64.tar.gz",
            "/uctags-2024.10.02-netbsd-9.3-amd64.tar.xz",
            "/uctags-2024.10.02-netbsd-9.4-amd64.tar.gz",
            "/uctags-2024.10.02-netbsd-9.4-amd64.tar.xz",
            "/uctags-2024.10.02-openbsd-7.3-amd64.tar.gz",
            "/uctags-2024.10.02-openbsd-7.3-amd64.tar.xz",
            "/uctags-2024.10.02-openbsd-7.4-amd64.tar.gz",
            "/uctags-2024.10.02-openbsd-7.4-amd64.tar.xz",
            "/uctags-2024.10.02-openbsd-7.5-amd64.tar.gz",
            "/uctags-2024.10.02-openbsd-7.5-amd64.tar.xz",
            "/uctags-debug-2024.10.02-1-x86_64.pkg.tar.xz",
        },
    }));

    try std.testing.expectError(error.DownloadUrlNotFound, findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .urls = &.{},
    }));
}

fn versionFromTag(tag: []const u8) []const u8 {
    var state: enum {
        start,
        sep,
        number,
    } = .start;

    for (0..tag.len) |i_forward| {
        const i_backward = (tag.len - i_forward) - 1;
        const c = tag[i_backward];
        switch (state) {
            .start => switch (c) {
                '0'...'9' => state = .number,
                else => return tag,
            },
            .sep => switch (c) {
                '0'...'9' => state = .number,
                else => return tag[i_backward + 2 ..],
            },
            .number => switch (c) {
                '0'...'9' => {},
                '.', '_' => state = .sep,
                else => return tag[i_backward + 1 ..],
            },
        }
    }

    switch (state) {
        .start, .number => return tag,
        .sep => return tag[1..],
    }
}

test versionFromTag {
    try std.testing.expectEqualStrings("1.8.3", versionFromTag("cli/v1.8.3"));
    try std.testing.expectEqualStrings("2024_01_01", versionFromTag("year-2024_01_01"));
    try std.testing.expectEqualStrings("2024_01_01", versionFromTag("year_2024_01_01"));
    try std.testing.expectEqualStrings("2024_01_01", versionFromTag("_2024_01_01"));
    try std.testing.expectEqualStrings("2024_01_01", versionFromTag(".2024_01_01"));
    try std.testing.expectEqualStrings("test", versionFromTag("test"));
}

test {
    _ = Progress;
    _ = Target;

    _ = download;
    _ = fs;
    _ = heap;
    _ = mem;
}

const Package = @This();

const Progress = @import("Progress.zig");
const Target = @import("Target.zig");

const builtin = @import("builtin");
const download = @import("download.zig");
const fs = @import("fs.zig");
const heap = @import("heap.zig");
const mem = @import("mem.zig");
const std = @import("std");
