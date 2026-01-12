test "dipm list all" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "list", "all" });
    try prefix.expectFile("stdout", "test-file\t0.1.0\n" ++
        "test-xz\t0.1.0\n" ++
        "test-gz\t0.1.0\n" ++
        "test-zst\t0.1.0\n" ++
        "wrong-hash\t0.1.0\n" ++
        "fails-download\t0.1.0\n" ++
        "dup-bin1\t0.1.0\n" ++
        "dup-bin2\t0.1.0\n" ++
        "dup-bin3\t0.1.0\n" ++
        "dup-lib1\t0.1.0\n" ++
        "dup-lib2\t0.1.0\n" ++
        "dup-lib3\t0.1.0\n");
}

test "dipm install test-file" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0
        \\
    );
    try prefix.expectFile("bin/test-file", "Binary");
    try prefix.expectFile("lib/test-file", "Binary");
    try prefix.expectFile("lib/subdir/test-file", "Binary");
    try prefix.expectFile("share/test-file", "Binary");
    try prefix.expectFile("share/subdir/test-file", "Binary");

    try prefix.expectFile("share/dipm/installed.ini",
        \\[test-file]
        \\version = 0.1.0
        \\location = bin/test-file
        \\location = lib/test-file
        \\location = lib/subdir/test-file
        \\location = share/test-file
        \\location = share/subdir/test-file
        \\
    );
}

test "dipm install test-xz" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-xz" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0
        \\
    );
    try prefix.expectFile("bin/test-xz", "");
    try prefix.expectFile("lib/test-xz", "");
    try prefix.expectFile("lib/test-xz-dir/file", "");
    try prefix.expectFile("share/test-xz", "");
    try prefix.expectFile("share/test-xz-dir/file", "");

    try prefix.expectFile("share/dipm/installed.ini",
        \\[test-xz]
        \\version = 0.1.0
        \\location = bin/test-xz
        \\location = lib/test-xz-dir
        \\location = lib/test-xz
        \\location = share/test-xz-dir
        \\location = share/test-xz
        \\
    );
}

test "dipm install test-gz" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-gz" });
    try prefix.expectFile("stderr",
        \\✓ test-gz 0.1.0
        \\
    );
    try prefix.expectFile("bin/test-gz", "");
    try prefix.expectFile("lib/test-gz", "");
    try prefix.expectFile("lib/test-gz-dir/file", "");
    try prefix.expectFile("share/test-gz", "");
    try prefix.expectFile("share/test-gz-dir/file", "");

    try prefix.expectFile("share/dipm/installed.ini",
        \\[test-gz]
        \\version = 0.1.0
        \\location = bin/test-gz
        \\location = lib/test-gz-dir
        \\location = lib/test-gz
        \\location = share/test-gz-dir
        \\location = share/test-gz
        \\
    );
}

test "install test-zst" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-zst" });
    try prefix.expectFile("stderr",
        \\✓ test-zst 0.1.0
        \\
    );
    try prefix.expectFile("bin/test-zst", "");
    try prefix.expectFile("lib/test-zst", "");
    try prefix.expectFile("lib/test-zst-dir/file", "");
    try prefix.expectFile("share/test-zst", "");
    try prefix.expectFile("share/test-zst-dir/file", "");

    try prefix.expectFile("share/dipm/installed.ini",
        \\[test-zst]
        \\version = 0.1.0
        \\location = bin/test-zst
        \\location = lib/test-zst-dir
        \\location = lib/test-zst
        \\location = share/test-zst-dir
        \\location = share/test-zst
        \\
    );
}

test "dipm install test-zst test-zst test-xz test-xz" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-zst", "test-zst", "test-xz", "test-xz" });
    try prefix.expectFile("stderr",
        \\✓ test-zst 0.1.0
        \\✓ test-xz 0.1.0
        \\
    );
}

test "dipm install test-file && dipm install test-file" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0
        \\
    );

    try prefix.run(&.{ "dipm", "install", "test-file" });
    try prefix.expectFile("stderr",
        \\⚠ test-file
        \\└── Package already installed
        \\
    );
}

test "dipm install test-file && dipm uninstall test-file" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0
        \\
    );

    try prefix.run(&.{ "dipm", "uninstall", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0 -> ✗
        \\
    );
    try prefix.expectNoFile("bin/test-file");
    try prefix.expectNoFile("lib/test-file");
    try prefix.expectNoFile("lib/subdir/test-file");
    try prefix.expectNoFile("share/test-file");
    try prefix.expectNoFile("share/subdir/test-file");
    try prefix.expectFile("share/dipm/installed.ini", "");
}

