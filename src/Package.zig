info: Info = .{},
update: Update = .{},
linux_x86_64: Arch = .{},

pub const Info = struct {
    version: Strings.Index = .empty,
    description: Strings.Index = .empty,
    donate: Strings.Indices = .empty,
};

pub const Update = struct {
    version: Strings.Index = .empty,
    download: Strings.Index = .empty,
};

pub const Arch = struct {
    url: Strings.Index = .empty,
    hash: Strings.Index = .empty,
    install_bin: Strings.Indices = .empty,
    install_lib: Strings.Indices = .empty,
    install_share: Strings.Indices = .empty,
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
    name: Strings.Index,
    pkg: Package,
};

pub const Specific = struct {
    name: []const u8,
    info: Info,
    update: Update,
    install: Arch,
};

pub fn specific(
    pkg: Package,
    name: []const u8,
    target: Target,
) ?Specific {
    const install = switch (target.os) {
        .linux => switch (target.arch) {
            .x86_64 => pkg.linux_x86_64,
            else => return null,
        },
        else => return null,
    };

    return .{
        .name = name,
        .info = pkg.info,
        .update = pkg.update,
        .install = install,
    };
}

pub fn write(pkg: Package, strs: Strings, name: []const u8, writer: *std.Io.Writer) !void {
    try writer.print("[{s}.info]\n", .{name});
    try writer.print("version = {s}\n", .{pkg.info.version.get(strs)});
    if (pkg.info.description.getNullIfEmpty(strs)) |description|
        try writer.print("description = {s}\n", .{description});

    for (pkg.info.donate.get(strs)) |donate|
        try writer.print("donate = {s}\n", .{donate.get(strs)});
    try writer.writeAll("\n");

    try writer.print("[{s}.update]\n", .{name});
    if (pkg.update.version.getNullIfEmpty(strs)) |version|
        try writer.print("version = {s}\n", .{version});
    if (pkg.update.download.getNullIfEmpty(strs)) |down|
        try writer.print("download = {s}\n", .{down});
    try writer.writeAll("\n");

    try writer.print("[{s}.linux_x86_64]\n", .{name});
    for (pkg.linux_x86_64.install_bin.get(strs)) |install|
        try writer.print("install_bin = {s}\n", .{install.get(strs)});
    for (pkg.linux_x86_64.install_lib.get(strs)) |install|
        try writer.print("install_lib = {s}\n", .{install.get(strs)});
    for (pkg.linux_x86_64.install_share.get(strs)) |install|
        try writer.print("install_share = {s}\n", .{install.get(strs)});

    try writer.print("url = {s}\n", .{pkg.linux_x86_64.url.get(strs)});
    try writer.print("hash = {s}\n", .{pkg.linux_x86_64.hash.get(strs)});
}

/// Creates a package from a url. This function will use different methods for creating the
/// package based on the domain. See:
/// * fromGithub
pub fn fromUrl(options: struct {
    gpa: std.mem.Allocator,
    strs: *Strings,

    http_client: *std.http.Client,
    progress: Progress.Node = .none,

    /// Name of the package. `null` means it should be inferred
    name: ?[]const u8 = null,

    /// The uri to the place where the version of the package can be obtained.
    version_uri: []const u8,

    /// The uri to somewhere that contains all the packages download links. If not `null` this is
    /// used to get the download url.
    download_uri: ?[]const u8 = null,

    target: Target,
}) !Named {
    if (GithubRepo.fromUri(options.version_uri)) |repo| {
        return fromGithub(.{
            .gpa = options.gpa,
            .strs = options.strs,
            .repo = repo,
            .http_client = options.http_client,
            .progress = options.progress,
            .name = options.name,
            .download_uri = options.download_uri,
            .target = options.target,
        });
    } else {
        return error.InvalidUrl;
    }
}

const GithubRepo = struct {
    user: []const u8,
    name: []const u8,

    fn fromUri(uri: []const u8) ?GithubRepo {
        const github_uri = "https://github.com/";
        if (!std.mem.startsWith(u8, uri, github_uri))
            return null;

        const repo = uri[github_uri.len..];
        var repo_split = std.mem.splitScalar(u8, repo, '/');

        const user = repo_split.first();
        const name = repo_split.next() orelse "";

        var name_split = std.mem.splitScalar(u8, name, '?');
        return .{ .user = user, .name = name_split.first() };
    }
};

