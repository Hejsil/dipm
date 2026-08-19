pub fn commitFile(io: std.Io, dir: std.Io.Dir, file: []const u8, msg: []const u8) !void {
    return switch (try runCommand(io, dir, &.{ "git", "commit", "-i", file, "-m", msg })) {
        0 => {},
        else => error.GitCommitFailed,
    };
}

pub fn hasDiffForFile(io: std.Io, dir: std.Io.Dir, file: []const u8) !bool {
    const code = try runCommand(io, dir, &.{ "git", "diff", "--quiet", "--", file });
    return switch (code) {
        0 => false,
        1 => true,
        else => error.GitDiffFailed,
    };
}

pub fn currentBranch(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "branch", "--show-current" },
        .cwd = .{ .dir = dir },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    switch (res.term) {
        .exited => |code| switch (code) {
            0 => {},
            else => return error.GitCurrentBranchFailed,
        },
        else => return error.ProcessExitedAbnormally,
    }

    const trimmed = std.mem.trim(u8, res.stdout, " \r\n\t");
    if (trimmed.len == 0)
        return error.GitCurrentBranchFailed;

    return gpa.dupe(u8, trimmed);
}

pub fn createBranch(io: std.Io, dir: std.Io.Dir, branch: []const u8) !void {
    const code = try runCommand(io, dir, &.{ "git", "switch", "-c", branch });
    if (code != 0)
        return error.GitCreateBranchFailed;
}

pub fn switchBranch(io: std.Io, dir: std.Io.Dir, branch: []const u8) !void {
    const code = try runCommand(io, dir, &.{ "git", "switch", branch });
    if (code != 0)
        return error.GitSwitchBranchFailed;
}

pub fn push(io: std.Io, dir: std.Io.Dir) !void {
    const code = try runCommand(io, dir, &.{ "git", "push" });
    if (code != 0)
        return error.GitPushFailed;
}

/// Prune remote-tracking refs, then delete every local branch that has no
/// remote-tracking branch of the same name. So a local `foo` is kept iff some
/// `refs/remotes/<remote>/foo` exists after pruning.
pub fn pruneBranches(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    // Drop remote-tracking refs whose branch no longer exists remotely, so the
    // remaining set only contains branches that actually exist.
    const code_fetch = try runCommand(io, dir, &.{ "git", "pull", "--prune" });
    if (code_fetch != 0)
        return error.GitFetchFailed;

    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "for-each-ref", "--format=%(refname)" },
        .cwd = .{ .dir = dir },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    var it_outer = std.mem.tokenizeScalar(u8, res.stdout, '\n');
    outer: while (it_outer.next()) |line_head| {
        if (!std.mem.startsWith(u8, line_head, "refs/heads/"))
            continue;

        const head_branch = std.fs.path.basename(line_head);

        var it_inner = std.mem.tokenizeScalar(u8, res.stdout, '\n');
        while (it_inner.next()) |line_remote| {
            if (!std.mem.startsWith(u8, line_remote, "refs/remotes/"))
                continue;

            const remote_branch = std.fs.path.basename(line_remote);
            if (std.mem.eql(u8, head_branch, remote_branch))
                continue :outer;
        }

        // No remote-tracking branch of the same name exists, so delete the local branch.
        const code_delete = try runCommand(io, dir, &.{ "git", "branch", "-D", head_branch });
        if (code_delete != 0)
            return error.GitBranchDeleteFailed;
    }
}

pub const PrOptions = struct {
    base: []const u8 = "main",
};

pub fn createPullRequest(io: std.Io, dir: std.Io.Dir, options: PrOptions) !void {
    const code = try runCommand(io, dir, &.{
        "gh", "pr", "create", "--fill", "--base", options.base,
    });
    if (code != 0)
        return error.GhPrCreateFailed;
}

fn runCommand(io: std.Io, dir: std.Io.Dir, argv: []const []const u8) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .cwd = .{ .dir = dir },
    });

    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => error.ProcessExitedAbnormally,
    };
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
