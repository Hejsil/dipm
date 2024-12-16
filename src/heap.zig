pub fn freeItems(gpa: std.mem.Allocator, slice: anytype) void {
    for (slice) |item|
        gpa.free(item);
}

test {}

const std = @import("std");