test "dipm uninstall test-file" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "uninstall", "test-file" });
    try prefix.expectFile("stderr",
        \\⚠ test-file
        \\└── Package is not installed
        \\
    );
}

test "dipm install test-file && dipm uninstall test-file && dipm uninstall test-file" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0
        \\
    );

    try prefix.run(&.{ "dipm", "uninstall", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0 -> ✗
        \\
    );

    try prefix.run(&.{ "dipm", "uninstall", "test-file" });
    try prefix.expectFile("stderr",
        \\⚠ test-file
        \\└── Package is not installed
        \\
    );
}

test "dipm install test-xz && rm bin/test-xz && dipm uninstall test-xz" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-xz" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0
        \\
    );
    try prefix.expectFile("bin/test-xz", "");

    try prefix.rm("bin/test-xz");
    try prefix.run(&.{ "dipm", "uninstall", "test-xz" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0 -> ✗
        \\
    );
}

test "dipm install test-xz test-zst && dipm update test-xz" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-xz", "test-zst" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0
        \\✓ test-zst 0.1.0
        \\
    );

    try prefix.expectFile("share/dipm/installed.ini",
        \\[test-xz]
        \\version = 0.1.0
        \\location = bin/test-xz
        \\location = lib/test-xz-dir
        \\location = lib/test-xz
        \\location = share/test-xz-dir
        \\location = share/test-xz
        \\
        \\[test-zst]
        \\version = 0.1.0
        \\location = bin/test-zst
        \\location = lib/test-zst-dir
        \\location = lib/test-zst
        \\location = share/test-zst-dir
        \\location = share/test-zst
        \\
    );

    // Override version of packages in prefix
    var prefix_v2 = try setupPrefix(.{ .version = "0.2.0", .prefix = prefix.prefix });
    defer prefix_v2.deinit();

    try prefix.run(&.{ "dipm", "update", "test-xz" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0 -> 0.2.0
        \\
    );
    try prefix.expectFile("share/dipm/installed.ini",
        \\[test-zst]
        \\version = 0.1.0
        \\location = bin/test-zst
        \\location = lib/test-zst-dir
        \\location = lib/test-zst
        \\location = share/test-zst-dir
        \\location = share/test-zst
        \\
        \\[test-xz]
        \\version = 0.2.0
        \\location = bin/test-xz
        \\location = lib/test-xz-dir
        \\location = lib/test-xz
        \\location = share/test-xz-dir
        \\location = share/test-xz
        \\
    );
}

test "dipm install test-xz test-zst && dipm update" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-xz", "test-zst" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0
        \\✓ test-zst 0.1.0
        \\
    );

    try prefix.expectFile("share/dipm/installed.ini",
        \\[test-xz]
        \\version = 0.1.0
        \\location = bin/test-xz
        \\location = lib/test-xz-dir
        \\location = lib/test-xz
        \\location = share/test-xz-dir
        \\location = share/test-xz
        \\
        \\[test-zst]
        \\version = 0.1.0
        \\location = bin/test-zst
        \\location = lib/test-zst-dir
        \\location = lib/test-zst
        \\location = share/test-zst-dir
        \\location = share/test-zst
        \\
    );

    // Override version of packages in prefix
    var prefix_v2 = try setupPrefix(.{ .version = "0.2.0", .prefix = prefix.prefix });
    defer prefix_v2.deinit();

    try prefix.run(&.{ "dipm", "update" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0 -> 0.2.0
        \\✓ test-zst 0.1.0 -> 0.2.0
        \\
    );
    try prefix.expectFile("share/dipm/installed.ini",
        \\[test-xz]
        \\version = 0.2.0
        \\location = bin/test-xz
        \\location = lib/test-xz-dir
        \\location = lib/test-xz
        \\location = share/test-xz-dir
        \\location = share/test-xz
        \\
        \\[test-zst]
        \\version = 0.2.0
        \\location = bin/test-zst
        \\location = lib/test-zst-dir
        \\location = lib/test-zst
        \\location = share/test-zst-dir
        \\location = share/test-zst
        \\
    );
}

