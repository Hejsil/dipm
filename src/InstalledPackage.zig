version: []const u8,
location: []const []const u8,

pub fn write(pkg: Package, name: []const u8, writer: *std.Io.Writer) !void {
    try writer.print("[{s}]\n", .{name});
    try writer.print("version = {s}\n", .{pkg.version});
    for (pkg.location) |install|
        try writer.print("location = {s}\n", .{install});
}

const Package = @This();

test {
    _ = Strings;
}

const Strings = @import("Strings.zig");

const std = @import("std");
