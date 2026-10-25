pub fn commitFile(io: std.Io, dir: std.Io.Dir, file: []const u8, msg: []const u8) !void {
    // Stage the file explicitly. `git commit --include <file>` (what dipm used to do) fails for a
    // file git does not know about yet, which is exactly the case for a brand new `pkgs.ini`.
    if (try runCommand(io, dir, &.{ "git", "add", "--", file }) != 0)
        return error.GitAddFailed;

    // Limiting the commit to `file` keeps staged changes of other files out of the commit.
    return switch (try runCommand(io, dir, &.{ "git", "commit", "-m", msg, "--", file })) {
        0 => {},
        else => error.GitCommitFailed,
    };
}

/// Returns whether `file` has changes that are not committed yet (staged or unstaged), including
/// the case where the file is not tracked yet.
pub fn hasDiffForFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    file: []const u8,
) !bool {
    // `git diff --quiet` only reports unstaged changes, so staged changes and a brand new,
    // untracked `pkgs.ini` would be reported as "no diff" and never committed.
    // `git status --porcelain` reports both, and works in a repo that has no commits yet.
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "status", "--porcelain", "--", file },
        .cwd = .{ .dir = dir },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    switch (res.term) {
        .exited => |code| if (code != 0) return error.GitStatusFailed,
        else => return error.ProcessExitedAbnormally,
    }

    return std.mem.trim(u8, res.stdout, " \r\n\t").len != 0;
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
    // `--set-upstream` is needed because the branch was just created, and has no upstream branch
    // yet. Without it, `git push` fails unless the user has `push.autoSetupRemote` configured.
    // Setting the upstream also means the branch is cleaned up by `pruneBranches` later, once the
    // PR branch is deleted on the remote.
    const code = try runCommand(io, dir, &.{ "git", "push", "--set-upstream", "origin", "HEAD" });
    if (code != 0)
        return error.GitPushFailed;
}

/// Prune remote-tracking refs, then delete every local branch whose upstream is gone (that is, the
/// remote branch it was tracking no longer exists). Local branches that were never pushed are left
/// alone, and the currently checked out branch is never deleted.
pub fn pruneBranches(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    // Drop remote-tracking refs whose branch no longer exists remotely, so the remaining set only
    // contains branches that actually exist.
    //
    // NOTE: `fetch` is used instead of `pull`, so that the working tree/index is never touched,
    //       and so that a checked out branch without an upstream is not an error.
    const code_fetch = try runCommand(io, dir, &.{ "git", "fetch", "--prune" });
    if (code_fetch != 0)
        return error.GitFetchFailed;

    const branches = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "for-each-ref", "--format=%(refname) %(upstream:track)", "refs/heads/" },
        .cwd = .{ .dir = dir },
    });
    defer gpa.free(branches.stdout);
    defer gpa.free(branches.stderr);

    switch (branches.term) {
        .exited => |code| if (code != 0) return error.GitBranchListFailed,
        else => return error.ProcessExitedAbnormally,
    }

    const head = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "branch", "--show-current" },
        .cwd = .{ .dir = dir },
    });
    defer gpa.free(head.stdout);
    defer gpa.free(head.stderr);

    // Empty when HEAD is detached, in which case no branch has to be protected.
    const current_branch = std.mem.trim(u8, head.stdout, " \r\n\t");

    var local_branches = std.mem.tokenizeScalar(u8, branches.stdout, '\n');
    while (local_branches.next()) |line| {
        const split = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const refname = line[0..split];
        const track = line[split + 1 ..];

        // `%(upstream:track)` is only `[gone]` for branches whose upstream existed at some point,
        // but has since been deleted on the remote. Branches that were never pushed have no
        // upstream at all, and must never be deleted: they can hold work that exists nowhere else.
        if (!std.mem.eql(u8, track, "[gone]"))
            continue;

        const head_branch = std.fs.path.basename(refname);
        if (std.mem.eql(u8, head_branch, current_branch))
            continue;

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

fn expectRun(io: std.Io, dir: std.Io.Dir, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .cwd = .{ .dir = dir },
    });

    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn branchExists(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, branch: []const u8) !bool {
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "branch", "--list", "--format=%(refname:short)", branch },
        .cwd = .{ .dir = dir },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    return std.mem.trim(u8, res.stdout, " \r\n\t").len != 0;
}

