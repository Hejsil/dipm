info: Info,
update: Update,
linux_x86_64: InstallArch,

const Info = struct {
    version: []const u8,
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
    for (package.linux_x86_64.bin) |item|
        allocator.free(item);
    for (package.linux_x86_64.lib) |item|
        allocator.free(item);
    for (package.linux_x86_64.share) |item|
        allocator.free(item);

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
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
) ?Specific {
    const install = switch (os) {
        .linux => switch (arch) {
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
    try writer.print("version = {s}\n\n", .{package.info.version});
    try writer.print("[{s}.update]\n", .{name});
    try writer.print("github = {s}\n\n", .{package.update.github});
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
    tmp_allocator: std.mem.Allocator,

    http_client: *std.http.Client,
    progress: Progress.Node = .none,

    /// Name of the package. `null` means it should be inferred
    name: ?[]const u8 = null,
    url: []const u8,

    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
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
            .os = options.os,
            .arch = options.arch,
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
    tmp_allocator: std.mem.Allocator,

    http_client: *std.http.Client,
    progress: Progress.Node = .none,

    /// Name of the package. `null` means it should be inferred
    name: ?[]const u8 = null,
    user: []const u8,
    repo: []const u8,

    /// Use this uri to download the latest release json. If `null` then this uri will be used:
    /// https://api.github.com/repos/<user>/<repo>/releases/latest
    latest_release_uri: ?[]const u8 = null,

    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
}) !Named {
    var arena_state = std.heap.ArenaAllocator.init(options.tmp_allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const latest_release_uri = options.latest_release_uri orelse try std.fmt.allocPrint(
        arena,
        "https://api.github.com/repos/{s}/{s}/releases/latest",
        .{ options.user, options.repo },
    );

    var latest_release_json = std.ArrayList(u8).init(arena);
    const release_download_result = try download.download(latest_release_json.writer(), .{
        .client = options.http_client,
        .uri_str = latest_release_uri,
        .progress = options.progress,
    });
    if (release_download_result.status != .ok)
        return error.DownloadFailed;

    const LatestRelease = struct {
        tag_name: []const u8,
        assets: []const struct {
            browser_download_url: []const u8,
        },

        fn version(release: @This()) []const u8 {
            return std.mem.trimLeft(u8, release.tag_name, "v");
        }
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

    const version = blk: {
        var version = latest_release.tag_name;
        if (std.mem.startsWith(u8, version, name))
            version = version[name.len..];
        if (std.mem.startsWith(u8, version, "-"))
            version = version["-".len..];
        if (std.mem.startsWith(u8, version, "v"))
            version = version["v".len..];
        break :blk try options.allocator.dupe(u8, version);
    };
    errdefer options.allocator.free(version);

    const download_url = try findDownloadUrl(.{
        .os = options.os,
        .arch = options.arch,
        .extra_strings_to_trim = &.{
            options.user,
            options.repo,
            name,
            version,
            latest_release.tag_name,
        },
        // This is only save because `assets` only have the field `browser_download_url`
        .urls = @ptrCast(latest_release.assets),
    });

    var global_tmp_dir = try std.fs.cwd().makeOpenPath("/tmp/dipm/", .{});
    defer global_tmp_dir.close();

    var tmp_dir = try fs.tmpDir(global_tmp_dir, .{});
    defer tmp_dir.close();

    const downloaded_file_name = std.fs.path.basename(download_url);
    const downloaded_file = try tmp_dir.createFile(downloaded_file_name, .{ .read = true });
    defer downloaded_file.close();

    const package_download_result = try download.download(downloaded_file.writer(), .{
        .client = options.http_client,
        .uri_str = download_url,
        .progress = options.progress,
    });
    if (package_download_result.status != .ok)
        return error.DownloadFailed;

    try downloaded_file.seekTo(0);
    try fs.extract(.{
        .allocator = arena,
        .input_name = downloaded_file_name,
        .input_file = downloaded_file,
        .output_dir = tmp_dir,
    });

    // TODO: Can this be ported to pure zig easily?
    const static_files_result = try std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{
            "sh", "-c",
            \\find -type f -exec file '{}' '+' |
            \\    grep -E 'statically linked|static-pie linked' |
            \\    cut -d: -f1 |
            \\    sed 's#^./##' |
            \\    sort
            \\
        },
        .cwd_dir = tmp_dir,
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
                .bin = try bins_list.toOwnedSlice(),
                .lib = &.{},
                .share = &.{},
                .url = download_url_duped,
                .hash = hash_duped,
            },
        },
    };
}

