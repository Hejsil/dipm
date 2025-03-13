gpa: std.mem.Allocator,
strings: Strings,
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

pub fn init(gpa: std.mem.Allocator) Diagnostics {
    return .{
        .gpa = gpa,
        .strings = .empty,
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
        @field(diag.successes, field.name).deinit(diag.gpa);
    inline for (@typeInfo(@TypeOf(diag.warnings)).@"struct".fields) |field|
        @field(diag.warnings, field.name).deinit(diag.gpa);
    inline for (@typeInfo(@TypeOf(diag.failures)).@"struct".fields) |field|
        @field(diag.failures, field.name).deinit(diag.gpa);

    diag.strings.deinit(diag.gpa);
    diag.* = undefined;
}

pub fn reportToFile(diag: *Diagnostics, file: std.fs.File) !void {
    var buffered = std.io.bufferedWriter(file.writer());

    const is_tty = file.supportsAnsiEscapeCodes();
    const escapes = if (is_tty) Escapes.ansi else Escapes.none;
    try diag.report(buffered.writer(), .{
        .is_tty = is_tty,
        .escapes = escapes,
    });

    try buffered.flush();
}

pub const ReportOptions = struct {
    is_tty: bool = false,
    escapes: Escapes = Escapes.none,
};

pub fn report(diag: *Diagnostics, writer: anytype, opt: ReportOptions) !void {
    diag.lock.lock();
    defer diag.lock.unlock();

    const esc = opt.escapes;

    inline for (@typeInfo(@TypeOf(diag.successes)).@"struct".fields) |field| {
        for (@field(diag.successes, field.name).items) |item| {
            try writer.print("{s}{s}✓{s} ", .{ esc.bold, esc.green, esc.reset });
            try item.print(diag.strings, esc, writer);
        }
    }
    inline for (@typeInfo(@TypeOf(diag.warnings)).@"struct".fields) |field| {
        for (@field(diag.warnings, field.name).items) |item| {
            try writer.print("{s}{s}⚠{s} ", .{ esc.bold, esc.yellow, esc.reset });
            try item.print(diag.strings, esc, writer);
        }
    }
    inline for (@typeInfo(@TypeOf(diag.failures)).@"struct".fields) |field| {
        for (@field(diag.failures, field.name).items) |item| {
            try writer.print("{s}{s}✗{s} ", .{ esc.bold, esc.red, esc.reset });
            try item.print(diag.strings, esc, writer);
        }
    }

    const show_donate_reminder = opt.is_tty and !diag.hasFailed() and
        (diag.successes.installs.items.len != 0 or diag.successes.updates.items.len != 0);

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

pub fn hasFailed(diag: Diagnostics) bool {
    inline for (@typeInfo(@TypeOf(diag.failures)).@"struct".fields) |field| {
        if (@field(diag.failures, field.name).items.len != 0)
            return true;
    }

    return false;
}

pub fn putStr(diag: *Diagnostics, string: []const u8) !Strings.Index {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.strings.putStr(diag.gpa, string);
}

pub fn donate(diag: *Diagnostics, package: PackageDonate) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.donate.append(diag.gpa, package);
}

pub fn installSucceeded(diag: *Diagnostics, package: PackageInstall) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.installs.append(diag.gpa, package);
}

pub fn updateSucceeded(diag: *Diagnostics, package: PackageFromTo) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.updates.append(diag.gpa, package);
}

pub fn uninstallSucceeded(diag: *Diagnostics, package: PackageUninstall) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.uninstalls.append(diag.gpa, package);
}

pub fn alreadyInstalled(diag: *Diagnostics, package: PackageAlreadyInstalled) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.already_installed.append(diag.gpa, package);
}

pub fn notInstalled(diag: *Diagnostics, package: PackageNotInstalled) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.not_installed.append(diag.gpa, package);
}

pub fn notFound(diag: *Diagnostics, package: PackageNotFound) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.not_found.append(diag.gpa, package);
}

pub fn notFoundForTarget(diag: *Diagnostics, not_found: PackageTarget) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.not_found_for_target.append(diag.gpa, not_found);
}

pub fn upToDate(diag: *Diagnostics, package: PackageUpToDate) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.up_to_date.append(diag.gpa, package);
}

pub fn noVersionFound(diag: *Diagnostics, package: PackageError) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.no_version_found.append(diag.gpa, package);
}

pub fn hashMismatch(diag: *Diagnostics, mismatch: HashMismatch) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.hash_mismatches.append(diag.gpa, mismatch);
}

