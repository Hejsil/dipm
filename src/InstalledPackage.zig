version: []const u8,
locations: []const []const u8,

pub fn write(package: Package, name: []const u8, writer: anytype) !void {
    try writer.print("[{s}]\n", .{name});
    try writer.print("version = {s}\n", .{package.version});
    for (package.locations) |install|
        try writer.print("location = {s}\n", .{install});
}

const Package = @This();

const std = @import("std");
