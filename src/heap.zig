pub fn freeItems(allocator: std.mem.Allocator, slice: anytype) void {
    for (slice) |item|
        allocator.free(item);
}

test {}

const std = @import("std");
