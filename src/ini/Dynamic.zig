arena: std.heap.ArenaAllocator,
root: Section,
sections: std.StringArrayHashMapUnmanaged(Section),

pub fn deinit(dynamic: Dynamic) void {
    dynamic.arena.deinit();
}

pub fn parse(allocator: std.mem.Allocator, string: []const u8, opt: ParseOptions) !Dynamic {
    var res = Dynamic{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = .{ .properties = .{} },
        .sections = .{},
    };
    const arena = res.arena.allocator();
    errdefer res.deinit();

    var current_section = &res.root;

    var parser = Parser.init(string);
    while (true) {
        const result = parser.next();
        switch (result.kind) {
            .end => break,
            .section => {
                const name = result.section(string).?.name;
                const entry = try res.sections.getOrPut(arena, name);
                if (!entry.found_existing) {
                    entry.value_ptr.* = Section.empty;
                    if (opt.allocate.section.name)
                        entry.key_ptr.* = try arena.dupe(u8, name);
                }

                current_section = entry.value_ptr;
            },
            .property => {
                const property = result.property(string).?;
                const name = if (opt.allocate.property.name) try arena.dupe(u8, property.name) else property.name;
                const value = if (opt.allocate.property.value) try arena.dupe(u8, property.value) else property.value;
                try current_section.properties.append(arena, .{
                    .name = name,
                    .value = value,
                });
            },
            .comment => {},
            .invalid => return error.InvalidString,
        }
    }

    return res;
}

pub fn write(ini: Dynamic, writer: anytype) !void {
    try ini.root.write(writer);
    for (ini.sections.keys(), ini.sections.values(), 0..) |name, section, i| {
        if (i != 0)
            try writer.writeAll("\n");

        try writer.writeAll("[");
        try writer.writeAll(name);
        try writer.writeAll("]\n");
        try section.write(writer);
    }
}

pub const Allocate = struct {
    property: struct {
        name: bool,
        value: bool,
    },
    section: struct {
        name: bool,
    },

    pub const all = Allocate{
        .property = .{ .name = true, .value = true },
        .section = .{ .name = true },
    };
    pub const none = Allocate{
        .property = .{ .name = false, .value = false },
        .section = .{ .name = false },
    };
};

pub const ParseOptions = struct {
    allocate: Allocate = Allocate.all,
};

fn parseAndWrite(allocator: std.mem.Allocator, string: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var dynamic = try parse(allocator, string, .{ .allocate = Allocate.none });
    defer dynamic.deinit();

    try dynamic.write(out.writer());
    return out.toOwnedSlice();
}

fn fuzz(fuzz_input: []const u8) !void {
    const allocator = std.testing.allocator;
    // This fuzz test ensure that once parsed and written out once, doing so again should yield the same result.
    const stage1 = parseAndWrite(allocator, fuzz_input) catch |err| switch (err) {
        // Ignore invalid strings produced by the fuzzer. We don't ignore them in stage 2
        error.InvalidString => return,
        else => |e| return e,
    };
    defer allocator.free(stage1);

    const stage2 = try parseAndWrite(allocator, stage1);
    defer allocator.free(stage2);

    // Use both expectEqualStrings and expectEqualSlices so that we get both the string and hex diff
    std.testing.expectEqualStrings(stage1, stage2) catch {};
    std.testing.expectEqualSlices(u8, stage1, stage2) catch |err| {
        // Also use the testing api to print out the fuzz input
        std.testing.expectEqualStrings(stage2, fuzz_input) catch {};
        std.testing.expectEqualSlices(u8, stage2, fuzz_input) catch {};
        return err;
    };
}

test "Dynamic fuzz" {
    try std.testing.fuzz(fuzz, .{});
}

pub const Section = @import("Section.zig");

const Dynamic = @This();

const Parser = @import("Parser.zig");
const std = @import("std");
