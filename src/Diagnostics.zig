gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,

successes: struct {
    installs: std.ArrayListUnmanaged(PackageVersion),
    updates: std.ArrayListUnmanaged(PackageFromTo),
    uninstalls: std.ArrayListUnmanaged(PackageVersion),
},

warnings: struct {
    already_installed: std.ArrayListUnmanaged(Package),
    not_installed: std.ArrayListUnmanaged(Package),
    not_found: std.ArrayListUnmanaged(NotFound),
    up_to_date: std.ArrayListUnmanaged(PackageVersion),
},

failures: struct {
    hash_mismatches: std.ArrayListUnmanaged(HashMismatch),
    downloads: std.ArrayListUnmanaged(DownloadFailed),
    downloads_with_status: std.ArrayListUnmanaged(DownloadFailedWithStatus),
},

pub fn init(allocator: std.mem.Allocator) Diagnostics {
    return .{
        .gpa = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .successes = .{
            .installs = .{},
            .updates = .{},
            .uninstalls = .{},
        },
        .warnings = .{
            .already_installed = .{},
            .not_installed = .{},
            .not_found = .{},
            .up_to_date = .{},
        },
        .failures = .{
            .hash_mismatches = .{},
            .downloads = .{},
            .downloads_with_status = .{},
        },
    };
}

pub fn reset(diagnostics: *Diagnostics) void {
    const allocator = diagnostics.gpa;
    diagnostics.deinit();
    diagnostics.* = init(allocator);
}

pub fn deinit(diagnostics: *Diagnostics) void {
    inline for (@typeInfo(@TypeOf(diagnostics.successes)).Struct.fields) |field|
        @field(diagnostics.successes, field.name).deinit(diagnostics.gpa);
    inline for (@typeInfo(@TypeOf(diagnostics.warnings)).Struct.fields) |field|
        @field(diagnostics.warnings, field.name).deinit(diagnostics.gpa);
    inline for (@typeInfo(@TypeOf(diagnostics.failures)).Struct.fields) |field|
        @field(diagnostics.failures, field.name).deinit(diagnostics.gpa);

    diagnostics.arena.deinit();
    diagnostics.* = undefined;
}

pub fn reportToFile(diagnostics: Diagnostics, file: std.fs.File) !void {
    var buffered = std.io.bufferedWriter(file.writer());

    const escapes = if (file.supportsAnsiEscapeCodes()) Escapes.ansi else Escapes.none;
    try diagnostics.report(buffered.writer(), .{ .escapes = escapes });

    try buffered.flush();
}

pub const ReportOptions = struct {
    escapes: Escapes = Escapes.none,
};

pub fn report(diagnostics: Diagnostics, writer: anytype, opt: ReportOptions) !void {
    const esc = opt.escapes;

    var buf: [1024]u8 = undefined;
    var fba_state = std.heap.FixedBufferAllocator.init(&buf);
    const fba = fba_state.allocator();

    const success = try std.fmt.allocPrint(fba, "{s}{s}✓{s}", .{
        esc.bold,
        esc.green,
        esc.reset,
    });
    const warning = try std.fmt.allocPrint(fba, "{s}{s}⚠{s}", .{
        esc.bold,
        esc.yellow,
        esc.reset,
    });
    const failure = try std.fmt.allocPrint(fba, "{s}{s}✗{s}", .{
        esc.bold,
        esc.red,
        esc.reset,
    });

    for (diagnostics.successes.installs.items) |installed|
        try writer.print("{s} {s}{s} {s}{s}\n", .{
            success,
            esc.bold,
            installed.name,
            installed.version,
            esc.reset,
        });
    for (diagnostics.successes.updates.items) |updated|
        try writer.print("{s} {s}{s} {s} -> {s}{s}\n", .{
            success,
            esc.bold,
            updated.name,
            updated.from_version,
            updated.to_version,
            esc.reset,
        });
    for (diagnostics.successes.uninstalls.items) |uninstall|
        try writer.print("{s} {s}{s} {s} -> ✗{s}\n", .{
            success,
            esc.bold,
            uninstall.name,
            uninstall.version,
            esc.reset,
        });

    for (diagnostics.warnings.already_installed.items) |already_installed| {
        try writer.print("{s} {s}{s}{s}\n", .{
            warning,
            esc.bold,
            already_installed.name,
            esc.reset,
        });
        try writer.print("└── Package already installed\n", .{});
    }
    for (diagnostics.warnings.not_installed.items) |not_installed| {
        try writer.print("{s} {s}{s}{s}\n", .{
            warning,
            esc.bold,
            not_installed.name,
            esc.reset,
        });
        try writer.print("└── Package is not installed\n", .{});
    }
    for (diagnostics.warnings.not_found.items) |not_found| {
        try writer.print("{s} {s}{s}{s}\n", .{
            warning,
            esc.bold,
            not_found.name,
            esc.reset,
        });
        try writer.print("└── Package not found for {s}_{s}\n", .{
            @tagName(not_found.os),
            @tagName(not_found.arch),
        });
    }
    for (diagnostics.warnings.up_to_date.items) |up_to_date| {
        try writer.print("{s} {s}{s} {s}{s}\n", .{
            warning,
            esc.bold,
            up_to_date.name,
            up_to_date.version,
            esc.reset,
        });
        try writer.print("└── Package is up to date\n", .{});
    }

    for (diagnostics.failures.downloads.items) |download| {
        try writer.print("{s} {s}{s} {s}{s}\n", .{
            failure,
            esc.bold,
            download.name,
            download.version,
            esc.reset,
        });
        try writer.print("│   Failed to download\n", .{});
        try writer.print("│     url:   {s}\n", .{download.url});
        try writer.print("└──   error: {s}\n", .{@errorName(download.err)});
    }
    for (diagnostics.failures.downloads_with_status.items) |download| {
        try writer.print("{s} {s}{s} {s}{s}\n", .{
            failure,
            esc.bold,
            download.name,
            download.version,
            esc.reset,
        });
        try writer.print("│   Failed to download\n", .{});
        try writer.print("│     url:   {s}\n", .{download.url});
        try writer.print("└──   status: {} {s}\n", .{
            @intFromEnum(download.status),
            download.status.phrase() orelse "",
        });
    }
    for (diagnostics.failures.hash_mismatches.items) |hash_mismatch| {
        try writer.print("{s} {s}{s} {s}{s}\n", .{
            failure,
            esc.bold,
            hash_mismatch.name,
            hash_mismatch.version,
            esc.reset,
        });
        try writer.print("│   Hash mismatch\n", .{});
        try writer.print("│     expected: {s}\n", .{hash_mismatch.expected_hash});
        try writer.print("└──   actual:   {s}\n", .{hash_mismatch.actual_hash});
    }
}

