pub const Result = struct {
    status: std.http.Status,
    hash: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

pub fn download(writer: anytype, options: struct {
    /// Client used to download files over the internet. If null then only `file://` schemes can
    /// be "downloaded"
    client: ?*std.http.Client = null,
    uri_str: []const u8,

    progress: Progress.Node = .none,
}) !Result {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var hashing_writer = std.compress.hashedWriter(writer, &hasher);
    const out = hashing_writer.writer();

    const uri = try std.Uri.parse(options.uri_str);
    const status = if (std.mem.eql(u8, uri.scheme, "file")) blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{raw}", .{uri.path});
        const file = try std.fs.cwd().openFile(path, .{});
        try io.pipe(file.reader(), out);
        break :blk .ok;
    } else blk: {
        const client = options.client orelse return error.NoHttpClientProvided;

        var header_buffer: [1024 * 8]u8 = undefined;
        var request = try client.open(.GET, uri, .{
            .server_header_buffer = &header_buffer,
            .keep_alive = false,
        });
        defer request.deinit();

        try request.send();
        try request.finish();
        try request.wait();

        if (request.response.content_length) |length|
            options.progress.setMax(@min(length, std.math.maxInt(u32)));

        var node_writer = Progress.nodeWriter(out, options.progress);
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