test pruneBranches {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp_dir = try fs.zigCacheTmpDir(io, .{});
    defer tmp_dir.deleteAndClose(io);

    const tmp_path = try tmp_dir.path(gpa);
    defer gpa.free(tmp_path);

    const origin_path = try std.fmt.allocPrint(gpa, "{s}/origin.git", .{tmp_path});
    defer gpa.free(origin_path);

    // `git` is not available everywhere. If it is not, there is nothing to test here.
    expectRun(io, tmp_dir.dir, &.{ "git", "init", "--bare", "origin.git" }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    try expectRun(io, tmp_dir.dir, &.{ "git", "init", "repo" });

    var repo_dir = try tmp_dir.dir.openDir(io, "repo", .{});
    defer repo_dir.close(io);

    try expectRun(io, repo_dir, &.{ "git", "config", "user.name", "dipm" });
    try expectRun(io, repo_dir, &.{ "git", "config", "user.email", "dipm@example.com" });
    try expectRun(io, repo_dir, &.{ "git", "config", "commit.gpgsign", "false" });

    try repo_dir.writeFile(io, .{ .sub_path = "file", .data = "1" });
    try expectRun(io, repo_dir, &.{ "git", "add", "file" });
    try expectRun(io, repo_dir, &.{ "git", "commit", "-m", "init" });
    try expectRun(io, repo_dir, &.{ "git", "remote", "add", "origin", origin_path });
    try expectRun(io, repo_dir, &.{ "git", "push", "--set-upstream", "origin", "HEAD" });

    const base_branch = try currentBranch(gpa, io, repo_dir);
    defer gpa.free(base_branch);

    // A local branch that was never pushed must survive pruning. Deleting it would delete work
    // that exists nowhere else.
    try expectRun(io, repo_dir, &.{ "git", "checkout", "-b", "local-work" });
    try repo_dir.writeFile(io, .{ .sub_path = "local", .data = "local" });
    try expectRun(io, repo_dir, &.{ "git", "add", "local" });
    try expectRun(io, repo_dir, &.{ "git", "commit", "-m", "local work" });
    try expectRun(io, repo_dir, &.{ "git", "checkout", base_branch });

    // A branch whose remote counterpart is deleted after it was pushed must be pruned.
    try expectRun(io, repo_dir, &.{ "git", "checkout", "-b", "pushed-and-deleted" });
    try repo_dir.writeFile(io, .{ .sub_path = "pushed", .data = "pushed" });
    try expectRun(io, repo_dir, &.{ "git", "add", "pushed" });
    try expectRun(io, repo_dir, &.{ "git", "commit", "-m", "pushed" });
    try expectRun(io, repo_dir, &.{ "git", "push", "--set-upstream", "origin", "pushed-and-deleted" });
    try expectRun(io, repo_dir, &.{ "git", "checkout", base_branch });
    try expectRun(io, repo_dir, &.{ "git", "push", "origin", "--delete", "pushed-and-deleted" });

    try pruneBranches(gpa, io, repo_dir);

    try std.testing.expect(try branchExists(io, gpa, repo_dir, "local-work"));
    try std.testing.expect(try branchExists(io, gpa, repo_dir, base_branch));
    try std.testing.expect(!try branchExists(io, gpa, repo_dir, "pushed-and-deleted"));
}

const Package = @import("Package.zig");
const Packages = @import("Packages.zig");

const fs = @import("fs.zig");

const std = @import("std");