/// Creates a package a Github repository. Will query the github API to figure out the
/// latest release of the repository and look for suitable download links for that release.
pub fn fromGithub(args: struct {
    gpa: std.mem.Allocator,
    strs: *Strings,

    http_client: *std.http.Client,
    progress: Progress.Node = .none,

    /// Name of the package. `null` means it should be inferred
    name: ?[]const u8 = null,
    repo: GithubRepo,

    /// The uri to somewhere that contains all the packages download links. If not `null` this is
    /// used to get the download url.
    download_uri: ?[]const u8 = null,

    /// Use this uri to download the repository json. If `null` then this uri will be used:
    /// https://api.github.com/repos/<user>/<repo>
    repository_uri: ?[]const u8 = null,

    /// Use this uri to download the latest release json. If `null` then this uri will be used:
    /// https://api.github.com/repos/<user>/<repo>/releases/latest
    latest_release_uri: ?[]const u8 = null,

    /// Use this uri to download the FUNDING.yml. If `null` then this uri will be used:
    /// https://raw.githubusercontent.com/<user>/<repo>/refs/tags/<tag>/.github/FUNDING.yml
    funding_uri: ?[]const u8 = null,

    target: Target,
}) !Named {
    var tmp_arena_state = std.heap.ArenaAllocator.init(args.gpa);
    const tmp_arena = tmp_arena_state.allocator();
    defer tmp_arena_state.deinit();

    const repository = try githubDownloadRepository(.{
        .arena = tmp_arena,
        .http_client = args.http_client,
        .repo = args.repo,
        .repository_uri = args.repository_uri,
    });
    const latest_release = try githubDownloadLatestRelease(.{
        .arena = tmp_arena,
        .http_client = args.http_client,
        .repo = args.repo,
        .latest_release_uri = args.latest_release_uri,
    });
    const donate = try githubDownloadSponsorUrls(.{
        .gpa = args.gpa,
        .strs = args.strs,
        .http_client = args.http_client,
        .repo = args.repo,
        .ref = latest_release.tag_name,
        .funding_uri = args.funding_uri,
    });

    const description = std.mem.trim(u8, repository.description, " ");
    const name = args.name orelse args.repo.name;
    const version = versionFromTag(latest_release.tag_name);

    var download_urls: std.MultiArrayList(struct {
        url: []const u8,
        digest: []const u8 = "",
    }) = .empty;
    if (args.download_uri) |download_uri| {
        var content = std.Io.Writer.Allocating.init(tmp_arena);
        const pkg_download_result = try download.download(.{
            .writer = &content.writer,
            .client = args.http_client,
            .uri_str = download_uri,
            .progress = args.progress,
        });
        if (pkg_download_result.status != .ok)
            return error.IndexDownloadFailed;

        var it = UrlsIterator.init(content.written());
        while (it.next()) |download_url|
            try download_urls.append(tmp_arena, .{ .url = download_url });
    } else {
        try download_urls.ensureTotalCapacity(tmp_arena, latest_release.assets.len);
        for (latest_release.assets) |asset|
            download_urls.appendAssumeCapacity(.{
                .url = asset.browser_download_url,
                .digest = asset.digest orelse "",
            });
    }

    const download_url_idx = try findDownloadUrlIndex(.{
        .target = args.target,
        .extra_strs = &.{
            name,
            version,
            latest_release.tag_name,

            // Pick `sccache-v0.8.1` over `sccache-dist-v0.8.1`
            try std.fmt.allocPrint(tmp_arena, "{s}-{s}", .{ name, version }),
            try std.fmt.allocPrint(tmp_arena, "{s}_{s}", .{ name, version }),
            try std.fmt.allocPrint(tmp_arena, "{s}-{s}", .{ name, latest_release.tag_name }),
            try std.fmt.allocPrint(tmp_arena, "{s}_{s}", .{ name, latest_release.tag_name }),
        },
        .urls = download_urls.items(.url),
    });
    const download_url = download_urls.get(download_url_idx);
    var downloaded = try downloadAndExtractToTmp(
        tmp_arena,
        args.http_client,
        args.progress,
        download_url.url,
    );
    defer downloaded.dir.deleteAndClose();

    const shares = try findShare(.{
        .gpa = args.gpa,
        .strs = args.strs,
        .dir = downloaded.dir.dir,
    });
    const man_pages = try findManPages(.{
        .gpa = args.gpa,
        .strs = args.strs,
        .dir = downloaded.dir.dir,
    });
    const binaries = try findStaticallyLinkedBinaries(.{
        .gpa = args.gpa,
        .strs = args.strs,
        .arch = args.target.arch,
        .dir = downloaded.dir.dir,
    });

    const hash = std.fmt.bytesToHex(downloaded.result.hash, .lower);
    const version_uri = try args.strs.print(args.gpa, "https://github.com/{s}/{s}", .{
        args.repo.user,
        args.repo.name,
    });
    if (std.mem.startsWith(u8, download_url.digest, "sha256:") and
        !std.mem.endsWith(u8, download_url.digest, &hash))
    {
        return error.InvalidHash;
    }

    return .{
        .name = try args.strs.putStr(args.gpa, name),
        .pkg = .{
            .info = .{
                .version = try args.strs.putStr(args.gpa, version),
                .description = try args.strs.putStr(args.gpa, description),
                .donate = donate,
            },
            .update = .{
                .version = version_uri,
                .download = if (args.download_uri) |d| try args.strs.putStr(args.gpa, d) else .empty,
            },
            .linux_x86_64 = .{
                .url = try args.strs.putStr(args.gpa, download_url.url),
                .hash = try args.strs.putStr(args.gpa, &hash),
                .install_bin = binaries,
                .install_share = try args.strs.concatIndices(args.gpa, &.{ shares, man_pages }),
            },
        },
    };
}

const Downloaded = struct {
    dir: fs.TmpDir,
    result: download.Result,
};

fn downloadAndExtractToTmp(
    gpa: std.mem.Allocator,
    http_client: *std.http.Client,
    progress: Progress.Node,
    download_url: []const u8,
) !Downloaded {
    var global_tmp_dir = try std.fs.cwd().makeOpenPath("/tmp/dipm/", .{});
    defer global_tmp_dir.close();

    var res = try fs.tmpDir(global_tmp_dir, .{ .iterate = true });
    errdefer res.deleteAndClose();

    const downloaded_file_name = std.fs.path.basename(download_url);
    const downloaded_file = try res.dir.createFile(downloaded_file_name, .{ .read = true });
    defer downloaded_file.close();

    var buf: [std.heap.page_size_min]u8 = undefined;
    var writer = downloaded_file.writer(&buf);
    const result = try download.download(.{
        .writer = &writer.interface,
        .client = http_client,
        .uri_str = download_url,
        .progress = progress,
    });
    try writer.end();
    if (result.status != .ok)
        return error.FileDownloadFailed;

    // TODO: Get rid of this once we have support for bz2 compression
    var download_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const downloaded_path = try res.dir.realpath(downloaded_file_name, &download_path_buf);

    try downloaded_file.seekTo(0);
    try fs.extract(.{
        .gpa = gpa,
        .input_name = downloaded_path,
        .input_file = downloaded_file,
        .output_dir = res.dir,
    });

    return .{ .dir = res, .result = result };
}

const github_api_uri_prefix = "https://api.github.com/";
const github_funding_uri_prefix = "https://raw.githubusercontent.com/";

const GithubLatestRelease = struct {
    tag_name: []const u8,
    assets: []const struct {
        digest: ?[]const u8 = null,
        browser_download_url: []const u8,
    },
};

fn githubDownloadLatestRelease(options: struct {
    arena: std.mem.Allocator,
    http_client: *std.http.Client,
    progress: Progress.Node = .none,
    repo: GithubRepo,
    latest_release_uri: ?[]const u8,
}) !GithubLatestRelease {
    const latest_release_uri = options.latest_release_uri orelse try std.fmt.allocPrint(
        options.arena,
        "{s}repos/{s}/{s}/releases/latest",
        .{ github_api_uri_prefix, options.repo.user, options.repo.name },
    );

    var latest_release_json = std.Io.Writer.Allocating.init(options.arena);
    const release_download_result = try download.download(.{
        .writer = &latest_release_json.writer,
        .client = options.http_client,
        .uri_str = latest_release_uri,
        .progress = options.progress,
    });
    if (release_download_result.status != .ok)
        return error.LatestReleaseDownloadFailed;

    const latest_release_value = try std.json.parseFromSlice(
        GithubLatestRelease,
        options.arena,
        latest_release_json.written(),
        .{ .ignore_unknown_fields = true },
    );
    return latest_release_value.value;
}

