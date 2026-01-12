pub const ZigCacheTmpDir = struct {
    zig_cache_path: []const u8,
    tmp_subdir_name: []const u8,
    dir_name: [tmp_dir_name_len]u8,
    dir: std.Io.Dir,

    pub fn deleteAndClose(dir: *ZigCacheTmpDir, io: std.Io) void {
        defer dir.dir.close(io);

        var parent_dir = dir.dir.openDir(io, "..", .{}) catch return;
        defer parent_dir.close(io);

        parent_dir.deleteTree(io, &dir.dir_name) catch {};
    }

    pub fn path(dir: ZigCacheTmpDir, gpa: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(gpa, &.{
            dir.zig_cache_path,
            dir.tmp_subdir_name,
            &dir.dir_name,
        });
    }
};

pub fn zigCacheTmpDir(io: std.Io, open_dir_options: std.Io.Dir.OpenOptions) !ZigCacheTmpDir {
    const zig_cache_path = zigCachePath(io);
    var zig_cache_dir = try std.Io.Dir.cwd().createDirPathOpen(io, zig_cache_path, .{});
    defer zig_cache_dir.close(io);

    const tmp_subdir_name = "tmp";
    var zig_cache_tmp_dir = try zig_cache_dir.createDirPathOpen(io, tmp_subdir_name, .{});
    defer zig_cache_tmp_dir.close(io);

    var res = try tmpDir(io, zig_cache_tmp_dir, open_dir_options);
    errdefer res.dir.close(io);

    return .{
        .zig_cache_path = zig_cache_path,
        .tmp_subdir_name = tmp_subdir_name,
        .dir_name = res.name,
        .dir = res.dir,
    };
}

pub fn zigCacheTmpDirPath(io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    var tmp_dir = try zigCacheTmpDir(io, .{});
    defer tmp_dir.dir.close(io);

    return tmp_dir.path(gpa);
}

var zig_cache_path_io: std.Io = undefined;
var zig_cache_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var zig_cache_path_len: usize = 0;
var zig_cache_path_once = std.once(zigCachePathOnce);

fn zigCachePathOnce() void {
    comptime std.debug.assert(builtin.is_test);

    var self_exe_dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe_dir_path = blk: {
        const len = std.process.executableDirPath(zig_cache_path_io, &self_exe_dir_path_buf) catch
            break :blk ".zig-cache/o/aaaa";
        break :blk self_exe_dir_path_buf[0..len];
    };

    // The code below assumes that the self exe dir path is in `.zig-cache/o/<hash>` and gets
    // us `.zig-cache/tmp` based on this assumption.
    const o_path = std.fs.path.dirname(self_exe_dir_path) orelse unreachable;
    const zig_cache_path = std.fs.path.dirname(o_path) orelse unreachable;

    zig_cache_path_len = zig_cache_path.len;
    @memcpy(zig_cache_path_buf[0..zig_cache_path.len], zig_cache_path);
}

pub fn zigCachePath(io: std.Io) []const u8 {
    zig_cache_path_io = io;
    zig_cache_path_once.call();
    return zig_cache_path_buf[0..zig_cache_path_len];
}

const tmp_dir_bytes_count = 12;
const tmp_dir_name_len = std.fs.base64_encoder.calcSize(tmp_dir_bytes_count);

pub fn tmpName(io: std.Io) [tmp_dir_name_len]u8 {
    var random_bytes: [tmp_dir_bytes_count]u8 = undefined;
    io.random(&random_bytes);

    var res: [tmp_dir_name_len]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&res, &random_bytes);
    return res;
}

pub const TmpDir = struct {
    dir: std.Io.Dir,
    name: [tmp_dir_name_len]u8,

    pub fn deleteAndClose(dir: *TmpDir, io: std.Io) void {
        defer dir.dir.close(io);

        var parent_dir = dir.dir.openDir(io, "..", .{}) catch return;
        defer parent_dir.close(io);

        parent_dir.deleteTree(io, &dir.name) catch {};
    }
};

