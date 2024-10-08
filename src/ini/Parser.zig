string: []const u8,
index: u32,

pub fn init(string: []const u8) Parser {
    return Parser{ .string = string, .index = 0 };
}

pub fn next(parser: *Parser) Result {
    var state: enum {
        start,
        comment,
        section_inner_start,
        section_inner,
        section_inner_end,
        section_end,
        invalid,
        property_name,
        property_name_end,
        property_value,
        property_value_end,
    } = .start;

    var invalid_start: u32 = parser.index;
    var start: u32 = parser.index;
    var end: u32 = parser.index;
    while (parser.index < parser.string.len) : (parser.index += 1) switch (state) {
        .start => switch (parser.string[parser.index]) {
            ' ', '\t', '\n', '\r' => {
                start += 1;
                invalid_start += 1;
            },
            ';', '#' => state = .comment,
            '[' => state = .section_inner_start,
            '=' => state = .invalid,
            else => state = .property_name,
        },
        .comment => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .comment, .start = start, .end = parser.index };
            },
            else => {},
        },
        .section_inner_start => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .invalid, .start = invalid_start, .end = parser.index };
            },
            ']' => {
                start = parser.index;
                end = parser.index;
                state = .section_end;
            },
            ' ', '\t' => {},
            else => {
                start = parser.index;
                state = .section_inner;
            },
        },
        .section_inner => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .invalid, .start = invalid_start, .end = parser.index };
            },
            ']' => {
                end = parser.index;
                state = .section_end;
            },
            ' ', '\t' => {
                end = parser.index;
                state = .section_inner_end;
            },
            else => {},
        },
        .section_inner_end => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .invalid, .start = invalid_start, .end = parser.index };
            },
            ']' => state = .section_end,
            ' ', '\t' => {},
            else => state = .section_inner,
        },
        .section_end => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .section, .start = start, .end = end };
            },
            ' ', '\t' => {},
            else => state = .invalid,
        },
        .property_name => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .property, .start = start, .end = parser.index };
            },
            '=' => state = .property_value,
            ' ', '\t' => {
                end = parser.index;
                state = .property_name_end;
            },
            else => {},
        },
        .property_name_end => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .property, .start = start, .end = end };
            },
            '=' => state = .property_value,
            ' ', '\t' => {},
            else => state = .property_name,
        },
        .property_value => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .property, .start = start, .end = parser.index };
            },
            ' ', '\t' => {
                end = parser.index;
                state = .property_value_end;
            },
            else => {},
        },
        .property_value_end => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .property, .start = start, .end = end };
            },
            ' ', '\t' => {},
            else => state = .property_value,
        },
        .invalid => switch (parser.string[parser.index]) {
            '\n' => {
                defer parser.index += 1;
                return .{ .kind = .invalid, .start = invalid_start, .end = parser.index };
            },
            else => {},
        },
    };

    switch (state) {
        .start => return .{ .kind = .end, .start = start, .end = parser.index },
        .comment => return .{ .kind = .comment, .start = start, .end = parser.index },
        .section_inner_start => return .{ .kind = .invalid, .start = invalid_start, .end = parser.index },
        .section_inner => return .{ .kind = .invalid, .start = invalid_start, .end = parser.index },
        .section_inner_end => return .{ .kind = .invalid, .start = invalid_start, .end = parser.index },
        .section_end => return .{ .kind = .section, .start = start, .end = end },
        .property_name => return .{ .kind = .property, .start = start, .end = parser.index },
        .property_name_end => return .{ .kind = .property, .start = start, .end = end },
        .property_value => return .{ .kind = .property, .start = start, .end = parser.index },
        .property_value_end => return .{ .kind = .property, .start = start, .end = end },
        .invalid => return .{ .kind = .invalid, .start = invalid_start, .end = parser.index },
    }
}

fn expectedParsed(string: []const u8, expected: []const Result.Kind) !void {
    const without_leading_or_trailing_ws = std.mem.trim(u8, string, " \t\n");
    try expectedParsedInner(without_leading_or_trailing_ws, expected);

    const with_trailing_nl = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{string});
    defer std.testing.allocator.free(with_trailing_nl);
    try expectedParsedInner(with_trailing_nl, expected);
}

