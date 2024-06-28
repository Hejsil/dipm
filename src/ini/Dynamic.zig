arena: std.heap.ArenaAllocator,
root: Section,
sections: std.StringArrayHashMapUnmanaged(Section),

pub fn deinit(dynamic: Dynamic) void {
    dynamic.arena.deinit();
}

pub const GetOrPutResult = struct {
    found_existing: bool,
    section: *Section,
};

pub fn getOrPutSection(dynamic: *Dynamic, name: []const u8) !GetOrPutResult {
    const entry = try dynamic.sections.getOrPut(dynamic.arena.allocator(), name);
    if (!entry.found_existing)
        entry.value_ptr.* = Section.empty;

    return .{
        .found_existing = entry.found_existing,
        .section = entry.value_ptr,
    };
}

pub fn addProperty(dynamic: *Dynamic, section: *Section, name: []const u8, value: []const u8) !void {
    try section.properties.append(dynamic.arena.allocator(), .{ .name = name, .value = value });
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
            .invalid => unreachable, // TODO: Error
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

pub const Section = @import("Section.zig");

const Dynamic = @This();

const Parser = @import("Parser.zig");
const std = @import("std");
