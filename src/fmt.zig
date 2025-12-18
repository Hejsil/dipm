pub fn parseDuration(str: []const u8) !std.Io.Duration {
    const Suffix = struct {
        str: []const u8,
        mult: i96,
    };

    const suffixes = [_]Suffix{
        .{ .str = "s", .mult = std.time.ns_per_s },
        .{ .str = "m", .mult = std.time.ns_per_min },
        .{ .str = "h", .mult = std.time.ns_per_hour },
        .{ .str = "d", .mult = std.time.ns_per_day },
    };
    const trimmed, const mult = for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, str, suffix.str)) {
            break .{ str[0 .. str.len - suffix.str.len], suffix.mult };
        }
    } else .{ str, std.time.ns_per_s };

    const base = try std.fmt.parseUnsigned(u32, trimmed, 10);
    return .fromNanoseconds(base * mult);
}

test parseDuration {
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(2), try parseDuration("2"));
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(4), try parseDuration("4s"));
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(6 * 60), try parseDuration("6m"));
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(8 * 60 * 60), try parseDuration("8h"));
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(10 * 60 * 60 * 24), try parseDuration("10d"));
}

test {}

const std = @import("std");