test "dipm install test-xz test-gz && dipm update && dipm uninstall test-xz test-gz" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-xz", "test-gz" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0
        \\✓ test-gz 0.1.0
        \\
    );

    // Override version of packages in prefix
    var prefix_v2 = try setupPrefix(.{ .version = "0.2.0", .prefix = prefix.prefix });
    defer prefix_v2.deinit();

    try prefix.run(&.{ "dipm", "update" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0 -> 0.2.0
        \\✓ test-gz 0.1.0 -> 0.2.0
        \\
    );

    try prefix.run(&.{ "dipm", "uninstall", "test-xz", "test-gz" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.2.0 -> ✗
        \\✓ test-gz 0.2.0 -> ✗
        \\
    );
}

test "dipm install wrong-hash" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    const res = prefix.run(&.{ "dipm", "install", "wrong-hash" });
    try std.testing.expectError(Diagnostics.Error.DiagnosticsReported, res);
    try prefix.expectFile("stderr",
        \\✗ wrong-hash 0.1.0
        \\│   Hash mismatch
        \\│     expected: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        \\└──   actual:   ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2
        \\
    );
}

test "dipm install not-found" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "not-found" });
    try prefix.expectFile("stderr",
        \\⚠ not-found
        \\└── Package not found
        \\
    );
}

test "dipm install test-xz test-xz && dipm uninstall test-xz test-xz" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-xz", "test-xz" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0
        \\
    );

    try prefix.run(&.{ "dipm", "uninstall", "test-xz", "test-xz" });
    try prefix.expectFile("stderr",
        \\✓ test-xz 0.1.0 -> ✗
        \\
    );
}

test "dipm install not-found not-found" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "not-found", "not-found" });
    try prefix.expectFile("stderr",
        \\⚠ not-found
        \\└── Package not found
        \\
    );
}

test "dipm install test-file && dipm update test-file" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0
        \\
    );

    try prefix.run(&.{ "dipm", "update", "test-file" });
    try prefix.expectFile("stderr",
        \\⚠ test-file 0.1.0
        \\└── Package is up to date
        \\
    );
}

test "dipm install test-file && dipm update --force test-file" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0
        \\
    );

    try prefix.run(&.{ "dipm", "update", "--force", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0 -> 0.1.0
        \\
    );
}

test "dipm install test-file && dipm update" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0
        \\
    );

    try prefix.run(&.{ "dipm", "update" });
    try prefix.expectFile("stderr",
        \\
    );
}

test "dipm install test-file && dipm update --force" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    try prefix.run(&.{ "dipm", "install", "test-file" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0
        \\
    );

    try prefix.run(&.{ "dipm", "update", "--force" });
    try prefix.expectFile("stderr",
        \\✓ test-file 0.1.0 -> 0.1.0
        \\
    );
}

test "dipm install fails-download" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    const res = prefix.run(&.{ "dipm", "install", "fails-download" });
    try std.testing.expectError(Diagnostics.Error.DiagnosticsReported, res);
    try prefix.expectFileStartsWith("stderr",
        \\✗ fails-download 0.1.0
        \\│   Failed to download
    );
}

test "dipm install packages with shared files in bin/" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    const res = prefix.run(&.{ "dipm", "install", "dup-bin1", "dup-bin2", "dup-bin3" });
    try std.testing.expectError(Diagnostics.Error.DiagnosticsReported, res);
    try prefix.expectFile("stderr",
        \\✓ dup-bin1 0.1.0
        \\✗ dup-bin2
        \\└── Path already exists: bin/test-file
        \\✗ dup-bin3
        \\└── Path already exists: bin/test-file
        \\
    );
    try prefix.expectFile("share/dipm/installed.ini",
        \\[dup-bin1]
        \\version = 0.1.0
        \\location = bin/test-file
        \\
    );
}

test "dipm install packages with shared files in lib/" {
    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    const res = prefix.run(&.{ "dipm", "install", "dup-lib1", "dup-lib2", "dup-lib3" });
    try std.testing.expectError(Diagnostics.Error.DiagnosticsReported, res);
    try prefix.expectFile("stderr",
        \\✓ dup-lib1 0.1.0
        \\✗ dup-lib2
        \\└── Path already exists: lib/test-file
        \\✗ dup-lib3
        \\└── Path already exists: lib/test-file
        \\
    );
    try prefix.expectFile("share/dipm/installed.ini",
        \\[dup-lib1]
        \\version = 0.1.0
        \\location = lib/test-file
        \\
    );
}

