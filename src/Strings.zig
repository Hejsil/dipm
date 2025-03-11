data: std.ArrayListUnmanaged(u8),
pointer_stability: std.debug.SafetyLock = .{},

pub const Index = enum(u32) {
    _,

    pub const Optional = enum(u32) {
        null = std.math.maxInt(u32),
        _,
    };
};

pub const empty = Strings{ .data = .empty };

pub fn deinit(strings: *Strings, gpa: std.mem.Allocator) void {
    strings.data.deinit(gpa);
    strings.* = undefined;
}

pub fn put(strings: *Strings, gpa: std.mem.Allocator, string: []const u8) !Index {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();

    try strings.data.ensureUnusedCapacity(gpa, string.len + 1);
    return strings.putAssumeCapacityNoLock(string);
}

pub fn putAssumeCapacity(strings: *Strings, string: []const u8) Index {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();
    return strings.putAssumeCapacityNoLock(string);
}

fn putAssumeCapacityNoLock(strings: *Strings, string: []const u8) Index {
    strings.pointer_stability.assertLocked();
    const index: u32 = @intCast(strings.data.items.len);
    strings.data.appendSliceAssumeCapacity(string);
    strings.data.appendAssumeCapacity(0);
    return @enumFromInt(index);
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

pub fn getPtr(strings: Strings, index: Index) [*:0]const u8 {
    strings.pointer_stability.assertUnlocked();
    const i = @intFromEnum(index);
    return strings.data.items[i .. strings.data.items.len - 1 :0];
}

pub fn get(strings: Strings, index: Index) [:0]const u8 {
    strings.pointer_stability.assertUnlocked();
    const ptr = strings.getPtr(index);
    return std.mem.span(ptr);
}

test {
    const gpa = std.testing.allocator;
    var strings = Strings.empty;
    defer strings.deinit(gpa);

    const a = try strings.put(gpa, "a");
    const b = try strings.print(gpa, "{s}{s}", .{ "b", "c" });
    try std.testing.expectEqualStrings("a", strings.get(a));
    try std.testing.expectEqualStrings("bc", strings.get(b));
}

pub const ArrayHashMapAdapter = struct {
    strings: *const Strings,

    pub fn eql(ctx: ArrayHashMapAdapter, a: []const u8, b: Index, _: usize) bool {
        const b_str = ctx.strings.get(b);
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
    a_entry.key_ptr.* = try strings.put(gpa, "a");

    try std.testing.expect(!a_entry.found_existing);
    try std.testing.expect(map.getAdapted("a", adapter) != null);
    try std.testing.expect(map.getAdapted("b", adapter) == null);
}

const Strings = @This();

const std = @import("std");
