pub fn tmpDirPath(allocator: std.mem.Allocator) ![]u8 {
    const tmp_dir_path = try zigCacheTmpPath(allocator);
    defer allocator.free(tmp_dir_path);

    const name = tmpDirName();
    return std.fs.path.join(allocator, &.{ tmp_dir_path, &name });
}

pub fn zigCacheTmpPath(allocator: std.mem.Allocator) ![]u8 {
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

pub fn tmpDirName() [tmp_dir_name_len]u8 {
    var random_bytes: [tmp_dir_bytes_count]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var res: [tmp_dir_name_len]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&res, &random_bytes);
    return res;
}

const std = @import("std");
