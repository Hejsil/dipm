info: Info,
update: Update,
linux_x86_64: Install,

const Info = struct {
    version: []const u8,
};

const Update = struct {
    github: []const u8,
};

const Install = struct {
    url: []const u8,
    hash: []const u8,
    bin: []const []const u8,
    lib: []const []const u8,
    share: []const []const u8,
};

pub const Specific = struct {
    name: []const u8,
    info: Info,
    update: Update,
    install: Install,
};

pub fn specific(
    package: Package,
    name: []const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
) ?Specific {
    const install = switch (os) {
        .linux => switch (arch) {
            .x86_64 => package.linux_x86_64,
            else => return null,
        },
        else => return null,
    };

    if (install.url.len == 0 or install.hash.len == 0)
        return null;

    return .{
        .name = name,
        .info = package.info,
        .update = package.update,
        .install = install,
    };
}

pub fn write(package: Package, name: []const u8, writer: anytype) !void {
    try writer.print("[{s}.info]\n", .{name});
    try writer.print("version = {s}\n\n", .{package.info.version});
    try writer.print("[{s}.update]\n", .{name});
    try writer.print("github = {s}\n\n", .{package.update.github});
    try writer.print("[{s}.linux_x86_64]\n", .{name});

    for (package.linux_x86_64.bin) |install|
        try writer.print("install_bin = {s}\n", .{install});
    for (package.linux_x86_64.lib) |install|
        try writer.print("install_lib = {s}\n", .{install});
    for (package.linux_x86_64.share) |install|
        try writer.print("install_share = {s}\n", .{install});

    try writer.print("url = {s}\n", .{package.linux_x86_64.url});
    try writer.print("hash = {s}\n", .{package.linux_x86_64.hash});
}

const Package = @This();

const std = @import("std");
