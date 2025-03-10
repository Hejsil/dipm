arena: std.heap.ArenaAllocator,
lock: std.Thread.Mutex,

successes: struct {
    donate: std.ArrayListUnmanaged(PackageDonate),
    installs: std.ArrayListUnmanaged(PackageVersion),
    updates: std.ArrayListUnmanaged(PackageFromTo),
    uninstalls: std.ArrayListUnmanaged(PackageVersion),
},

warnings: struct {
    already_installed: std.ArrayListUnmanaged(Package),
    not_installed: std.ArrayListUnmanaged(Package),
    not_found: std.ArrayListUnmanaged(Package),
    not_found_for_target: std.ArrayListUnmanaged(PackageTarget),
    up_to_date: std.ArrayListUnmanaged(PackageVersion),
},

failures: struct {
    no_version_found: std.ArrayListUnmanaged(PackageError),
    hash_mismatches: std.ArrayListUnmanaged(HashMismatch),
    downloads: std.ArrayListUnmanaged(DownloadFailed),
    downloads_with_status: std.ArrayListUnmanaged(DownloadFailedWithStatus),
    path_already_exists: std.ArrayListUnmanaged(PathAlreadyExists),
    generic_error: std.ArrayListUnmanaged(GenericError),
},

pub fn init(allocator: std.mem.Allocator) Diagnostics {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .lock = .{},
        .successes = .{
            .donate = .{},
            .installs = .{},
            .updates = .{},
            .uninstalls = .{},
        },
        .warnings = .{
            .already_installed = .{},
            .not_installed = .{},
            .not_found = .{},
            .not_found_for_target = .{},
            .up_to_date = .{},
        },
        .failures = .{
            .no_version_found = .{},
            .hash_mismatches = .{},
            .downloads = .{},
            .downloads_with_status = .{},
            .path_already_exists = .{},
            .generic_error = .{},
        },
    };
}

pub fn reset(diagnostics: *Diagnostics) void {
    const allocator = diagnostics.gpa();
    diagnostics.deinit();
    diagnostics.* = init(allocator);
}

fn gpa(diagnostics: *Diagnostics) std.mem.Allocator {
    return diagnostics.arena.child_allocator;
}

pub fn deinit(diagnostics: *Diagnostics) void {
    inline for (@typeInfo(@TypeOf(diagnostics.successes)).@"struct".fields) |field|
        @field(diagnostics.successes, field.name).deinit(diagnostics.gpa());
    inline for (@typeInfo(@TypeOf(diagnostics.warnings)).@"struct".fields) |field|
        @field(diagnostics.warnings, field.name).deinit(diagnostics.gpa());
    inline for (@typeInfo(@TypeOf(diagnostics.failures)).@"struct".fields) |field|
        @field(diagnostics.failures, field.name).deinit(diagnostics.gpa());

    diagnostics.arena.deinit();
    diagnostics.* = undefined;
}

pub fn reportToFile(diagnostics: *Diagnostics, file: std.fs.File) !void {
    var buffered = std.io.bufferedWriter(file.writer());

    const is_tty = file.supportsAnsiEscapeCodes();
    const escapes = if (is_tty) Escapes.ansi else Escapes.none;
    try diagnostics.report(buffered.writer(), .{
        .is_tty = is_tty,
        .escapes = escapes,
    });

    try buffered.flush();
}

pub const ReportOptions = struct {
    is_tty: bool = false,
    escapes: Escapes = Escapes.none,
};

pub fn report(diagnostics: *Diagnostics, writer: anytype, opt: ReportOptions) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

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
        try writer.print("└── Package not found\n", .{});
    }
    for (diagnostics.warnings.not_found_for_target.items) |not_found| {
        try writer.print("{s} {s}{s}{s}\n", .{
            warning,
            esc.bold,
            not_found.name,
            esc.reset,
        });
        try writer.print("└── Package not found for {s}_{s}\n", .{
            @tagName(not_found.target.os),
            @tagName(not_found.target.arch),
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
    for (diagnostics.failures.no_version_found.items) |no_version| {
        try writer.print("{s} {s}{s}{s}\n", .{
            failure,
            esc.bold,
            no_version.name,
            esc.reset,
        });
        try writer.print("└── No version found: {s}\n", .{@errorName(no_version.err)});
    }
    for (diagnostics.failures.path_already_exists.items) |err| {
        try writer.print("{s} {s}{s}{s}\n", .{
            failure,
            esc.bold,
            err.name,
            esc.reset,
        });
        try writer.print("└── Path already exists: {s}\n", .{err.path});
    }
    for (diagnostics.failures.generic_error.items) |err| {
        try writer.print("{s} {s}{s}{s}\n", .{
            failure,
            esc.bold,
            err.id,
            esc.reset,
        });
        try writer.print("│   {s}\n", .{err.msg});
        try writer.print("└──   {s}\n", .{@errorName(err.err)});
    }
    for (diagnostics.successes.donate.items) |package| {
        try writer.print("{s} {s}{s} {s}{s}\n", .{
            success,
            esc.bold,
            package.name,
            package.version,
            esc.reset,
        });
        for (package.donate, 0..) |d, i| {
            const prefix = if (i == package.donate.len - 1)
                "└──"
            else
                "│  ";
            try writer.print("{s} {s}\n", .{ prefix, d });
        }
    }

    const show_donate_reminder = opt.is_tty and !diagnostics.hasFailed() and
        (diagnostics.successes.installs.items.len != 0 or diagnostics.successes.updates.items.len != 0);

    if (show_donate_reminder) {
        try writer.writeAll("\n");
        try writer.writeAll(esc.dim);
        try writer.writeAll(
            \\Consider donating to the open source software you use.
            \\└── see dipm donate
            \\
        );
        try writer.writeAll(esc.reset);
    }
}

pub fn hasFailed(diagnostics: Diagnostics) bool {
    inline for (@typeInfo(@TypeOf(diagnostics.failures)).@"struct".fields) |field| {
        if (@field(diagnostics.failures, field.name).items.len != 0)
            return true;
    }

    return false;
}

pub fn donate(diagnostics: *Diagnostics, package: PackageDonate) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    const donate_duped = try arena.dupe([]const u8, package.donate);
    for (donate_duped, package.donate) |*res, d|
        res.* = try arena.dupe(u8, d);

    return diagnostics.successes.donate.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, package.name),
        .version = try arena.dupe(u8, package.version),
        .donate = donate_duped,
    });
}

