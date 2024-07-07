pub fn pipe(reader: anytype, writer: anytype) !void {
    var buf: [std.mem.page_size]u8 = undefined;
    while (true) {
        const len = try reader.read(&buf);
        if (len == 0)
            break;

        try writer.writeAll(buf[0..len]);
    }
}

const std = @import("std");
