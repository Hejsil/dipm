pub fn fnFromParseAndWrite(
    comptime parseAndWrite: fn (std.mem.Allocator, []const u8) anyerror![]u8,
) fn (void, *std.testing.Smith) anyerror!void {
    return struct {
        fn fuzz(_: void, smith: *std.testing.Smith) !void {
            const gpa = std.testing.allocator;

            const fuzz_input = try gpa.alloc(u8, smith.value(u16));
            smith.bytes(fuzz_input);

            // This fuzz test ensure that once parsed and written out once, doing so again should
            // yield the same result.
            const stage1 = parseAndWrite(gpa, fuzz_input) catch return;
            defer gpa.free(stage1);

            const stage2 = try parseAndWrite(gpa, stage1);
            defer gpa.free(stage2);

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