pub fn installSucceeded(diagnostics: *Diagnostics, package: PackageVersion) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.successes.installs.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, package.name),
        .version = try arena.dupe(u8, package.version),
    });
}

pub fn updateSucceeded(diagnostics: *Diagnostics, package: PackageFromTo) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.successes.updates.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, package.name),
        .from_version = try arena.dupe(u8, package.from_version),
        .to_version = try arena.dupe(u8, package.to_version),
    });
}

pub fn uninstallSucceeded(diagnostics: *Diagnostics, package: PackageVersion) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.successes.uninstalls.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, package.name),
        .version = try arena.dupe(u8, package.version),
    });
}

pub fn alreadyInstalled(diagnostics: *Diagnostics, package: Package) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.warnings.already_installed.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, package.name),
    });
}

pub fn notInstalled(diagnostics: *Diagnostics, package: Package) !void {
    const arena = diagnostics.arena.allocator();
    return diagnostics.warnings.not_installed.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, package.name),
    });
}

pub fn notFound(diagnostics: *Diagnostics, package: Package) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.warnings.not_found.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, package.name),
    });
}

pub fn notFoundForTarget(diagnostics: *Diagnostics, not_found: PackageTarget) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.warnings.not_found_for_target.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, not_found.name),
        .target = not_found.target,
    });
}

pub fn upToDate(diagnostics: *Diagnostics, package: PackageVersion) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.warnings.up_to_date.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, package.name),
        .version = try arena.dupe(u8, package.version),
    });
}

pub fn noVersionFound(diagnostics: *Diagnostics, package: PackageError) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.failures.no_version_found.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, package.name),
        .err = package.err,
    });
}

pub fn hashMismatch(diagnostics: *Diagnostics, mismatch: HashMismatch) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.failures.hash_mismatches.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, mismatch.name),
        .version = try arena.dupe(u8, mismatch.version),
        .expected_hash = try arena.dupe(u8, mismatch.expected_hash),
        .actual_hash = try arena.dupe(u8, mismatch.actual_hash),
    });
}

pub fn downloadFailed(diagnostics: *Diagnostics, failure: DownloadFailed) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.failures.downloads.append(diagnostics.gpa(), .{
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
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.failures.downloads_with_status.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, failure.name),
        .version = try arena.dupe(u8, failure.version),
        .url = try arena.dupe(u8, failure.url),
        .status = failure.status,
    });
}

pub fn pathAlreadyExists(diagnostics: *Diagnostics, failure: PathAlreadyExists) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.failures.path_already_exists.append(diagnostics.gpa(), .{
        .name = try arena.dupe(u8, failure.name),
        .path = try arena.dupe(u8, failure.path),
    });
}

pub fn genericError(diagnostics: *Diagnostics, failure: GenericError) !void {
    diagnostics.lock.lock();
    defer diagnostics.lock.unlock();

    const arena = diagnostics.arena.allocator();
    return diagnostics.failures.generic_error.append(diagnostics.gpa(), .{
        .id = try arena.dupe(u8, failure.id),
        .msg = try arena.dupe(u8, failure.msg),
        .err = failure.err,
    });
}

pub const Package = struct {
    name: []const u8,
};

pub const PackageDonate = struct {
    name: []const u8,
    version: []const u8,
    donate: []const []const u8,
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

pub const PackageError = struct {
    name: []const u8,
    err: anyerror,
};

pub const PackageTarget = struct {
    name: []const u8,
    target: Target,
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

pub const PathAlreadyExists = struct {
    name: []const u8,
    path: []const u8,
};

pub const GenericError = struct {
    id: []const u8,
    msg: []const u8,
    err: anyerror,
};

pub const Error = error{
    DiagnosticsReported,
};

test {
    _ = Escapes;
    _ = Target;
}

const Diagnostics = @This();

const Escapes = @import("Escapes.zig");
const Target = @import("Target.zig");

const std = @import("std");
