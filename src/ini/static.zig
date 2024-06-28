pub fn parse(comptime T: type, allocator: std.mem.Allocator, string: []const u8, opt: ParseOptions) !T {}

pub fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,
    };
}

pub const Allocate = struct {
    property: struct {
        value: bool,
    },

    pub const all = Allocate{
        .property = .{ .value = true },
    };
};

pub const ParseOptions = struct {
    allocate: Allocate = Allocate.all,
};

const std = @import("std");
