version: Strings.Index,
location: Strings.Indices,

pub fn write(pkg: Package, strings: Strings, name: []const u8, writer: anytype) !void {
    try writer.print("[{s}]\n", .{name});
    try writer.print("version = {s}\n", .{pkg.version.get(strings)});
    for (pkg.location.get(strings)) |install|
        try writer.print("location = {s}\n", .{install.get(strings)});
}

const Package = @This();

test {
    _ = Strings;
}

const Strings = @import("Strings.zig");

const std = @import("std");
