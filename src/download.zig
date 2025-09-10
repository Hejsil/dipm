pub const Result = struct {
    status: std.http.Status,
    hash: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

pub fn download(options: struct {
    /// Client used to download files over the internet. If null then only `file://` schemes can
    /// be "downloaded"
    client: ?*std.http.Client = null,
    uri_str: []const u8,
    writer: *std.Io.Writer,

    progress: Progress.Node = .none,
}) !Result {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    var hashing_writer_buf: [std.heap.page_size_min]u8 = undefined;
    var hashing_writer = options.writer.hashed(&hasher, &hashing_writer_buf);
    const out = &hashing_writer.writer;

    const uri = try std.Uri.parse(options.uri_str);
    const status = if (std.mem.eql(u8, uri.scheme, "file")) blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try uri.path.toRaw(&path_buf);
        const file = try std.fs.cwd().openFile(path, .{});

        var file_buf: [std.heap.page_size_min]u8 = undefined;
        var file_reader = file.reader(&file_buf);
        _ = try file_reader.interface.streamRemaining(out);
        try out.flush();
        break :blk .ok;
    } else blk: {
        // No downloading using http from tests
        std.debug.assert(!builtin.is_test);
        const client = options.client.?;

        var request = try client.request(.GET, uri, .{
            .keep_alive = false,
        });
        defer request.deinit();

        try request.sendBodiless();

        var redirect_buffer: [std.heap.page_size_min]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        if (response.head.content_length) |length|
            options.progress.set(.{ .max = @truncate(length) });

        var transfer_buffer: [std.heap.page_size_min]u8 = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

        while (true) {
            const amount = body_reader.stream(out, .unlimited) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            options.progress.advance(@truncate(amount));
        }

        break :blk response.head.status;
    };

    try out.flush();

    var result = Result{
        .status = status,
        .hash = undefined,
    };
    hasher.final(&result.hash);
    return result;
}

test {
    _ = Progress;
}

const Progress = @import("Progress.zig");

const builtin = @import("builtin");
const std = @import("std");
