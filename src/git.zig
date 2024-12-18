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

/// Create a commit message based on what `Package.update` did. Depending on what changed between
/// the old and new package, the commit message will differ.
pub fn createCommitMessage(gpa: std.mem.Allocator, package: Package.Named, m_old_package: ?Package) ![]u8 {
    const old_package = m_old_package orelse {
        return std.fmt.allocPrint(gpa, "{s}: Add {s}", .{
            package.name,
            package.package.info.version,
        });
    };
    if (!std.mem.eql(u8, package.package.info.version, old_package.info.version)) {
        return std.fmt.allocPrint(gpa, "{s}: Update {s}", .{
            package.name,
            package.package.info.version,
        });
    }
    if (!std.mem.eql(u8, package.package.linux_x86_64.hash, old_package.linux_x86_64.hash))
        return std.fmt.allocPrint(gpa, "{s}: Update hash", .{package.name});
    if (!std.mem.eql(u8, package.package.linux_x86_64.url, old_package.linux_x86_64.url))
        return std.fmt.allocPrint(gpa, "{s}: Update url", .{package.name});
    if (!std.mem.eql(u8, package.package.info.description, old_package.info.description))
        return std.fmt.allocPrint(gpa, "{s}: Update description", .{package.name});
    if (package.package.info.donate.len != old_package.info.donate.len)
        return std.fmt.allocPrint(gpa, "{s}: Update donations", .{package.name});
    for (package.package.info.donate, old_package.info.donate) |new, old| {
        if (!std.mem.eql(u8, new, old))
            return std.fmt.allocPrint(gpa, "{s}: Update donations", .{package.name});
    }

    // TODO: Better message
    return std.fmt.allocPrint(gpa, "{s}: Update something", .{package.name});
}

fn expectCreateCommitMessage(expected: []const u8, package: Package.Named, m_old_package: ?Package) !void {
    const actual = try createCommitMessage(std.testing.allocator, package, m_old_package);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test createCommitMessage {
    try expectCreateCommitMessage(
        "dipm: Add 0.1.0",
        .{
            .name = "dipm",
            .package = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{ .github = "" },
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
            .package = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{ .github = "" },
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
            .update = .{ .github = "" },
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
            .package = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{ .github = "" },
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
            .update = .{ .github = "" },
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
            .package = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{ .github = "" },
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
            .update = .{ .github = "" },
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
            .package = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                },
                .update = .{ .github = "" },
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
            .update = .{ .github = "" },
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
            .package = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                    .donate = &.{},
                },
                .update = .{ .github = "" },
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
            .update = .{ .github = "" },
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
            .package = .{
                .info = .{
                    .version = "0.1.0",
                    .description = "Description 1",
                    .donate = &.{"a"},
                },
                .update = .{ .github = "" },
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
            .update = .{ .github = "" },
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
