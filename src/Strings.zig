arena: std.heap.ArenaAllocator,
strings: std.ArrayListUnmanaged([]const u8),
indices: std.ArrayListUnmanaged(Index),

pub const Index = enum(u32) {
    empty = std.math.maxInt(u32),
    _,

    pub fn get(i: Index, strings: Strings) []const u8 {
        return strings.getStr(i);
    }

    pub fn getNullIfEmpty(i: Index, strings: Strings) ?[]const u8 {
        const res = i.get(strings);
        if (res.len == 0) return null;
        return res;
    }
};

pub const Indices = struct {
    off: u32,
    len: u32,

    pub const empty = Indices{
        .off = 0,
        .len = 0,
    };

    pub fn get(i: Indices, strings: Strings) []Index {
        return strings.getIndices(i);
    }
};

pub fn init(gpa: std.mem.Allocator) Strings {
    return .{
        .arena = .init(gpa),
        .strings = .empty,
        .indices = .empty,
    };
}

pub fn deinit(strings: *Strings) void {
    strings.strings.deinit(strings.arena.child_allocator);
    strings.indices.deinit(strings.arena.child_allocator);
    strings.arena.deinit();
    strings.* = undefined;
}

pub fn putStr(strings: *Strings, string: []const u8) !Index {
    const duped = try strings.arena.allocator().dupe(u8, string);
    try strings.strings.append(strings.arena.child_allocator, duped);
    return @enumFromInt(strings.strings.items.len - 1);
}

test putStr {
    const gpa = std.testing.allocator;
    var strings = Strings.init(gpa);
    defer strings.deinit();

    const a = try strings.putStr("a");
    const b = try strings.putStr("b");
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(a));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(b));
    try std.testing.expectEqualStrings("a", a.get(strings));
    try std.testing.expectEqualStrings("b", b.get(strings));
}

pub fn putStrs(strings: *Strings, strs: []const []const u8) !Indices {
    try strings.indices.ensureUnusedCapacity(strings.arena.child_allocator, strs.len);

    const off = strings.putIndicesBegin();
    for (strs) |str| {
        const index = try strings.putStr(str);
        strings.indices.appendAssumeCapacity(index);
    }
    return strings.putIndicesEnd(off);
}

test putStrs {
    const gpa = std.testing.allocator;
    var strings = Strings.init(gpa);
    defer strings.deinit();

    const indices = try strings.putStrs(&.{ "a", "b" });
    try std.testing.expectEqual(@as(u32, 0), indices.off);
    try std.testing.expectEqual(@as(u32, 2), indices.len);

    const indices_slice = indices.get(strings);
    try std.testing.expectEqual(@as(usize, 2), indices_slice.len);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(indices_slice[0]));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(indices_slice[1]));
    try std.testing.expectEqualStrings("a", indices_slice[0].get(strings));
    try std.testing.expectEqualStrings("b", indices_slice[1].get(strings));
}

pub fn putIndices(strings: *Strings, indices: []const Index) !Indices {
    try strings.indices.ensureUnusedCapacity(strings.arena.child_allocator, indices.len);

    const off = strings.putIndicesBegin();
    strings.indices.appendSliceAssumeCapacity(indices);
    return strings.putIndicesEnd(off);
}

test putIndices {
    const gpa = std.testing.allocator;
    var strings = Strings.init(gpa);
    defer strings.deinit();

    const a = try strings.putStr("a");
    const b = try strings.putStr("b");
    const indices = try strings.putIndices(&.{ a, b });
    try std.testing.expectEqual(@as(u32, 0), indices.off);
    try std.testing.expectEqual(@as(u32, 2), indices.len);

    const indices_slice = indices.get(strings);
    try std.testing.expectEqual(@as(usize, 2), indices_slice.len);
    try std.testing.expectEqual(a, indices_slice[0]);
    try std.testing.expectEqual(b, indices_slice[1]);
    try std.testing.expectEqualStrings("a", strings.getStr(indices_slice[0]));
    try std.testing.expectEqualStrings("b", strings.getStr(indices_slice[1]));
}

