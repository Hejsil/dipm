nodes: []NodeState,
maximum_node_name_len: u32,

pub var dummy = Progress{ .nodes = &.{}, .maximum_node_name_len = 0 };

var nodes_buf: [128]NodeState = @splat(NodeState.none);
pub var global = Progress{
    .nodes = &nodes_buf,
    .maximum_node_name_len = 15,
};

pub const Node = enum(usize) {
    none = 0,
    _,

    fn init(ptr: ?*NodeState) Node {
        return @enumFromInt(@intFromPtr(ptr));
    }

    fn unwrap(node: Node) ?*NodeState {
        return @ptrFromInt(@intFromEnum(node));
    }

    pub fn advance(node: Node, amount: u32) void {
        const state = node.unwrap() orelse return;
        state.lock.lock();
        state.inner.curr += amount;
        state.lock.unlock();
    }

    pub fn setMax(node: Node, max: u32) void {
        const state = node.unwrap() orelse return;
        state.lock.lock();
        state.inner.max = max;
        state.lock.unlock();
    }

    pub fn setCurr(node: Node, curr: u32) void {
        const state = node.unwrap() orelse return;
        state.lock.lock();
        state.inner.curr = curr;
        state.lock.unlock();
    }

    pub fn writer(node: Node, child_writer: anytype) Writer(@TypeOf(child_writer)) {
        return .{ .child = child_writer, .node = node };
    }

    pub fn Writer(comptime Child: type) type {
        return struct {
            child: Child,
            node: Node,

            pub const Error = Child.Error;
            pub const Writer = std.io.Writer(*Self, Error, write);

            const Self = @This();

            pub fn writer(self: *Self) @This().Writer {
                return .{ .context = self };
            }

            pub fn write(self: *Self, bytes: []const u8) Error!usize {
                const res = try self.child.write(bytes);
                self.node.advance(@min(res, std.math.maxInt(u32)));
                return res;
            }
        };
    }

    pub fn reader(node: Node, child_reader: anytype) Reader(@TypeOf(child_reader)) {
        return .{ .child = child_reader, .node = node };
    }

    pub fn Reader(comptime Child: type) type {
        return struct {
            child: Child,
            node: Node,

            pub const Error = Child.Error;
            pub const Reader = std.io.Reader(*Self, Error, read);

            const Self = @This();

            pub fn reader(self: *Self) Self.Reader {
                return .{ .context = self };
            }

            pub fn read(self: *Self, buf: []u8) Error!usize {
                const res = try self.child.read(buf);
                self.node.advance(@min(res, std.math.maxInt(u32)));
                return res;
            }
        };
    }
};

const NodeState = struct {
    inner: Inner,
    // TODO: This can probably be done in a lock free way using a certain value of `max` as a
    //       "locked" value, and spinning until we can get it
    lock: std.Thread.Mutex,

    pub const Inner = struct {
        name: ?[]const u8 = null,
        curr: u32 = 0,
        max: u32 = 0,
    };

    const none = NodeState{
        .inner = .{},
        .lock = .{},
    };

    fn get(node: *NodeState) Inner {
        node.lock.lock();
        const res = node.inner;
        node.lock.unlock();
        return res;
    }

    fn acquire(node: *NodeState, inner: Inner) bool {
        node.lock.lock();
        defer node.lock.unlock();

        if (node.inner.name != null)
            return false;

        node.inner = inner;
        return true;
    }

    fn release(node: *NodeState) void {
        node.lock.lock();
        node.inner = .{};
        node.lock.unlock();
    }
};

pub fn start(progress: Progress, name: []const u8, max: u32) Node {
    for (progress.nodes) |*node| {
        if (node.acquire(.{ .name = name, .max = max }))
            return Node.init(node);
    }
    return .none;
}

pub fn end(progress: Progress, node: Node) void {
    _ = progress;
    if (node.unwrap()) |n| n.release();
}

const clear = "\x1b[J";
const finish_sync = "\x1b[?2026l";
const start_sync = "\x1b[?2026h";
const up_one_line = "\x1bM";

