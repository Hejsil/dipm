pub fn download(
    client: *std.http.Client,
    uri_str: []const u8,
    progress: ?*Progress.Node,
    writer: anytype,
) !std.http.Status {
    const uri = try std.Uri.parse(uri_str);
    if (std.mem.eql(u8, uri.scheme, "file")) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{raw}", .{uri.path});
        const file = try std.fs.cwd().openFile(path, .{});
        try io.pipe(file.reader(), writer);
        return .ok;
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
        return request.response.status;

    if (progress != null and request.response.content_length != null) {
        const content_length = request.response.content_length.?;
        progress.?.setMax(@min(content_length, std.math.maxInt(u32)));
    }
    var node_writer = Progress.nodeWriter(writer, progress);

    try io.pipe(request.reader(), node_writer.writer());
    return request.response.status;
}

test {
    _ = Progress;

    _ = io;
}

const Progress = @import("Progress.zig");

const io = @import("io.zig");

const std = @import("std");
