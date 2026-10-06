const std = @import("std");
const svg = @import("svg.zig");
pub const Error = std.mem.Allocator.Error || error{ UnsupportedSyntax, InvalidSyntax, LimitExceeded, MissingAsset, MissingContext };
pub fn starts(source: []const u8, prefix: []const u8) bool {
    return source.len >= prefix.len and std.ascii.eqlIgnoreCase(source[0..prefix.len], prefix);
}
pub fn parse(a: std.mem.Allocator, source: []const u8) Error![]const u8 {
    if (source.len > 512) return error.LimitExceeded;
    if (starts(source, "wrap:") or starts(source, "nowrap:")) return error.UnsupportedSyntax;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    var lines: usize = 1;
    while (i < source.len) {
        if (source[i] == '<') {
            var length: usize = 0;
            if (starts(source[i..], "<br")) {
                var end = i + 3;
                while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
                if (end < source.len and source[end] == '/') end += 1;
                if (end < source.len and source[end] == '>') length = end - i + 1;
            }
            if (length == 0) {
                if (i + 1 < source.len and (std.ascii.isAlphabetic(source[i + 1]) or source[i + 1] == '/') and std.mem.indexOfScalarPos(u8, source, i + 1, '>') != null) return error.UnsupportedSyntax;
                try out.append(a, '<');
                i += 1;
                continue;
            }
            lines += 1;
            if (lines > 16) return error.LimitExceeded;
            try out.append(a, '\n');
            i += length;
        } else if (source[i] == '#') {
            const end = std.mem.indexOfScalarPos(u8, source, i + 1, ';') orelse {
                try out.append(a, '#');
                i += 1;
                continue;
            };
            const entity = source[i + 1 .. end];
            if (entity.len == 0 or std.mem.indexOfAny(u8, entity, " \t\r\n#") != null) {
                try out.append(a, '#');
                i += 1;
                continue;
            }
            var point: u21 = 0;
            const names = .{ .{ "quot", @as(u21, 34) }, .{ "amp", @as(u21, 38) }, .{ "apos", @as(u21, 39) }, .{ "lt", @as(u21, 60) }, .{ "gt", @as(u21, 62) }, .{ "nbsp", @as(u21, 160) }, .{ "infin", @as(u21, 8734) }, .{ "copy", @as(u21, 169) }, .{ "reg", @as(u21, 174) }, .{ "trade", @as(u21, 8482) }, .{ "mdash", @as(u21, 8212) }, .{ "ndash", @as(u21, 8211) }, .{ "bull", @as(u21, 8226) }, .{ "hellip", @as(u21, 8230) }, .{ "times", @as(u21, 215) }, .{ "divide", @as(u21, 247) }, .{ "le", @as(u21, 8804) }, .{ "ge", @as(u21, 8805) }, .{ "ne", @as(u21, 8800) } };
            inline for (names) |name| {
                if (std.mem.eql(u8, entity, name[0])) {
                    point = name[1];
                }
            }
            if (point == 0) point = std.fmt.parseInt(u21, entity, 10) catch return error.UnsupportedSyntax;
            if (point < 32 or point == 0xfffe or point == 0xffff) return error.InvalidSyntax;
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(point, &encoded) catch return error.InvalidSyntax;
            try out.appendSlice(a, encoded[0..length]);
            i = end + 1;
        } else {
            if (source[i] == '\n') {
                lines += 1;
                if (lines > 16) return error.LimitExceeded;
            }
            try out.append(a, source[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}
pub fn width(label: []const u8) usize {
    var lines = std.mem.splitScalar(u8, label, '\n');
    var value: usize = 0;
    while (lines.next()) |line| value = @max(value, svg.textWidth(line));
    return value;
}
pub fn height(label: []const u8) usize {
    return 20 * (1 + std.mem.count(u8, label, "\n"));
}
pub fn draw(out: *svg.Svg, x: usize, top: usize, label: []const u8) !void {
    var lines = std.mem.splitScalar(u8, label, '\n');
    var y = top + 10;
    while (lines.next()) |line| {
        try out.text(x, y, line);
        y += 20;
    }
}
test "sequence text decodes supported breaks and entities, not HTML" {
    const a = std.testing.allocator;
    const label = try parse(a, "Hello<br/>#quot;SVG#quot;<BR />#9829; #59;");
    defer a.free(label);
    try std.testing.expectEqualStrings("Hello\n\"SVG\"\n♥ ;", label);
    try std.testing.expectEqual(@as(usize, 60), height(label));
    try std.testing.expectError(error.UnsupportedSyntax, parse(a, "<img src=x>"));
    try std.testing.expectError(error.InvalidSyntax, parse(a, "#0;"));
    try std.testing.expectError(error.InvalidSyntax, parse(a, "#55296;"));
}