fn fuzz(_: void, fuzz_input: []const u8) !void {
    const gpa = std.testing.allocator;
    var args = std.ArrayList([*:0]const u8){};
    defer args.deinit(gpa);

    var args_it = try std.process.Args.IteratorGeneral(.{}).init(std.testing.allocator, fuzz_input);
    defer args_it.deinit();

    try args.append(gpa, "dipm");
    while (args_it.next()) |arg|
        try args.append(gpa, arg.ptr);

    var prefix = try setupPrefix(.{ .version = "0.1.0" });
    defer prefix.deinit();

    prefix.run(args.items) catch |err| switch (err) {
        Diagnostics.Error.DiagnosticsReported => {},
        error.InvalidArgument => {},
        else => try std.testing.expect(false),
    };
}

test "fuzz" {
    try std.testing.fuzz({}, fuzz, .{});
}

fn setupPrefix(options: struct {
    version: []const u8,

    /// If null, a random prefix will be generated
    prefix: ?[]const u8 = null,
}) !Prefix {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const pkgs = [_]TestPackage{
        simple_file,
        simple_tree_tar_xz,
        simple_tree_tar_gz,
        simple_tree_tar_zst,
        wrong_hash,
        fails_download,
        duplicate_bin_file1,
        duplicate_bin_file2,
        duplicate_bin_file3,
        duplicate_lib_file1,
        duplicate_lib_file2,
        duplicate_lib_file3,
    };

    const prefix_path = if (options.prefix) |prefix|
        try gpa.dupe(u8, prefix)
    else
        try fs.zigCacheTmpDirPath(io, gpa);
    errdefer gpa.free(prefix_path);

    const cwd = std.Io.Dir.cwd();
    var prefix_dir = try cwd.createDirPathOpen(io, prefix_path, .{});
    errdefer prefix_dir.close(io);

    const pkgs_ini_path = try std.fs.path.join(gpa, &.{
        prefix_path,
        paths.own_data_subpath,
        paths.pkgs_file_name,
    });
    defer gpa.free(pkgs_ini_path);

    const pkgs_dir_path = try std.fs.path.join(gpa, &.{ prefix_path, "pkgs" });
    defer gpa.free(pkgs_dir_path);

    var pkgs_dir = try cwd.createDirPathOpen(io, pkgs_dir_path, .{});
    defer pkgs_dir.close(io);

    var pkgs_ini_dir, const pkgs_ini_file = try fs.createDirAndFile(io, cwd, pkgs_ini_path, .{});
    defer pkgs_ini_dir.close(io);
    defer pkgs_ini_file.close(io);

    var pkgs_ini_writer_buffer: [std.heap.page_size_min]u8 = undefined;
    var pkgs_ini_file_writer = pkgs_ini_file.writer(io, &pkgs_ini_writer_buffer);
    const pkgs_ini_writer = &pkgs_ini_file_writer.interface;

    for (pkgs, 0..) |pkg, i| {
        if (pkg.file.content) |content|
            try pkgs_dir.writeFile(io, .{
                .sub_path = pkg.file.name,
                .data = content,
                .flags = .{},
            });

        if (i != 0) try pkgs_ini_writer.writeAll("\n");

        try pkgs_ini_writer.print("[{s}.info]\n", .{pkg.name});
        try pkgs_ini_writer.print("version = {s}\n", .{options.version});
        try pkgs_ini_writer.print("[{s}.linux_x86_64]\n", .{pkg.name});
        for (pkg.install_bin) |install|
            try pkgs_ini_writer.print("install_bin = {s}\n", .{install});
        for (pkg.install_lib) |install|
            try pkgs_ini_writer.print("install_lib = {s}\n", .{install});
        for (pkg.install_share) |install|
            try pkgs_ini_writer.print("install_share = {s}\n", .{install});
        try pkgs_ini_writer.print("url = file://{s}/{s}\n", .{
            pkgs_dir_path,
            pkg.file.name,
        });
        try pkgs_ini_writer.print("hash = {s}\n", .{pkg.file.hash});
    }

    try pkgs_ini_writer.flush();

    const pkgs_uri = try std.fmt.allocPrint(gpa, "file://{s}", .{pkgs_ini_path});
    errdefer gpa.free(pkgs_uri);

    return .{
        .io = io,
        .gpa = gpa,
        .pkgs_uri = pkgs_uri,
        .prefix = prefix_path,
        .prefix_dir = prefix_dir,
    };
}