fn expectedParsedInner(string: []const u8, expected: []const Result.Kind) !void {
    var parser = Parser.init(string);
    for (expected) |expect|
        try std.testing.expectEqual(expect, parser.next().kind);

    try std.testing.expectEqual(parser.index, parser.string.len);
}

test "Parser tokens" {
    try expectedParsed(
        \\
    ,
        &.{
            .end,
        },
    );
    try expectedParsed(
        \\test
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test=
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test =
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test=test
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test =test
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test = test
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test=test=test
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test =test=test
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test = test=test
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test = test =test
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\test = test = test
    ,
        &.{
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\# comment
    ,
        &.{
            .comment,
            .end,
        },
    );
    try expectedParsed(
        \\; comment
    ,
        &.{
            .comment,
            .end,
        },
    );
    try expectedParsed(
        \\[]
    ,
        &.{
            .section,
            .end,
        },
    );
    try expectedParsed(
        \\[project]
        \\name = orchard rental service (with app)
        \\target region = "Bay Area"
        \\; TODO: advertise vacant positions
        \\legal team = (vacant)
        \\
        \\[fruit "Apple"]
        \\trademark issues = foreseeable
        \\taste = known
        \\
        \\[fruit.Date]
        \\taste = novel
        \\Trademark Issues="truly unlikely"
    ,
        &.{
            .section,
            .property,
            .property,
            .comment,
            .property,
            .section,
            .property,
            .property,
            .section,
            .property,
            .property,
            .end,
        },
    );
    try expectedParsed(
        \\[
    ,
        &.{
            .invalid,
            .end,
        },
    );
    try expectedParsed(
        \\[] test
    ,
        &.{
            .invalid,
            .end,
        },
    );
    try expectedParsed(
        \\=
    ,
        &.{
            .invalid,
            .end,
        },
    );
    try expectedParsed(
        \\= test
    ,
        &.{
            .invalid,
            .end,
        },
    );
}

fn parseAndWrite(allocator: std.mem.Allocator, string: []const u8) ![]u8 {
    var parser = Parser.init(string);
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    while (true) {
        const result = parser.next();
        if (result.kind == .end)
            return out.toOwnedSlice();

        try result.write(string, out.writer());
    }
}

test "fuzz" {
    try std.testing.fuzz(fuzz.fnFromParseAndWrite(parseAndWrite), .{});
}

pub const Result = struct {
    kind: Kind,
    start: u32,
    end: u32,

    pub fn slice(result: Result, string: []const u8) []const u8 {
        return string[result.start..result.end];
    }

    pub fn property(result: Result, string: []const u8) ?Property {
        if (result.kind != .property) return null;

        const content = result.slice(string);
        const equal_index = std.mem.indexOfScalar(u8, content, '=') orelse return .{
            .name = content,
            .value = content[0..0],
        };

        const name = std.mem.trimRight(u8, content[0..equal_index], " \t");
        const value = std.mem.trimLeft(u8, content[equal_index + 1 ..], " \t");
        return .{ .name = name, .value = value };
    }

    pub fn section(result: Result, string: []const u8) ?Section {
        if (result.kind != .section) return null;
        return .{ .name = result.slice(string) };
    }

    pub fn write(result: Result, string: []const u8, writer: anytype) !void {
        switch (result.kind) {
            .comment, .invalid => {
                try writer.writeAll(result.slice(string));
                try writer.writeAll("\n");
            },
            .section => {
                try writer.writeAll("[");
                try writer.writeAll(result.section(string).?.name);
                try writer.writeAll("]\n");
            },
            .property => {
                const prop = result.property(string).?;
                try writer.writeAll(prop.name);

                if (prop.value.len != 0) {
                    try writer.writeAll(" = ");
                    try writer.writeAll(prop.value);
                }

                try writer.writeAll("\n");
            },
            .end => {},
        }
    }

    pub const Kind = enum {
        comment,
        section,
        property,
        invalid,
        end,
    };

    pub const Property = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Section = struct {
        name: []const u8,
    };
};

fn expectResult(string: []const u8, result: Result) !void {
    var parser = Parser.init(string);
    const actual = parser.next();
    try std.testing.expectEqual(result.kind, actual.kind);
    try std.testing.expectEqual(result.start, actual.start);
    try std.testing.expectEqual(result.end, actual.end);
}

fn expectProperty(string: []const u8, result: Result, expected: Result.Property) !void {
    try expectResult(string, result);

    const property = result.property(string);
    try std.testing.expect(property != null);
    try std.testing.expectEqualStrings(expected.name, property.?.name);
    try std.testing.expectEqualStrings(expected.value, property.?.value);
}

test "Result.property" {
    try expectProperty(
        "test=test",
        .{ .kind = .property, .start = 0, .end = 9 },
        .{ .name = "test", .value = "test" },
    );
    try expectProperty(
        "test= test",
        .{ .kind = .property, .start = 0, .end = 10 },
        .{ .name = "test", .value = "test" },
    );
    try expectProperty(
        "test = test",
        .{ .kind = .property, .start = 0, .end = 11 },
        .{ .name = "test", .value = "test" },
    );
    try expectProperty(
        "test = test = test",
        .{ .kind = .property, .start = 0, .end = 18 },
        .{ .name = "test", .value = "test = test" },
    );
    try expectProperty(
        "test =",
        .{ .kind = .property, .start = 0, .end = 6 },
        .{ .name = "test", .value = "" },
    );
    try expectProperty(
        " test =",
        .{ .kind = .property, .start = 1, .end = 7 },
        .{ .name = "test", .value = "" },
    );
    try expectProperty(
        " test = ",
        .{ .kind = .property, .start = 1, .end = 7 },
        .{ .name = "test", .value = "" },
    );
    try expectProperty(
        "test = ",
        .{ .kind = .property, .start = 0, .end = 6 },
        .{ .name = "test", .value = "" },
    );
    try expectProperty(
        "test",
        .{ .kind = .property, .start = 0, .end = 4 },
        .{ .name = "test", .value = "" },
    );
    try expectProperty(
        " test",
        .{ .kind = .property, .start = 1, .end = 5 },
        .{ .name = "test", .value = "" },
    );
    try expectProperty(
        " test ",
        .{ .kind = .property, .start = 1, .end = 5 },
        .{ .name = "test", .value = "" },
    );
    try expectProperty(
        "test ",
        .{ .kind = .property, .start = 0, .end = 4 },
        .{ .name = "test", .value = "" },
    );
}

fn expectSection(string: []const u8, result: Result, expected: Result.Section) !void {
    try expectResult(string, result);

    const section = result.section(string);
    try std.testing.expect(section != null);
    try std.testing.expectEqualStrings(expected.name, section.?.name);
}

test "Result.section" {
    try expectSection(
        \\[]
    ,
        .{ .kind = .section, .start = 1, .end = 1 },
        .{ .name = "" },
    );
    try expectSection(
        \\[ ]
    ,
        .{ .kind = .section, .start = 2, .end = 2 },
        .{ .name = "" },
    );
    try expectSection(
        \\[test]
    ,
        .{ .kind = .section, .start = 1, .end = 5 },
        .{ .name = "test" },
    );
    try expectSection(
        \\[ test]
    ,
        .{ .kind = .section, .start = 2, .end = 6 },
        .{ .name = "test" },
    );
    try expectSection(
        \\[ test ]
    ,
        .{ .kind = .section, .start = 2, .end = 6 },
        .{ .name = "test" },
    );
    try expectSection(
        \\[test ]
    ,
        .{ .kind = .section, .start = 1, .end = 5 },
        .{ .name = "test" },
    );
}

test "Result.invalid" {
    try expectResult(
        \\[
    ,
        .{ .kind = .invalid, .start = 0, .end = 1 },
    );
    try expectResult(
        \\[ty=;i>
    ,
        .{ .kind = .invalid, .start = 0, .end = 7 },
    );
}

test {
    _ = fuzz;
}

const Parser = @This();

const fuzz = @import("../fuzz.zig");
const std = @import("std");
