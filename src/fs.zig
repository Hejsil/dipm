pub fn zigCacheTmpDirPath(allocator: std.mem.Allocator) ![]u8 {
    const tmp_dir_path = try zigCacheTmpPath(allocator);
    defer allocator.free(tmp_dir_path);

    const name = tmpName();
    return std.fs.path.join(allocator, &.{ tmp_dir_path, &name });
}

pub fn zigCacheTmpPath(allocator: std.mem.Allocator) ![]u8 {
    comptime std.debug.assert(builtin.is_test);

    var self_exe_dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe_dir_path = try std.fs.selfExeDirPath(&self_exe_dir_path_buf);

    // The code below assumes that the self exe dir path is in `.zig-cache/o/<hash>` and gets
    // us `.zig-cache/tmp` based on this assumption.
    const o_path = std.fs.path.dirname(self_exe_dir_path) orelse unreachable;
    const zig_cache_path = std.fs.path.dirname(o_path) orelse unreachable;
    return std.fs.path.join(allocator, &.{ zig_cache_path, "tmp" });
}

const tmp_dir_bytes_count = 12;
const tmp_dir_name_len = std.fs.base64_encoder.calcSize(tmp_dir_bytes_count);

pub fn tmpName() [tmp_dir_name_len]u8 {
    var random_bytes: [tmp_dir_bytes_count]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var res: [tmp_dir_name_len]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&res, &random_bytes);
    return res;
}

pub fn tmpDir(dir: std.fs.Dir, open_dir_options: std.fs.Dir.OpenOptions) !std.fs.Dir {
    const name = tmpName();
    return dir.makeOpenPath(&name, open_dir_options);
}

pub const FileType = enum {
    tar_bz2,
    tar_gz,
    tar_xz,
    tar_zst,
    gz,
    tar,
    zip,
    binary,

    pub const extensions = [_]struct { ext: []const u8, file_type: FileType }{
        .{ .ext = ".tar.bz2", .file_type = .tar_bz2 },
        .{ .ext = ".tar.gz", .file_type = .tar_gz },
        .{ .ext = ".tar.xz", .file_type = .tar_xz },
        .{ .ext = ".tar.zst", .file_type = .tar_zst },
        .{ .ext = ".tbz", .file_type = .tar_bz2 },
        .{ .ext = ".tgz", .file_type = .tar_gz },
        .{ .ext = ".tar", .file_type = .tar },
        .{ .ext = ".zip", .file_type = .zip },
        .{ .ext = ".gz", .file_type = .gz },
        .{ .ext = "", .file_type = .binary },
    };

    pub fn fromPath(path: []const u8) FileType {
        for (extensions) |entry| {
            if (std.mem.endsWith(u8, path, entry.ext))
                return entry.file_type;
        }

        return .binary;
    }

    pub fn stripPath(path: []const u8) []const u8 {
        for (extensions) |entry| {
            if (std.mem.endsWith(u8, path, entry.ext))
                return path[0 .. path.len - entry.ext.len];
        }

        return path;
    }
};

pub const ExtractOptions = struct {
    allocator: std.mem.Allocator,

    input_name: []const u8,
    input_file: std.fs.File,

    output_dir: std.fs.Dir,

    node: ?*Progress.Node = null,
};

pub fn extract(options: ExtractOptions) !void {
    const allocator = options.allocator;
    const tar_pipe_options = std.tar.PipeOptions{ .exclude_empty_directories = true };

    var buffered_reader = std.io.bufferedReader(options.input_file.reader());
    var node_reader_state = Progress.nodeReader(buffered_reader.reader(), options.node);
    const node_reader = node_reader_state.reader();

    if (options.node) |p| {
        p.setMax(@min(std.math.maxInt(u32), try options.input_file.getEndPos()));
        p.setCurr(0);
    }

    switch (FileType.fromPath(options.input_name)) {
        .tar_bz2 => {
            // TODO: For now we bail out to an external program for tar.bz2 files.
            //       This makes dipm not self contained, which kinda defeats the points
            var out_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const out_path = try options.output_dir.realpath(".", &out_path_buf);

            var child = std.process.Child.init(
                &.{ "tar", "-xvf", options.input_name, "-C", out_path },
                allocator,
            );
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            try child.spawn();
            _ = try child.wait();
        },
        .tar_gz => {
            var decomp = std.compress.gzip.decompressor(node_reader);
            try std.tar.pipeToFileSystem(options.output_dir, decomp.reader(), tar_pipe_options);
        },
        .tar_zst => {
            const window_len = std.compress.zstd.DecompressorOptions.default_window_buffer_len;
            var window_buffer: [window_len]u8 = undefined;
            var decomp = std.compress.zstd.decompressor(node_reader, .{
                .window_buffer = &window_buffer,
            });
            try std.tar.pipeToFileSystem(options.output_dir, decomp.reader(), tar_pipe_options);
        },
        .tar_xz => {
            var decomp = try std.compress.xz.decompress(allocator, node_reader);
            defer decomp.deinit();
            try std.tar.pipeToFileSystem(options.output_dir, decomp.reader(), tar_pipe_options);
        },
        .gz => {
            const file_base_name = std.fs.path.basename(options.input_name);
            const file_base_name_no_ext = FileType.stripPath(file_base_name);

            const out_file = try options.output_dir.createFile(file_base_name_no_ext, .{});
            defer out_file.close();

            var decomp = std.compress.gzip.decompressor(node_reader);
            var buf: [std.mem.page_size]u8 = undefined;
            while (true) {
                const len = try decomp.reader().read(&buf);
                if (len == 0)
                    break;
                try out_file.writeAll(buf[0..len]);
            }
        },
        .tar => {
            try std.tar.pipeToFileSystem(
                options.output_dir,
                node_reader,
                tar_pipe_options,
            );
        },
        .zip => {
            try std.zip.extract(options.output_dir, options.input_file.seekableStream(), .{});
        },
        .binary => {},
    }
}

pub fn openDirAndFile(
    dir: std.fs.Dir,
    path: []const u8,
    args: struct {
        dir: std.fs.Dir.OpenOptions = .{},
        file: std.fs.File.OpenFlags = .{},
    },
) !struct { std.fs.Dir, std.fs.File } {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var result_dir = try dir.openDir(dir_path, args.dir);
    errdefer result_dir.close();

    const base_name = std.fs.path.basename(path);
    const result_file = try result_dir.openFile(base_name, args.file);
    errdefer result_file.close();

    return .{ result_dir, result_file };
}

pub fn createDirAndFile(
    dir: std.fs.Dir,
    path: []const u8,
    args: struct {
        dir: std.fs.Dir.OpenOptions = .{},
        file: std.fs.File.CreateFlags = .{},
    },
) !struct { std.fs.Dir, std.fs.File } {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var result_dir = try dir.makeOpenPath(dir_path, args.dir);
    errdefer result_dir.close();

    const base_name = std.fs.path.basename(path);
    const result_file = try result_dir.createFile(base_name, args.file);
    errdefer result_file.close();

    return .{ result_dir, result_file };
}

const Progress = @import("Progress.zig");

const builtin = @import("builtin");
const std = @import("std");
