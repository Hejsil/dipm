test "install test-file" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    var buf: [std.mem.page_size]u8 = undefined;
    try pm.pm.installOne("test-file");
    try pm.expectFile("bin/test-file", "Binary");
    try pm.expectFile("share/dipm/installed.ini", try std.fmt.bufPrint(&buf,
        \\[test-file]
        \\version = 0.1.0
        \\location = {[prefix]s}/bin/test-file
        \\
    , .{ .prefix = pm.pm.prefix_path }));
    try pm.expectDiagnostics(
        \\<B><g>✓<R> <B>test-file 0.1.0<R>
        \\
    );
    try pm.cleanup();
}

test "install test-xz" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    var buf: [std.mem.page_size]u8 = undefined;
    try pm.pm.installOne("test-xz");
    try pm.expectFile("bin/test-xz", "");
    try pm.expectFile("lib/test-xz", "");
    try pm.expectFile("lib/test-xz-dir/file", "");
    try pm.expectFile("share/test-xz", "");
    try pm.expectFile("share/test-xz-dir/file", "");
    try pm.expectFile("share/dipm/installed.ini", try std.fmt.bufPrint(&buf,
        \\[test-xz]
        \\version = 0.1.0
        \\location = {[prefix]s}/bin/test-xz
        \\location = {[prefix]s}/lib/test-xz-dir
        \\location = {[prefix]s}/lib/test-xz
        \\location = {[prefix]s}/share/test-xz-dir
        \\location = {[prefix]s}/share/test-xz
        \\
    , .{ .prefix = pm.pm.prefix_path }));
    try pm.expectDiagnostics(
        \\<B><g>✓<R> <B>test-xz 0.1.0<R>
        \\
    );
    try pm.cleanup();
}

test "install test-gz" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    var buf: [std.mem.page_size]u8 = undefined;
    try pm.pm.installOne("test-gz");
    try pm.expectFile("bin/test-gz", "");
    try pm.expectFile("lib/test-gz", "");
    try pm.expectFile("lib/test-gz-dir/file", "");
    try pm.expectFile("share/test-gz", "");
    try pm.expectFile("share/test-gz-dir/file", "");
    try pm.expectFile("share/dipm/installed.ini", try std.fmt.bufPrint(&buf,
        \\[test-gz]
        \\version = 0.1.0
        \\location = {[prefix]s}/bin/test-gz
        \\location = {[prefix]s}/lib/test-gz-dir
        \\location = {[prefix]s}/lib/test-gz
        \\location = {[prefix]s}/share/test-gz-dir
        \\location = {[prefix]s}/share/test-gz
        \\
    , .{ .prefix = pm.pm.prefix_path }));
    try pm.expectDiagnostics(
        \\<B><g>✓<R> <B>test-gz 0.1.0<R>
        \\
    );
    try pm.cleanup();
}

test "install test-zst" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    var buf: [std.mem.page_size]u8 = undefined;
    try pm.pm.installOne("test-zst");
    try pm.expectFile("bin/test-zst", "");
    try pm.expectFile("lib/test-zst", "");
    try pm.expectFile("lib/test-zst-dir/file", "");
    try pm.expectFile("share/test-zst", "");
    try pm.expectFile("share/test-zst-dir/file", "");
    try pm.expectFile("share/dipm/installed.ini", try std.fmt.bufPrint(&buf,
        \\[test-zst]
        \\version = 0.1.0
        \\location = {[prefix]s}/bin/test-zst
        \\location = {[prefix]s}/lib/test-zst-dir
        \\location = {[prefix]s}/lib/test-zst
        \\location = {[prefix]s}/share/test-zst-dir
        \\location = {[prefix]s}/share/test-zst
        \\
    , .{ .prefix = pm.pm.prefix_path }));
    try pm.expectDiagnostics(
        \\<B><g>✓<R> <B>test-zst 0.1.0<R>
        \\
    );
    try pm.cleanup();
}

