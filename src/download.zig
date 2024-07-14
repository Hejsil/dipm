pub const Result = struct {
    status: std.http.Status,
    hash: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

pub fn download(
    client: *std.http.Client,
    uri_str: []const u8,
    progress: ?*Progress.Node,
    writer: anytype,
) !Result {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var hashing_writer = std.compress.hashedWriter(writer, &hasher);
    const out = hashing_writer.writer();

    const uri = try std.Uri.parse(uri_str);
    const status = if (std.mem.eql(u8, uri.scheme, "file")) blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{raw}", .{uri.path});
        const file = try std.fs.cwd().openFile(path, .{});
        try io.pipe(file.reader(), out);
        break :blk .ok;
    } else blk: {
        var header_buffer: [std.mem.page_size]u8 = undefined;
        var request = try client.open(.GET, uri, .{
            .server_header_buffer = &header_buffer,
            .keep_alive = false,
        });
        defer request.deinit();

        try request.send();
        try request.finish();
        try request.wait();

        if (progress != null and request.response.content_length != null) {
            const content_length = request.response.content_length.?;
            progress.?.setMax(@min(content_length, std.math.maxInt(u32)));
        }

        var node_writer = Progress.nodeWriter(out, progress);
        try io.pipe(request.reader(), node_writer.writer());
        break :blk request.response.status;
    };

    var result = Result{
        .status = status,
        .hash = undefined,
    };
    hasher.final(&result.hash);
    return result;
}

test {
    _ = Progress;

    _ = io;
}

const Progress = @import("Progress.zig");

const io = @import("io.zig");

const std = @import("std");
