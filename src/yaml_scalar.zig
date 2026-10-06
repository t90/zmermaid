const std = @import("std");
const d = @import("document.zig");

// A bounded scalar reader, not a YAML object loader. Tags, aliases and arbitrary
// object construction are intentionally absent; the document owns map flattening.
pub fn plain(raw: []const u8) []const u8 {
    for (raw, 0..) |c, i| if (c == '#' and (i == 0 or std.ascii.isWhitespace(raw[i - 1]))) return d.trim(raw[0..i]);
    return d.trim(raw);
}
fn addCodepoint(a: std.mem.Allocator, out: *std.ArrayList(u8), n: u32) d.Error!void {
    if (n > 0x10ffff or (n >= 0xd800 and n <= 0xdfff) or n == 0xfffe or n == 0xffff or (n < 32 and n != 9 and n != 10 and n != 13)) return error.InvalidSyntax;
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(n), &bytes) catch return error.InvalidSyntax;
    try out.appendSlice(a, bytes[0..len]);
}
pub fn quoted(a: std.mem.Allocator, source: []const u8, at: *usize) d.Error![]const u8 {
    const quote = source[at.*];
    at.* += 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    while (at.* < source.len) {
        const c = source[at.*];
        at.* += 1;
        if (c == quote) {
            if (quote == '\'' and at.* < source.len and source[at.*] == '\'') {
                at.* += 1;
                try out.append(a, '\'');
                continue;
            }
            return out.toOwnedSlice(a);
        }
        if (quote == '"' and c == '\\') {
            if (at.* == source.len) return error.InvalidSyntax;
            const escaped = source[at.*];
            at.* += 1;
            if (escaped == '\n' or escaped == '\r') {
                if (escaped == '\r' and at.* < source.len and source[at.*] == '\n') at.* += 1;
                while (at.* < source.len and (source[at.*] == ' ' or source[at.*] == '\t')) at.* += 1;
                continue;
            }
            const n: u32 = switch (escaped) {
                'n' => 10,
                'r' => 13,
                't', '\t' => 9,
                '"', '\\', '/', ' ' => escaped,
                'N' => 0x85,
                '_' => 0xa0,
                'L' => 0x2028,
                'P' => 0x2029,
                'x', 'u', 'U' => blk: {
                    const length: usize = if (escaped == 'x') 2 else if (escaped == 'u') 4 else 8;
                    if (source.len - at.* < length) return error.InvalidSyntax;
                    const code = std.fmt.parseInt(u32, source[at.*..][0..length], 16) catch return error.InvalidSyntax;
                    at.* += length;
                    break :blk code;
                },
                else => return error.UnsupportedSyntax,
            };
            try addCodepoint(a, &out, n);
        } else if (c == '\n' or c == '\r') {
            if (c == '\r' and at.* < source.len and source[at.*] == '\n') at.* += 1;
            while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t')) out.items.len -= 1;
            var breaks: usize = 0;
            while (at.* < source.len) {
                if (source[at.*] == ' ' or source[at.*] == '\t' or source[at.*] == '\r') {
                    at.* += 1;
                } else if (source[at.*] == '\n') {
                    breaks += 1;
                    at.* += 1;
                } else break;
            }
            if (breaks == 0) try out.append(a, ' ') else try out.appendNTimes(a, '\n', breaks);
        } else try out.append(a, c);
    }
    return error.InvalidSyntax;
}

pub fn block(a: std.mem.Allocator, source: []const u8, at: *usize, parent_indent: usize, header: []const u8) d.Error![]const u8 {
    const folded = header[0] == '>';
    var chomp: u8 = 0;
    var indent: ?usize = null;
    for (header[1..]) |c| {
        if ((c == '+' or c == '-') and chomp == 0) chomp = c else if (c >= '1' and c <= '9' and indent == null) indent = parent_indent + c - '0' else return error.UnsupportedSyntax;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var previous_nonempty = false;
    var previous_indented = false;
    while (at.* < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, at.*, '\n') orelse source.len;
        const line = std.mem.trimEnd(u8, source[at.*..end], "\r");
        const spaces = line.len - std.mem.trimStart(u8, line, " ").len;
        const empty = d.trim(line).len == 0;
        if (!empty and spaces <= parent_indent) break;
        if (!empty and indent == null) indent = spaces;
        if (!empty and spaces < indent.?) return error.InvalidSyntax;
        const value = if (empty) "" else line[@min(indent.?, line.len)..];
        const indented = !empty and spaces > indent.?;
        if (folded and out.items.len > 0 and previous_nonempty and !empty and !previous_indented and !indented) out.items[out.items.len - 1] = ' ';
        try out.appendSlice(a, value);
        if (!(folded and empty and previous_nonempty and !previous_indented)) try out.append(a, '\n');
        previous_nonempty = !empty;
        previous_indented = indented;
        at.* = @min(end + 1, source.len);
    }
    if (chomp != '+') {
        while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
        if (chomp != '-' and out.items.len > 0) try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

test "quoted YAML scalars decode and fold without executing content" {
    const a = std.testing.allocator;
    var at: usize = 0;
    const value = try quoted(a, "\"line one\n  line two\\n\\u2665\"", &at);
    defer a.free(value);
    try std.testing.expectEqualStrings("line one line two\n♥", value);
    at = 0;
    const single = try quoted(a, "'it''s # literal'", &at);
    defer a.free(single);
    try std.testing.expectEqualStrings("it's # literal", single);
    try std.testing.expectEqualStrings("blue", plain("blue # comment"));
    try std.testing.expectEqualStrings("abc#def", plain("abc#def"));
}

test "literal and folded YAML blocks preserve paragraphs indentation and chomping" {
    const a = std.testing.allocator;
    var at: usize = 0;
    const folded = try block(a, "  one\n  two\n\n  three\nnext: value", &at, 0, ">-");
    defer a.free(folded);
    try std.testing.expectEqualStrings("one two\nthree", folded);
    at = 0;
    const literal = try block(a, "  one\n    two\n\nnext: value", &at, 0, "|+");
    defer a.free(literal);
    try std.testing.expectEqualStrings("one\n  two\n\n", literal);
}