test "install already installed" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    try pm.pm.installOne("test-xz");
    pm.diag.reset();

    try pm.pm.installOne("test-xz");
    try pm.expectDiagnostics(
        \\<B><y>⚠<R> <B>test-xz<R>
        \\└── Package already installed
        \\
    );
    try pm.cleanup();
}

test "uninstall" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    try pm.pm.installOne("test-xz");
    pm.diag.reset();

    try pm.pm.uninstallOne("test-xz");
    try pm.expectNoFile("bin/test-xz");
    try pm.expectNoFile("lib/test-xz");
    try pm.expectNoFile("lib/test-xz-dir/file");
    try pm.expectNoFile("share/test-xz");
    try pm.expectNoFile("share/test-xz-dir/file");
    try pm.expectFile("share/dipm/installed.ini", "");
    try pm.expectDiagnostics(
        \\<B><g>✓<R> <B>test-xz 0.1.0 -> ✗<R>
        \\
    );

    try pm.cleanup();
}

test "uninstall not installed" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    try pm.pm.uninstallOne("test-xz");
    try pm.expectDiagnostics(
        \\<B><y>⚠<R> <B>test-xz<R>
        \\└── Package is not installed
        \\
    );
    try pm.cleanup();
}

test "uninstall already uninstalled" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    try pm.pm.installOne("test-xz");
    pm.diag.reset();

    try pm.pm.uninstallOne("test-xz");
    pm.diag.reset();

    try pm.pm.uninstallOne("test-xz");
    try pm.expectDiagnostics(
        \\<B><y>⚠<R> <B>test-xz<R>
        \\└── Package is not installed
        \\
    );
    try pm.cleanup();
}

test "update" {
    const repo_v1 = simple_repository_v1.get();
    var pm_v1 = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo_v1.pkgs_ini_path,
    });
    defer pm_v1.deinit();

    try pm_v1.pm.installOne("test-xz");
    try pm_v1.pm.installOne("test-zst");

    // TODO: Currently the package manager cannot install the same package again if the tmp dir
    //       hasn't been cleaned. This needs to be fixed.
    try pm_v1.pm.cleanup();

    const repo_v2 = simple_repository_v2.get();
    var pm_v2 = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo_v2.pkgs_ini_path,
        .prefix = pm_v1.pm.prefix_path,
    });
    defer pm_v2.deinit();

    // the package manager should still know about the installed v1
    var buf: [std.mem.page_size]u8 = undefined;
    try pm_v2.expectFile("share/dipm/installed.ini", try std.fmt.bufPrint(&buf,
        \\[test-xz]
        \\version = 0.1.0
        \\location = {[prefix]s}/bin/test-xz
        \\location = {[prefix]s}/lib/test-xz-dir
        \\location = {[prefix]s}/lib/test-xz
        \\location = {[prefix]s}/share/test-xz-dir
        \\location = {[prefix]s}/share/test-xz
        \\
        \\[test-zst]
        \\version = 0.1.0
        \\location = {[prefix]s}/bin/test-zst
        \\location = {[prefix]s}/lib/test-zst-dir
        \\location = {[prefix]s}/lib/test-zst
        \\location = {[prefix]s}/share/test-zst-dir
        \\location = {[prefix]s}/share/test-zst
        \\
    , .{ .prefix = pm_v2.pm.prefix_path }));

    try pm_v2.pm.updateOne("test-xz");
    try pm_v2.expectFile("share/dipm/installed.ini", try std.fmt.bufPrint(&buf,
        \\[test-zst]
        \\version = 0.1.0
        \\location = {[prefix]s}/bin/test-zst
        \\location = {[prefix]s}/lib/test-zst-dir
        \\location = {[prefix]s}/lib/test-zst
        \\location = {[prefix]s}/share/test-zst-dir
        \\location = {[prefix]s}/share/test-zst
        \\
        \\[test-xz]
        \\version = 0.2.0
        \\location = {[prefix]s}/bin/test-xz
        \\location = {[prefix]s}/lib/test-xz-dir
        \\location = {[prefix]s}/lib/test-xz
        \\location = {[prefix]s}/share/test-xz-dir
        \\location = {[prefix]s}/share/test-xz
        \\
    , .{ .prefix = pm_v2.pm.prefix_path }));
    try pm_v2.expectDiagnostics(
        \\<B><g>✓<R> <B>test-xz 0.1.0 -> 0.2.0<R>
        \\
    );

    try pm_v2.cleanup();
}