const GithubRepository = struct {
    description: []const u8,
};

fn githubDownloadRepository(options: struct {
    arena: std.mem.Allocator,
    http_client: *std.http.Client,
    progress: Progress.Node = .none,
    repo: GithubRepo,
    repository_uri: ?[]const u8,
}) !GithubRepository {
    const repository_uri = options.repository_uri orelse try std.fmt.allocPrint(
        options.arena,
        "{s}repos/{s}/{s}",
        .{ github_api_uri_prefix, options.repo.user, options.repo.name },
    );

    var repository_json = std.Io.Writer.Allocating.init(options.arena);
    const repository_result = try download.download(.{
        .writer = &repository_json.writer,
        .client = options.http_client,
        .uri_str = repository_uri,
        .progress = options.progress,
    });
    if (repository_result.status != .ok)
        return error.LatestReleaseDownloadFailed;

    const latest_release_value = try std.json.parseFromSlice(
        GithubRepository,
        options.arena,
        repository_json.written(),
        .{ .ignore_unknown_fields = true },
    );
    return latest_release_value.value;
}

fn githubDownloadSponsorUrls(args: struct {
    gpa: std.mem.Allocator,
    strs: *Strings,
    http_client: *std.http.Client,
    progress: Progress.Node = .none,
    repo: GithubRepo,
    ref: []const u8,
    funding_uri: ?[]const u8,
}) !Strings.Indices {
    var arena_state = std.heap.ArenaAllocator.init(args.gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const funding_uri = args.funding_uri orelse try std.fmt.allocPrint(
        arena,
        "{s}{s}/{s}/refs/tags/{s}/.github/FUNDING.yml",
        .{ github_funding_uri_prefix, args.repo.user, args.repo.name, args.ref },
    );

    var funding_yml = std.Io.Writer.Allocating.init(arena);
    const repository_result = try download.download(.{
        .writer = &funding_yml.writer,
        .client = args.http_client,
        .uri_str = funding_uri,
        .progress = args.progress,
    });
    if (repository_result.status != .ok)
        return .empty;

    return fundingYmlToUrls(args.gpa, args.strs, funding_yml.written());
}

// Very scuffed but working parser for FUNDING.yml. Didn't really wonna write something proper or
// pull in a yaml dependency.
fn fundingYmlToUrls(gpa: std.mem.Allocator, strs: *Strings, string: []const u8) !Strings.Indices {
    const off = strs.putIndicesBegin();
    const Tokenizer = struct {
        str: []const u8,

        pub fn next(tok: *@This()) []const u8 {
            tok.str = std.mem.trimLeft(u8, tok.str, "\t ");
            if (tok.str.len == 0)
                return tok.str;

            switch (tok.str[0]) {
                '#' => {
                    const end = std.mem.indexOfScalar(u8, tok.str, '\n') orelse {
                        tok.str = tok.str[tok.str.len..];
                        return tok.str;
                    };

                    const res = tok.str[end .. end + 1];
                    tok.str = tok.str[end + 1 ..];
                    return res;
                },
                ',', ':', '\n', '-', '[', ']' => {
                    const res = tok.str[0..1];
                    tok.str = tok.str[1..];
                    return res;
                },
                '"', '\'' => {
                    const end = std.mem.indexOfScalarPos(u8, tok.str, 1, tok.str[0]) orelse {
                        const res = tok.str[1..];
                        tok.str = tok.str[tok.str.len..];
                        return res;
                    };

                    const res = tok.str[1..end];
                    tok.str = tok.str[end + 1 ..];
                    return res;
                },
                else => {
                    const end = std.mem.indexOfAny(u8, tok.str, ",:-[]#\t\n ") orelse tok.str.len;
                    const res = tok.str[0..end];
                    tok.str = tok.str[end..];
                    return res;
                },
            }
        }

        pub fn nextValue(tok: *@This()) []const u8 {
            tok.str = std.mem.trimLeft(u8, tok.str, "\t ");
            if (tok.str.len == 0)
                return tok.str;

            if (tok.str[0] == '"' or tok.str[0] == '\'') {
                const term = tok.str[0];
                const end = std.mem.indexOfScalarPos(u8, tok.str, 1, term) orelse tok.str.len;
                const value = tok.str[1..end];
                tok.str = tok.str[end + 1 ..];
                return value;
            }

            const end = std.mem.indexOfAny(u8, tok.str, "],#\n") orelse tok.str.len;
            const value = tok.str[0..end];
            tok.str = tok.str[end..];
            return std.mem.trim(u8, value, "\t \"'");
        }
    };

    const prefixes = std.StaticStringMap([]const u8).initComptime(.{
        .{ "buy_me_a_coffee", "https://buymeacoffee.com/" },
        .{ "github", "https://github.com/sponsors/" },
        .{ "ko_fi", "https://ko-fi.com/" },
        .{ "liberapay", "https://liberapay.com/" },
        .{ "patreon", "https://www.patreon.com/" },
        .{ "open_collective", "https://opencollective.com/" },
        .{ "polar", "https://polar.sh/" },
        .{ "thanks_dev", "https://thanks.dev/" },
    });

    var tok = Tokenizer{ .str = blk: {
        var res = std.mem.trimLeft(u8, string, "");
        if (std.mem.startsWith(u8, res, "---"))
            res = res[3..];
        break :blk res;
    } };
    var curr = tok.next();
    while (curr.len != 0) {
        if (curr[0] == '\n') {
            curr = tok.next();
            continue;
        }

        const key = curr;
        const prefix = prefixes.get(key) orelse "";

        curr = tok.next();
        if (curr.len == 0)
            break;
        if (curr[0] != ':')
            return error.InvalidFundingYml;

        var reset = tok;
        curr = tok.next();
        if (curr.len == 0)
            break;

        switch (curr[0]) {
            '\n' => while (true) {
                curr = tok.next();
                if (curr.len == 0)
                    break;
                if (curr[0] == '\n')
                    continue;
                if (curr[0] != '-')
                    break;

                const value = tok.nextValue();
                const url = try strs.print(gpa, "{s}{s}", .{ prefix, value });
                try strs.indices.append(gpa, url);
            },
            '[' => while (true) {
                reset = tok;
                curr = tok.next();
                if (curr.len == 0)
                    break;
                if (curr[0] == '\n' or curr[0] == ',')
                    continue;
                if (curr[0] == ']') {
                    curr = tok.next();
                    break;
                }

                tok = reset;
                const value = tok.nextValue();
                const url = try strs.print(gpa, "{s}{s}", .{ prefix, value });
                try strs.indices.append(gpa, url);
            },
            else => {
                tok = reset;
                const value = tok.nextValue();
                const url = try strs.print(gpa, "{s}{s}", .{ prefix, value });
                try strs.indices.append(gpa, url);
                curr = tok.next();
            },
        }
    }

    return strs.putIndicesEnd(off);
}

fn expectFundingUrls(funding_yml: []const u8, expected: []const []const u8) !void {
    var strs = Strings.empty;
    defer strs.deinit(std.testing.allocator);

    const actual = try fundingYmlToUrls(std.testing.allocator, &strs, funding_yml);
    const len = @min(expected.len, actual.len);
    for (expected[0..len], actual.get(strs)[0..len]) |e, a|
        try std.testing.expectEqualStrings(e, a.get(strs));
    for (expected[len..]) |e|
        try std.testing.expectEqualStrings(e, "");
    for (actual.get(strs)[len..]) |a|
        try std.testing.expectEqualStrings("", a.get(strs));
    try std.testing.expectEqual(expected.len, actual.len);
}

test fundingYmlToUrls {
    try expectFundingUrls(
        \\github: test1
    ,
        &.{
            "https://github.com/sponsors/test1",
        },
    );
    try expectFundingUrls(
        \\github: test1
        \\github: test2
    ,
        &.{
            "https://github.com/sponsors/test1",
            "https://github.com/sponsors/test2",
        },
    );
    try expectFundingUrls(
        \\github: [test1]
    ,
        &.{
            "https://github.com/sponsors/test1",
        },
    );
    try expectFundingUrls(
        \\github: [test1]
        \\github: [test2]
    ,
        &.{
            "https://github.com/sponsors/test1",
            "https://github.com/sponsors/test2",
        },
    );
    try expectFundingUrls(
        \\github: [test1, test2, test3]
    ,
        &.{
            "https://github.com/sponsors/test1",
            "https://github.com/sponsors/test2",
            "https://github.com/sponsors/test3",
        },
    );
    try expectFundingUrls(
        \\custom: ["url"]
    ,
        &.{
            "url",
        },
    );
    try expectFundingUrls(
        \\custom: # comment
    ,
        &.{},
    );
    try expectFundingUrls(
        \\patreon: [test]
        \\buy_me_a_coffee: [test]
        \\ko_fi: [test]
        \\liberapay: [test]
        \\open_collective: [test]
        \\polar: [test]
        \\thanks_dev: [test]
    ,
        &.{
            "https://www.patreon.com/test",
            "https://buymeacoffee.com/test",
            "https://ko-fi.com/test",
            "https://liberapay.com/test",
            "https://opencollective.com/test",
            "https://polar.sh/test",
            "https://thanks.dev/test",
        },
    );
    try expectFundingUrls(
        \\# Funding links
        \\github:
        \\  - test
        \\custom:
        \\  - "https://test.com/donate"
        \\  - 'https://test.com/donate'
        \\patreon: test
        \\ko_fi: test
        \\
    ,
        &.{
            "https://github.com/sponsors/test",
            "https://test.com/donate",
            "https://test.com/donate",
            "https://www.patreon.com/test",
            "https://ko-fi.com/test",
        },
    );
    try expectFundingUrls(
        \\# These are supported funding model platforms
        \\
        \\github: test # Replace with up to 4 GitHub Sponsors-enabled usernames e.g., [user1, user2]
        \\patreon: # Replace with a single Patreon username
        \\open_collective: # Replace with a single Open Collective username
        \\ko_fi: test # Replace with a single Ko-fi username
        \\tidelift: # Replace with a single Tidelift platform-name/package-name e.g., npm/babel
        \\community_bridge: # Replace with a single Community Bridge project-name e.g., cloud-foundry
        \\liberapay: # Replace with a single Liberapay username
        \\issuehunt: # Replace with a single IssueHunt username
        \\otechie: # Replace with a single Otechie username
        \\lfx_crowdfunding: # Replace with a single LFX Crowdfunding project-name e.g., cloud-foundry
        \\custom: # Replace with up to 4 custom sponsorship URLs e.g., ['link1', 'link2']
        \\
    ,
        &.{
            "https://github.com/sponsors/test",
            "https://ko-fi.com/test",
        },
    );
    try expectFundingUrls(
        \\github: test
        \\custom: paypal.me/test
        \\
    ,
        &.{
            "https://github.com/sponsors/test",
            "paypal.me/test",
        },
    );
    try expectFundingUrls(
        \\custom: https://paypal.me/test
    ,
        &.{
            "https://paypal.me/test",
        },
    );
    try expectFundingUrls(
        \\custom:
        \\  - https://paypal.me/test
    ,
        &.{
            "https://paypal.me/test",
        },
    );
    try expectFundingUrls(
        \\custom: "https://github.com/test#support"
    ,
        &.{
            "https://github.com/test#support",
        },
    );
    try expectFundingUrls(
        \\custom:
        \\  - "https://github.com/test#support"
    ,
        &.{
            "https://github.com/test#support",
        },
    );
    try expectFundingUrls(
        \\custom: ["https://github.com/test#support"]
    ,
        &.{
            "https://github.com/test#support",
        },
    );
    try expectFundingUrls(
        \\github: [test-test]
    ,
        &.{
            "https://github.com/sponsors/test-test",
        },
    );
    try expectFundingUrls(
        \\---
        \\github: test
        \\ko_fi: test
        \\custom: "https://www.paypal.me/test"
    ,
        &.{
            "https://github.com/sponsors/test",
            "https://ko-fi.com/test",
            "https://www.paypal.me/test",
        },
    );
}

const UrlsIterator = struct {
    str: []const u8,
    i: usize,

    fn init(str: []const u8) @This() {
        return .{ .str = str, .i = 0 };
    }

    fn next(it: *UrlsIterator) ?[]const u8 {
        const url_start = "://";
        while (true) {
            var start = std.mem.indexOfPos(u8, it.str, it.i, url_start) orelse return null;
            it.i = start + url_start.len;

            const prefixes = [_][]const u8{
                "https",
                "file",
            };

            for (prefixes) |prefix| {
                if (std.mem.endsWith(u8, it.str[0..start], prefix)) {
                    start -= prefix.len;
                    break;
                }
            } else {
                continue;
            }

            while (it.i < it.str.len) : (it.i += 1) switch (it.str[it.i]) {
                'a'...'z', 'A'...'Z', '0'...'9', '/', '.', '_', '-' => {},
                else => break,
            };

            return it.str[start..it.i];
        }
    }
};

fn testUrlsIterator(str: []const u8, expected: []const []const u8) !void {
    var it = UrlsIterator.init(str);
    for (expected) |expect| {
        const next = it.next();
        try std.testing.expect(next != null);
        try std.testing.expectEqualStrings(expect, next.?);
    }

    try std.testing.expect(it.next() == null);
}

test UrlsIterator {
    try testUrlsIterator(
        \\https://dl.elv.sh/linux-amd64/elvish-v0.21.0-rc1.sha256sum
        \\https://dl.elv.sh/linux-amd64/elvish-v0.21.0-rc1.tar.gz
        \\https://dl.elv.sh/linux-amd64/elvish-v0.21.0-rc1.tar.gz.sha256sum
        \\https://dl.elv.sh/linux-amd64/elvish-v0.21.0.sha256sum
        \\https://dl.elv.sh/linux-amd64/elvish-v0.21.0.tar.gz
        \\https://dl.elv.sh/linux-amd64/elvish-v0.21.0.tar.gz.sha256sum
    ,
        &.{
            "https://dl.elv.sh/linux-amd64/elvish-v0.21.0-rc1.sha256sum",
            "https://dl.elv.sh/linux-amd64/elvish-v0.21.0-rc1.tar.gz",
            "https://dl.elv.sh/linux-amd64/elvish-v0.21.0-rc1.tar.gz.sha256sum",
            "https://dl.elv.sh/linux-amd64/elvish-v0.21.0.sha256sum",
            "https://dl.elv.sh/linux-amd64/elvish-v0.21.0.tar.gz",
            "https://dl.elv.sh/linux-amd64/elvish-v0.21.0.tar.gz.sha256sum",
        },
    );
    try testUrlsIterator(
        \\<td class="">x86_64</td>
        \\<td class="">
        \\<a href="https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz">zig-linux-x86_64-0.13.0.tar.xz</a>
        \\</td>
        \\<td class="">
        \\<a href="https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz.minisig">minisig</a>
        \\</td>
    ,
        &.{
            "https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz",
            "https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz.minisig",
        },
    );
    try testUrlsIterator(
        \\test://
        \\https://test.test
        \\://
    ,
        &.{
            "https://test.test",
        },
    );
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
    digest: ?[]const u8 = null,
    description: []const u8,
    repo: GithubRepo,
    tag_name: []const u8,
    target: Target,
    expect: []const u8,
}) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    var tmp_dir = try fs.zigCacheTmpDir(.{});
    defer tmp_dir.deleteAndClose();

    const tmp_dir_path = try tmp_dir.path(arena);
    const static_binary_name = try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{
        options.repo.user,
        options.repo.name,
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
    const latest_release_file_uri = try std.fmt.allocPrint(arena, "file://{s}", .{
        latest_release_file_path,
    });
    try cwd.writeFile(.{
        .sub_path = latest_release_file_path,
        .data = blk: {
            var out = std.ArrayList(u8){};
            try out.appendSlice(arena, "{\"tag_name\": \"");
            try out.appendSlice(arena, options.tag_name);
            try out.appendSlice(arena, "\",\"assets\": [{");
            if (options.digest) |digest| {
                try out.appendSlice(arena, "\"digest\": \"");
                try out.appendSlice(arena, digest);
                try out.appendSlice(arena, "\",");
            }
            try out.appendSlice(arena, "\"browser_download_url\": \"");
            try out.appendSlice(arena, static_binary_uri);
            try out.appendSlice(arena, "\"}]}");
            break :blk out.items;
        },
    });

    const download_file_path = try std.fs.path.join(arena, &.{ tmp_dir_path, "index" });
    const download_file_uri = try std.fmt.allocPrint(arena, "file://{s}", .{download_file_path});
    try cwd.writeFile(.{
        .sub_path = download_file_path,
        .data = try std.fmt.allocPrint(arena,
            \\{s}
            \\
        , .{static_binary_uri}),
    });

    const funding_file_path = try std.fs.path.join(arena, &.{ tmp_dir_path, "FUNDING.yml" });
    const funding_file_uri = try std.fmt.allocPrint(arena, "file://{s}", .{
        funding_file_path,
    });
    try cwd.writeFile(.{
        .sub_path = funding_file_path,
        .data = try std.fmt.allocPrint(arena,
            \\github: {s}
            \\ko_fi: {s}
            \\
        , .{ options.repo.user, options.repo.user }),
    });

    const repository_file_path = try std.fs.path.join(arena, &.{
        tmp_dir_path,
        "repository.json",
    });
    const repository_file_uri = try std.fmt.allocPrint(arena, "file://{s}", .{
        repository_file_path,
    });
    try cwd.writeFile(.{
        .sub_path = repository_file_path,
        .data = try std.fmt.allocPrint(arena,
            \\{{
            \\  "description": "{s}"
            \\}}
            \\
        , .{options.description}),
    });

    var strs = Strings.empty;
    const pkg_from_latest_release = try fromGithub(.{
        .gpa = arena,
        .strs = &strs,
        .http_client = undefined, // Not used when downloading from file:// uris
        .repo = options.repo,
        .repository_uri = repository_file_uri,
        .latest_release_uri = latest_release_file_uri,
        .funding_uri = funding_file_uri,
        .target = options.target,
    });
    const pkg_from_index = try fromGithub(.{
        .gpa = arena,
        .strs = &strs,
        .http_client = undefined, // Not used when downloading from file:// uris
        .repo = options.repo,
        .download_uri = download_file_uri,
        .repository_uri = repository_file_uri,
        .latest_release_uri = latest_release_file_uri,
        .funding_uri = funding_file_uri,
        .target = options.target,
    });

    const expected = try std.mem.replaceOwned(
        u8,
        arena,
        options.expect,
        "<url>",
        static_binary_uri,
    );
    for ([_]Package.Named{ pkg_from_latest_release, pkg_from_index }) |pkg| {
        var actual = std.Io.Writer.Allocating.init(arena);
        try pkg.pkg.write(strs, pkg.name.get(strs), &actual.writer);

        // Remove download field
        try std.testing.expectEqualStrings(expected, try std.mem.replaceOwned(
            u8,
            arena,
            actual.written(),
            try std.fmt.allocPrint(arena, "download = {s}\n", .{download_file_uri}),
            "",
        ));
    }
}

