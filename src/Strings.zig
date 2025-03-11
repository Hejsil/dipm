data: std.ArrayListUnmanaged(u8),
pointer_stability: std.debug.SafetyLock = .{},

pub const Index = enum(u32) {
    null = std.math.maxInt(u32),
    _,
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

pub fn print(strings: *Strings, gpa: std.mem.Allocator, format: []const u8, args: anytype) !Index {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();

    const len = std.fmt.count(format, args);
    try strings.data.ensureUnusedCapacity(gpa, len + 1);
    return strings.printAssumeCapacityNoLock(format, args);
}

pub fn printAssumeCapacity(strings: *Strings, format: []const u8, args: anytype) Index {
    strings.pointer_stability.lock();
    defer strings.pointer_stability.unlock();
    return strings.printAssumeCapacityNoLock(format, args);
}

fn printAssumeCapacityNoLock(strings: *Strings, format: []const u8, args: anytype) Index {
    strings.pointer_stability.assertLocked();
    const index: u32 = @intCast(strings.data.items.len);
    strings.data.writer.print(format, args);
    strings.data.appendAssumeCapacity(0);
    return @enumFromInt(index);
}

pub fn getPtr(strings: *Strings, index: Index) ?[*:0]const u8 {
    strings.pointer_stability.assertUnlocked();
    if (index == .null) return null;
    const i = @intFromEnum(index);
    return strings.data.items[i .. strings.data.items.len - 1 :0];
}

pub fn get(strings: *Strings, index: Index) ?[:0]const u8 {
    strings.pointer_stability.assertUnlocked();
    const ptr = strings.getPtr(index) orelse return null;
    return std.mem.span(ptr);
}

test {
    const gpa = std.testing.allocator;
    var strings = Strings.empty;
    defer strings.deinit(gpa);

    const a = try strings.put(gpa, "a");
    const b = try strings.put(gpa, "b");
    try std.testing.expectEqualStrings("a", strings.get(a).?);
    try std.testing.expectEqualStrings("b", strings.get(b).?);
    try std.testing.expect(strings.get(.null) == null);
}

const Strings = @This();

const std = @import("std");