test "update all" {
    const repo_v1 = simple_repository_v1.get();
    var pm_v1 = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo_v1.pkgs_ini_path,
    });
    defer pm_v1.deinit();

    try pm_v1.pm.installOne("test-xz");
    try pm_v1.pm.installOne("test-zst");

    // TODO: Currently the package manager cannot install the same package again if the tmp dir
    //       hasn't been cleaned. This needs to be fixed.
    try pm_v1.pm.cleanup();

    const repo_v2 = simple_repository_v2.get();
    var pm_v2 = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo_v2.pkgs_ini_path,
        .prefix = pm_v1.pm.prefix_path,
    });
    defer pm_v2.deinit();

    // the package manager should still know about the installed v1
    var buf: [std.mem.page_size]u8 = undefined;
    try pm_v2.expectFile("share/dipm/installed.ini", try std.fmt.bufPrint(&buf,
        \\[test-xz]
        \\version = 0.1.0
        \\location = {[prefix]s}/bin/test-xz
        \\location = {[prefix]s}/lib/test-xz-dir
        \\location = {[prefix]s}/lib/test-xz
        \\location = {[prefix]s}/share/test-xz-dir
        \\location = {[prefix]s}/share/test-xz
        \\
        \\[test-zst]
        \\version = 0.1.0
        \\location = {[prefix]s}/bin/test-zst
        \\location = {[prefix]s}/lib/test-zst-dir
        \\location = {[prefix]s}/lib/test-zst
        \\location = {[prefix]s}/share/test-zst-dir
        \\location = {[prefix]s}/share/test-zst
        \\
    , .{ .prefix = pm_v2.pm.prefix_path }));

    try pm_v2.pm.updateAll();
    try pm_v2.expectFile("share/dipm/installed.ini", try std.fmt.bufPrint(&buf,
        \\[test-xz]
        \\version = 0.2.0
        \\location = {[prefix]s}/bin/test-xz
        \\location = {[prefix]s}/lib/test-xz-dir
        \\location = {[prefix]s}/lib/test-xz
        \\location = {[prefix]s}/share/test-xz-dir
        \\location = {[prefix]s}/share/test-xz
        \\
        \\[test-zst]
        \\version = 0.2.0
        \\location = {[prefix]s}/bin/test-zst
        \\location = {[prefix]s}/lib/test-zst-dir
        \\location = {[prefix]s}/lib/test-zst
        \\location = {[prefix]s}/share/test-zst-dir
        \\location = {[prefix]s}/share/test-zst
        \\
    , .{ .prefix = pm_v2.pm.prefix_path }));
    try pm_v2.expectDiagnostics(
        \\<B><g>✓<R> <B>test-xz 0.1.0 -> 0.2.0<R>
        \\<B><g>✓<R> <B>test-zst 0.1.0 -> 0.2.0<R>
        \\
    );

    try pm_v2.cleanup();
}

test "cleanup" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    try pm.pm.installOne("test-xz");
    try pm.expectDir("share/dipm/tmp");
    try pm.pm.cleanup();
    try pm.expectNoDir("share/dipm/tmp");
    try pm.expectDir("share/dipm");
    try pm.cleanup();
}

test "hash mismatch" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    try pm.pm.installOne("wrong-hash");
    try pm.expectDiagnostics(
        \\<B><r>✗<R> <B>wrong-hash 0.1.0<R>
        \\│   Hash mismatch
        \\│     expected: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        \\└──   actual:   ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2
        \\
    );
    try pm.cleanup();
}