test fromGithub {
    try testFromGithub(.{
        .description = " :cherry_blossom: A command-line fuzzy finder ",
        .repo = .{ .user = "junegunn", .name = "fzf" },
        .tag_name = "v0.54.0",
        .target = .{ .os = .linux, .arch = .x86_64 },
        .expect =
        \\[fzf.info]
        \\version = 0.54.0
        \\description = :cherry_blossom: A command-line fuzzy finder
        \\donate = https://github.com/sponsors/junegunn
        \\donate = https://ko-fi.com/junegunn
        \\
        \\[fzf.update]
        \\version = https://github.com/junegunn/fzf
        \\
        \\[fzf.linux_x86_64]
        \\install_bin = junegunn-fzf-v0.54.0
        \\url = <url>
        \\hash = 86e9fa65b9f0f0f6949ac09c6692d78db54443bf9a69cc8ba366c5ab281b26cf
        \\
        ,
    });
    try testFromGithub(.{
        .description = "Where in we pursue oxidizing (context: https://github.com/googlefonts/oxidize) fontmake.",
        .digest = "sha256:86e9fa65b9f0f0f6949ac09c6692d78db54443bf9a69cc8ba366c5ab281b26cf",
        .repo = .{ .user = "googlefonts", .name = "fontc" },
        .tag_name = "fontc-v0.0.1",
        .target = .{ .os = .linux, .arch = .x86_64 },
        .expect =
        \\[fontc.info]
        \\version = 0.0.1
        \\description = Where in we pursue oxidizing (context: https://github.com/googlefonts/oxidize) fontmake.
        \\donate = https://github.com/sponsors/googlefonts
        \\donate = https://ko-fi.com/googlefonts
        \\
        \\[fontc.update]
        \\version = https://github.com/googlefonts/fontc
        \\
        \\[fontc.linux_x86_64]
        \\install_bin = googlefonts-fontc-fontc-v0.0.1
        \\url = <url>
        \\hash = 86e9fa65b9f0f0f6949ac09c6692d78db54443bf9a69cc8ba366c5ab281b26cf
        \\
        ,
    });
    try std.testing.expectError(error.InvalidHash, testFromGithub(.{
        .description = "Where in we pursue oxidizing (context: https://github.com/googlefonts/oxidize) fontmake.",
        .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .repo = .{ .user = "googlefonts", .name = "fontc" },
        .tag_name = "fontc-v0.0.1",
        .target = .{ .os = .linux, .arch = .x86_64 },
        .expect = "",
    }));
}

fn findStaticallyLinkedBinaries(args: struct {
    gpa: std.mem.Allocator,
    strs: *Strings,
    arch: std.Target.Cpu.Arch,
    dir: std.fs.Dir,
}) !Strings.Indices {
    var arena_state = std.heap.ArenaAllocator.init(args.gpa);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const arch_str = switch (args.arch) {
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
        .cwd_dir = args.dir,
    });

    if (static_files_result.stdout.len < 1)
        return error.NoStaticallyLinkedFiles;

    const off = args.strs.putIndicesBegin();
    var static_files_lines = std.mem.tokenizeScalar(u8, static_files_result.stdout, '\n');
    while (static_files_lines.next()) |static_bin|
        _ = try args.strs.putStrs(args.gpa, &.{static_bin});

    return args.strs.putIndicesEnd(off);
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

    const gpa = std.testing.allocator;
    var strs = Strings.empty;
    defer strs.deinit(gpa);

    const result = try findStaticallyLinkedBinaries(.{
        .gpa = gpa,
        .strs = &strs,
        .arch = options.arch,
        .dir = tmp_dir.dir,
    });

    const len = @min(options.expected.len, result.len);
    for (options.expected[0..len], result.get(strs)[0..len]) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual.get(strs));
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

