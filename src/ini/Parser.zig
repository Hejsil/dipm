string: [:0]const u8,
index: u32,

pub fn init(string: [:0]const u8) Parser {
    return Parser{ .string = string, .index = 0 };
}

pub fn next(parser: *Parser) Result {
    const State = enum {
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
    };

    var invalid_start: u32 = parser.index;
    var start: u32 = parser.index;
    var end: u32 = parser.index;
    loop: switch (State.start) {
        .start => switch (parser.string[parser.index]) {
            0 => return .init(.end, start, parser.index),
            ' ', '\t', '\n', '\r' => {
                start += 1;
                invalid_start += 1;
                parser.index += 1;
                continue :loop .start;
            },
            ';', '#' => {
                parser.index += 1;
                continue :loop .comment;
            },
            '[' => {
                parser.index += 1;
                continue :loop .section_inner_start;
            },
            '=' => {
                parser.index += 1;
                continue :loop .invalid;
            },
            else => {
                parser.index += 1;
                continue :loop .property_name;
            },
        },
        .comment => switch (parser.string[parser.index]) {
            0 => return .init(.comment, start, parser.index),
            '\n' => {
                defer parser.index += 1;
                return .init(.comment, start, parser.index);
            },
            else => {
                parser.index += 1;
                continue :loop .comment;
            },
        },
        .section_inner_start => switch (parser.string[parser.index]) {
            0 => return .init(.invalid, invalid_start, parser.index),
            '\n' => {
                defer parser.index += 1;
                return .init(.invalid, invalid_start, parser.index);
            },
            ']' => {
                start = parser.index;
                end = parser.index;
                parser.index += 1;
                continue :loop .section_end;
            },
            ' ', '\t' => {
                parser.index += 1;
                continue :loop .section_inner_start;
            },
            else => {
                start = parser.index;
                parser.index += 1;
                continue :loop .section_inner;
            },
        },
        .section_inner => switch (parser.string[parser.index]) {
            0 => return .init(.invalid, invalid_start, parser.index),
            '\n' => {
                defer parser.index += 1;
                return .init(.invalid, invalid_start, parser.index);
            },
            ']' => {
                end = parser.index;
                parser.index += 1;
                continue :loop .section_end;
            },
            ' ', '\t' => {
                end = parser.index;
                parser.index += 1;
                continue :loop .section_inner_end;
            },
            else => {
                parser.index += 1;
                continue :loop .section_inner;
            },
        },
        .section_inner_end => switch (parser.string[parser.index]) {
            0 => return .init(.invalid, invalid_start, parser.index),
            '\n' => {
                defer parser.index += 1;
                return .init(.invalid, invalid_start, parser.index);
            },
            ']' => {
                parser.index += 1;
                continue :loop .section_end;
            },
            ' ', '\t' => {
                parser.index += 1;
                continue :loop .section_inner_end;
            },
            else => {
                parser.index += 1;
                continue :loop .section_inner;
            },
        },
        .section_end => switch (parser.string[parser.index]) {
            0 => return .init(.section, start, end),
            '\n' => {
                defer parser.index += 1;
                return .init(.section, start, end);
            },
            ' ', '\t' => {
                parser.index += 1;
                continue :loop .section_end;
            },
            else => {
                parser.index += 1;
                continue :loop .invalid;
            },
        },
        .property_name => switch (parser.string[parser.index]) {
            0 => return .init(.property, start, parser.index),
            '\n' => {
                defer parser.index += 1;
                return .init(.property, start, parser.index);
            },
            '=' => {
                parser.index += 1;
                continue :loop .property_value;
            },
            ' ', '\t' => {
                end = parser.index;
                parser.index += 1;
                continue :loop .property_name_end;
            },
            else => {
                parser.index += 1;
                continue :loop .property_name;
            },
        },
        .property_name_end => switch (parser.string[parser.index]) {
            0 => return .init(.property, start, end),
            '\n' => {
                defer parser.index += 1;
                return .init(.property, start, end);
            },
            '=' => {
                parser.index += 1;
                continue :loop .property_value;
            },
            ' ', '\t' => {
                parser.index += 1;
                continue :loop .property_name_end;
            },
            else => {
                parser.index += 1;
                continue :loop .property_name;
            },
        },
        .property_value => switch (parser.string[parser.index]) {
            0 => return .init(.property, start, parser.index),
            '\n' => {
                defer parser.index += 1;
                return .init(.property, start, parser.index);
            },
            ' ', '\t' => {
                end = parser.index;
                parser.index += 1;
                continue :loop .property_value_end;
            },
            else => {
                parser.index += 1;
                continue :loop .property_value;
            },
        },
        .property_value_end => switch (parser.string[parser.index]) {
            0 => return .init(.property, start, end),
            '\n' => {
                defer parser.index += 1;
                return .init(.property, start, end);
            },
            ' ', '\t' => {
                parser.index += 1;
                continue :loop .property_value_end;
            },
            else => {
                parser.index += 1;
                continue :loop .property_value;
            },
        },
        .invalid => switch (parser.string[parser.index]) {
            0 => return .init(.invalid, invalid_start, parser.index),
            '\n' => {
                defer parser.index += 1;
                return .init(.invalid, invalid_start, parser.index);
            },
            else => {
                parser.index += 1;
                continue :loop .invalid;
            },
        },
    }
}

fn expectedParsed(string: [:0]const u8, expected: []const Result.Kind) !void {
    const gpa = std.testing.allocator;
    const without_leading_or_trailing_ws = try gpa.dupeZ(u8, std.mem.trim(u8, string, " \t\n"));
    defer gpa.free(without_leading_or_trailing_ws);

    const with_trailing_nl = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}\n", .{string}, 0);
    defer std.testing.allocator.free(with_trailing_nl);

    try expectedParsedInner(without_leading_or_trailing_ws, expected);
    try expectedParsedInner(with_trailing_nl, expected);
}

fn expectedParsedInner(string: [:0]const u8, expected: []const Result.Kind) !void {
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

fn parseAndWrite(gpa: std.mem.Allocator, string: []const u8) ![]u8 {
    const str_z = try gpa.dupeZ(u8, string);
    defer gpa.free(str_z);

    var out = std.io.Writer.Allocating.init(gpa);
    errdefer out.deinit();

    var parser = Parser.init(str_z);
    while (true) {
        const result = parser.next();
        if (result.kind == .end)
            return out.toOwnedSlice();

        try result.write(string, &out.writer);
    }
}

test "fuzz" {
    try std.testing.fuzz({}, fuzz.fnFromParseAndWrite(parseAndWrite), .{});
}

pub const Result = struct {
    kind: Kind,
    start: u32,
    end: u32,

    pub fn init(kind: Kind, start: u32, end: u32) Result {
        return .{ .kind = kind, .start = start, .end = end };
    }

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

    pub fn write(result: Result, string: []const u8, writer: *std.io.Writer) !void {
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

fn expectResult(string: [:0]const u8, result: Result) !void {
    var parser = Parser.init(string);
    const actual = parser.next();
    try std.testing.expectEqual(result.kind, actual.kind);
    try std.testing.expectEqual(result.start, actual.start);
    try std.testing.expectEqual(result.end, actual.end);
}

fn expectProperty(string: [:0]const u8, result: Result, expected: Result.Property) !void {
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

fn expectSection(string: [:0]const u8, result: Result, expected: Result.Section) !void {
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