pub fn renderToTty(progress: Progress, tty: std.fs.File) !void {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const err = std.posix.system.ioctl(tty.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(err) != .SUCCESS)
        return;

    // The -2 here is so that the PS1 is not scrolled off the top of the terminal.
    // one because we keep the cursor on the next line
    // one more to account for the PS1
    const height = winsize.row -| 2;

    var buffered_tty = std.io.bufferedWriter(tty.writer());
    const writer = buffered_tty.writer();

    try writer.writeAll(start_sync ++ clear);
    const nodes_printed = try progress.render(writer, .{
        .width = winsize.col,
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

        const bar_start = " [";
        const bar_end = "]";

        const node_name_len = std.unicode.utf8CountCodepoints(node_name) catch continue;
        const codepoints_to_write = @min(node_name_len, options.width, progress.maximum_node_name_len);

        if (node_name_len == codepoints_to_write) {
            try writer.writeAll(node_name);
        } else switch (codepoints_to_write) {
            0...3 => try writer.writeByteNTimes('.', codepoints_to_write),
            else => {
                const view = std.unicode.Utf8View.init(node_name) catch continue;
                var it = view.iterator();
                var i: usize = 0;
                while (i < codepoints_to_write - 3) : (i += 1) {
                    // We counted the codepoints above with `utf8CountCodepoints`, so
                    // `nextCodepointSlice` should never return null
                    try writer.writeAll(it.nextCodepointSlice().?);
                }
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
            const max: u64 = @max(1, node.max);
            const percent = (curr * 100) / max;

            try writer.writeByteNTimes(' ', progress.maximum_node_name_len - codepoints_to_write);
            try writer.print(" {d:>3}", .{percent});
            remaining_width -= 4;
        }
        if (remaining_width >= 1) {
            try writer.writeAll("%");
            remaining_width -= 1;
        }
        if (remaining_width >= bar_start.len + bar_end.len + 1) {
            remaining_width -= bar_start.len + bar_end.len;

            const curr: u64 = node.curr;
            const max: u64 = @max(1, node.max);
            const filled = (curr * remaining_width) / max;

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

fn expectRender(
    expected: []const u8,
    nodes: []const NodeState.Inner,
    render_options: RenderOptions,
    maximum_node_name_len: u32,
) !void {
    var buf: [128]NodeState = @splat(NodeState.none);
    var progress = Progress{
        .nodes = &buf,
        .maximum_node_name_len = maximum_node_name_len,
    };

    for (progress.nodes[0..nodes.len], nodes) |*out, in|
        try std.testing.expect(out.acquire(in));

    var actual = std.ArrayList(u8).init(std.testing.allocator);
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
        7,
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
        7,
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
        7,
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
            6,
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
        6,
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
            6,
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
        0,
    );
    try expectRender(
        \\.   0% [                ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        1,
    );
    try expectRender(
        \\..   0% [               ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        2,
    );
    try expectRender(
        \\...   0% [              ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        3,
    );
    try expectRender(
        \\n...   0% [             ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        4,
    );
    try expectRender(
        \\no...   0% [            ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        5,
    );
    try expectRender(
        \\node 0   0% [           ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        6,
    );

    try expectRender(
        \\↓ ...   0% [            ]
        \\
    ,
        &.{.{ .name = "↓ node", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        5,
    );
    try expectRender(
        \\↓ node   0% [           ]
        \\
    ,
        &.{.{ .name = "↓ node", .curr = 0, .max = 10 }},
        .{ .width = 25, .height = 4 },
        6,
    );
}

test "render: max greater than curr" {
    try expectRender(
        \\node 0  200% [==========]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 20, .max = 10 }},
        .{ .width = 25, .height = 1 },
        7,
    );
}

test "render: max is 0" {
    try expectRender(
        \\node 0    0% [          ]
        \\
    ,
        &.{.{ .name = "node 0", .curr = 0, .max = 0 }},
        .{ .width = 25, .height = 1 },
        7,
    );
}

test {
    _ = Escapes;
}

const Progress = @This();

const Escapes = @import("Escapes.zig");

const std = @import("std");