fn findShare(args: struct {
    gpa: std.mem.Allocator,
    strs: *Strings,
    dir: std.fs.Dir,
}) !Strings.Indices {
    var walker = try args.dir.walk(args.gpa);
    defer walker.deinit();

    const off = args.strs.putIndicesBegin();
    while (try walker.next()) |entry| {
        if (entry.kind != .directory)
            continue;
        if (!std.mem.eql(u8, entry.basename, "share"))
            continue;

        var dir = try args.dir.openDir(entry.path, .{ .iterate = true });
        var it = dir.iterate();
        while (try it.next()) |share_dir_entry| {
            // Some of the folders we don't want to install
            if (std.mem.eql(u8, share_dir_entry.name, "man"))
                continue;
            if (std.mem.eql(u8, share_dir_entry.name, "doc"))
                continue;
            if (std.mem.eql(u8, share_dir_entry.name, "applications"))
                continue;
            if (std.mem.indexOf(u8, share_dir_entry.name, "completion") != null)
                continue;

            const path = try args.strs.print(args.gpa, "{s}/{s}", .{ entry.path, share_dir_entry.name });
            _ = try args.strs.putIndices(args.gpa, &.{path});
        }
        break;
    }

    const res = args.strs.putIndicesEnd(off);

    const SortContext = struct {
        strs: *Strings,

        fn lessThan(ctx: @This(), a: Strings.Index, b: Strings.Index) bool {
            return std.mem.lessThan(u8, a.get(ctx.strs.*), b.get(ctx.strs.*));
        }
    };
    std.mem.sort(
        Strings.Index,
        res.get(args.strs.*),
        SortContext{ .strs = args.strs },
        SortContext.lessThan,
    );

    return res;
}

