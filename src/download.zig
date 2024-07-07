pub fn download(client: *std.http.Client, uri_str: []const u8, writer: anytype) !void {
    const uri = try std.Uri.parse(uri_str);
    if (std.mem.eql(u8, uri.scheme, "file")) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{raw}", .{uri.path});
        const file = try std.fs.cwd().openFile(path, .{});
        return io.pipe(file.reader(), writer);
    }

    var header_buffer: [std.mem.page_size]u8 = undefined;
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
    });
    defer request.deinit();

    try request.send();
    try request.finish();
    try request.wait();

    if (request.response.status != .ok)
        return error.HttpServerRepliedWithUnsucessfulResponse;

    return io.pipe(request.reader(), writer);
}

test {
    _ = io;
}

const io = @import("io.zig");

const std = @import("std");
