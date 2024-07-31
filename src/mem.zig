pub fn sortLessThan(comptime T: type) fn (void, []const T, []const T) bool {
    return struct {
        fn lessThan(_: void, a: []const T, b: []const T) bool {
            return std.mem.lessThan(T, a, b);
        }
    }.lessThan;
}

test {}

const std = @import("std");