fn testFindShare(options: struct {
    files: []const std.fs.Dir.WriteFileOptions,
    expected: []const []const u8,
}) !void {
    var tmp_dir = try fs.zigCacheTmpDir(.{ .iterate = true });
    defer tmp_dir.deleteAndClose();

    for (options.files) |file_options| {
        try tmp_dir.dir.makePath(std.fs.path.dirname(file_options.sub_path) orelse ".");
        try tmp_dir.dir.writeFile(file_options);
    }

    const gpa = std.testing.allocator;
    var strs = Strings.empty;
    defer strs.deinit(gpa);

    const result = try findShare(.{
        .gpa = gpa,
        .strs = &strs,
        .dir = tmp_dir.dir,
    });

    const len = @min(options.expected.len, result.len);
    for (options.expected[0..len], result.get(strs)[0..len]) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual.get(strs));
    try std.testing.expectEqual(options.expected.len, result.len);
}

test findShare {
    try testFindShare(.{
        .files = &.{
            .{ .sub_path = "bin/bin", .data = "" },
            .{ .sub_path = "libexec/bin", .data = "" },
            .{ .sub_path = "share/a/test.txt", .data = "" },
            .{ .sub_path = "share/b/test.txt", .data = "" },
            .{ .sub_path = "share/bash-completion/test.txt", .data = "" },
            .{ .sub_path = "share/doc/test.txt", .data = "" },
            .{ .sub_path = "share/man/test.txt", .data = "" },
        },
        .expected = &.{
            "share/a",
            "share/b",
        },
    });
}

