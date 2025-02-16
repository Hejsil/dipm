pub fn fnFromParseAndWrite(
    comptime parseAndWrite: fn (std.mem.Allocator, []const u8) anyerror![]u8,
) fn (void, []const u8) anyerror!void {
    return struct {
        fn fuzz(_: void, fuzz_input: []const u8) !void {
            const allocator = std.testing.allocator;
            // This fuzz test ensure that once parsed and written out once, doing so again should
            // yield the same result.
            const stage1 = parseAndWrite(allocator, fuzz_input) catch return;
            defer allocator.free(stage1);

            const stage2 = try parseAndWrite(allocator, stage1);
            defer allocator.free(stage2);

            std.testing.expectEqualStrings(stage1, stage2) catch |err| {
                // On failure, also do `expectEqualSlices` to get a hex diff
                std.testing.expectEqualSlices(u8, stage1, stage2) catch {};

                // Also use the testing api to print out the fuzz input
                std.testing.expectEqualStrings(stage2, fuzz_input) catch {};
                std.testing.expectEqualSlices(u8, stage2, fuzz_input) catch {};
                return err;
            };
        }
    }.fuzz;
}

const std = @import("std");
