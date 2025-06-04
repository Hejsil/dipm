pub fn parseDuration(str: []const u8) !u64 {
    const Suffix = struct {
        str: []const u8,
        mult: u64,
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

    return (try std.fmt.parseUnsigned(u8, trimmed, 10)) * mult;
}

test parseDuration {
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), try parseDuration("2"));
    try std.testing.expectEqual(@as(u64, 4 * std.time.ns_per_s), try parseDuration("4s"));
    try std.testing.expectEqual(@as(u64, 6 * std.time.ns_per_min), try parseDuration("6m"));
    try std.testing.expectEqual(@as(u64, 8 * std.time.ns_per_hour), try parseDuration("8h"));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_day), try parseDuration("10d"));
}

test {}

const std = @import("std");