fn findManPages(args: struct {
    gpa: std.mem.Allocator,
    strs: *Strings,
    dir: std.fs.Dir,
}) !Strings.Indices {
    var walker = try args.dir.walk(args.gpa);
    defer walker.deinit();

    const off = args.strs.putIndicesBegin();
    while (try walker.next()) |entry| {
        if (entry.kind != .file)
            continue;
        if (std.mem.startsWith(u8, entry.basename, "."))
            continue;
        if (!isManPage(entry.basename))
            continue;

        var name_split = std.mem.splitScalar(u8, entry.path, '.');
        _ = name_split.first();
        const man_section = name_split.next() orelse continue;

        const install = try args.strs.print(args.gpa, "man/man{s}/{s}:{s}", .{
            man_section,
            std.fs.path.basename(entry.path),
            entry.path,
        });
        _ = try args.strs.putIndices(args.gpa, &.{install});
    }

    const SortContext = struct {
        strs: *Strings,

        fn lessThan(ctx: @This(), a: Strings.Index, b: Strings.Index) bool {
            return std.mem.lessThan(u8, a.get(ctx.strs.*), b.get(ctx.strs.*));
        }
    };

    const res = args.strs.putIndicesEnd(off);
    std.mem.sort(
        Strings.Index,
        res.get(args.strs.*),
        SortContext{ .strs = args.strs },
        SortContext.lessThan,
    );
    return res;
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

    const gpa = std.testing.allocator;
    var strs = Strings.empty;
    defer strs.deinit(gpa);

    const result = try findManPages(.{
        .gpa = gpa,
        .strs = &strs,
        .dir = tmp_dir.dir,
    });

    const len = @min(options.expected.len, result.len);
    for (options.expected[0..len], result.get(strs)[0..len]) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual.get(strs));
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
            "man/man1/text.1.gz:subdir/text.1.gz",
            "man/man1/text.1.gz:text.1.gz",
            "man/man1/text.1:subdir/text.1",
            "man/man1/text.1:text.1",
            "man/man10/text.10.gz:subdir/text.10.gz",
            "man/man10/text.10.gz:text.10.gz",
            "man/man10/text.10:subdir/text.10",
            "man/man10/text.10:text.10",
        },
    });
}

const FindDownloadUrlOptions = struct {
    target: Target,
    extra_strs: []const []const u8 = &.{},
    urls: []const []const u8,
};

fn findDownloadUrl(options: FindDownloadUrlOptions) ![]const u8 {
    const idx = try findDownloadUrlIndex(options);
    return options.urls[idx];
}

