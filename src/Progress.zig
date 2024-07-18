nodes: []Node,
maximum_node_name_len: u32,

pub const Node = struct {
    inner: Inner,
    // TODO: This can probably be done in a lock free way using a certain value of `max` as a
    //       "locked" value, and spinning until we can get it
    lock: std.Thread.Mutex,

    pub const Inner = struct {
        name: ?[]const u8 = null,
        curr: u32 = 0,
        max: u32 = 0,
    };

    const none = Node{
        .inner = .{},
        .lock = .{},
    };

    pub fn advance(node: *Node, amount: u32) void {
        node.lock.lock();
        node.inner.curr += amount;
        node.lock.unlock();
    }

    pub fn setMax(node: *Node, max: u32) void {
        node.lock.lock();
        node.inner.max = max;
        node.lock.unlock();
    }

    pub fn setCurr(node: *Node, curr: u32) void {
        node.lock.lock();
        node.inner.curr = curr;
        node.lock.unlock();
    }

    fn get(node: *Node) Inner {
        node.lock.lock();
        const res = node.inner;
        node.lock.unlock();
        return res;
    }

    fn aquire(node: *Node, inner: Inner) bool {
        node.lock.lock();
        defer node.lock.unlock();

        if (node.inner.name != null)
            return false;

        node.inner = inner;
        return true;
    }

    fn release(node: *Node) void {
        node.lock.lock();
        node.inner = .{};
        node.lock.unlock();
    }
};

pub fn init(options: Options) !Progress {
    const allocator = options.allocator;
    const nodes = try allocator.alloc(Node, options.maximum_nodes);
    errdefer allocator.free(nodes);

    @memset(nodes, Node.none);

    return .{
        .nodes = nodes,
        .maximum_node_name_len = options.maximum_node_name_len,
    };
}

pub const Options = struct {
    allocator: std.mem.Allocator,
    maximum_node_name_len: u32,
    maximum_nodes: u32 = 128,
};

pub fn deinit(progress: *Progress, allocator: std.mem.Allocator) void {
    allocator.free(progress.nodes);
    progress.* = undefined;
}

pub fn start(progress: Progress, name: []const u8, max: u32) ?*Node {
    for (progress.nodes) |*node| {
        if (node.aquire(.{ .name = name, .max = max }))
            return node;
    }
    return null;
}

pub fn end(progress: Progress, node: ?*Node) void {
    _ = progress;
    if (node) |n| n.release();
}

const clear = "\x1b[J";
const finish_sync = "\x1b[?2026l";
const start_sync = "\x1b[?2026h";
const up_one_line = "\x1bM";

pub fn renderToTty(progress: Progress, tty: std.fs.File) !void {
    if (!tty.supportsAnsiEscapeCodes())
        return;

    var winsize: std.posix.winsize = .{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const err = std.posix.system.ioctl(tty.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(err) != .SUCCESS)
        return;

    // The -2 here is so that the PS1 is not scrolled off the top of the terminal.
    // one because we keep the cursor on the next line
    // one more to account for the PS1
    const height = winsize.ws_row -| 2;

    var buffered_tty = std.io.bufferedWriter(tty.writer());
    const writer = buffered_tty.writer();

    try writer.writeAll(start_sync ++ clear);
    const nodes_printed = try progress.render(writer, .{
        .width = winsize.ws_col,
        .height = height,
        .escapes = Escapes.ansi,
    });

    if (nodes_printed != 0) {
        try writer.writeAll("\r");
        try writer.writeBytesNTimes(up_one_line, nodes_printed);
    }

    try writer.writeAll(finish_sync);
    return buffered_tty.flush();
}

pub fn cleanupTty(progress: Progress, tty: std.fs.File) !void {
    _ = progress;

    if (tty.supportsAnsiEscapeCodes())
        try tty.writeAll(clear);
}

pub const RenderOptions = struct {
    width: usize,
    height: usize,
    escapes: Escapes = Escapes.none,
};

pub fn render(progress: Progress, writer: anytype, options: RenderOptions) !usize {
    try writer.writeAll(options.escapes.bold);

    var nodes_printed: usize = 0;
    for (progress.nodes) |*node_ptr| {
        if (nodes_printed == options.height)
            break;

        const node = node_ptr.get();
        const node_name = node.name orelse continue;

        nodes_printed += 1;
        const node_name_len = @min(node_name.len, options.width, progress.maximum_node_name_len);

        const bar_start = " [";
        const bar_end = "]";

        if (node_name.len == node_name_len) {
            try writer.writeAll(node_name);
        } else switch (node_name_len) {
            0...3 => try writer.writeByteNTimes('.', node_name_len),
            else => {
                try writer.writeAll(node_name[0 .. node_name_len - 3]);
                try writer.writeAll("...");
            },
        }

        var remaining_width = options.width -| progress.maximum_node_name_len;
        if (remaining_width < 4) {
            try writer.writeAll(options.escapes.reset);
            try writer.writeAll("\n");
            continue;
        }
        if (remaining_width >= 4) {
            const curr: u64 = node.curr;
            const max: u64 = node.max;
            const percent = (curr * 100) / max;
            try writer.writeByteNTimes(' ', progress.maximum_node_name_len - node_name_len);
            try writer.print(" {d:>3}", .{percent});
            remaining_width -= 4;
        }
        if (remaining_width >= 1) {
            try writer.writeAll("%");
            remaining_width -= 1;
        }
        if (remaining_width >= bar_start.len + bar_end.len + 1) {
            remaining_width -= bar_start.len + bar_end.len;
            const filled = (node.curr * remaining_width) / node.max;
            try writer.writeAll(bar_start);
            try writer.writeByteNTimes('=', @min(filled, remaining_width));
            try writer.writeByteNTimes(' ', remaining_width -| filled);
            try writer.writeAll(bar_end);
        }

        try writer.writeAll("\n");
    }

    try writer.writeAll(options.escapes.reset);
    return nodes_printed;
}

// TODO: Bad name, but what is a better one? :thinking:
pub fn NodeWriter(comptime Child: type) type {
    return struct {
        child: Child,
        node: ?*Node,

        pub const Error = Child.Error;
        pub const Writer = std.io.Writer(*Self, Error, write);

        const Self = @This();

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            const res = try self.child.write(bytes);
            if (self.node) |node|
                node.advance(@min(res, std.math.maxInt(u32)));

            return res;
        }
    };
}

