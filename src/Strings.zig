data: std.ArrayListUnmanaged(u8),
indices: std.ArrayListUnmanaged(Index),
pointer_stability: std.debug.SafetyLock,

pub const Index = enum(u32) { _ };

pub const Indices = struct {
    off: u32,
    len: u32,

    pub const empty = Indices{
        .off = 0,
        .len = 0,
    };
};

pub const empty = Strings{
    .data = .empty,
    .indices = .empty,
    .pointer_stability = .{},
};

pub fn deinit(strings: *Strings, gpa: std.mem.Allocator) void {
    strings.data.deinit(gpa);
    strings.indices.deinit(gpa);
    strings.* = undefined;
}

pub fn putStr(strings: *Strings, gpa: std.mem.Allocator, string: []const u8) !Index {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();

    try strings.data.ensureUnusedCapacity(gpa, string.len + 1);
    return strings.putStrAssumeCapacityNoLock(string);
}

pub fn putStrAssumeCapacity(strings: *Strings, string: []const u8) Index {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();
    return strings.putStrAssumeCapacityNoLock(string);
}

fn putStrAssumeCapacityNoLock(strings: *Strings, string: []const u8) Index {
    strings.pointer_stability.assertLocked();
    const index: u32 = @intCast(strings.data.items.len);
    strings.data.appendSliceAssumeCapacity(string);
    strings.data.appendAssumeCapacity(0);
    return @enumFromInt(index);
}

test putStr {
    const gpa = std.testing.allocator;
    var strings = Strings.empty;
    defer strings.deinit(gpa);

    const a = try strings.putStr(gpa, "a");
    const b = try strings.putStr(gpa, "b");
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(a));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(b));
    try std.testing.expectEqualStrings("a", strings.getStr(a));
    try std.testing.expectEqualStrings("b", strings.getStr(b));
}

pub fn putStrs(strings: *Strings, gpa: std.mem.Allocator, strs: []const []const u8) !Indices {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();

    try strings.data.ensureUnusedCapacity(gpa, blk: {
        var needed_capacity: usize = 0;
        for (strs) |str| needed_capacity += str.len + 1;
        break :blk needed_capacity;
    });
    try strings.indices.ensureUnusedCapacity(gpa, strs.len);

    return strings.putStrsAssumeCapacityNoLock(strs);
}

pub fn putStrsAssumeCapacity(strings: *Strings, strs: []const []const u8) Indices {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();
    return strings.putStrsAssumeCapacityNoLock(strs);
}

fn putStrsAssumeCapacityNoLock(strings: *Strings, strs: []const []const u8) Indices {
    strings.pointer_stability.assertLocked();

    const off = strings.putIndicesBegin();
    for (strs) |str| {
        const index = strings.putStrAssumeCapacityNoLock(str);
        strings.indices.appendAssumeCapacity(index);
    }

    return strings.putIndicesEnd(off);
}

test putStrs {
    const gpa = std.testing.allocator;
    var strings = Strings.empty;
    defer strings.deinit(gpa);

    const indices = try strings.putStrs(gpa, &.{ "a", "b" });
    try std.testing.expectEqual(@as(u32, 0), indices.off);
    try std.testing.expectEqual(@as(u32, 2), indices.len);

    const indices_slice = strings.getIndices(indices);
    try std.testing.expectEqual(@as(usize, 2), indices_slice.len);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(indices_slice[0]));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(indices_slice[1]));
    try std.testing.expectEqualStrings("a", strings.getStr(indices_slice[0]));
    try std.testing.expectEqualStrings("b", strings.getStr(indices_slice[1]));
}

pub fn putIndices(strings: *Strings, gpa: std.mem.Allocator, indices: []const Index) !Indices {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();
    try strings.indices.ensureUnusedCapacity(gpa, indices.len);
    return strings.putIndicesAssumeCapacityNoLock(indices);
}

pub fn putIndicesAssumeCapacity(strings: *Strings, indices: []const Index) !Indices {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();
    return strings.putIndicesAssumeCapacityNoLock(indices);
}

fn putIndicesAssumeCapacityNoLock(strings: *Strings, indices: []const Index) !Indices {
    strings.pointer_stability.assertLocked();
    const off = strings.putIndicesBegin();
    strings.indices.appendSliceAssumeCapacity(indices);
    return strings.putIndicesEnd(off);
}

