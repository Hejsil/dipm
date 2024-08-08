green: []const u8,
yellow: []const u8,
red: []const u8,
bold: []const u8,
dim: []const u8,
reset: []const u8,

pub const none = Escapes{
    .red = "",
    .green = "",
    .yellow = "",
    .bold = "",
    .dim = "",
    .reset = "",
};

pub const ansi = Escapes{
    .reset = "\x1b[0m",
    .bold = "\x1b[1m",
    .dim = "\x1b[2m",
    .red = "\x1b[31m",
    .green = "\x1b[32m",
    .yellow = "\x1b[33m",
};

test {}

const Escapes = @This();
