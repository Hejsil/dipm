args: []const []const u8,
index: usize = 0,

pub fn isDone(parser: ArgParser) bool {
    return parser.index >= parser.args.len;
}

pub fn flag(parser: *ArgParser, names: []const []const u8) bool {
    for (names) |name| {
        if (!std.mem.eql(u8, parser.args[parser.index], name))
            continue;

        parser.index += 1;
        return true;
    }

    return false;
}

pub fn option(parser: *ArgParser, names: []const []const u8) ?[]const u8 {
    const arg = parser.args[parser.index];
    for (names) |name| {
        if (!std.mem.startsWith(u8, arg, name))
            continue;
        if (!std.mem.startsWith(u8, arg[name.len..], "="))
            continue;

        parser.index += 1;
        return arg[name.len + 1 ..];
    }

    if (parser.index + 1 < parser.args.len) {
        if (parser.flag(names))
            return parser.eat();
    }

    return null;
}

pub fn eat(parser: *ArgParser) []const u8 {
    defer parser.index += 1;
    return parser.args[parser.index];
}

test flag {
    var parser = ArgParser{ .args = &.{
        "-a", "--beta", "command",
    } };

    try std.testing.expect(!parser.flag(&.{"command"}));
    try std.testing.expect(!parser.flag(&.{ "-b", "--beta" }));
    try std.testing.expect(parser.flag(&.{ "-a", "--alpha" }));
    try std.testing.expect(!parser.isDone());
    try std.testing.expect(!parser.flag(&.{"command"}));
    try std.testing.expect(parser.flag(&.{ "-b", "--beta" }));
    try std.testing.expect(!parser.isDone());
    try std.testing.expect(!parser.flag(&.{ "-a", "--alpha" }));
    try std.testing.expect(parser.flag(&.{"command"}));
    try std.testing.expect(parser.isDone());
}

fn expectEqualOptionalString(m_expect: ?[]const u8, m_actual: ?[]const u8) !void {
    if (m_expect) |expect| {
        try std.testing.expect(m_actual != null);
        try std.testing.expectEqualStrings(expect, m_actual.?);
    } else {
        try std.testing.expect(m_actual == null);
    }
}

test option {
    var parser = ArgParser{ .args = &.{
        "-a",
        "a_value",
        "--beta=b_value",
        "command",
        "command_value",
    } };

    try expectEqualOptionalString(null, parser.option(&.{"command"}));
    try expectEqualOptionalString(null, parser.option(&.{ "-b", "--beta" }));
    try expectEqualOptionalString("a_value", parser.option(&.{ "-a", "--alpha" }));
    try std.testing.expect(!parser.isDone());
    try expectEqualOptionalString(null, parser.option(&.{"command"}));
    try expectEqualOptionalString("b_value", parser.option(&.{ "-b", "--beta" }));
    try expectEqualOptionalString(null, parser.option(&.{ "-a", "--alpha" }));
    try std.testing.expect(!parser.isDone());
    try expectEqualOptionalString("command_value", parser.option(&.{"command"}));
    try std.testing.expect(parser.isDone());
}

test eat {
    var parser = ArgParser{ .args = &.{
        "-a",
        "--beta",
        "command",
    } };

    try std.testing.expectEqualStrings("-a", parser.eat());
    try std.testing.expect(!parser.isDone());
    try std.testing.expectEqualStrings("--beta", parser.eat());
    try std.testing.expect(!parser.isDone());
    try std.testing.expectEqualStrings("command", parser.eat());
    try std.testing.expect(parser.isDone());
}

test "all" {
    var parser = ArgParser{ .args = &.{
        "-a",
        "--beta",
        "b_value",
        "-c=c_value",
        "command",
    } };

    try expectEqualOptionalString(null, parser.option(&.{ "-c", "--center" }));
    try expectEqualOptionalString(null, parser.option(&.{ "-b", "--beta" }));
    try std.testing.expect(parser.flag(&.{ "-a", "--alpha" }));
    try std.testing.expect(!parser.isDone());
    try expectEqualOptionalString(null, parser.option(&.{ "-c", "--center" }));
    try expectEqualOptionalString("b_value", parser.option(&.{ "-b", "--beta" }));
    try std.testing.expect(!parser.flag(&.{ "-a", "--alpha" }));
    try std.testing.expect(!parser.isDone());
    try expectEqualOptionalString("c_value", parser.option(&.{ "-c", "--center" }));
    try expectEqualOptionalString(null, parser.option(&.{ "-b", "--beta" }));
    try std.testing.expect(!parser.flag(&.{ "-a", "--alpha" }));
    try std.testing.expect(!parser.isDone());
    try expectEqualOptionalString(null, parser.option(&.{ "-c", "--center" }));
    try expectEqualOptionalString(null, parser.option(&.{ "-b", "--beta" }));
    try std.testing.expect(!parser.flag(&.{ "-a", "--alpha" }));
    try std.testing.expect(!parser.isDone());
    try std.testing.expectEqualStrings("command", parser.eat());
    try std.testing.expect(parser.isDone());
}

const ArgParser = @This();

const std = @import("std");