pub fn tmpDir(io: std.Io, dir: std.Io.Dir, open_dir_options: std.Io.Dir.OpenOptions) !TmpDir {
    while (true) {
        const name = tmpName(io);
        dir.createDir(io, &name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        var res = dir.openDir(io, &name, open_dir_options) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        errdefer res.close();

        return .{ .dir = res, .name = name };
    }
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
    gpa: std.mem.Allocator,
    io: std.Io,

    input_name: []const u8,
    input_file: std.Io.File,

    output_dir: std.Io.Dir,

    node: Progress.Node = .none,
};

pub fn extract(options: ExtractOptions) !void {
    const io = options.io;
    const tar_pipe_options = std.tar.PipeOptions{ .exclude_empty_directories = true };

    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var input_file_reader_buf: [std.heap.page_size_min]u8 = undefined;
    var input_file_reader = options.node.fileReader(options.input_file, options.io, &input_file_reader_buf);
    const reader = &input_file_reader.file.interface;

    switch (FileType.fromPath(options.input_name)) {
        .tar_bz2 => {
            // TODO: For now we bail out to an external program for tar.bz2 files.
            //       This makes dipm not self contained, which kinda defeats the points
            var out_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const out_path_len = try options.output_dir.realPath(io, &out_path_buf);

            var child = try std.process.spawn(io, .{
                .argv = &.{ "tar", "-xvf", options.input_name, "-C", out_path_buf[0..out_path_len] },
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .pipe,
            });
            _ = try child.wait(io);
        },
        .tar_gz => {
            var decomp = std.compress.flate.Decompress.init(reader, .gzip, &decomp_buf);
            try std.tar.pipeToFileSystem(io, options.output_dir, &decomp.reader, tar_pipe_options);
        },
        .tar_zst => {
            const buffer_size = std.compress.zstd.default_window_len +
                std.compress.zstd.block_size_max;
            var buffer: [buffer_size]u8 = undefined;
            var decomp = std.compress.zstd.Decompress.init(reader, &buffer, .{});
            try std.tar.pipeToFileSystem(io, options.output_dir, &decomp.reader, tar_pipe_options);
        },
        .tar_xz => {
            var decomp = try std.compress.xz.Decompress.init(reader, options.gpa, &.{});
            defer decomp.deinit();

            try std.tar.pipeToFileSystem(io, options.output_dir, &decomp.reader, tar_pipe_options);
        },
        .gz => {
            const file_base_name = std.fs.path.basename(options.input_name);
            const file_base_name_no_ext = FileType.stripPath(file_base_name);

            const out_file = try options.output_dir.createFile(io, file_base_name_no_ext, .{});
            defer out_file.close(io);

            var out_file_writer_buf: [std.heap.page_size_min]u8 = undefined;
            var out_file_writer = out_file.writer(io, &out_file_writer_buf);
            var decomp = std.compress.flate.Decompress.init(reader, .gzip, &decomp_buf);
            _ = try decomp.reader.streamRemaining(&out_file_writer.interface);
            try out_file_writer.end();
        },
        .tar => try std.tar.pipeToFileSystem(io, options.output_dir, reader, tar_pipe_options),
        .zip => try std.zip.extract(options.output_dir, &input_file_reader.file, .{}),
        .binary => {},
    }
}

fn testOneExtract(file_type: FileType, files: []const std.Io.Dir.WriteFileOptions) !void {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    const arena = arena_state.allocator();
    defer arena_state.deinit();

    const compressed_file_name = switch (file_type) {
        .zip => "compressed.zip",
        .tar_xz => "compressed.tar.xz",
        .tar_bz2 => "compressed.tar.bz2",
        .tar_gz => "compressed.tar.gz",
        .tar_zst => "compressed.tar.zst",
        .tar => "compressed.tar",
        .gz => blk: {
            if (files.len != 1) return error.SkipZigTest;
            break :blk try std.fmt.allocPrint(arena, "{s}.gz", .{files[0].sub_path});
        },
        .binary => blk: {
            if (files.len != 1) return error.SkipZigTest;
            break :blk files[0].sub_path;
        },
    };

    var tmp_dir = try zigCacheTmpDir(io, .{});
    defer tmp_dir.deleteAndClose(io);

    var args = std.ArrayList([]const u8){};
    try args.ensureTotalCapacity(arena, 4 + files.len);

    for (files) |file| {
        try tmp_dir.dir.writeFile(io, file);
        args.appendAssumeCapacity(file.sub_path);
    }

    switch (file_type) {
        .gz => try args.insertSlice(arena, 0, &.{"gzip"}),
        .zip => try args.insertSlice(arena, 0, &.{ "zip", compressed_file_name }),
        .tar_xz => try args.insertSlice(arena, 0, &.{ "tar", "-cJf", compressed_file_name }),
        .tar_bz2 => try args.insertSlice(arena, 0, &.{ "tar", "-cjf", compressed_file_name }),
        .tar_gz => try args.insertSlice(arena, 0, &.{ "tar", "-czf", compressed_file_name }),
        .tar_zst => try args.insertSlice(arena, 0, &.{ "tar", "--zstd", "-cf", compressed_file_name }),
        .tar => try args.insertSlice(arena, 0, &.{ "tar", "-cf", compressed_file_name }),
        .binary => {},
    }
    const res = switch (file_type) {
        .gz, .zip, .tar_xz, .tar_bz2, .tar_gz, .tar_zst, .tar => std.process.run(arena, io, .{
            .argv = args.items,
            .cwd_dir = tmp_dir.dir,
        }),
        .binary => std.process.RunResult{
            .term = .{ .exited = 0 },
            .stdout = &.{},
            .stderr = &.{},
        },
    } catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    switch (res.term) {
        .exited => |e| if (e != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    switch (file_type) {
        .gz, .binary => {},
        else => {
            for (files) |file| {
                try tmp_dir.dir.deleteFile(io, file.sub_path);
            }
        },
    }

    // TODO: Remove realpath once bz2 decomp is not outsourced to `tar` command
    const compressed_file_path = try tmp_dir.dir.realPathFileAlloc(io, compressed_file_name, arena);
    const compressed_file = try tmp_dir.dir.openFile(io, compressed_file_path, .{});
    defer compressed_file.close(io);

    try extract(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .input_file = compressed_file,
        .input_name = compressed_file_path,
        .output_dir = tmp_dir.dir,
    });

    for (files) |file| {
        const uncompressed = try tmp_dir.dir.readFileAlloc(io, file.sub_path, arena, .unlimited);
        try std.testing.expectEqualSlices(u8, file.data, uncompressed);
    }
}

fn testExtract(file_type: FileType) !void {
    const bytes: [1024 * 1024 * 8]u8 = @splat(0);
    try testOneExtract(file_type, &.{.{ .sub_path = "binary1", .data = bytes[0..0] }});
    try testOneExtract(file_type, &.{.{ .sub_path = "binary1", .data = bytes[0..124] }});
    try testOneExtract(file_type, &.{.{ .sub_path = "binary1", .data = bytes[0..] }});
    try testOneExtract(file_type, &.{
        .{ .sub_path = "binary1", .data = bytes[0..] },
        .{ .sub_path = "binary2", .data = bytes[0..] },
        .{ .sub_path = "binary3", .data = bytes[0..] },
        .{ .sub_path = "binary4", .data = bytes[0..] },
        .{ .sub_path = "binary5", .data = bytes[0..] },
        .{ .sub_path = "binary6", .data = bytes[0..] },
    });
}

// zig fmt: off
test "extract.tar_bz2" { try testExtract(.tar_bz2); }
test "extract.tar_gz"  { try testExtract(.tar_gz);  }
test "extract.tar_xz"  { try testExtract(.tar_xz);  }
test "extract.tar_zst" { try testExtract(.tar_zst); }
test "extract.gz"      { try testExtract(.gz);      }
test "extract.tar"     { try testExtract(.tar);     }
test "extract.zip"     { try testExtract(.zip);     }
test "extract.binary"  { try testExtract(.binary);  }
// zig fmt: on

pub fn openDirAndFile(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    options: struct {
        dir: std.Io.Dir.OpenOptions = .{},
        file: std.Io.File.OpenFlags = .{},
    },
) !struct { std.Io.Dir, std.Io.File } {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var result_dir = try dir.openDir(io, dir_path, options.dir);
    errdefer result_dir.close(io);

    const base_name = std.fs.path.basename(path);
    const result_file = try result_dir.openFile(io, base_name, options.file);
    errdefer result_file.close(io);

    return .{ result_dir, result_file };
}

pub fn createDirAndFile(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    options: struct {
        dir: std.Io.Dir.CreateDirPathOpenOptions = .{},
        file: std.Io.File.CreateFlags = .{},
    },
) !struct { std.Io.Dir, std.Io.File } {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var result_dir = try dir.createDirPathOpen(io, dir_path, options.dir);
    errdefer result_dir.close(io);

    const base_name = std.fs.path.basename(path);
    const result_file = try result_dir.createFile(io, base_name, options.file);
    errdefer result_file.close(io);

    return .{ result_dir, result_file };
}

pub fn copyTree(io: std.Io, from_dir: std.Io.Dir, to_dir: std.Io.Dir) !void {
    var iter = from_dir.iterate();
    while (try iter.next(io)) |entry| switch (entry.kind) {
        .directory => {
            var child_from_dir = try from_dir.openDir(io, entry.name, .{ .iterate = true });
            defer child_from_dir.close(io);
            var child_to_dir = try to_dir.createDirPathOpen(io, entry.name, .{});
            defer child_to_dir.close(io);

            try copyTree(io, child_from_dir, child_to_dir);
        },
        .file => try from_dir.copyFile(entry.name, to_dir, entry.name, io, .{}),
        .sym_link => {
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const link_len = try from_dir.readLink(io, entry.name, &link_buf);
            try to_dir.symLink(io, link_buf[0..link_len], entry.name, .{});
        },
        .block_device,
        .character_device,
        .named_pipe,
        .unix_domain_socket,
        .whiteout,
        .door,
        .event_port,
        .unknown,
        => return error.CouldNotCopyEntireTree,
    };
}

pub fn exists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    _ = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };

    return true;
}

test {
    _ = Progress;
}

const Progress = @import("Progress.zig");

const builtin = @import("builtin");
const std = @import("std");
