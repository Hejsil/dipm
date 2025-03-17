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
    pkgs: *const Packages,
    new: Package.Named,
    m_old: ?Package,
    options: MessageOptions,
) ![]u8 {
    const name = new.name.get(pkgs.strs);
    const old = m_old orelse {
        return std.fmt.allocPrint(gpa, "{s}: Add {s}", .{
            name,
            new.pkg.info.version.get(pkgs.strs),
        });
    };
    if (!pkgs.strs.eql(new.pkg.info.version, old.info.version)) {
        return std.fmt.allocPrint(gpa, "{s}: Update {s}", .{
            name,
            new.pkg.info.version.get(pkgs.strs),
        });
    }
    if (!pkgs.strs.eql(new.pkg.linux_x86_64.hash, old.linux_x86_64.hash))
        return std.fmt.allocPrint(gpa, "{s}: Update hash", .{name});
    if (!pkgs.strs.eql(new.pkg.linux_x86_64.url, old.linux_x86_64.url))
        return std.fmt.allocPrint(gpa, "{s}: Update url", .{name});
    if (options.description) {
        const new_desc = new.pkg.info.description.get(pkgs.strs) orelse "";
        const old_desc = old.info.description.get(pkgs.strs) orelse "";
        if (!std.mem.eql(u8, new_desc, old_desc))
            return std.fmt.allocPrint(gpa, "{s}: Update description", .{name});
    }
    if (new.pkg.info.donate.len != old.info.donate.len)
        return std.fmt.allocPrint(gpa, "{s}: Update donations", .{name});
    for (new.pkg.info.donate.get(pkgs.strs), old.info.donate.get(pkgs.strs)) |n, o| {
        if (!pkgs.strs.eql(n, o))
            return std.fmt.allocPrint(gpa, "{s}: Update donations", .{name});
    }

    // TODO: Better message
    return std.fmt.allocPrint(gpa, "{s}: Update something", .{name});
}

fn expectCreateCommitMessage(
    expected: []const u8,
    pkgs: *const Packages,
    pkg: Package.Named,
    m_old_pkg: ?Package,
) !void {
    const actual = try createCommitMessage(std.testing.allocator, pkgs, pkg, m_old_pkg, .{
        .description = true,
    });
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test createCommitMessage {
    var pkgs = Packages.init(std.testing.allocator);
    defer pkgs.deinit();

    try expectCreateCommitMessage(
        "dipm: Add 0.1.0",
        &pkgs,
        .{
            .name = try pkgs.putStr("dipm"),
            .pkg = .{
                .info = .{
                    .version = try pkgs.putStr("0.1.0"),
                    .description = .some(try pkgs.putStr("Description 1")),
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = try pkgs.putStr("a"),
                    .hash = try pkgs.putStr("a"),
                },
            },
        },
        null,
    );
    try expectCreateCommitMessage(
        "dipm: Update 0.1.0",
        &pkgs,
        .{
            .name = try pkgs.putStr("dipm"),
            .pkg = .{
                .info = .{
                    .version = try pkgs.putStr("0.1.0"),
                    .description = .some(try pkgs.putStr("Description 1")),
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = try pkgs.putStr("a"),
                    .hash = try pkgs.putStr("a"),
                },
            },
        },
        .{
            .info = .{
                .version = try pkgs.putStr("0.2.0"),
                .description = .some(try pkgs.putStr("Description 2")),
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = try pkgs.putStr("b"),
                .hash = try pkgs.putStr("b"),
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update hash",
        &pkgs,
        .{
            .name = try pkgs.putStr("dipm"),
            .pkg = .{
                .info = .{
                    .version = try pkgs.putStr("0.1.0"),
                    .description = .some(try pkgs.putStr("Description 1")),
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = try pkgs.putStr("a"),
                    .hash = try pkgs.putStr("a"),
                },
            },
        },
        .{
            .info = .{
                .version = try pkgs.putStr("0.1.0"),
                .description = .some(try pkgs.putStr("Description 2")),
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = try pkgs.putStr("b"),
                .hash = try pkgs.putStr("b"),
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update url",
        &pkgs,
        .{
            .name = try pkgs.putStr("dipm"),
            .pkg = .{
                .info = .{
                    .version = try pkgs.putStr("0.1.0"),
                    .description = .some(try pkgs.putStr("Description 1")),
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = try pkgs.putStr("a"),
                    .hash = try pkgs.putStr("a"),
                },
            },
        },
        .{
            .info = .{
                .version = try pkgs.putStr("0.1.0"),
                .description = .some(try pkgs.putStr("Description 2")),
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = try pkgs.putStr("b"),
                .hash = try pkgs.putStr("a"),
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update description",
        &pkgs,
        .{
            .name = try pkgs.putStr("dipm"),
            .pkg = .{
                .info = .{
                    .version = try pkgs.putStr("0.1.0"),
                    .description = .some(try pkgs.putStr("Description 1")),
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = try pkgs.putStr("a"),
                    .hash = try pkgs.putStr("a"),
                },
            },
        },
        .{
            .info = .{
                .version = try pkgs.putStr("0.1.0"),
                .description = .some(try pkgs.putStr("Description 2")),
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = try pkgs.putStr("a"),
                .hash = try pkgs.putStr("a"),
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update donations",
        &pkgs,
        .{
            .name = try pkgs.putStr("dipm"),
            .pkg = .{
                .info = .{
                    .version = try pkgs.putStr("0.1.0"),
                    .description = .some(try pkgs.putStr("Description 1")),
                    .donate = .empty,
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = try pkgs.putStr("a"),
                    .hash = try pkgs.putStr("a"),
                },
            },
        },
        .{
            .info = .{
                .version = try pkgs.putStr("0.1.0"),
                .description = .some(try pkgs.putStr("Description 1")),
                .donate = try pkgs.putStrs(&.{"a"}),
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = try pkgs.putStr("a"),
                .hash = try pkgs.putStr("a"),
            },
        },
    );
    try expectCreateCommitMessage(
        "dipm: Update donations",
        &pkgs,
        .{
            .name = try pkgs.putStr("dipm"),
            .pkg = .{
                .info = .{
                    .version = try pkgs.putStr("0.1.0"),
                    .description = .some(try pkgs.putStr("Description 1")),
                    .donate = try pkgs.putStrs(&.{"a"}),
                },
                .update = .{},
                .linux_x86_64 = .{
                    .url = try pkgs.putStr("a"),
                    .hash = try pkgs.putStr("a"),
                },
            },
        },
        .{
            .info = .{
                .version = try pkgs.putStr("0.1.0"),
                .description = .some(try pkgs.putStr("Description 1")),
                .donate = try pkgs.putStrs(&.{"b"}),
            },
            .update = .{},
            .linux_x86_64 = .{
                .url = try pkgs.putStr("a"),
                .hash = try pkgs.putStr("a"),
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