pub fn hasFailed(diagnostics: Diagnostics) bool {
    inline for (@typeInfo(@TypeOf(diagnostics.failures))) |field| {
        if (@field(diagnostics.failures, field.name).items.len != 0)
            return true;
    }

    return false;
}

pub fn installSucceeded(diagnostics: *Diagnostics, package: PackageVersion) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.successes.installs.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, package.name),
        .version = try arena.dupe(u8, package.version),
    });
}

pub fn updateSucceeded(diagnostics: *Diagnostics, package: PackageFromTo) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.successes.updates.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, package.name),
        .from_version = try arena.dupe(u8, package.from_version),
        .to_version = try arena.dupe(u8, package.to_version),
    });
}

pub fn uninstallSucceeded(diagnostics: *Diagnostics, package: PackageVersion) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.successes.uninstalls.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, package.name),
        .version = try arena.dupe(u8, package.version),
    });
}

pub fn alreadyInstalled(diagnostics: *Diagnostics, package: Package) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.warnings.already_installed.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, package.name),
    });
}

pub fn notInstalled(diagnostics: *Diagnostics, package: Package) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.warnings.not_installed.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, package.name),
    });
}

pub fn notFound(diagnostics: *Diagnostics, not_found: NotFound) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.warnings.not_found.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, not_found.name),
        .os = not_found.os,
        .arch = not_found.arch,
    });
}

pub fn upToDate(diagnostics: *Diagnostics, package: PackageVersion) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.warnings.up_to_date.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, package.name),
        .version = try arena.dupe(u8, package.version),
    });
}

pub fn hashMismatch(diagnostics: *Diagnostics, mismatch: HashMismatch) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.failures.hash_mismatches.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, mismatch.name),
        .version = try arena.dupe(u8, mismatch.version),
        .expected_hash = try arena.dupe(u8, mismatch.expected_hash),
        .actual_hash = try arena.dupe(u8, mismatch.actual_hash),
    });
}

pub fn downloadFailed(diagnostics: *Diagnostics, failure: DownloadFailed) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.failures.downloads.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, failure.name),
        .version = try arena.dupe(u8, failure.version),
        .url = try arena.dupe(u8, failure.url),
        .err = failure.err,
    });
}

pub fn downloadFailedWithStatus(
    diagnostics: *Diagnostics,
    failure: DownloadFailedWithStatus,
) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.failures.downloads_with_status.append(diagnostics.gpa, .{
        .name = try arena.dupe(u8, failure.name),
        .version = try arena.dupe(u8, failure.version),
        .url = try arena.dupe(u8, failure.url),
        .status = failure.status,
    });
}

pub const Package = struct {
    name: []const u8,
};

pub const PackageVersion = struct {
    name: []const u8,
    version: []const u8,
};

pub const PackageFromTo = struct {
    name: []const u8,
    from_version: []const u8,
    to_version: []const u8,
};

pub const NotFound = struct {
    name: []const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
};

pub const HashMismatch = struct {
    name: []const u8,
    version: []const u8,
    expected_hash: []const u8,
    actual_hash: []const u8,
};

pub const DownloadFailed = struct {
    name: []const u8,
    version: []const u8,
    url: []const u8,
    err: anyerror,
};

pub const DownloadFailedWithStatus = struct {
    name: []const u8,
    version: []const u8,
    url: []const u8,
    status: std.http.Status,
};

test {
    _ = Escapes;
}

const Diagnostics = @This();

const Escapes = @import("Escapes.zig");

const std = @import("std");