fn findDownloadUrlIndex(options: FindDownloadUrlOptions) !usize {
    if (options.urls.len == 0)
        return error.DownloadUrlNotFound;

    var best_score: usize = 0;
    var best_index: usize = 0;

    for (options.urls, 0..) |url, i| {
        var this_score: usize = 0;

        this_score += std.mem.count(u8, url, @tagName(options.target.arch));
        this_score += std.mem.count(u8, url, @tagName(options.target.os));

        switch (options.target.os) {
            .linux => {
                this_score += std.mem.count(u8, url, "Linux");

                // Targeting musl abi or the alpine distro tends mean the executable is statically
                // linked
                this_score += std.mem.count(u8, url, "alpine");
                this_score += std.mem.count(u8, url, "musl");
                this_score += std.mem.count(u8, url, "static");
            },
            else => {},
        }

        switch (options.target.arch) {
            .x86_64 => {
                this_score += std.mem.count(u8, url, "64bit");
                this_score += std.mem.count(u8, url, "amd64");
                this_score += std.mem.count(u8, url, "x64");
                this_score += std.mem.count(u8, url, "x86-64");

                switch (options.target.os) {
                    .linux => {
                        this_score += std.mem.count(u8, url, "linux64");
                    },
                    else => {},
                }
            },
            .x86 => {
                this_score += std.mem.count(u8, url, "32bit");
            },
            else => {},
        }

        // The above rules are the most important
        this_score *= 10;

        var buf: [1024]u8 = undefined;
        for (options.extra_strs) |string| {
            this_score += std.mem.count(u8, url, string);
            // We wonna pick `tau` instead of `taucorder`. Most of the time, these names are
            // separated with `_` or `-`
            this_score += std.mem.count(u8, url, try std.fmt.bufPrint(&buf, "{s}_", .{string}));
            this_score += std.mem.count(u8, url, try std.fmt.bufPrint(&buf, "{s}-", .{string}));
            this_score += std.mem.count(u8, url, try std.fmt.bufPrint(&buf, "_{s}", .{string}));
            this_score += std.mem.count(u8, url, try std.fmt.bufPrint(&buf, "-{s}", .{string}));
            this_score += std.mem.count(u8, url, try std.fmt.bufPrint(&buf, "_{s}_", .{string}));
            this_score += std.mem.count(u8, url, try std.fmt.bufPrint(&buf, "-{s}-", .{string}));
        }

        // Certain extensions indicate means the link downloads a signature, deb package or other
        // none useful resources to `dipm`
        const deprioritized_suffixs = [_][]const u8{
            ".asc",
            ".b3",
            ".deb",
            ".json",
            ".minisig",
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
            ".sigstore",

            // HACK: atuin has an "update" binary used for (I assume) updating atuin itself. This
            //       is picked instead of the actual binary, so lets just deprioritized it
            "-update",
        };
        for (deprioritized_suffixs) |suffix|
            this_score -|= @as(usize, @intFromBool(std.mem.endsWith(u8, url, suffix))) * 1000;

        // Avoid debug builds of binaries
        this_score -|= std.mem.count(u8, url, "debug");

        // Avoid release candidates
        this_score -|= std.mem.count(u8, url, "rc") * 2;

        switch (options.target.os) {
            .linux => {
                // Targeting the gnu abi tends to not be statically linked
                this_score -|= std.mem.count(u8, url, "gnu");
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

    return best_index;
}

test findDownloadUrl {
    try std.testing.expectEqualStrings("/fzf-0.54.0-linux_amd64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strs = &.{"fzf"},
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
        .extra_strs = &.{"fzf"},
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
        .extra_strs = &.{"gophish"},
        .urls = &.{
            "/gophish-v0.12.1-linux-32bit.zip",
            "/gophish-v0.12.1-linux-64bit.zip",
            "/gophish-v0.12.1-osx-64bit.zip",
            "/gophish-v0.12.1-windows-64bit.zip",
        },
    }));
    try std.testing.expectEqualStrings("/gophish-v0.12.1-windows-64bit.zip", try findDownloadUrl(.{
        .target = .{ .os = .windows, .arch = .x86_64 },
        .extra_strs = &.{"gophish"},
        .urls = &.{
            "/gophish-v0.12.1-linux-32bit.zip",
            "/gophish-v0.12.1-linux-64bit.zip",
            "/gophish-v0.12.1-osx-64bit.zip",
            "/gophish-v0.12.1-windows-64bit.zip",
        },
    }));
    try std.testing.expectEqualStrings("/gophish-v0.12.1-linux-32bit.zip", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86 },
        .extra_strs = &.{"gophish"},
        .urls = &.{
            "/gophish-v0.12.1-linux-32bit.zip",
            "/gophish-v0.12.1-linux-64bit.zip",
            "/gophish-v0.12.1-osx-64bit.zip",
            "/gophish-v0.12.1-windows-64bit.zip",
        },
    }));
    try std.testing.expectEqualStrings("/wasmer-linux-musl-amd64.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strs = &.{"wasmer"},
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
        .extra_strs = &.{"mise"},
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
        .extra_strs = &.{"shadowsocks"},
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
        .extra_strs = &.{"sigrs"},
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
        .extra_strs = &.{"dockerc"},
        .urls = &.{
            "/dockerc_aarch64",
            "/dockerc_x86-64",
            "/dockerc_x86-64-gnu",
        },
    }));
    try std.testing.expectEqualStrings("/micro-2.0.14-linux64-static.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strs = &.{"micro"},
        .urls = &.{
            "/micro-2.0.14-linux64-static.tar.gz",
            "/micro-2.0.14-linux64.tar.gz",
        },
    }));
    try std.testing.expectEqualStrings("/jq-linux64", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strs = &.{"jq"},
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
        .extra_strs = &.{"act"},
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
        .extra_strs = &.{"age"},
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
        .extra_strs = &.{"caddy"},
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
        .extra_strs = &.{"glow"},
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
        .extra_strs = &.{"iamb"},
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
        .extra_strs = &.{"linutil"},
        .urls = &.{
            "/linutil",
            "/start.sh",
            "/startdev.sh",
        },
    }));
    try std.testing.expectEqualStrings("/ownserver_v0.6.0_x86_64-unknown-linux-musl.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strs = &.{"ownserver"},
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
        .extra_strs = &.{"presenterm"},
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
        .extra_strs = &.{"rustic"},
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
        .extra_strs = &.{"watchexec"},
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
        .extra_strs = &.{"tigerbeetle"},
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
        .extra_strs = &.{"tau"},
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
        .extra_strs = &.{"sccache"},
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
        .extra_strs = &.{ "sccache", "sccache-v0.8.1" },
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
        .extra_strs = &.{"dns53"},
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
        .extra_strs = &.{"dotenv-linter"},
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
        .extra_strs = &.{"micro"},
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
        .extra_strs = &.{ "usql", "usql-0.19.3" },
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
        .extra_strs = &.{"uctags"},
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
    try std.testing.expectEqualStrings("linux-amd64/elvish-v0.21.0.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strs = &.{"elvish"},
        .urls = &.{
            "darwin-arm64/elvish-v0.21.0.tar.gz",
            "darwin-amd64/elvish-v0.21.0.tar.gz",
            "linux-arm64/elvish-v0.21.0.tar.gz",
            "linux-amd64/elvish-v0.21.0.tar.gz",
        },
    }));
    try std.testing.expectEqualStrings("/elvish-v0.21.0.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strs = &.{"elvish"},
        .urls = &.{
            "/elvish-v0.21.0-rc1.tar.gz",
            "/elvish-v0.21.0.tar.gz",
        },
    }));
    try std.testing.expectEqualStrings("/zls-x86-linux.tar.xz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strs = &.{"zls"},
        .urls = &.{
            "/zls-x86-linux.tar.xz",
            "/zls-x86-linux.tar.xz.minisig",
        },
    }));
    try std.testing.expectEqualStrings("/atuin-x86_64-unknown-linux-musl.tar.gz", try findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .extra_strs = &.{"atuin"},
        .urls = &.{
            "/atuin-x86_64-unknown-linux-musl-update",
            "/atuin-x86_64-unknown-linux-musl.tar.gz",
        },
    }));

    try std.testing.expectError(error.DownloadUrlNotFound, findDownloadUrl(.{
        .target = .{ .os = .linux, .arch = .x86_64 },
        .urls = &.{},
    }));
}

fn versionFromTag(tag: []const u8) []const u8 {
    for (tag, 0..) |c, i| switch (c) {
        '0'...'9' => return tag[i..],
        else => {},
    };

    return tag;
}

test versionFromTag {
    try std.testing.expectEqualStrings("1.8.3", versionFromTag("cli/v1.8.3"));
    try std.testing.expectEqualStrings("2024_01_01", versionFromTag("year-2024_01_01"));
    try std.testing.expectEqualStrings("2024_01_01", versionFromTag("year_2024_01_01"));
    try std.testing.expectEqualStrings("2024_01_01", versionFromTag("_2024_01_01"));
    try std.testing.expectEqualStrings("2024_01_01", versionFromTag(".2024_01_01"));
    try std.testing.expectEqualStrings("test", versionFromTag("test"));
    try std.testing.expectEqualStrings("0.13.0-alpha.11", versionFromTag("v0.13.0-alpha.11"));
    try std.testing.expectEqualStrings("1", versionFromTag("v1"));
    try std.testing.expectEqualStrings("1.", versionFromTag("v1."));
    try std.testing.expectEqualStrings("1.1", versionFromTag("v1.1"));
}

test {
    _ = Progress;
    _ = Strings;
    _ = Target;

    _ = download;
    _ = fs;
    _ = heap;
}

const Package = @This();

const Packages = @import("Packages.zig");
const Progress = @import("Progress.zig");
const Strings = @import("Strings.zig");
const Target = @import("Target.zig");

const builtin = @import("builtin");
const download = @import("download.zig");
const fs = @import("fs.zig");
const heap = @import("heap.zig");
const std = @import("std");
