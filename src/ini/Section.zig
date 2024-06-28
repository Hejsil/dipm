properties: std.ArrayListUnmanaged(Property),

pub fn get(section: Section, name: []const u8, opt: GetOptions) ?[]const u8 {
    var i: usize = 0;
    for (section.properties.items) |property| {
        if (std.mem.eql(u8, property.name, name)) {
            if (i == opt.index)
                return property.value;

            i += 1;
        }
    }
    return null;
}

pub const GetOptions = struct {
    index: usize = 0,
};

pub fn write(section: Section, writer: anytype) !void {
    for (section.properties.items) |property| {
        try writer.writeAll(property.name);
        try writer.writeAll(" = ");
        try writer.writeAll(property.value);
        try writer.writeAll("\n");
    }
}

pub const Property = struct {
    name: []const u8,
    value: []const u8,
};

pub const empty = Section{ .properties = .{} };

const Section = @This();
const std = @import("std");
