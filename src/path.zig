pub fn isManPage(path: []const u8) ?[]const u8 {
    var basename = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, basename, "."))
        return null;
    if (std.mem.endsWith(u8, basename, ".gz"))
        basename = basename[0 .. basename.len - ".gz".len];

    var state: enum {
        start,
        number,
        end,
    } = .start;

    for (0..basename.len) |i_forward| {
        const i_backward = (basename.len - i_forward) - 1;
        const c = basename[i_backward];
        switch (state) {
            .start => switch (c) {
                '0'...'9' => state = .number,
                else => return null,
            },
            .number => switch (c) {
                '0'...'9' => {},
                '.' => state = .end,
                else => return null,
            },
            .end => switch (c) {
                // This seems like a binary ending with a version number, like fzf-0.2.2
                '0'...'9' => return null,
                else => return basename[i_backward + 2 ..],
            },
        }
    }

    return null;
}

test isManPage {
    try std.testing.expectEqualDeep(@as(?[]const u8, "1"), isManPage("man/foo.1"));
    try std.testing.expectEqualDeep(@as(?[]const u8, "1"), isManPage("man/foo.1.gz"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/foo.1.2"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/foo.1.2.gz"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/foo.1a"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/foo.1a.gz"));
    try std.testing.expectEqualDeep(@as(?[]const u8, "2"), isManPage("man/foo.1a.2"));
    try std.testing.expectEqualDeep(@as(?[]const u8, "2"), isManPage("man/foo.1a.2.gz"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/foo"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/foo.gz"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/.foo.1"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/.foo.1.gz"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/.foo.1a.2"));
    try std.testing.expectEqualDeep(@as(?[]const u8, null), isManPage("man/.foo.1a.2.gz"));
}

const std = @import("std");