pub fn nodeWriter(child: anytype, node: ?*Node) NodeWriter(@TypeOf(child)) {
    return .{ .child = child, .node = node };
}

// TODO: Bad name, but what is a better one? :thinking:
pub fn NodeReader(comptime Child: type) type {
    return struct {
        child: Child,
        node: ?*Node,

        pub const Error = Child.Error;
        pub const Reader = std.io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        pub fn read(self: *Self, buf: []u8) Error!usize {
            const res = try self.child.read(buf);
            if (self.node) |node|
                node.advance(@min(res, std.math.maxInt(u32)));

            return res;
        }
    };
}

pub fn nodeReader(child: anytype, node: ?*Node) NodeReader(@TypeOf(child)) {
    return .{ .child = child, .node = node };
}

fn expectRender(
    expected: []const u8,
    nodes: []const Node.Inner,
    render_options: RenderOptions,
    options: Options,
) !void {
    var progress = try Progress.init(options);
    defer progress.deinit(options.allocator);

    for (progress.nodes[0..nodes.len], nodes) |*out, in|
        try std.testing.expect(out.aquire(in));

    var actual = std.ArrayList(u8).init(options.allocator);
    defer actual.deinit();

    _ = try progress.render(actual.writer(), render_options);
    try std.testing.expectEqualStrings(expected, actual.items);
}

test "render" {
    try expectRender(
        \\node 0    0% [          ]
        \\node 1   10% [=         ]
        \\node 5   50% [=====     ]
        \\node 10 100% [==========]
        \\
    ,
        &.{
            .{ .name = "node 0", .curr = 0, .max = 10 },
            .{ .name = "node 1", .curr = 1, .max = 10 },
            .{ .name = "node 5", .curr = 5, .max = 10 },
            .{ .name = "node 10", .curr = 10, .max = 10 },
        },
        .{ .width = 25, .height = 4 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 7,
        },
    );
}

test "render: empty node" {
    try expectRender(
        \\node 0    0% [          ]
        \\node 5   50% [=====     ]
        \\node 10 100% [==========]
        \\
    ,
        &.{
            .{ .name = "node 0", .curr = 0, .max = 10 },
            .{ .name = null },
            .{ .name = "node 5", .curr = 5, .max = 10 },
            .{ .name = "node 10", .curr = 10, .max = 10 },
        },
        .{ .width = 25, .height = 4 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 7,
        },
    );
}

test "render: more nodes than height" {
    try expectRender(
        \\node 0    0% [          ]
        \\
    ,
        &.{
            .{ .name = "node 0", .curr = 0, .max = 10 },
            .{ .name = "node 5", .curr = 5, .max = 10 },
        },
        .{ .width = 25, .height = 1 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 7,
        },
    );
}

test "render: no room for bar" {
    for (6..10) |width| {
        try expectRender(
            \\node 0
            \\
        ,
            &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
            .{ .width = width, .height = 1 },
            .{
                .allocator = std.testing.allocator,
                .maximum_node_name_len = 6,
            },
        );
    }
}

test "render: only room for percent without %" {
    try expectRender(
        \\node 0   0
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 10, .height = 1 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 6,
        },
    );
}

test "render: only room for percent" {
    for (11..15) |width| {
        try expectRender(
            \\node 0   0%
            \\
        ,
            &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
            .{ .width = width, .height = 1 },
            .{
                .allocator = std.testing.allocator,
                .maximum_node_name_len = 6,
            },
        );
    }
}

test "render: no room for name" {
    try expectRender(
        \\   0% [                 ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 0,
        },
    );
    try expectRender(
        \\.   0% [                ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 1,
        },
    );
    try expectRender(
        \\..   0% [               ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 2,
        },
    );
    try expectRender(
        \\...   0% [              ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 3,
        },
    );
    try expectRender(
        \\n...   0% [             ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 4,
        },
    );
    try expectRender(
        \\no...   0% [            ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 5,
        },
    );
    try expectRender(
        \\node 0   0% [           ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 6,
        },
    );
}

test "render: max greater than curr" {
    try expectRender(
        \\node 0  200% [==========]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 20, .max = 10 }},
        .{ .width = 25, .height = 1 },
        .{
            .allocator = std.testing.allocator,
            .maximum_node_name_len = 7,
        },
    );
}

test {
    _ = Escapes;
}

const Progress = @This();

const Escapes = @import("Escapes.zig");

const std = @import("std");