pub fn downloadFailed(diag: *Diagnostics, failure: DownloadFailed) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.downloads.append(diag.gpa, failure);
}

pub fn downloadFailedWithStatus(diag: *Diagnostics, failure: DownloadFailedWithStatus) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.downloads_with_status.append(diag.gpa, failure);
}

pub fn pathAlreadyExists(diag: *Diagnostics, failure: PathAlreadyExists) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.path_already_exists.append(diag.gpa, failure);
}

pub fn genericError(diag: *Diagnostics, failure: GenericError) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.generic_error.append(diag.gpa, failure);
}

pub const PackageAlreadyInstalled = struct {
    name: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            esc.reset,
        });
        try writer.print("└── Package already installed\n", .{});
    }
};

pub const PackageNotInstalled = struct {
    name: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            esc.reset,
        });
        try writer.print("└── Package is not installed\n", .{});
    }
};

pub const PackageNotFound = struct {
    name: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            esc.reset,
        });
        try writer.print("└── Package not found\n", .{});
    }
};

pub const PackageDonate = struct {
    name: Strings.Index,
    version: Strings.Index,
    donate: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            strings.getStr(this.version),
            esc.reset,
        });
        try writer.print("└── {s}\n", .{strings.getStr(this.donate)});
    }
};

pub const PackageInstall = struct {
    name: Strings.Index,
    version: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            strings.getStr(this.version),
            esc.reset,
        });
    }
};

pub const PackageUninstall = struct {
    name: Strings.Index,
    version: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s} {s} -> ✗{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            strings.getStr(this.version),
            esc.reset,
        });
    }
};

pub const PackageUpToDate = struct {
    name: Strings.Index,
    version: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            strings.getStr(this.version),
            esc.reset,
        });
        try writer.print("└── Package is up to date\n", .{});
    }
};

pub const PackageFromTo = struct {
    name: Strings.Index,
    from_version: Strings.Index,
    to_version: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s} {s} -> {s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            strings.getStr(this.from_version),
            strings.getStr(this.to_version),
            esc.reset,
        });
    }
};

pub const PackageError = struct {
    name: Strings.Index,
    err: anyerror,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            esc.reset,
        });
        try writer.print("└── No version found: {s}\n", .{@errorName(this.err)});
    }
};

pub const PackageTarget = struct {
    name: Strings.Index,
    target: Target,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            esc.reset,
        });
        try writer.print("└── Package not found for {s}_{s}\n", .{
            @tagName(this.target.os),
            @tagName(this.target.arch),
        });
    }
};

pub const HashMismatch = struct {
    name: Strings.Index,
    version: Strings.Index,
    expected_hash: Strings.Index,
    actual_hash: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            strings.getStr(this.version),
            esc.reset,
        });
        try writer.print("│   Hash mismatch\n", .{});
        try writer.print("│     expected: {s}\n", .{strings.getStr(this.expected_hash)});
        try writer.print("└──   actual:   {s}\n", .{strings.getStr(this.actual_hash)});
    }
};

pub const DownloadFailed = struct {
    name: Strings.Index,
    version: Strings.Index,
    url: Strings.Index,
    err: anyerror,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            strings.getStr(this.version),
            esc.reset,
        });
        try writer.print("│   Failed to download\n", .{});
        try writer.print("│     url:   {s}\n", .{strings.getStr(this.url)});
        try writer.print("└──   error: {s}\n", .{@errorName(this.err)});
    }
};

pub const DownloadFailedWithStatus = struct {
    name: Strings.Index,
    version: Strings.Index,
    url: Strings.Index,
    status: std.http.Status,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            strings.getStr(this.version),
            esc.reset,
        });
        try writer.print("│   Failed to download\n", .{});
        try writer.print("│     url:   {s}\n", .{strings.getStr(this.url)});
        try writer.print("└──   status: {} {s}\n", .{
            @intFromEnum(this.status),
            this.status.phrase() orelse "",
        });
    }
};

pub const PathAlreadyExists = struct {
    name: Strings.Index,
    path: Strings.Index,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            strings.getStr(this.name),
            esc.reset,
        });
        try writer.print("└── Path already exists: {s}\n", .{strings.getStr(this.path)});
    }
};

pub const GenericError = struct {
    id: Strings.Index,
    msg: Strings.Index,
    err: anyerror,

    fn print(this: @This(), strings: Strings, esc: Escapes, writer: anytype) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            strings.getStr(this.id),
            esc.reset,
        });
        try writer.print("│   {s}\n", .{strings.getStr(this.msg)});
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
const Strings = @import("Strings.zig");
const Target = @import("Target.zig");

const std = @import("std");