test "not found" {
    const repo = simple_repository_v1.get();
    var pm = try TestingPackageManager.init(.{
        .pkgs_ini_path = repo.pkgs_ini_path,
    });
    defer pm.deinit();

    try pm.pm.installOne("not-found");
    try pm.expectDiagnostics(
        \\<B><y>⚠<R> <B>not-found<R>
        \\└── Package not found for linux_x86_64
        \\
    );
    try pm.cleanup();
}

const simple_repository_v1 = struct {
    fn get() *const TestingPackageRepository {
        once.call();
        return &repository;
    }

    const packages = [_]TestingPackageRepository.Package{
        simple_file,
        simple_tree_tar_xz,
        simple_tree_tar_gz,
        simple_tree_tar_zst,
        wrong_hash,
    };

    var repository: TestingPackageRepository = undefined;
    var once = std.once(init);
    fn init() void {
        repository = TestingPackageRepository.init(.{
            .allocator = std.heap.page_allocator,
            .packages = &packages,
        }) catch @panic("Failed to initialize simple repository");
    }
};

const simple_repository_v2 = struct {
    fn get() *const TestingPackageRepository {
        once.call();
        return &repository;
    }

    const packages = blk: {
        var res: [simple_repository_v1.packages.len]TestingPackageRepository.Package = undefined;
        for (&res, simple_repository_v1.packages) |*pkg_v2, pkg| {
            pkg_v2.* = pkg;
            pkg_v2.version = "0.2.0";
        }
        break :blk res;
    };

    var repository: TestingPackageRepository = undefined;
    var once = std.once(init);
    fn init() void {
        repository = TestingPackageRepository.init(.{
            .allocator = std.heap.page_allocator,
            .packages = &packages,
        }) catch @panic("Failed to initialize simple repository");
    }
};

pub const simple_file = TestingPackageRepository.Package{
    .name = "test-file",
    .version = "0.1.0",
    .github_update = "test-file/test-file",
    .file = .{
        .name = "pkg",
        .hash = "ee1c8277caf5fb9b9ac4168c73fc03d982e0859d58ab730b6e15a20c14059ff2",
        .content = "Binary",
    },
    .install_bin = &.{"test-file:pkg"},
};

// All `simple_tree_` binaries are compressed archives. They're generated with the following
// commands:
//   COMPRESSION='<compresssion>'
//   FILE='file.tar.<ext>'
//   cd "$(mktemp -d)"
//   mkdir -p bin lib/dir share/dir
//   touch bin/file lib/file lib/dir/file share/file share/dir/file
//   tar --use-compress-program "$COMPRESSION" -cvf "$FILE" bin lib/ share/
//   xxd -p "$FILE" | tr -d '\n' | sed -E 's/([a-z0-9]{2})/0x\1,/g'
//   sha256sum "$FILE"
//
pub const simple_tree_tar_xz = TestingPackageRepository.Package{
    .name = "test-xz",
    .version = "0.1.0",
    .github_update = "test-xz/test-xz",
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

pub const simple_tree_tar_gz = TestingPackageRepository.Package{
    .name = "test-gz",
    .version = "0.1.0",
    .github_update = "test-xz/test-gz",
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

pub const simple_tree_tar_zst = TestingPackageRepository.Package{
    .name = "test-zst",
    .version = "0.1.0",
    .github_update = "test-zst/test-zst",
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

pub const wrong_hash = TestingPackageRepository.Package{
    .name = "wrong-hash",
    .version = "0.1.0",
    .github_update = "wrong-hash/wrong-hash",
    .file = .{
        .name = "wrong-hash",
        .hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .content = "Binary",
    },
    .install_bin = &.{"wrong-hash"},
};

const TestingPackageManager = @import("TestingPackageManager.zig");
const TestingPackageRepository = @import("TestingPackageRepository.zig");

const std = @import("std");
