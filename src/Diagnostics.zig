arena_alloc: std.heap.ArenaAllocator,
lock: std.Thread.Mutex,

successes: struct {
    donate: std.ArrayListUnmanaged(PackageDonate),
    installs: std.ArrayListUnmanaged(PackageInstall),
    updates: std.ArrayListUnmanaged(PackageFromTo),
    uninstalls: std.ArrayListUnmanaged(PackageUninstall),
},

warnings: struct {
    already_installed: std.ArrayListUnmanaged(PackageAlreadyInstalled),
    not_installed: std.ArrayListUnmanaged(PackageNotInstalled),
    not_found: std.ArrayListUnmanaged(PackageNotFound),
    not_found_for_target: std.ArrayListUnmanaged(PackageTarget),
    up_to_date: std.ArrayListUnmanaged(PackageUpToDate),
},

failures: struct {
    no_version_found: std.ArrayListUnmanaged(PackageError),
    hash_mismatches: std.ArrayListUnmanaged(HashMismatch),
    downloads: std.ArrayListUnmanaged(DownloadFailed),
    downloads_with_status: std.ArrayListUnmanaged(DownloadFailedWithStatus),
    path_already_exists: std.ArrayListUnmanaged(PathAlreadyExists),
    generic_error: std.ArrayListUnmanaged(GenericError),
},

pub fn init(alloc: std.mem.Allocator) Diagnostics {
    return .{
        .arena_alloc = std.heap.ArenaAllocator.init(alloc),
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

pub fn deinit(diag: *Diagnostics) void {
    inline for (@typeInfo(@TypeOf(diag.successes)).@"struct".fields) |field|
        @field(diag.successes, field.name).deinit(diag.gpa());
    inline for (@typeInfo(@TypeOf(diag.warnings)).@"struct".fields) |field|
        @field(diag.warnings, field.name).deinit(diag.gpa());
    inline for (@typeInfo(@TypeOf(diag.failures)).@"struct".fields) |field|
        @field(diag.failures, field.name).deinit(diag.gpa());

    diag.arena_alloc.deinit();
    diag.* = undefined;
}

fn gpa(diag: *Diagnostics) std.mem.Allocator {
    return diag.arena_alloc.child_allocator;
}

fn arena(diag: *Diagnostics) std.mem.Allocator {
    return diag.arena_alloc.allocator();
}

pub fn reportToFile(diag: *Diagnostics, writer: *std.Io.File.Writer) !void {
    const is_tty = try writer.file.supportsAnsiEscapeCodes(writer.io);
    const escapes = if (is_tty) Escapes.ansi else Escapes.none;

    try diag.report(&writer.interface, .{
        .escapes = escapes,
    });
}

pub const ReportOptions = struct {
    escapes: Escapes = Escapes.none,
};

pub fn report(diag: *Diagnostics, writer: *std.Io.Writer, opt: ReportOptions) !void {
    diag.lock.lock();
    defer diag.lock.unlock();

    const esc = opt.escapes;
    inline for (@typeInfo(@TypeOf(diag.successes)).@"struct".fields) |field| {
        for (@field(diag.successes, field.name).items) |item| {
            try writer.print("{s}{s}✓{s} ", .{ esc.bold, esc.green, esc.reset });
            try item.print(esc, writer);
        }
    }
    inline for (@typeInfo(@TypeOf(diag.warnings)).@"struct".fields) |field| {
        for (@field(diag.warnings, field.name).items) |item| {
            try writer.print("{s}{s}⚠{s} ", .{ esc.bold, esc.yellow, esc.reset });
            try item.print(esc, writer);
        }
    }
    inline for (@typeInfo(@TypeOf(diag.failures)).@"struct".fields) |field| {
        for (@field(diag.failures, field.name).items) |item| {
            try writer.print("{s}{s}✗{s} ", .{ esc.bold, esc.red, esc.reset });
            try item.print(esc, writer);
        }
    }
}

pub fn hasFailed(diag: Diagnostics) bool {
    inline for (@typeInfo(@TypeOf(diag.failures)).@"struct".fields) |field| {
        if (@field(diag.failures, field.name).items.len != 0)
            return true;
    }

    return false;
}

pub fn donate(diag: *Diagnostics, pkg: PackageDonate) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.donate.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, pkg.name),
        .version = try diag.arena().dupe(u8, pkg.version),
        .donate = try diag.arena().dupe(u8, pkg.donate),
    });
}

pub fn installSucceeded(diag: *Diagnostics, pkg: PackageInstall) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.installs.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, pkg.name),
        .version = try diag.arena().dupe(u8, pkg.version),
    });
}

pub fn updateSucceeded(diag: *Diagnostics, pkg: PackageFromTo) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.updates.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, pkg.name),
        .from_version = try diag.arena().dupe(u8, pkg.from_version),
        .to_version = try diag.arena().dupe(u8, pkg.to_version),
    });
}

pub fn uninstallSucceeded(diag: *Diagnostics, pkg: PackageUninstall) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.uninstalls.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, pkg.name),
        .version = try diag.arena().dupe(u8, pkg.version),
    });
}

pub fn alreadyInstalled(diag: *Diagnostics, pkg: PackageAlreadyInstalled) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.already_installed.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, pkg.name),
    });
}

pub fn notInstalled(diag: *Diagnostics, pkg: PackageNotInstalled) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.not_installed.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, pkg.name),
    });
}

pub fn notFound(diag: *Diagnostics, pkg: PackageNotFound) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.not_found.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, pkg.name),
    });
}

pub fn notFoundForTarget(diag: *Diagnostics, not_found: PackageTarget) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.not_found_for_target.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, not_found.name),
        .target = not_found.target,
    });
}

