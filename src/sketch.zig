const std = @import("std");
const svg = @import("svg.zig");
const Error = @import("sequence_text.zig").Error;
const Attr = struct { name: []const u8, value: []const u8 };
const Attributes = struct {
    items: [64]Attr = undefined,
    count: usize = 0,
    fn parse(raw: []const u8) Error!Attributes {
        var result: Attributes = .{};
        var at: usize = 0;
        while (at < raw.len) {
            while (at < raw.len and std.ascii.isWhitespace(raw[at])) : (at += 1) {}
            if (at == raw.len or raw[at] == '/') break;
            const start = at;
            while (at < raw.len and raw[at] != '=') : (at += 1) {}
            if (at + 1 >= raw.len or result.count == 64) return error.InvalidSyntax;
            const name = std.mem.trim(u8, raw[start..at], " \t\r\n");
            at += 1;
            const quote = raw[at];
            if (quote != '"' and quote != '\'') return error.InvalidSyntax;
            at += 1;
            const value_start = at;
            while (at < raw.len and raw[at] != quote) : (at += 1) {}
            if (at == raw.len) return error.InvalidSyntax;
            result.items[result.count] = .{ .name = name, .value = raw[value_start..at] };
            result.count += 1;
            at += 1;
        }
        return result;
    }
    fn get(self: *const Attributes, name: []const u8) ?[]const u8 {
        for (self.items[0..self.count]) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
        return null;
    }
    fn num(self: *const Attributes, name: []const u8, fallback: f64) ?f64 {
        const raw = self.get(name) orelse return fallback;
        const value = std.fmt.parseFloat(f64, raw) catch return null;
        if (!std.math.isFinite(value)) return null;
        return value;
    }
};
const Random = struct {
    value: u32,
    fn jitter(self: *Random) f64 {
        self.value = self.value *% 1664525 +% 1013904223;
        return (@as(f64, @floatFromInt(self.value >> 8)) / 16777215 - 0.5) * 1.2;
    }
};
fn listed(value: []const u8, words: []const u8) bool {
    var names = std.mem.tokenizeScalar(u8, words, ' ');
    while (names.next()) |name| if (std.mem.eql(u8, value, name)) return true;
    return false;
}
fn curve(out: *svg.Svg, rng: *Random, x: f64, y: f64, xx: f64, yy: f64) Error!void {
    try out.fmt(" Q {d:.2} {d:.2} {d:.2} {d:.2}", .{ (x + xx) / 2 + rng.jitter(), (y + yy) / 2 + rng.jitter(), xx, yy });
}
fn outline(out: *svg.Svg, name: []const u8, attrs: *const Attributes, rng: *Random) Error!void {
    if (std.mem.eql(u8, attrs.get("stroke") orelse "", "none")) return;
    if (std.mem.eql(u8, name, "rect") and (attrs.num("width", 0) == null or attrs.num("height", 0) == null)) return;
    const custom_path = std.mem.eql(u8, name, "rect") or std.mem.eql(u8, name, "line");
    try out.fmt("<g data-sketch-outline=\"true\" aria-hidden=\"true\" pointer-events=\"none\" transform=\"translate({d:.2} {d:.2})\"><{s}", .{ rng.jitter(), rng.jitter(), if (custom_path) "path" else name });
    // Keep paint/geometry, not semantic IDs, event metadata or duplicate markers.
    for (attrs.items[0..attrs.count]) |attr| {
        if (!listed(attr.name, "class transform vector-effect stroke stroke-width stroke-opacity stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin opacity clip-path mask d points cx cy r rx ry x y width height")) continue;
        if (custom_path and listed(attr.name, "d points x y width height rx ry")) continue;
        try out.fmt(" {s}=\"{s}\"", .{ attr.name, attr.value });
    }
    try out.add(" style=\"");
    if (attrs.get("style")) |style| {
        try out.add(style);
        try out.add(";");
    }
    try out.add("fill:none;stroke-linecap:round;stroke-linejoin:round\"");
    if (custom_path) {
        try out.add(" d=\"");
        if (std.mem.eql(u8, name, "line")) {
            const x = attrs.num("x1", 0) orelse 0;
            const y = attrs.num("y1", 0) orelse 0;
            const xx = attrs.num("x2", 0) orelse 0;
            const yy = attrs.num("y2", 0) orelse 0;
            try out.fmt("M {d:.2} {d:.2}", .{ x, y });
            try curve(out, rng, x, y, xx, yy);
        } else {
            const x = attrs.num("x", 0) orelse 0;
            const y = attrs.num("y", 0) orelse 0;
            const w = attrs.num("width", 0).?;
            const h = attrs.num("height", 0).?;
            const rx = @min(@max(0, attrs.num("rx", 0) orelse 0), w / 2);
            const ry = @min(@max(0, attrs.num("ry", rx) orelse rx), h / 2);
            try out.fmt("M {d:.2} {d:.2}", .{ x + rx, y });
            try curve(out, rng, x + rx, y, x + w - rx, y);
            try out.fmt(" Q {d:.2} {d:.2} {d:.2} {d:.2}", .{ x + w, y, x + w, y + ry });
            try curve(out, rng, x + w, y + ry, x + w, y + h - ry);
            try out.fmt(" Q {d:.2} {d:.2} {d:.2} {d:.2}", .{ x + w, y + h, x + w - rx, y + h });
            try curve(out, rng, x + w - rx, y + h, x + rx, y + h);
            try out.fmt(" Q {d:.2} {d:.2} {d:.2} {d:.2}", .{ x, y + h, x, y + h - ry });
            try curve(out, rng, x, y + h - ry, x, y + ry);
            try out.fmt(" Q {d:.2} {d:.2} {d:.2} {d:.2} Z", .{ x, y, x + rx, y });
        }
        try out.add("\"");
    }
    try out.add("/></g>");
}
// Operates only on our generated SVG. Geometry gets a second lightweight ink
// stroke; text, markers, embedded assets and mathematical notation stay crisp.
pub fn render(a: std.mem.Allocator, source: []const u8, seed: u32) Error![]u8 {
    var out: svg.Svg = .{ .allocator = a, .theme = .light };
    defer out.deinit();
    var rng: Random = .{ .value = if (seed == 0) 1 else seed };
    var ignored: [128]bool = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    var count: usize = 0;
    while (at < source.len) {
        const start = std.mem.indexOfScalarPos(u8, source, at, '<') orelse source.len;
        try out.add(source[at..start]);
        if (start == source.len) break;
        const end = std.mem.indexOfScalarPos(u8, source, start, '>') orelse return error.InvalidSyntax;
        const raw = source[start + 1 .. end];
        at = end + 1;
        if (raw.len == 0) return error.InvalidSyntax;
        const close = raw[0] == '/';
        const name_start: usize = if (close) 1 else 0;
        const name_end = std.mem.indexOfAnyPos(u8, raw, name_start, " \t\r\n/") orelse raw.len;
        const name = raw[name_start..name_end];
        if (close) {
            if (depth == 0) return error.InvalidSyntax;
            depth -= 1;
            try out.add(source[start..at]);
            continue;
        }
        const attrs = try Attributes.parse(raw[name_end..]);
        const skip = (depth > 0 and ignored[depth - 1]) or listed(name, "defs marker clipPath mask style text title desc") or attrs.get("data-asset") != null or attrs.get("data-math") != null;
        const empty = std.mem.endsWith(u8, raw, "/");
        if (depth == 0 and std.mem.eql(u8, name, "svg")) {
            try out.add(source[start..end]);
            try out.fmt(" data-look=\"handDrawn\" data-sketch-seed=\"{d}\">", .{seed});
        } else try out.add(source[start..at]);
        if (empty and !skip and listed(name, "path rect circle ellipse line polyline polygon")) {
            count += 1;
            if (count > 8192) return error.LimitExceeded;
            try outline(&out, name, &attrs, &rng);
        }
        if (!empty) {
            if (depth == ignored.len) return error.LimitExceeded;
            ignored[depth] = skip;
            depth += 1;
        }
    }
    if (depth != 0) return error.InvalidSyntax;
    return out.bytes.toOwnedSlice(a);
}
test "sketch keeps identifiers text and asset content intact" {
    const a = std.testing.allocator;
    const source = "<svg><defs><path id=\"m\" d=\"M 0 0 L 1 1\"/></defs><rect width=\"100%\" height=\"100%\"/><g><rect id=\"n\" width=\"100\" height=\"40\"/><text>Title</text><svg data-asset=\"0\"><path d=\"M 0 0 L 2 2\"/></svg></g></svg>";
    const result = try render(a, source, 42);
    defer a.free(result);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "data-sketch-outline"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "id=\"n\""));
    try std.testing.expect(std.mem.indexOf(u8, result, "<text>Title</text>") != null);
}
