const std = @import("std");
const svg = @import("svg.zig");
const txt = @import("sequence_text.zig");
const images = @import("inline_image.zig");
const math = @import("math_text.zig");
const Tag = struct { name: []const u8, attributes: []const u8 };
const tags = [_]Tag{
    .{ .name = "b", .attributes = "font-weight=\"bold\"" },               .{ .name = "strong", .attributes = "font-weight=\"bold\"" },
    .{ .name = "i", .attributes = "font-style=\"italic\"" },              .{ .name = "em", .attributes = "font-style=\"italic\"" },
    .{ .name = "u", .attributes = "text-decoration=\"underline\"" },      .{ .name = "s", .attributes = "text-decoration=\"line-through\"" },
    .{ .name = "del", .attributes = "text-decoration=\"line-through\"" }, .{ .name = "code", .attributes = "font-family=\"Consolas,monospace\"" },
};
pub fn hasFormatting(raw: []const u8) bool {
    if (std.mem.indexOf(u8, raw, "$$") != null) return true;
    if (images.find(raw, 0) != null) return true;
    for (tags) |tag| {
        var buf: [20]u8 = undefined;
        const open = std.fmt.bufPrint(&buf, "<{s}>", .{tag.name}) catch unreachable;
        for (0..raw.len) |i| if (txt.starts(raw[i..], open)) return true;
    }
    return false;
}
// SVG-only emphasis and caller-registered images. No HTML or DOM callbacks.
pub fn parse(a: std.mem.Allocator, raw: []const u8) txt.Error![]const u8 {
    if (raw.len > 512) return error.LimitExceeded;
    if (std.mem.indexOf(u8, raw, "](") != null or std.mem.indexOf(u8, raw, "][") != null) return error.UnsupportedSyntax;
    if (!hasFormatting(raw)) return txt.parse(a, raw);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var stack: [16]usize = undefined;
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (std.mem.startsWith(u8, raw[i..], "$$")) {
            const length = math.token(raw[i..]) orelse return error.InvalidSyntax;
            _ = try math.Layout.init(raw[i .. i + length]);
            const decoded = try txt.parse(a, raw[start..i]);
            defer a.free(decoded);
            try appendLines(a, &out, decoded, stack[0..depth]);
            for (raw[i .. i + length]) |c| try out.append(a, if (c == '\n' or c == '\r') ' ' else c);
            start = i + length;
            i = start - 1;
            continue;
        }
        if (raw[i] != '<') continue;
        if (images.starts(raw[i..])) {
            const item = try images.parse(raw[i..]);
            const decoded = try txt.parse(a, raw[start..i]);
            defer a.free(decoded);
            try appendLines(a, &out, decoded, stack[0..depth]);
            try out.appendSlice(a, raw[i .. i + item.end]);
            start = i + item.end;
            i = start - 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, raw, i, '>') orelse continue;
        const closing = i + 1 < raw.len and raw[i + 1] == '/';
        const name = raw[i + (if (closing) @as(usize, 2) else 1) .. end];
        var found: ?usize = null;
        for (tags, 0..) |tag, index| if (std.ascii.eqlIgnoreCase(name, tag.name)) {
            found = index;
        };
        const index = found orelse continue;
        const decoded = try txt.parse(a, raw[start..i]);
        defer a.free(decoded);
        try appendLines(a, &out, decoded, stack[0..depth]);
        if (closing) {
            if (depth == 0 or stack[depth - 1] != index) return error.InvalidSyntax;
            depth -= 1;
        } else {
            if (depth == stack.len) return error.LimitExceeded;
            stack[depth] = index;
            depth += 1;
        }
        try out.appendSlice(a, if (closing) "</" else "<");
        try out.appendSlice(a, tags[index].name);
        try out.append(a, '>');
        start = end + 1;
        i = end;
    }
    if (depth != 0) return error.InvalidSyntax;
    const decoded = try txt.parse(a, raw[start..]);
    defer a.free(decoded);
    try appendLines(a, &out, decoded, &.{});
    if (std.mem.count(u8, out.items, "\n") >= 16) return error.LimitExceeded;
    return out.toOwnedSlice(a);
}
fn appendLines(a: std.mem.Allocator, out: *std.ArrayList(u8), decoded: []const u8, active: []const usize) !void {
    for (decoded) |c| {
        if (c == '\n') {
            var i = active.len;
            while (i > 0) {
                i -= 1;
                try out.appendSlice(a, "</");
                try out.appendSlice(a, tags[active[i]].name);
                try out.append(a, '>');
            }
            try out.append(a, '\n');
            for (active) |index| {
                try out.append(a, '<');
                try out.appendSlice(a, tags[index].name);
                try out.append(a, '>');
            }
        } else try out.append(a, c);
    }
}
fn closeTag(raw: []const u8, start: usize, open: []const u8, close: []const u8) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < raw.len) : (i += 1) {
        if (std.mem.startsWith(u8, raw[i..], open)) {
            depth += 1;
            i += open.len - 1;
        } else if (std.mem.startsWith(u8, raw[i..], close)) {
            depth -= 1;
            if (depth == 0) return i;
            i += close.len - 1;
        }
    }
    return null;
}
pub fn width(raw: []const u8) usize {
    var glyphs: [512]Glyph = undefined;
    const count = flatten(raw, &glyphs) catch {
        var lines = std.mem.splitScalar(u8, raw, '\n');
        var widest: usize = 0;
        while (lines.next()) |line| widest = @max(widest, svg.textWidth(line));
        return widest;
    };
    var widest: usize = 0;
    var line: usize = 0;
    for (glyphs[0..count]) |glyph| {
        if (std.mem.eql(u8, glyph.text, "\n")) {
            widest = @max(widest, line);
            line = 0;
        } else line += glyphWidth(glyph.text);
    }
    return @max(widest, line);
}
pub const Glyph = struct { text: []const u8, style: u8 };
pub fn flatten(raw: []const u8, glyphs: *[512]Glyph) txt.Error!usize {
    var count: usize = 0;
    try styledGlyphs(glyphs, &count, raw, 0, 0);
    return count;
}
pub fn drawStyled(out: *svg.Svg, x: usize, y: usize, raw: []const u8, fg: []const u8, style: u8) !void {
    try out.add("<g");
    if (style & 1 != 0) try out.add(" font-weight=\"bold\"");
    if (style & 2 != 0) try out.add(" font-style=\"italic\"");
    if (style & 12 != 0) try out.fmt(" text-decoration=\"{s}{s}{s}\"", .{ if (style & 4 != 0) "underline" else "", if (style & 12 == 12) " " else "", if (style & 8 != 0) "line-through" else "" });
    try out.add(">");
    try out.textColor(x, y, raw, fg);
    try out.add("</g>");
}
pub fn glyphWidth(glyph: []const u8) usize {
    if (math.token(glyph)) |len| {
        const layout = math.Layout.init(glyph[0..len]) catch return svg.textWidth(glyph);
        return layout.pixelWidth() + 4;
    }
    if (images.token(glyph)) |item| return item.width + 4;
    if (@import("assets.zig").inlineIcon(glyph, 0)) |icon| if (icon.start == 0 and icon.end == glyph.len) return 20;
    return svg.textWidth(glyph);
}
fn literalGlyphs(glyphs: *[512]Glyph, count: *usize, raw: []const u8, style: u8) txt.Error!void {
    if (style & 16 != 0 and std.mem.indexOf(u8, raw, "</code>") != null) return error.UnsupportedSyntax;
    var i: usize = 0;
    while (i < raw.len) {
        if (count.* == glyphs.len) return error.LimitExceeded;
        var length: usize = std.unicode.utf8ByteSequenceLength(raw[i]) catch return error.InvalidSyntax;
        if (math.token(raw[i..])) |len| length = len;
        if (images.token(raw[i..])) |item| length = item.end;
        if (@import("assets.zig").inlineIcon(raw, i)) |icon| if (icon.start == i) {
            length = icon.end - i;
        };
        if (i + length > raw.len) return error.InvalidSyntax;
        glyphs[count.*] = .{ .text = raw[i .. i + length], .style = style };
        count.* += 1;
        i += length;
    }
}
fn styledGlyphs(glyphs: *[512]Glyph, count: *usize, raw: []const u8, style: u8, depth: usize) txt.Error!void {
    if (depth > 16) return error.LimitExceeded;
    var i: usize = 0;
    while (i < raw.len) {
        if (math.token(raw[i..])) |len| {
            try literalGlyphs(glyphs, count, raw[i .. i + len], style);
            i += len;
            continue;
        }
        if (images.token(raw[i..])) |item| {
            try literalGlyphs(glyphs, count, raw[i .. i + item.end], style);
            i += item.end;
            continue;
        }
        if (@import("assets.zig").inlineIcon(raw, i)) |icon| if (icon.start == i) {
            try literalGlyphs(glyphs, count, raw[i..icon.end], style);
            i = icon.end;
            continue;
        };
        if (raw[i] == '<') {
            var matched = false;
            for (tags, 0..) |tag, index| {
                var open_buf: [20]u8 = undefined;
                var close_buf: [20]u8 = undefined;
                const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag.name}) catch unreachable;
                const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag.name}) catch unreachable;
                if (!std.mem.startsWith(u8, raw[i..], open)) continue;
                const end = closeTag(raw, i + open.len, open, close) orelse continue;
                const flag: u8 = switch (index) {
                    0, 1 => 1,
                    2, 3 => 2,
                    4 => 4,
                    5, 6 => 8,
                    else => 16,
                };
                const inner = raw[i + open.len .. end];
                if (flag == 16) try literalGlyphs(glyphs, count, inner, style | flag) else try styledGlyphs(glyphs, count, inner, style | flag, depth + 1);
                i = end + close.len;
                matched = true;
                break;
            }
            if (matched) continue;
        }
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            const length = std.unicode.utf8ByteSequenceLength(raw[i]) catch return error.InvalidSyntax;
            if (i + length > raw.len) return error.InvalidSyntax;
            try literalGlyphs(glyphs, count, raw[i .. i + length], style);
            i += length;
            continue;
        }
        if ((raw[i] == '*' or raw[i] == '_' or raw[i] == '`') and !(raw[i] == '_' and i > 0 and std.ascii.isAlphanumeric(raw[i - 1]))) {
            const marker: usize = if (raw[i] != '`' and i + 1 < raw.len and raw[i + 1] == raw[i]) 2 else 1;
            if (std.mem.indexOfPos(u8, raw, i + marker, raw[i .. i + marker])) |end| {
                if (end > i + marker and !std.ascii.isWhitespace(raw[i + marker])) {
                    const flag: u8 = if (raw[i] == '`') 16 else if (marker == 2) 1 else 2;
                    if (flag == 16) try literalGlyphs(glyphs, count, raw[i + marker .. end], style | flag) else try styledGlyphs(glyphs, count, raw[i + marker .. end], style | flag, depth + 1);
                    i = end + marker;
                    continue;
                }
            }
        }
        const length = std.unicode.utf8ByteSequenceLength(raw[i]) catch return error.InvalidSyntax;
        if (i + length > raw.len) return error.InvalidSyntax;
        try literalGlyphs(glyphs, count, raw[i .. i + length], style);
        i += length;
    }
}
fn changeStyle(a: std.mem.Allocator, out: *std.ArrayList(u8), active: *u8, next: u8) !void {
    if (active.* == next) return;
    const names = [_][]const u8{ "b", "i", "u", "s", "code" };
    for (0..5) |reverse| {
        const i = 4 - reverse;
        if (active.* & (@as(u8, 1) << @intCast(i)) != 0) {
            try out.appendSlice(a, "</");
            try out.appendSlice(a, names[i]);
            try out.append(a, '>');
        }
    }
    for (names, 0..) |name, i| if (next & (@as(u8, 1) << @intCast(i)) != 0) {
        try out.append(a, '<');
        try out.appendSlice(a, name);
        try out.append(a, '>');
    };
    active.* = next;
}
// Wrap visible glyphs, not markup bytes; each resulting line has balanced styles.
pub fn wrap(a: std.mem.Allocator, raw: []const u8, max_width: usize) txt.Error![]const u8 {
    var glyphs: [512]Glyph = undefined;
    var count: usize = 0;
    try styledGlyphs(&glyphs, &count, raw, 0, 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var active: u8 = 0;
    var line: usize = 0;
    var lines: usize = 1;
    var i: usize = 0;
    while (i < count) {
        const char = glyphs[i].text;
        if (std.mem.eql(u8, char, "\n")) {
            try changeStyle(a, &out, &active, 0);
            try out.append(a, '\n');
            lines += 1;
            line = 0;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, char, " ") or std.mem.eql(u8, char, "\t")) {
            i += 1;
            continue;
        }
        var end = i;
        var word_width: usize = 0;
        while (end < count and !std.mem.eql(u8, glyphs[end].text, " ") and !std.mem.eql(u8, glyphs[end].text, "\t") and !std.mem.eql(u8, glyphs[end].text, "\n")) : (end += 1) word_width += glyphWidth(glyphs[end].text);
        if (line > 0) {
            if (line + 9 + word_width > max_width) {
                try changeStyle(a, &out, &active, 0);
                try out.append(a, '\n');
                lines += 1;
                line = 0;
            } else {
                try out.append(a, ' ');
                line += 9;
            }
        }
        while (i < end) : (i += 1) {
            const glyph = glyphs[i];
            const w = glyphWidth(glyph.text);
            if (line > 0 and line + w > max_width) {
                try changeStyle(a, &out, &active, 0);
                try out.append(a, '\n');
                lines += 1;
                line = 0;
            }
            if (lines > 64) return error.LimitExceeded;
            try changeStyle(a, &out, &active, glyph.style);
            if (glyph.style & 16 == 0 and glyph.text.len == 1 and std.mem.indexOfScalar(u8, "*_`<\\", glyph.text[0]) != null) try out.append(a, '\\');
            try out.appendSlice(a, glyph.text);
            line += w;
        }
    }
    if (lines > 64) return error.LimitExceeded;
    try changeStyle(a, &out, &active, 0);
    return out.toOwnedSlice(a);
}
test "Markdown wrapping preserves styles escapes and UTF-8 across lines" {
    const a = std.testing.allocator;
    const result = try wrap(a, "**Alpha beta gamma delta** and `code words`", 90);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<b>Alpha beta</b>\n<b>gamma</b>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<code>code words</code>") != null);
    const escaped = try wrap(a, "\\*literal\\* 文件文件文件", 90);
    defer a.free(escaped);
    try std.testing.expect(std.unicode.utf8ValidateSlice(escaped));
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\*literal\\*") != null);
    const nested = try wrap(a, "<b>One <i>two three four</i> five</b>", 60);
    defer a.free(nested);
    var lines = std.mem.splitScalar(u8, nested, '\n');
    while (lines.next()) |line| {
        try std.testing.expectEqual(std.mem.count(u8, line, "<b>"), std.mem.count(u8, line, "</b>"));
        try std.testing.expectEqual(std.mem.count(u8, line, "<i>"), std.mem.count(u8, line, "</i>"));
    }
}
fn spans(out: *svg.Svg, raw: []const u8, depth: usize) std.mem.Allocator.Error!void {
    if (depth == 16) {
        try out.escape(raw);
        return;
    }
    var i: usize = 0;
    var plain: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '<') {
            var matched = false;
            for (tags) |tag| {
                var open_buf: [20]u8 = undefined;
                var close_buf: [20]u8 = undefined;
                const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag.name}) catch unreachable;
                const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag.name}) catch unreachable;
                if (!std.mem.startsWith(u8, raw[i..], open)) continue;
                const end = closeTag(raw, i + open.len, open, close) orelse continue;
                try out.escape(raw[plain..i]);
                try out.fmt("<tspan {s}>", .{tag.attributes});
                if (std.mem.eql(u8, tag.name, "code")) try out.escape(raw[i + open.len .. end]) else try spans(out, raw[i + open.len .. end], depth + 1);
                try out.add("</tspan>");
                i = end + close.len;
                plain = i;
                matched = true;
                break;
            }
            if (matched) continue;
        }
        if (raw[i] == '\\' and i + 1 < raw.len) {
            try out.escape(raw[plain..i]);
            try out.escape(raw[i + 1 .. i + 2]);
            i += 2;
            plain = i;
            continue;
        }
        if (raw[i] != '*' and raw[i] != '_' and raw[i] != '`') {
            i += 1;
            continue;
        }
        if (raw[i] == '_' and i > 0 and std.ascii.isAlphanumeric(raw[i - 1])) {
            i += 1;
            continue;
        }
        const count: usize = if (raw[i] != '`' and i + 1 < raw.len and raw[i + 1] == raw[i]) 2 else 1;
        const end = std.mem.indexOfPos(u8, raw, i + count, raw[i .. i + count]) orelse {
            i += count;
            continue;
        };
        if (end == i + count or std.ascii.isWhitespace(raw[i + count])) {
            i += count;
            continue;
        }
        try out.escape(raw[plain..i]);
        try out.add(if (raw[i] == '`') "<tspan font-family=\"Consolas,monospace\">" else if (count == 2) "<tspan font-weight=\"bold\">" else "<tspan font-style=\"italic\">");
        if (raw[i] == '`') try out.escape(raw[i + count .. end]) else try spans(out, raw[i + count .. end], depth + 1);
        try out.add("</tspan>");
        i = end + count;
        plain = i;
    }
    try out.escape(raw[plain..]);
}
pub fn draw(out: *svg.Svg, x: usize, y: usize, raw: []const u8, fg: []const u8) !void {
    try out.fmt("<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-family=\"Arial,Helvetica,sans-serif\" font-size=\"14\" fill=\"{s}\" stroke=\"none\">", .{ x, y, fg });
    try spans(out, raw, 0);
    try out.add("</text>");
}