pub fn upToDate(diag: *Diagnostics, pkg: PackageUpToDate) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.up_to_date.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, pkg.name),
        .version = try diag.arena().dupe(u8, pkg.version),
    });
}

pub fn noVersionFound(diag: *Diagnostics, pkg: PackageError) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.no_version_found.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, pkg.name),
        .err = pkg.err,
    });
}

pub fn hashMismatch(diag: *Diagnostics, mismatch: HashMismatch) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.hash_mismatches.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, mismatch.name),
        .version = try diag.arena().dupe(u8, mismatch.version),
        .expected_hash = try diag.arena().dupe(u8, mismatch.expected_hash),
        .actual_hash = try diag.arena().dupe(u8, mismatch.actual_hash),
    });
}

pub fn downloadFailed(diag: *Diagnostics, failure: DownloadFailed) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.downloads.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, failure.name),
        .version = try diag.arena().dupe(u8, failure.version),
        .url = try diag.arena().dupe(u8, failure.url),
        .err = failure.err,
    });
}

pub fn downloadFailedWithStatus(diag: *Diagnostics, failure: DownloadFailedWithStatus) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.downloads_with_status.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, failure.name),
        .version = try diag.arena().dupe(u8, failure.version),
        .url = try diag.arena().dupe(u8, failure.url),
        .status = failure.status,
    });
}

pub fn pathAlreadyExists(diag: *Diagnostics, failure: PathAlreadyExists) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.path_already_exists.append(diag.gpa(), .{
        .name = try diag.arena().dupe(u8, failure.name),
        .path = try diag.arena().dupe(u8, failure.path),
    });
}

pub fn genericError(diag: *Diagnostics, failure: GenericError) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.generic_error.append(diag.gpa(), .{
        .id = try diag.arena().dupe(u8, failure.id),
        .msg = try diag.arena().dupe(u8, failure.msg),
        .err = failure.err,
    });
}

pub const PackageAlreadyInstalled = struct {
    name: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{ esc.bold, this.name, esc.reset });
        try writer.print("└── Package already installed\n", .{});
    }
};

pub const PackageNotInstalled = struct {
    name: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{ esc.bold, this.name, esc.reset });
        try writer.print("└── Package is not installed\n", .{});
    }
};

pub const PackageNotFound = struct {
    name: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{ esc.bold, this.name, esc.reset });
        try writer.print("└── Package not found\n", .{});
    }
};

pub const PackageDonate = struct {
    name: []const u8,
    version: []const u8,
    donate: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{ esc.bold, this.name, this.version, esc.reset });
        try writer.print("└── {s}\n", .{this.donate});
    }
};

pub const PackageInstall = struct {
    name: []const u8,
    version: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{ esc.bold, this.name, this.version, esc.reset });
    }
};

pub const PackageUninstall = struct {
    name: []const u8,
    version: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s} -> ✗{s}\n", .{ esc.bold, this.name, this.version, esc.reset });
    }
};

pub const PackageUpToDate = struct {
    name: []const u8,
    version: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{ esc.bold, this.name, this.version, esc.reset });
        try writer.print("└── Package is up to date\n", .{});
    }
};

pub const PackageFromTo = struct {
    name: []const u8,
    from_version: []const u8,
    to_version: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s} -> {s}{s}\n", .{
            esc.bold,
            this.name,
            this.from_version,
            this.to_version,
            esc.reset,
        });
    }
};

pub const PackageError = struct {
    name: []const u8,
    err: anyerror,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{ esc.bold, this.name, esc.reset });
        try writer.print("└── No version found: {s}\n", .{@errorName(this.err)});
    }
};

pub const PackageTarget = struct {
    name: []const u8,
    target: Target,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{ esc.bold, this.name, esc.reset });
        try writer.print("└── Package not found for {s}_{s}\n", .{
            @tagName(this.target.os),
            @tagName(this.target.arch),
        });
    }
};

pub const HashMismatch = struct {
    name: []const u8,
    version: []const u8,
    expected_hash: []const u8,
    actual_hash: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{ esc.bold, this.name, this.version, esc.reset });
        try writer.print("│   Hash mismatch\n", .{});
        try writer.print("│     expected: {s}\n", .{this.expected_hash});
        try writer.print("└──   actual:   {s}\n", .{this.actual_hash});
    }
};

pub const DownloadFailed = struct {
    name: []const u8,
    version: []const u8,
    url: []const u8,
    err: anyerror,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{ esc.bold, this.name, this.version, esc.reset });
        try writer.print("│   Failed to download\n", .{});
        try writer.print("│     url:   {s}\n", .{this.url});
        try writer.print("└──   error: {s}\n", .{@errorName(this.err)});
    }
};

pub const DownloadFailedWithStatus = struct {
    name: []const u8,
    version: []const u8,
    url: []const u8,
    status: std.http.Status,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{ esc.bold, this.name, this.version, esc.reset });
        try writer.print("│   Failed to download\n", .{});
        try writer.print("│     url:   {s}\n", .{this.url});
        try writer.print("└──   status: {} {s}\n", .{
            @intFromEnum(this.status),
            this.status.phrase() orelse "",
        });
    }
};

pub const PathAlreadyExists = struct {
    name: []const u8,
    path: []const u8,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{ esc.bold, this.name, esc.reset });
        try writer.print("└── Path already exists: {s}\n", .{this.path});
    }
};

pub const GenericError = struct {
    id: []const u8,
    msg: []const u8,
    err: anyerror,

    fn print(this: @This(), esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{ esc.bold, this.id, esc.reset });
        try writer.print("│   {s}\n", .{this.msg});
        try writer.print("└──   {s}\n", .{@errorName(this.err)});
    }
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
