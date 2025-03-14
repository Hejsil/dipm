pub fn commitFile(gpa: std.mem.Allocator, dir: std.fs.Dir, file: []const u8, msg: []const u8) !void {
    var child = std.process.Child.init(
        &.{ "git", "commit", "-i", file, "-m", msg },
        gpa,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd_dir = dir;

    try child.spawn();
    _ = try child.wait();
}

pub const MessageOptions = struct {
    description: bool = false,
};

/// Create a commit message based on what `Package.update` did. Depending on what changed between
/// the old and new package, the commit message will differ.
pub fn createCommitMessage(
    gpa: std.mem.Allocator,
    pkg: Package.Named,
    m_old_pkg: ?Package,
    options: MessageOptions,
) ![]u8 {
    const old_pkg = m_old_pkg orelse {
        return std.fmt.allocPrint(gpa, "{s}: Add {s}", .{
            pkg.name,
            pkg.pkg.info.version,
        });
    };
    if (!std.mem.eql(u8, pkg.pkg.info.version, old_pkg.info.version)) {
        return std.fmt.allocPrint(gpa, "{s}: Update {s}", .{
            pkg.name,
            pkg.pkg.info.version,
        });
    }
    if (!std.mem.eql(u8, pkg.pkg.linux_x86_64.hash, old_pkg.linux_x86_64.hash))
        return std.fmt.allocPrint(gpa, "{s}: Update hash", .{pkg.name});
    if (!std.mem.eql(u8, pkg.pkg.linux_x86_64.url, old_pkg.linux_x86_64.url))
        return std.fmt.allocPrint(gpa, "{s}: Update url", .{pkg.name});
    if (options.description and !std.mem.eql(u8, pkg.pkg.info.description, old_pkg.info.description))
        return std.fmt.allocPrint(gpa, "{s}: Update description", .{pkg.name});
    if (pkg.pkg.info.donate.len != old_pkg.info.donate.len)
        return std.fmt.allocPrint(gpa, "{s}: Update donations", .{pkg.name});
    for (pkg.pkg.info.donate, old_pkg.info.donate) |new, old| {
        if (!std.mem.eql(u8, new, old))
            return std.fmt.allocPrint(gpa, "{s}: Update donations", .{pkg.name});
    }

    // TODO: Better message
    return std.fmt.allocPrint(gpa, "{s}: Update something", .{pkg.name});
}

fn expectCreateCommitMessage(expected: []const u8, pkg: Package.Named, m_old_pkg: ?Package) !void {
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
                .hash = "a",
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
                    .donate = &.{},
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

test {}

const Package = @import("Package.zig");

const std = @import("std");
