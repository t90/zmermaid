const std = @import("std");
const txt = @import("sequence_text.zig");

// A label image is a registry key, never an HTML element or a resource request.
pub const Image = struct { end: usize, name: []const u8, alt: []const u8 = "", width: usize = 64, height: usize = 64 };
pub fn starts(raw: []const u8) bool {
    return txt.starts(raw, "<img") and raw.len > 4 and (std.ascii.isWhitespace(raw[4]) or raw[4] == '/' or raw[4] == '>');
}
pub fn find(raw: []const u8, from: usize) ?usize {
    var i = from;
    while (i < raw.len) : (i += 1) if (starts(raw[i..])) return i;
    return null;
}
pub fn parse(raw: []const u8) txt.Error!Image {
    if (!starts(raw)) return error.InvalidSyntax;
    var result: Image = .{ .end = 0, .name = "" };
    var seen: u8 = 0;
    var i: usize = 4;
    while (i < raw.len) {
        while (i < raw.len and std.ascii.isWhitespace(raw[i])) : (i += 1) {}
        if (i == raw.len) return error.InvalidSyntax;
        if (raw[i] == '/' and i + 1 < raw.len and raw[i + 1] == '>') i += 1;
        if (raw[i] == '>') {
            if (result.name.len == 0) {
                if (seen & 2 == 0) result.width = 16;
                if (seen & 4 == 0) result.height = 16;
            }
            result.end = i + 1;
            return result;
        }
        const start = i;
        while (i < raw.len and std.ascii.isAlphabetic(raw[i])) : (i += 1) {}
        const name = raw[start..i];
        const bit: u8 = if (std.ascii.eqlIgnoreCase(name, "src")) 1 else if (std.ascii.eqlIgnoreCase(name, "width")) 2 else if (std.ascii.eqlIgnoreCase(name, "height")) 4 else if (std.ascii.eqlIgnoreCase(name, "alt")) 8 else if (std.ascii.eqlIgnoreCase(name, "title")) 16 else return error.UnsupportedSyntax;
        if (seen & bit != 0) return error.InvalidSyntax;
        seen |= bit;
        while (i < raw.len and std.ascii.isWhitespace(raw[i])) : (i += 1) {}
        if (i == raw.len or raw[i] != '=') return error.InvalidSyntax;
        i += 1;
        while (i < raw.len and std.ascii.isWhitespace(raw[i])) : (i += 1) {}
        if (i == raw.len) return error.InvalidSyntax;
        const quote = if (raw[i] == '\'' or raw[i] == '"') raw[i] else @as(u8, 0);
        if (quote != 0) i += 1;
        const value_start = i;
        while (i < raw.len and (if (quote != 0) raw[i] != quote else !std.ascii.isWhitespace(raw[i]) and raw[i] != '>')) : (i += 1) {
            if (raw[i] < 32 or raw[i] == '<' or (quote == 0 and (raw[i] == '"' or raw[i] == '\'' or raw[i] == '`' or raw[i] == '='))) return error.InvalidSyntax;
        }
        if (i == raw.len) return error.InvalidSyntax;
        const value = raw[value_start..i];
        if (quote != 0) {
            i += 1;
            if (i < raw.len and !std.ascii.isWhitespace(raw[i]) and raw[i] != '/' and raw[i] != '>') return error.InvalidSyntax;
        }
        switch (bit) {
            1 => result.name = value,
            2, 4 => {
                const pixels = if (std.mem.endsWith(u8, value, "px")) value[0 .. value.len - 2] else value;
                const size = std.fmt.parseInt(usize, pixels, 10) catch return error.InvalidSyntax;
                if (size == 0 or size > 2048) return error.LimitExceeded;
                if (bit == 2) result.width = size else result.height = size;
            },
            8, 16 => {
                if (bit == 8 or result.alt.len == 0) result.alt = value;
            },
            else => unreachable,
        }
    }
    return error.InvalidSyntax;
}
pub fn token(raw: []const u8) ?Image {
    if (!starts(raw)) return null;
    return parse(raw) catch null;
}
pub fn height(raw: []const u8) usize {
    var value: usize = 20;
    var at: usize = 0;
    while (find(raw, at)) |pos| {
        const item = parse(raw[pos..]) catch {
            at = pos + 4;
            continue;
        };
        value = @max(value, item.height + 4);
        at = pos + item.end;
    }
    return value;
}
test "inline images are bounded registry references, never arbitrary HTML" {
    const image = try parse("<IMG src='local' width=100 height=40px alt='Preview'/>rest");
    try std.testing.expectEqualStrings("local", image.name);
    try std.testing.expectEqual(@as(usize, 100), image.width);
    try std.testing.expectEqual(@as(usize, 40), image.height);
    try std.testing.expectError(error.UnsupportedSyntax, parse("<img src=x onerror='alert(1)'>"));
    try std.testing.expectError(error.InvalidSyntax, parse("<img src=x SRC=y>"));
    try std.testing.expectError(error.LimitExceeded, parse("<img src=x width=2049>"));
}
