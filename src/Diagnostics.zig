gpa: std.mem.Allocator,
strs: Strings,
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
        .strs = .empty,
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

    diag.strs.deinit(diag.gpa);
    diag.* = undefined;
}

pub fn reportToFile(diag: *Diagnostics, writer: *std.fs.File.Writer) !void {
    const is_tty = writer.file.supportsAnsiEscapeCodes();
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
            try item.print(diag.strs, esc, writer);
        }
    }
    inline for (@typeInfo(@TypeOf(diag.warnings)).@"struct".fields) |field| {
        for (@field(diag.warnings, field.name).items) |item| {
            try writer.print("{s}{s}⚠{s} ", .{ esc.bold, esc.yellow, esc.reset });
            try item.print(diag.strs, esc, writer);
        }
    }
    inline for (@typeInfo(@TypeOf(diag.failures)).@"struct".fields) |field| {
        for (@field(diag.failures, field.name).items) |item| {
            try writer.print("{s}{s}✗{s} ", .{ esc.bold, esc.red, esc.reset });
            try item.print(diag.strs, esc, writer);
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

pub fn putStr(diag: *Diagnostics, string: []const u8) !Strings.Index {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.strs.putStr(diag.gpa, string);
}

pub fn donate(diag: *Diagnostics, pkg: PackageDonate) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.donate.append(diag.gpa, pkg);
}

pub fn installSucceeded(diag: *Diagnostics, pkg: PackageInstall) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.installs.append(diag.gpa, pkg);
}

pub fn updateSucceeded(diag: *Diagnostics, pkg: PackageFromTo) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.updates.append(diag.gpa, pkg);
}

pub fn uninstallSucceeded(diag: *Diagnostics, pkg: PackageUninstall) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.successes.uninstalls.append(diag.gpa, pkg);
}

pub fn alreadyInstalled(diag: *Diagnostics, pkg: PackageAlreadyInstalled) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.already_installed.append(diag.gpa, pkg);
}

pub fn notInstalled(diag: *Diagnostics, pkg: PackageNotInstalled) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.not_installed.append(diag.gpa, pkg);
}

pub fn notFound(diag: *Diagnostics, pkg: PackageNotFound) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.not_found.append(diag.gpa, pkg);
}

pub fn notFoundForTarget(diag: *Diagnostics, not_found: PackageTarget) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.not_found_for_target.append(diag.gpa, not_found);
}

pub fn upToDate(diag: *Diagnostics, pkg: PackageUpToDate) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.warnings.up_to_date.append(diag.gpa, pkg);
}

pub fn noVersionFound(diag: *Diagnostics, pkg: PackageError) !void {
    diag.lock.lock();
    defer diag.lock.unlock();
    return diag.failures.no_version_found.append(diag.gpa, pkg);
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

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            esc.reset,
        });
        try writer.print("└── Package already installed\n", .{});
    }
};

pub const PackageNotInstalled = struct {
    name: Strings.Index,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            esc.reset,
        });
        try writer.print("└── Package is not installed\n", .{});
    }
};

pub const PackageNotFound = struct {
    name: Strings.Index,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            esc.reset,
        });
        try writer.print("└── Package not found\n", .{});
    }
};

pub const PackageDonate = struct {
    name: Strings.Index,
    version: Strings.Index,
    donate: Strings.Index,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            this.version.get(strs),
            esc.reset,
        });
        try writer.print("└── {s}\n", .{this.donate.get(strs)});
    }
};

pub const PackageInstall = struct {
    name: Strings.Index,
    version: Strings.Index,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            this.version.get(strs),
            esc.reset,
        });
    }
};

pub const PackageUninstall = struct {
    name: Strings.Index,
    version: Strings.Index,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s} -> ✗{s}\n", .{
            esc.bold,
            this.name.get(strs),
            this.version.get(strs),
            esc.reset,
        });
    }
};

pub const PackageUpToDate = struct {
    name: Strings.Index,
    version: Strings.Index,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            this.version.get(strs),
            esc.reset,
        });
        try writer.print("└── Package is up to date\n", .{});
    }
};

pub const PackageFromTo = struct {
    name: Strings.Index,
    from_version: Strings.Index,
    to_version: Strings.Index,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s} -> {s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            this.from_version.get(strs),
            this.to_version.get(strs),
            esc.reset,
        });
    }
};

pub const PackageError = struct {
    name: Strings.Index,
    err: anyerror,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            esc.reset,
        });
        try writer.print("└── No version found: {s}\n", .{@errorName(this.err)});
    }
};

pub const PackageTarget = struct {
    name: Strings.Index,
    target: Target,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
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

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            this.version.get(strs),
            esc.reset,
        });
        try writer.print("│   Hash mismatch\n", .{});
        try writer.print("│     expected: {s}\n", .{this.expected_hash.get(strs)});
        try writer.print("└──   actual:   {s}\n", .{this.actual_hash.get(strs)});
    }
};

pub const DownloadFailed = struct {
    name: Strings.Index,
    version: Strings.Index,
    url: Strings.Index,
    err: anyerror,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            this.version.get(strs),
            esc.reset,
        });
        try writer.print("│   Failed to download\n", .{});
        try writer.print("│     url:   {s}\n", .{this.url.get(strs)});
        try writer.print("└──   error: {s}\n", .{@errorName(this.err)});
    }
};

pub const DownloadFailedWithStatus = struct {
    name: Strings.Index,
    version: Strings.Index,
    url: Strings.Index,
    status: std.http.Status,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s} {s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            this.version.get(strs),
            esc.reset,
        });
        try writer.print("│   Failed to download\n", .{});
        try writer.print("│     url:   {s}\n", .{this.url.get(strs)});
        try writer.print("└──   status: {} {s}\n", .{
            @intFromEnum(this.status),
            this.status.phrase() orelse "",
        });
    }
};

pub const PathAlreadyExists = struct {
    name: Strings.Index,
    path: Strings.Index,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            this.name.get(strs),
            esc.reset,
        });
        try writer.print("└── Path already exists: {s}\n", .{this.path.get(strs)});
    }
};

pub const GenericError = struct {
    id: Strings.Index,
    msg: Strings.Index,
    err: anyerror,

    fn print(this: @This(), strs: Strings, esc: Escapes, writer: *std.Io.Writer) !void {
        try writer.print("{s}{s}{s}\n", .{
            esc.bold,
            this.id.get(strs),
            esc.reset,
        });
        try writer.print("│   {s}\n", .{this.msg.get(strs)});
        try writer.print("└──   {s}\n", .{@errorName(this.err)});
    }
};

pub const Error = error{
    DiagnosticsReported,
};

test {
    _ = Escapes;
    _ = Strings;
    _ = Target;
}

const Diagnostics = @This();

const Escapes = @import("Escapes.zig");
const Strings = @import("Strings.zig");
const Target = @import("Target.zig");

const std = @import("std");