const Prefix = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    pkgs_uri: []const u8,
    prefix: []const u8,
    prefix_dir: std.Io.Dir,

    fn deinit(prefix: *Prefix) void {
        prefix.prefix_dir.close(prefix.io);
        std.Io.Dir.cwd().deleteTree(prefix.io, prefix.prefix) catch {};
        prefix.gpa.free(prefix.pkgs_uri);
        prefix.gpa.free(prefix.prefix);
    }

    fn run(prefix: Prefix, args: []const [*:0]const u8) !void {
        const io = prefix.io;
        const gpa = prefix.gpa;

        var dir = try std.Io.Dir.cwd().openDir(io, prefix.prefix, .{});
        defer dir.close(io);

        var io_lock = std.Thread.Mutex{};
        var stdout = try dir.createFile(io, "stdout", .{ .read = true });
        defer stdout.close(io);

        var stderr = try dir.createFile(io, "stderr", .{ .read = true });
        defer stderr.close(io);

        var stdout_buf: [std.heap.page_size_min]u8 = undefined;
        var stderr_buf: [std.heap.page_size_min]u8 = undefined;
        var stdout_file_writer = stdout.writer(io, &stdout_buf);
        var stderr_file_writer = stderr.writer(io, &stderr_buf);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        var environ_map = std.process.Environ.Map.init(arena.allocator());
        try main.mainFull(.{
            .minimal = .{
                .args = .{ .vector = args },
                .environ = .empty,
            },
            .io = io,
            .gpa = gpa,
            .arena = &arena,
            .environ_map = &environ_map,
            .preopens = .empty,
        }, .{
            .io_lock = &io_lock,
            .stdout = &stdout_file_writer,
            .stderr = &stderr_file_writer,
            .forced_prefix = prefix.prefix,
            .forced_pkgs_uri = prefix.pkgs_uri,
        });

        try stdout_file_writer.end();
        try stderr_file_writer.end();
    }

    fn rm(prefix: Prefix, path: []const u8) !void {
        return prefix.prefix_dir.deleteTree(prefix.io, path);
    }

    fn expectNoFile(prefix: Prefix, file: []const u8) !void {
        const err_file = prefix.prefix_dir.openFile(prefix.io, file, .{});
        defer if (err_file) |f| f.close(prefix.io) else |_| {};

        try std.testing.expectError(error.FileNotFound, err_file);
    }

    fn expectFile(prefix: Prefix, file: []const u8, content: []const u8) !void {
        const actual = try prefix.prefix_dir.readFileAlloc(
            prefix.io,
            file,
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(actual, content);
    }

    fn expectFileStartsWith(prefix: Prefix, file: []const u8, content: []const u8) !void {
        const actual = try prefix.prefix_dir.readFileAlloc(
            prefix.io,
            file,
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(actual);
        try std.testing.expectStringStartsWith(actual, content);
    }
};

const TestPackage = struct {
    name: []const u8,
    file: File,
    install_bin: []const []const u8 = &.{},
    install_lib: []const []const u8 = &.{},
    install_share: []const []const u8 = &.{},

    const File = struct {
        name: []const u8,
        hash: []const u8,
        content: ?[]const u8,
    };
};

const simple_file = TestPackage{
    .name = "test-file",
    .file = .{
        .name = "pkg",
        .hash = "ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2",
        .content = "Binary",
    },
    .install_bin = &.{"test-file:pkg"},
    .install_lib = &.{ "test-file:pkg", "subdir/test-file:pkg" },
    .install_share = &.{ "test-file:pkg", "subdir/test-file:pkg" },
};

// All `simple_tree_` binaries are compressed archives. They're generated with the following
// commands:
//   COMPRESSION='<compression>'
//   FILE='file.tar.<ext>'
//   cd "$(mktemp -d)"
//   mkdir -p bin lib/dir share/dir
//   touch bin/file lib/file lib/dir/file share/file share/dir/file
//   tar --use-compress-program "$COMPRESSION" -cvf "$FILE" bin lib/ share/
//   xxd -p "$FILE" | tr -d '\n' | sed -E 's/([a-z0-9]{2})/0x\1,/g'
//   sha256sum "$FILE"
//
const simple_tree_tar_xz = TestPackage{
    .name = "test-xz",
    .file = .{
        .name = "pkg.tar.xz",
        .hash = "c7de5b61d6d31bbb5ad53b149ada3eaf6c0fcf084210339ba9639e3c26d900fe",
        .content = &[_]u8{
            0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x04, 0xe6, 0xd6, 0xb4, 0x46, 0x04, 0xc0,
            0xd2, 0x01, 0x80, 0x50, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x86, 0x43, 0x3f, 0x31, 0xe0, 0x27, 0xff, 0x00, 0xca, 0x5d, 0x00, 0x31, 0x1a, 0x4a,
            0x1b, 0x05, 0x91, 0x90, 0x37, 0x3a, 0x51, 0xbd, 0x57, 0x73, 0xde, 0x3d, 0xdf, 0x6f,
            0x04, 0xc0, 0xaf, 0x92, 0x58, 0x61, 0x4e, 0x33, 0x67, 0x83, 0x4f, 0xf9, 0xc2, 0x24,
            0x70, 0x58, 0x9a, 0xc1, 0xae, 0xac, 0x08, 0xc5, 0x4b, 0x42, 0xda, 0x32, 0x95, 0xaf,
            0xf1, 0x0e, 0x99, 0x46, 0xd5, 0xc5, 0xc9, 0x29, 0x85, 0xf9, 0x17, 0x20, 0x84, 0xa8,
            0xdf, 0xd1, 0x4b, 0xc1, 0x76, 0x1d, 0x18, 0xc7, 0xa1, 0x1c, 0x0a, 0x6e, 0x32, 0x71,
            0xac, 0xd4, 0x7e, 0xbc, 0xae, 0xe6, 0xab, 0x9a, 0x68, 0xc4, 0xf2, 0x96, 0x20, 0xa6,
            0x36, 0xa2, 0x4b, 0x0f, 0x62, 0xc1, 0xeb, 0x9e, 0x39, 0x97, 0x95, 0x56, 0x74, 0x4b,
            0xf5, 0xde, 0x93, 0xcf, 0x7c, 0x8c, 0xf2, 0x4e, 0x97, 0xd9, 0x7c, 0x88, 0x65, 0xac,
            0x00, 0x16, 0x4b, 0x21, 0x26, 0xc4, 0xf5, 0xb7, 0xcb, 0xae, 0x51, 0x98, 0xfe, 0x90,
            0xa9, 0x3f, 0x02, 0x9f, 0x7d, 0xae, 0x9a, 0xfb, 0xe3, 0x2f, 0xd0, 0xe9, 0x42, 0x0c,
            0x4d, 0x4c, 0x02, 0x1d, 0x95, 0x3e, 0x9f, 0x97, 0x06, 0x39, 0xda, 0x71, 0xb2, 0x44,
            0x80, 0x43, 0x53, 0x73, 0x87, 0x10, 0xf9, 0x71, 0x4a, 0x3b, 0xfa, 0xf0, 0x45, 0xa2,
            0xa3, 0xf2, 0x2e, 0x36, 0x8b, 0x5a, 0x12, 0x7b, 0xfa, 0x46, 0xcf, 0x3f, 0x37, 0xe6,
            0xaf, 0xb5, 0xdc, 0x78, 0x6f, 0xdf, 0x79, 0x47, 0xb9, 0x46, 0xaf, 0xa4, 0x2b, 0x49,
            0xe5, 0x25, 0xc0, 0x00, 0x00, 0x00, 0x52, 0x39, 0x07, 0x47, 0x0b, 0x7d, 0xdd, 0xb5,
            0x00, 0x01, 0xee, 0x01, 0x80, 0x50, 0x00, 0x00, 0x14, 0x1f, 0x9e, 0x53, 0xb1, 0xc4,
            0x67, 0xfb, 0x02, 0x00, 0x00, 0x00, 0x00, 0x04, 0x59, 0x5a,
        },
    },
    .install_bin = &.{"test-xz:bin/file"},
    .install_lib = &.{ "test-xz-dir:lib/dir", "test-xz:lib/dir/file" },
    .install_share = &.{ "test-xz-dir:share/dir", "test-xz:share/dir/file" },
};

const simple_tree_tar_gz = TestPackage{
    .name = "test-gz",
    .file = .{
        .name = "pkg.tar.gz",
        .hash = "e29e2abc9f14456b28eeb0ac1b91270eff27ca1151aa406f9a172c2ac8541742",
        .content = &[_]u8{
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xed, 0xd7, 0xdf, 0x0a,
            0xc2, 0x20, 0x14, 0x06, 0x70, 0x1f, 0x65, 0x6f, 0x90, 0xc7, 0x3f, 0xc7, 0xe7, 0x69,
            0xb4, 0x98, 0x31, 0xba, 0xd8, 0xea, 0xfd, 0x53, 0x64, 0xd4, 0x4d, 0x84, 0x8b, 0x23,
            0x8b, 0xbe, 0xdf, 0x8d, 0x83, 0x09, 0x13, 0x3e, 0x3e, 0x75, 0x7d, 0xbc, 0x1e, 0x94,
            0x30, 0x9d, 0x04, 0xef, 0xf3, 0x48, 0xc1, 0xeb, 0xd7, 0x71, 0xa5, 0xc8, 0xb1, 0x0d,
            0xd6, 0x78, 0xcf, 0x69, 0x1e, 0x11, 0xb1, 0x53, 0x9d, 0x97, 0x5e, 0x58, 0x76, 0x5f,
            0x6e, 0xc7, 0xb9, 0xeb, 0xd4, 0x38, 0x5c, 0x96, 0x38, 0xbd, 0x9f, 0xf7, 0xe9, 0xfd,
            0x8f, 0xea, 0x53, 0xfe, 0xe7, 0x38, 0x0d, 0x92, 0xdf, 0xc8, 0x01, 0xb3, 0x73, 0x15,
            0xf9, 0x1b, 0x4d, 0x29, 0x7f, 0x2d, 0xb9, 0xa8, 0xd5, 0x9f, 0xe7, 0x3f, 0xc5, 0x7e,
            0x5f, 0xfd, 0x0f, 0xb6, 0xf4, 0x9f, 0xd0, 0xff, 0x16, 0x72, 0xfe, 0xbb, 0xec, 0xbf,
            0x41, 0xff, 0x5b, 0xc8, 0xf9, 0x9f, 0xe2, 0x2c, 0xba, 0x07, 0xd4, 0xf4, 0x9f, 0xb5,
            0xcb, 0xfd, 0x4f, 0x8f, 0xe8, 0x7f, 0x0b, 0x6b, 0xfe, 0x92, 0x7b, 0x40, 0x4d, 0xff,
            0x4b, 0xfe, 0x69, 0x44, 0xff, 0x9b, 0x58, 0xc6, 0xe3, 0x3c, 0x08, 0xdf, 0x00, 0x36,
            0x9c, 0xff, 0x9e, 0x3c, 0xfa, 0xdf, 0x42, 0xc9, 0x5f, 0xf6, 0x06, 0xb0, 0xe1, 0xfc,
            0xb7, 0x8e, 0xd1, 0xff, 0x16, 0x4a, 0xfe, 0xb2, 0x37, 0x80, 0xfa, 0xf3, 0xdf, 0x18,
            0x66, 0xf4, 0xbf, 0x85, 0x67, 0xfe, 0x72, 0x7b, 0x40, 0xfd, 0xf9, 0x6f, 0xd3, 0x0f,
            0x20, 0xfa, 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x8d,
            0x07, 0xb7, 0xdf, 0x20, 0xdb, 0x00, 0x28, 0x00, 0x00,
        },
    },
    .install_bin = &.{"test-gz:bin/file"},
    .install_lib = &.{ "test-gz-dir:lib/dir", "test-gz:lib/dir/file" },
    .install_share = &.{ "test-gz-dir:share/dir", "test-gz:share/dir/file" },
};

const simple_tree_tar_zst = TestPackage{
    .name = "test-zst",
    .file = .{
        .name = "pkg.tar.zst",
        .hash = "e86233491689293db7c053e1740f8859a0435e96f4bfa8871fa9ab21f6cf1838",
        .content = &[_]u8{
            0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0xed, 0x06, 0x00, 0x72, 0x87, 0x15, 0x15, 0xa0,
            0xa5, 0x6d, 0x9f, 0x59, 0xfb, 0xcf, 0xc2, 0x37, 0x67, 0x55, 0x2d, 0x8b, 0xec, 0xee,
            0x5e, 0x2b, 0x01, 0xf0, 0x90, 0x01, 0x66, 0xb8, 0x7b, 0x9b, 0x78, 0x6a, 0x6a, 0x90,
            0x40, 0xa4, 0xd5, 0x3b, 0xe4, 0xfc, 0x12, 0xd4, 0xc3, 0x19, 0x72, 0xe9, 0xf3, 0x51,
            0x69, 0xbf, 0xcc, 0xfd, 0xff, 0x32, 0xa7, 0x01, 0xa4, 0xe8, 0x52, 0xa7, 0x53, 0xc0,
            0x10, 0x35, 0x06, 0x12, 0x04, 0x69, 0x50, 0x3a, 0x2a, 0xd7, 0xcc, 0x5e, 0xba, 0xaa,
            0x87, 0x8c, 0x9b, 0x56, 0x57, 0xb6, 0xff, 0xa5, 0xca, 0xff, 0x5f, 0xa4, 0xe8, 0x12,
            0x31, 0x20, 0x00, 0x03, 0x91, 0x40, 0x22, 0xa1, 0xf3, 0xfd, 0x53, 0x7a, 0x40, 0x36,
            0x40, 0xd5, 0x0c, 0x28, 0x06, 0x07, 0x50, 0xa0, 0x15, 0xb6, 0x00, 0x27, 0xf4, 0x01,
            0x8c, 0x0d, 0x40, 0x6a, 0x06, 0xe4, 0x42, 0x6d, 0xc2, 0x16, 0x80, 0x09, 0xa4, 0x0d,
            0x60, 0x8a, 0x06, 0x0c, 0x06, 0x07, 0x50, 0x00, 0x18, 0x64, 0x00, 0x9d, 0x30, 0xe0,
            0x00, 0xc6, 0x4e, 0xcd, 0x00, 0xb8, 0x70, 0x26, 0xd0, 0x00, 0x3c, 0x69, 0xb2, 0x01,
            0xa8, 0x11, 0x06, 0x07, 0xb0, 0xa0, 0x2b, 0xe4, 0x01, 0x07, 0x58, 0xe0, 0xac, 0x8e,
            0xeb, 0x28, 0xa4, 0xe8, 0xac, 0x7a, 0x92, 0x14, 0x2d, 0x18, 0xab, 0xee, 0x18, 0x5e,
            0x0c, 0x30, 0x35, 0xc0, 0xa0, 0xda, 0x00, 0xd6, 0xa1, 0x24, 0xb0, 0x60, 0x10, 0x60,
            0x5f, 0xce, 0xa0, 0xe9, 0x68, 0x81, 0x82, 0x11, 0x07, 0x2c, 0x35, 0x90, 0xc4, 0xbc,
            0xd6, 0x70, 0x95, 0xa7, 0xf9, 0x06, 0x41, 0xf7, 0xd6, 0x70,
        },
    },
    .install_bin = &.{"test-zst:bin/file"},
    .install_lib = &.{ "test-zst-dir:lib/dir", "test-zst:lib/dir/file" },
    .install_share = &.{ "test-zst-dir:share/dir", "test-zst:share/dir/file" },
};

const wrong_hash = TestPackage{
    .name = "wrong-hash",
    .file = .{
        .name = "wrong-hash",
        .hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .content = "Binary",
    },
    .install_bin = &.{"wrong-hash"},
};

const fails_download = TestPackage{
    .name = "fails-download",
    .file = .{
        .name = "fails-download",
        .hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .content = null,
    },
    .install_bin = &.{"fails-download"},
};

const duplicate_bin_file1 = TestPackage{
    .name = "dup-bin1",
    .file = .{
        .name = "pkg",
        .hash = "ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2",
        .content = "Binary",
    },
    .install_bin = &.{"test-file:pkg"},
};

const duplicate_bin_file2 = TestPackage{
    .name = "dup-bin2",
    .file = .{
        .name = "pkg",
        .hash = "ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2",
        .content = "Binary",
    },
    .install_bin = &.{"test-file:pkg"},
};

const duplicate_bin_file3 = TestPackage{
    .name = "dup-bin3",
    .file = .{
        .name = "pkg",
        .hash = "ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2",
        .content = "Binary",
    },
    .install_bin = &.{"test-file:pkg"},
};

const duplicate_lib_file1 = TestPackage{
    .name = "dup-lib1",
    .file = .{
        .name = "pkg",
        .hash = "ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2",
        .content = "Binary",
    },
    .install_lib = &.{"test-file:pkg"},
};

const duplicate_lib_file2 = TestPackage{
    .name = "dup-lib2",
    .file = .{
        .name = "pkg",
        .hash = "ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2",
        .content = "Binary",
    },
    .install_lib = &.{"test-file:pkg"},
};

const duplicate_lib_file3 = TestPackage{
    .name = "dup-lib3",
    .file = .{
        .name = "pkg",
        .hash = "ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2",
        .content = "Binary",
    },
    .install_lib = &.{"test-file:pkg"},
};

test {
    _ = Diagnostics;
    _ = Package;

    _ = fs;
    _ = main;
    _ = paths;
}

const Diagnostics = @import("Diagnostics.zig");
const Package = @import("Package.zig");

const paths = @import("paths.zig");
const fs = @import("fs.zig");
const main = @import("main.zig");
const std = @import("std");