fn testFromGithub(options: struct {
    /// Name of the package. `null` means it should be inferred
    name: ?[]const u8 = null,
    user: []const u8,
    repo: []const u8,
    tag_name: []const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    expect: []const u8,
}) !void {
    const allocator = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const cwd = std.fs.cwd();
    const tmp_dir_path = try fs.zigCacheTmpDirPath(arena);
    try cwd.makeDir(tmp_dir_path);

    const static_binary_name = try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{
        options.user,
        options.repo,
        options.tag_name,
    });
    const static_binary_path = try std.fs.path.join(arena, &.{
        tmp_dir_path,
        static_binary_name,
    });
    try cwd.writeFile(.{
        .sub_path = static_binary_path,
        // Small static binary produced with:
        //   echo 'pub export fn _start() callconv(.C) noreturn {unreachable;}' > test.zig
        //   zig build-exe test.zig -OReleaseFast -fstrip
        //   sstrip -z test
        //   xxd -i test
        .data = &.{
            0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x3e, 0x00, 0x01, 0x00, 0x00, 0x00,
            0xb0, 0x11, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x38, 0x00, 0x04, 0x00, 0x40, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x18, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x92, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0xa4, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x50, 0xe5, 0x74, 0x64,
            0x04, 0x00, 0x00, 0x00, 0x58, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x58, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x58, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x51, 0xe5, 0x74, 0x64, 0x06, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x1b, 0x03, 0x3b,
            0x14, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x58, 0x10, 0x00, 0x00,
            0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x7a, 0x52, 0x00, 0x01, 0x78, 0x10, 0x01,
            0x1b, 0x0c, 0x07, 0x08, 0x90, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
            0x1c, 0x00, 0x00, 0x00, 0x20, 0x10,
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
        .os = options.os,
        .arch = options.arch,
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
        .os = .linux,
        .arch = .x86_64,
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
        .os = .linux,
        .arch = .x86_64,
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

fn findDownloadUrl(options: struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    extra_strings_to_trim: []const []const u8,
    urls: []const []const u8,
}) ![]const u8 {
    // To find the download url, a trim list is constructed. It contains only things that are
    // expected to be in file name. Each url is the continuesly trimmed until either:
    // * `/` is reach. This means it is the download url
    // * Nothing was trimmed. The file name contains something unwanted

    var trim_list = std.BoundedArray([]const u8, 128){};
    try trim_list.append("_");
    try trim_list.append("-");
    try trim_list.append("unknown");
    try trim_list.append("musl");
    try trim_list.append("static");
    try trim_list.append(@tagName(options.arch));
    try trim_list.append(@tagName(options.os));

    switch (options.arch) {
        .x86_64 => {
            try trim_list.append("amd64");
            try trim_list.append("64bit");
            try trim_list.append("x64");
        },
        .x86 => {
            try trim_list.append("32bit");
        },
        else => {},
    }

    for (options.extra_strings_to_trim) |item|
        if (item.len != 0)
            try trim_list.append(item);

    for (fs.FileType.extensions) |ext|
        if (ext.ext.len != 0)
            try trim_list.append(ext.ext);

    std.sort.insertion([]const u8, trim_list.slice(), {}, struct {
        fn lenGt(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.lenGt);

    var best_match: ?usize = null;

    outer: for (options.urls, 0..) |url, i| {
        var download_url = url;
        inner: while (!std.mem.endsWith(u8, download_url, "/")) {
            for (trim_list.slice()) |trim| {
                std.debug.assert(trim.len != 0);
                if (std.ascii.endsWithIgnoreCase(download_url, trim)) {
                    download_url.len -= trim.len;
                    continue :inner;
                }
            }

            continue :outer;
        }

        const old_match = if (best_match) |b| options.urls[b] else "";
        if (url.len > old_match.len)
            best_match = i;
    }

    if (best_match) |res|
        return options.urls[res];

    return error.DownloadUrlNotFound;
}

test findDownloadUrl {
    try std.testing.expectEqualStrings("/fzf-0.54.0-linux_amd64.tar.gz", try findDownloadUrl(.{
        .os = .linux,
        .arch = .x86_64,
        .extra_strings_to_trim = &.{
            "fzf",
            "0.54.0",
        },
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
        .os = .windows,
        .arch = .x86_64,
        .extra_strings_to_trim = &.{
            "fzf",
            "0.54.0",
        },
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
        .os = .linux,
        .arch = .x86_64,
        .extra_strings_to_trim = &.{
            "gophish",
            "v0.12.1",
        },
        .urls = &.{
            "/gophish-v0.12.1-linux-32bit.zip",
            "/gophish-v0.12.1-linux-64bit.zip",
            "/gophish-v0.12.1-osx-64bit.zip",
            "/gophish-v0.12.1-windows-64bit.zip",
        },
    }));
    try std.testing.expectEqualStrings("/gophish-v0.12.1-windows-64bit.zip", try findDownloadUrl(.{
        .os = .windows,
        .arch = .x86_64,
        .extra_strings_to_trim = &.{
            "gophish",
            "v0.12.1",
        },
        .urls = &.{
            "/gophish-v0.12.1-linux-32bit.zip",
            "/gophish-v0.12.1-linux-64bit.zip",
            "/gophish-v0.12.1-osx-64bit.zip",
            "/gophish-v0.12.1-windows-64bit.zip",
        },
    }));
    try std.testing.expectEqualStrings("/gophish-v0.12.1-linux-32bit.zip", try findDownloadUrl(.{
        .os = .linux,
        .arch = .x86,
        .extra_strings_to_trim = &.{
            "gophish",
            "v0.12.1",
        },
        .urls = &.{
            "/gophish-v0.12.1-linux-32bit.zip",
            "/gophish-v0.12.1-linux-64bit.zip",
            "/gophish-v0.12.1-osx-64bit.zip",
            "/gophish-v0.12.1-windows-64bit.zip",
        },
    }));
    try std.testing.expectEqualStrings("/wasmer-linux-musl-amd64.tar.gz", try findDownloadUrl(.{
        .os = .linux,
        .arch = .x86_64,
        .extra_strings_to_trim = &.{
            "wasmer",
        },
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
        .os = .linux,
        .arch = .x86_64,
        .extra_strings_to_trim = &.{
            "mise",
            "v2024.7.4",
        },
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

    try std.testing.expectError(error.DownloadUrlNotFound, findDownloadUrl(.{
        .os = .linux,
        .arch = .x86_64,
        .extra_strings_to_trim = &.{},
        .urls = &.{},
    }));
}

pub fn newestUpstreamVersion(package: Package, options: struct {
    /// Allocator used for the result
    allocator: std.mem.Allocator,

    /// Allocator used for internal allocations. None of the allocations made with this
    /// allocator will be returned.
    tmp_allocator: std.mem.Allocator,

    http_client: *std.http.Client,
    progress: Progress.Node = .none,
}) ![]const u8 {
    if (package.update.github.len != 0)
        return newestUpstreamVersionGithub(.{
            .allocator = options.allocator,
            .tmp_allocator = options.tmp_allocator,
            .http_client = options.http_client,
            .progress = options.progress,
            .repo = package.update.github,
        });

    return error.NoVersionFound;
}

fn newestUpstreamVersionGithub(options: struct {
    /// Allocator used for the result
    allocator: std.mem.Allocator,

    /// Allocator used for internal allocations. None of the allocations made with this
    /// allocator will be returned.
    tmp_allocator: std.mem.Allocator,

    http_client: *std.http.Client,
    progress: Progress.Node = .none,

    repo: []const u8,
}) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(options.tmp_allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const releases_atom_uri = try std.fmt.allocPrint(
        arena,
        "https://github.com/{s}/releases.atom",
        .{options.repo},
    );

    var result = std.ArrayList(u8).init(arena);
    const release_download_result = try download.download(result.writer(), .{
        .client = options.http_client,
        .uri_str = releases_atom_uri,
        .progress = options.progress,
    });
    if (release_download_result.status != .ok)
        return error.DownloadFailed;

    const version = try newestUpstreamVersionFromGithubRelease(
        result.items,
    );
    return options.allocator.dupe(u8, version);
}

fn newestUpstreamVersionFromGithubRelease(string: []const u8) ![]const u8 {
    const end_id = "</id>";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, string, pos, end_id)) |end| : (pos = end + end_id.len) {
        var start = end;
        while (0 < start) : (start -= 1) switch (string[start - 1]) {
            '0'...'9', '.', '_' => {},
            else => break,
        };

        const version = string[start..end];
        if (std.mem.count(u8, version, ".") == 0 and
            std.mem.count(u8, version, "_") == 0)
            continue;
        if (std.mem.startsWith(u8, version, "."))
            continue;
        if (std.mem.endsWith(u8, version, "."))
            continue;

        return version;
    }

    return error.NoVersionFound;
}

test newestUpstreamVersionFromGithubRelease {
    try std.testing.expectEqualStrings("0.54.0", try newestUpstreamVersionFromGithubRelease(
        \\  <id>tag:github.com,2008:https://github.com/junegunn/fzf/releases</id>
        \\    <id>tag:github.com,2008:Repository/13807606/v0.54.0</id>
        \\    <id>tag:github.com,2008:Repository/13807606/0.53.0</id>
        \\    <id>tag:github.com,2008:Repository/13807606/0.52.1</id>
        \\    <id>tag:github.com,2008:Repository/13807606/0.52.0</id>
        \\    <id>tag:github.com,2008:Repository/13807606/0.51.0</id>
        \\    <id>tag:github.com,2008:Repository/13807606/0.50.0</id>
        \\    <id>tag:github.com,2008:Repository/13807606/0.49.0</id>
        \\    <id>tag:github.com,2008:Repository/13807606/0.48.1</id>
        \\    <id>tag:github.com,2008:Repository/13807606/0.48.0</id>
        \\    <id>tag:github.com,2008:Repository/13807606/0.47.0</id>
        \\
    ));
    try std.testing.expectEqualStrings("2024_05_05", try newestUpstreamVersionFromGithubRelease(
        \\  <id>tag:github.com,2008:https://github.com/marler8997/zigup/releases</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2024_05_05</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2024_05_04</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2024_03_13</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2024_02_25</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2023_07_27</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2022_08_25</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2022_07_04</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2022_02_08</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2022_01_14</id>
        \\    <id>tag:github.com,2008:Repository/268129020/v2021_10_16</id>
        \\
    ));
}

test {
    _ = Progress;

    _ = download;
    _ = fs;
}

const Package = @This();

const Progress = @import("Progress.zig");

const builtin = @import("builtin");
const download = @import("download.zig");
const fs = @import("fs.zig");
const std = @import("std");