pub fn concatIndices(strings: *Strings, indices: []const Indices) !Indices {
    var num: usize = 0;
    for (indices) |i|
        num += i.len;

    try strings.indices.ensureUnusedCapacity(strings.arena.child_allocator, num);
    const off = strings.putIndicesBegin();
    for (indices) |i|
        strings.indices.appendSliceAssumeCapacity(i.get(strings.*));
    return strings.putIndicesEnd(off);
}

test concatIndices {
    const gpa = std.testing.allocator;
    var strings = Strings.init(gpa);
    defer strings.deinit();

    const as = try strings.putStrs(&.{ "a", "aa", "aaa" });
    const bs = try strings.putStrs(&.{ "b", "bb", "bbb" });
    const both = try strings.concatIndices(&.{ as, bs });
    const both_slice = both.get(strings);
    try std.testing.expectEqual(@as(usize, 6), both_slice.len);
    try std.testing.expectEqualStrings("a", strings.getStr(both_slice[0]));
    try std.testing.expectEqualStrings("aa", strings.getStr(both_slice[1]));
    try std.testing.expectEqualStrings("aaa", strings.getStr(both_slice[2]));
    try std.testing.expectEqualStrings("b", strings.getStr(both_slice[3]));
    try std.testing.expectEqualStrings("bb", strings.getStr(both_slice[4]));
    try std.testing.expectEqualStrings("bbb", strings.getStr(both_slice[5]));
}

pub fn putIndicesBegin(strings: *Strings) u32 {
    return @intCast(strings.indices.items.len);
}

pub fn putIndicesEnd(strings: *Strings, off: u32) Indices {
    return .{ .off = off, .len = @intCast(strings.indices.items.len - off) };
}

pub fn print(strings: *Strings, comptime format: []const u8, args: anytype) !Index {
    const string = try std.fmt.allocPrint(strings.arena.child_allocator, format, args);
    defer strings.arena.child_allocator.free(string);

    return strings.putStr(string);
}

test print {
    const gpa = std.testing.allocator;
    var strings = Strings.init(gpa);
    defer strings.deinit();

    const a = try strings.print("{}{}", .{ 0, 1 });
    const b = try strings.print("{s}{s}", .{ "b", "c" });
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(a));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(b));
    try std.testing.expectEqualStrings("01", strings.getStr(a));
    try std.testing.expectEqualStrings("bc", strings.getStr(b));
}

pub fn eql(strings: Strings, a: Index, b: Index) bool {
    return std.mem.eql(u8, a.get(strings), b.get(strings));
}

fn getStr(strings: Strings, index: Index) []const u8 {
    if (index == .empty) return "";

    const i = @intFromEnum(index);
    return strings.strings.items[i];
}

pub fn getIndices(strings: Strings, indices: Indices) []Index {
    return strings.indices.items[indices.off..][0..indices.len];
}

pub fn adapter(strings: *const Strings) ArrayHashMapAdapter {
    return .{ .strings = strings };
}

pub const ArrayHashMapAdapter = struct {
    strings: *const Strings,

    pub fn eql(ctx: ArrayHashMapAdapter, a: []const u8, b: Index, _: usize) bool {
        const b_str = b.get(ctx.strings.*);
        return std.mem.eql(u8, a, b_str);
    }

    pub fn hash(ctx: ArrayHashMapAdapter, s: []const u8) u32 {
        _ = ctx;
        return std.array_hash_map.hashString(s);
    }
};

test ArrayHashMapAdapter {
    const gpa = std.testing.allocator;
    var strings = Strings.init(gpa);
    defer strings.deinit();

    var map = std.ArrayHashMapUnmanaged(Index, void, void, true){};
    defer map.deinit(gpa);

    const a_entry = try map.getOrPutAdapted(gpa, "a", strings.adapter());
    a_entry.key_ptr.* = try strings.putStr("a");

    try std.testing.expect(!a_entry.found_existing);
    try std.testing.expect(map.getAdapted("a", strings.adapter()) != null);
    try std.testing.expect(map.getAdapted("b", strings.adapter()) == null);
}

const Strings = @This();

const std = @import("std");
