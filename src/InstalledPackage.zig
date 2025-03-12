version: Strings.Index,
location: Strings.Indices,

pub fn write(package: Package, strings: Strings, name: []const u8, writer: anytype) !void {
    try writer.print("[{s}]\n", .{name});
    try writer.print("version = {s}\n", .{strings.getStr(package.version)});
    for (strings.getIndices(package.location)) |install|
        try writer.print("location = {s}\n", .{strings.getStr(install)});
}

const Package = @This();

test {
    _ = Strings;
}

const Strings = @import("Strings.zig");

const std = @import("std");