test putIndices {
    const gpa = std.testing.allocator;
    var strings = Strings.empty;
    defer strings.deinit(gpa);

    const a = try strings.putStr(gpa, "a");
    const b = try strings.putStr(gpa, "b");
    const indices = try strings.putIndices(gpa, &.{ a, b });
    try std.testing.expectEqual(@as(u32, 0), indices.off);
    try std.testing.expectEqual(@as(u32, 2), indices.len);

    const indices_slice = strings.getIndices(indices);
    try std.testing.expectEqual(@as(usize, 2), indices_slice.len);
    try std.testing.expectEqual(a, indices_slice[0]);
    try std.testing.expectEqual(b, indices_slice[1]);
    try std.testing.expectEqualStrings("a", strings.getStr(indices_slice[0]));
    try std.testing.expectEqualStrings("b", strings.getStr(indices_slice[1]));
}

pub fn putIndicesBegin(strings: *Strings) u32 {
    return @intCast(strings.indices.items.len);
}

pub fn putIndicesEnd(strings: *Strings, off: u32) Indices {
    return .{ .off = off, .len = @intCast(strings.indices.items.len - off) };
}

pub fn print(
    strings: *Strings,
    gpa: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) !Index {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();

    const len = std.fmt.count(format, args);
    try strings.data.ensureUnusedCapacity(gpa, len + 1);
    return strings.printAssumeCapacityNoLock(format, args);
}

pub fn printAssumeCapacity(strings: *Strings, comptime format: []const u8, args: anytype) Index {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();
    return strings.printAssumeCapacityNoLock(format, args);
}

fn printAssumeCapacityNoLock(strings: *Strings, comptime format: []const u8, args: anytype) Index {
    strings.pointer_stability.assertLocked();
    var fba = std.heap.FixedBufferAllocator.init("");
    const index: u32 = @intCast(strings.data.items.len);
    strings.data.writer(fba.allocator()).print(format, args) catch unreachable;
    strings.data.appendAssumeCapacity(0);
    return @enumFromInt(index);
}

test print {
    const gpa = std.testing.allocator;
    var strings = Strings.empty;
    defer strings.deinit(gpa);

    const a = try strings.print(gpa, "{}{}", .{ 0, 1 });
    const b = try strings.print(gpa, "{s}{s}", .{ "b", "c" });
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(a));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(b));
    try std.testing.expectEqualStrings("01", strings.getStr(a));
    try std.testing.expectEqualStrings("bc", strings.getStr(b));
}

pub fn getPtr(strings: Strings, index: Index) [*:0]const u8 {
    strings.pointer_stability.assertUnlocked();
    const i = @intFromEnum(index);
    return strings.data.items[i .. strings.data.items.len - 1 :0];
}

pub fn getStr(strings: Strings, index: Index) [:0]const u8 {
    strings.pointer_stability.assertUnlocked();
    const ptr = strings.getPtr(index);
    return std.mem.span(ptr);
}

pub fn getIndices(strings: Strings, indices: Indices) []const Index {
    return strings.indices.items[indices.off..][0..indices.len];
}

pub const ArrayHashMapAdapter = struct {
    strings: *const Strings,

    pub fn eql(ctx: ArrayHashMapAdapter, a: []const u8, b: Index, _: usize) bool {
        const b_str = ctx.strings.getStr(b);
        return std.mem.eql(u8, a, b_str);
    }

    pub fn hash(ctx: ArrayHashMapAdapter, s: []const u8) u32 {
        _ = ctx;
        return std.array_hash_map.hashString(s);
    }
};

test ArrayHashMapAdapter {
    const gpa = std.testing.allocator;
    var strings = Strings.empty;
    defer strings.deinit(gpa);

    var map = std.ArrayHashMapUnmanaged(Index, void, void, true){};
    defer map.deinit(gpa);

    const adapter = ArrayHashMapAdapter{ .strings = &strings };
    const a_entry = try map.getOrPutAdapted(gpa, "a", adapter);
    a_entry.key_ptr.* = try strings.putStr(gpa, "a");

    try std.testing.expect(!a_entry.found_existing);
    try std.testing.expect(map.getAdapted("a", adapter) != null);
    try std.testing.expect(map.getAdapted("b", adapter) == null);
}

const Strings = @This();

const std = @import("std");
