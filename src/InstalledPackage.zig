version: Strings.Index,
location: Strings.Indices,

pub fn write(pkg: Package, strs: Strings, name: []const u8, writer: anytype) !void {
    try writer.print("[{s}]\n", .{name});
    try writer.print("version = {s}\n", .{pkg.version.get(strs)});
    for (pkg.location.get(strs)) |install|
        try writer.print("location = {s}\n", .{install.get(strs)});
}

const Package = @This();

test {
    _ = Strings;
}

const Strings = @import("Strings.zig");

const std = @import("std");
