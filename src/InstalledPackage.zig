version: Strings.Index,
location: []const Strings.Index = &.{},

pub fn write(package: Package, strings: Strings, name: []const u8, writer: anytype) !void {
    try writer.print("[{s}]\n", .{name});
    try writer.print("version = {s}\n", .{strings.get(package.version)});
    for (package.location) |install|
        try writer.print("location = {s}\n", .{strings.get(install)});
}

const Package = @This();

test {
    _ = Strings;
}

const Strings = @import("Strings.zig");

const std = @import("std");
