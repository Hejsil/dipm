pub fn commitFile(io: std.Io, dir: std.Io.Dir, file: []const u8, msg: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "commit", "-i", file, "-m", msg },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd_dir = dir,
    });
    const failed = switch (try child.wait(io)) {
        .exited => |code| switch (code) {
            0 => false, // successful commit
            1 => false, // nothing to commit commit
            else => true,
        },
        else => true,
    };
    if (failed)
        return error.GitCommitFailed;
}

pub const MessageOptions = struct {
    description: bool = false,
};

/// Create a commit message based on what `Package.update` did. Depending on what changed between
/// the old and new package, the commit message will differ.
pub fn createCommitMessage(
    gpa: std.mem.Allocator,
    new: Package.Named,
    m_old: ?Package,
    options: MessageOptions,
) ![]u8 {
    const name = new.name;
    const old = m_old orelse {
        return std.fmt.allocPrint(gpa, "{s}: Add {s}", .{
            name,
            new.pkg.info.version,
        });
    };
    if (!std.mem.eql(u8, new.pkg.info.version, old.info.version)) {
        return std.fmt.allocPrint(gpa, "{s}: Update {s}", .{ name, new.pkg.info.version });
    }
    if (!std.mem.eql(u8, new.pkg.linux_x86_64.url, old.linux_x86_64.url))
        return std.fmt.allocPrint(gpa, "{s}: Update url", .{name});
    if (!std.mem.eql(u8, new.pkg.linux_x86_64.hash, old.linux_x86_64.hash))
        return std.fmt.allocPrint(gpa, "{s}: Update hash", .{name});
    if (options.description) {
        if (!std.mem.eql(u8, new.pkg.info.description, old.info.description))
            return std.fmt.allocPrint(gpa, "{s}: Update description", .{name});
    }
    if (new.pkg.info.donate.len != old.info.donate.len)
        return std.fmt.allocPrint(gpa, "{s}: Update donations", .{name});
    for (new.pkg.info.donate, old.info.donate) |n, o| {
        if (!std.mem.eql(u8, n, o))
            return std.fmt.allocPrint(gpa, "{s}: Update donations", .{name});
    }

    // TODO: Better message
    return std.fmt.allocPrint(gpa, "{s}: Update something", .{name});
}

fn expectCreateCommitMessage(
    expected: []const u8,
    pkg: Package.Named,
    m_old_pkg: ?Package,
) !void {
    const actual = try createCommitMessage(std.testing.allocator, pkg, m_old_pkg, .{
        .description = true,
    });
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test createCommitMessage {
    try expectCreateCommitMessage(
        "dipm: Add 0.1.0",
        .{
            .name = "dipm",
            .pkg = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = "a",
                    .hash = "a",
                },
            },
        },
        null,
    );
    try expectCreateCommitMessage(
        "dipm: Update 0.1.0",
        .{
            .name = "dipm",
            .pkg = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = "a",
                    .hash = "a",
                },
            },
        },
        .{
            .info = .{
                .version = "0.2.0",
                .description = "Description 2",
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = "b",
                .hash = "b",
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update url",
        .{
            .name = "dipm",
            .pkg = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = "a",
                    .hash = "a",
                },
            },
        },
        .{
            .info = .{
                .version = "0.1.0",
                .description = "Description 2",
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = "b",
                .hash = "b",
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update hash",
        .{
            .name = "dipm",
            .pkg = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = "a",
                    .hash = "a",
                },
            },
        },
        .{
            .info = .{
                .version = "0.1.0",
                .description = "Description 2",
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = "a",
                .hash = "b",
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update description",
        .{
            .name = "dipm",
            .pkg = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = "a",
                    .hash = "a",
                },
            },
        },
        .{
            .info = .{
                .version = "0.1.0",
                .description = "Description 2",
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = "a",
                .hash = "a",
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update donations",
        .{
            .name = "dipm",
            .pkg = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = "a",
                    .hash = "a",
                },
            },
        },
        .{
            .info = .{
                .version = "0.1.0",
                .description = "Description 1",
                .donate = &.{"a"},
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = "a",
                .hash = "a",
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update donations",
        .{
            .name = "dipm",
            .pkg = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                    .donate = &.{"a"},
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = "a",
                    .hash = "a",
                },
            },
        },
        .{
            .info = .{
                .version = "0.1.0",
                .description = "Description 1",
                .donate = &.{"b"},
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = "a",
                .hash = "a",
            },
        },
    );
}

test {
    _ = Package;
    _ = Packages;
}

const Package = @import("Package.zig");
const Packages = @import("Packages.zig");

const std = @import("std");
