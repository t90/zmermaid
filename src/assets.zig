const std = @import("std");
const d = @import("document.zig");
const svg = @import("svg.zig");
pub const Asset = struct { width: f64 = 24, height: f64 = 24, svg: []const u8 = "", data: []const u8 = "" };
pub const Registry = struct {
    map: std.json.ArrayHashMap(Asset) = .{},
    pub fn parse(a: std.mem.Allocator, raw: []const u8) d.Error!Registry {
        if (raw.len == 0) return .{};
        if (raw.len > 1024 * 1024) return error.LimitExceeded;
        const parsed = std.json.parseFromSlice(std.json.ArrayHashMap(Asset), a, raw, .{ .allocate = .alloc_always }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidSyntax,
        };
        if (parsed.value.map.count() > 256) return error.LimitExceeded;
        var it = parsed.value.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.len == 0 or entry.key_ptr.len > 2048) return error.InvalidSyntax;
            const item = entry.value_ptr;
            if (!std.math.isFinite(item.width) or !std.math.isFinite(item.height) or item.width <= 0 or item.height <= 0 or item.width > 16384 or item.height > 16384) return error.InvalidSyntax;
            if ((item.svg.len == 0) == (item.data.len == 0)) return error.InvalidSyntax;
            if (item.svg.len > 0) try body(null, item.svg, 0, 0) else try raster(item.data);
        }
        return .{ .map = parsed.value };
    }
    pub fn get(self: *const Registry, name: []const u8) d.Error!*const Asset {
        return self.map.map.getPtr(name) orelse error.MissingAsset;
    }
};
fn raster(value: []const u8) d.Error!void {
    var start: usize = 0;
    for ([_][]const u8{ "data:image/png;base64,", "data:image/jpeg;base64,", "data:image/gif;base64,", "data:image/webp;base64," }) |prefix| if (std.mem.startsWith(u8, value, prefix)) {
        start = prefix.len;
    };
    if (start == 0 or value.len == start or (value.len - start) % 4 != 0) return error.InvalidSyntax;
    var padding: usize = 0;
    for (value[start..]) |c| {
        if (c == '=') {
            padding += 1;
            if (padding > 2) return error.InvalidSyntax;
        } else if (padding > 0 or (!std.ascii.isAlphanumeric(c) and c != '+' and c != '/')) return error.InvalidSyntax;
    }
}
fn listed(value: []const u8, names: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, names, ' ');
    while (words.next()) |name| if (std.mem.eql(u8, value, name)) return true;
    return false;
}
fn nameValid(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    return true;
}
const Tag = struct { name: []const u8, close: bool, empty: bool, attrs: []const u8 };
fn tag(raw: []const u8) d.Error!Tag {
    var text = d.trim(raw);
    var close = false;
    var empty = false;
    if (text.len == 0) return error.InvalidSyntax;
    if (text[0] == '/') {
        close = true;
        text = d.trim(text[1..]);
    }
    if (std.mem.endsWith(u8, text, "/")) {
        empty = true;
        text = d.trim(text[0 .. text.len - 1]);
    }
    const at = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
    const name = text[0..at];
    if (!listed(name, "svg g path rect circle ellipse line polyline polygon defs linearGradient radialGradient stop clipPath mask use title desc")) return error.UnsupportedSyntax;
    if (close and (empty or at != text.len)) return error.InvalidSyntax;
    return .{ .name = name, .close = close, .empty = empty, .attrs = d.trim(text[at..]) };
}
fn attribute(name: []const u8, value: []const u8) d.Error!void {
    for (value) |c| if (c < 32 or c == '&' or c == '<' or c == '>') return error.InvalidSyntax;
    if (std.mem.eql(u8, name, "xmlns")) {
        if (!std.mem.eql(u8, value, "http://www.w3.org/2000/svg")) return error.InvalidSyntax;
        return;
    }
    if (std.mem.eql(u8, name, "xmlns:xlink")) {
        if (!std.mem.eql(u8, value, "http://www.w3.org/1999/xlink")) return error.InvalidSyntax;
        return;
    }
    if (std.mem.eql(u8, name, "id")) {
        if (!nameValid(value)) return error.InvalidSyntax;
        return;
    }
    if (listed(name, "href xlink:href")) {
        if (value.len < 2 or value[0] != '#' or !nameValid(value[1..])) return error.UnsupportedSyntax;
        return;
    }
    if (listed(name, "fill stroke stop-color color clip-path mask")) {
        if (std.mem.startsWith(u8, value, "url(#") and std.mem.endsWith(u8, value, ")")) {
            if (!nameValid(value[5 .. value.len - 1])) return error.InvalidSyntax;
            return;
        }
        if (listed(value, "none currentColor transparent")) return;
        _ = try d.color(value);
        return;
    }
    if (listed(name, "fill-rule clip-rule")) {
        if (!listed(value, "nonzero evenodd")) return error.InvalidSyntax;
        return;
    }
    if (listed(name, "stroke-linecap stroke-linejoin")) {
        if (!listed(value, "butt round square miter bevel")) return error.InvalidSyntax;
        return;
    }
    if (listed(name, "gradientUnits clipPathUnits maskUnits maskContentUnits")) {
        if (!listed(value, "userSpaceOnUse objectBoundingBox")) return error.InvalidSyntax;
        return;
    }
    if (std.mem.eql(u8, name, "spreadMethod")) {
        if (!listed(value, "pad reflect repeat")) return error.InvalidSyntax;
        return;
    }
    if (std.mem.eql(u8, name, "preserveAspectRatio")) {
        if (!listed(value, "none xMidYMid xMinYMin") and !std.mem.eql(u8, value, "xMidYMid meet")) return error.UnsupportedSyntax;
        return;
    }
    if (listed(name, "transform gradientTransform")) {
        for (value) |c| if (!std.ascii.isAlphabetic(c) and !std.ascii.isDigit(c) and std.mem.indexOfScalar(u8, " .,+-()\t", c) == null) return error.InvalidSyntax;
        return;
    }
    if (std.mem.eql(u8, name, "d")) {
        for (value) |c| if (!std.ascii.isDigit(c) and std.mem.indexOfScalar(u8, "MmZzLlHhVvCcSsQqTtAaEe .,+-\t", c) == null) return error.InvalidSyntax;
        return;
    }
    if (!listed(name, "x y x1 y1 x2 y2 cx cy r rx ry width height viewBox points opacity fill-opacity stroke-opacity stop-opacity offset stroke-width stroke-miterlimit stroke-dasharray stroke-dashoffset pathLength fx fy fr")) return error.UnsupportedSyntax;
    var nums = std.mem.tokenizeAny(u8, value, " ,\t");
    var count: usize = 0;
    while (nums.next()) |raw| {
        const n = try d.number(if (std.mem.endsWith(u8, raw, "%")) raw[0 .. raw.len - 1] else raw);
        if (@abs(n) > 1e7) return error.LimitExceeded;
        count += 1;
    }
    if (count == 0 or count > 8192) return error.InvalidSyntax;
}
// Deliberately bounded SVG subset: no scripts, events, CSS, foreignObject,
// entities, external references or remote fonts. IDs/references are scoped per instance.
const References = struct {
    starts: [512]usize = undefined,
    ends: [512]usize = .{0} ** 512,
    levels: [512]usize = undefined,
    positions: [1024]usize = undefined,
    targets: [1024]usize = undefined,
    states: [512]u8 = .{0} ** 512,
    costs: [512]usize = .{0} ** 512,
    lengths: [512]usize = .{0} ** 512,
    count: usize = 0,
    fn visit(self: *References, index: usize, depth: usize) d.Error!usize {
        if (self.states[index] == 1) return error.InvalidSyntax;
        if (depth > 32) return error.LimitExceeded;
        if (self.states[index] == 2) {
            if (depth + self.lengths[index] > 32) return error.LimitExceeded;
            return self.costs[index];
        }
        self.states[index] = 1;
        var cost = self.ends[index] - self.starts[index] + 1;
        var length: usize = 0;
        for (self.positions[0..self.count], self.targets[0..self.count]) |pos, target| {
            if (pos < self.starts[index] or pos > self.ends[index]) continue;
            cost += try self.visit(target, depth + 1);
            length = @max(length, self.lengths[target] + 1);
            if (cost > 65536) return error.LimitExceeded;
        }
        self.states[index] = 2;
        self.costs[index] = cost;
        self.lengths[index] = length;
        return cost;
    }
};
fn body(output: ?*svg.Svg, raw: []const u8, prefix: u32, instance: usize) d.Error!void {
    var at: usize = 0;
    var stack: [32][]const u8 = undefined;
    var depth: usize = 0;
    var tags: usize = 0;
    var ids: [512][]const u8 = undefined;
    var id_count: usize = 0;
    var refs: [1024][]const u8 = undefined;
    var ref_count: usize = 0;
    var graph: References = .{};
    while (at < raw.len) {
        if (raw[at] != '<') {
            const end = std.mem.indexOfScalarPos(u8, raw, at, '<') orelse raw.len;
            const text = raw[at..end];
            if (d.trim(text).len > 0) {
                if (depth == 0 or !listed(stack[depth - 1], "title desc")) return error.InvalidSyntax;
                if (output) |out| try out.escape(text);
            }
            at = end;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, raw, at + 1, '>') orelse return error.InvalidSyntax;
        const t = try tag(raw[at + 1 .. end]);
        at = end + 1;
        tags += 1;
        if (tags > 4096) return error.LimitExceeded;
        if (t.close) {
            if (depth == 0 or !std.mem.eql(u8, stack[depth - 1], t.name)) return error.InvalidSyntax;
            for (0..id_count) |i| if (graph.ends[i] == 0 and graph.levels[i] == depth) {
                graph.ends[i] = tags;
            };
            depth -= 1;
            if (output) |out| try out.fmt("</{s}>", .{t.name});
            continue;
        }
        if (depth > 0 and listed(stack[depth - 1], "title desc")) return error.InvalidSyntax;
        if (!t.empty) {
            if (depth == 32) return error.LimitExceeded;
            stack[depth] = t.name;
            depth += 1;
        }
        if (output) |out| try out.fmt("<{s}", .{t.name});
        var attrs = t.attrs;
        var names: [64][]const u8 = undefined;
        var name_count: usize = 0;
        while (attrs.len > 0) {
            const eq = std.mem.indexOfScalar(u8, attrs, '=') orelse return error.InvalidSyntax;
            const name = d.trim(attrs[0..eq]);
            attrs = d.trim(attrs[eq + 1 ..]);
            if (attrs.len < 2 or (attrs[0] != '"' and attrs[0] != '\'')) return error.InvalidSyntax;
            const stop = std.mem.indexOfScalarPos(u8, attrs, 1, attrs[0]) orelse return error.InvalidSyntax;
            const value = attrs[1..stop];
            attrs = d.trim(attrs[stop + 1 ..]);
            if (name_count == 64) return error.LimitExceeded;
            for (names[0..name_count]) |old| if (std.mem.eql(u8, old, name)) return error.InvalidSyntax;
            names[name_count] = name;
            name_count += 1;
            try attribute(name, value);
            const is_id = std.mem.eql(u8, name, "id");
            const is_href = listed(name, "href xlink:href");
            const is_url = std.mem.startsWith(u8, value, "url(#");
            const ref = if (is_id) value else if (is_href) value[1..] else if (is_url) value[5 .. value.len - 1] else "";
            if (is_id) {
                if (id_count == 512) return error.LimitExceeded;
                for (ids[0..id_count]) |old| if (std.mem.eql(u8, old, ref)) return error.InvalidSyntax;
                ids[id_count] = ref;
                graph.starts[id_count] = tags;
                graph.ends[id_count] = if (t.empty) tags else 0;
                graph.levels[id_count] = depth;
                id_count += 1;
            } else if (is_href or is_url) {
                if (ref_count == 1024) return error.LimitExceeded;
                refs[ref_count] = ref;
                graph.positions[ref_count] = tags;
                ref_count += 1;
            }
            if (output) |out| {
                try out.fmt(" {s}=\"", .{if (is_href) "href" else name});
                if (is_id or is_href or is_url) try out.fmt("{s}zm-{d}-asset-{d}-{s}{s}", .{ if (is_href) "#" else if (is_url) "url(#" else "", prefix, instance, ref, if (is_url) ")" else "" }) else try out.escape(value);
                try out.add("\"");
            }
        }
        if (output) |out| try out.add(if (t.empty) "/>" else ">");
    }
    if (depth != 0 or tags == 0) return error.InvalidSyntax;
    graph.count = ref_count;
    for (refs[0..ref_count], 0..) |ref, r| {
        var found = false;
        for (ids[0..id_count], 0..) |id, i| if (std.mem.eql(u8, id, ref)) {
            found = true;
            graph.targets[r] = i;
        };
        if (!found) return error.InvalidSyntax;
    }
    for (0..id_count) |i| _ = try graph.visit(i, 0);
    var expanded = tags;
    for (graph.targets[0..ref_count]) |target| {
        expanded += graph.costs[target];
        if (expanded > 65536) return error.LimitExceeded;
    }
}
pub fn draw(out: *svg.Svg, item: *const Asset, x: usize, y: usize, width: usize, height: usize) d.Error!void {
    const instance = out.asset_instance;
    out.asset_instance += 1;
    if (item.data.len > 0) {
        try out.fmt("<image data-asset=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" href=\"{s}\"/>", .{ instance, x, y, width, height, item.data });
        return;
    }
    try out.fmt("<svg data-asset=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\" fill=\"currentColor\" stroke=\"none\" color=\"{s}\">", .{ instance, x, y, width, height, item.width, item.height, if (out.theme == .dark) "#e0e0e0" else "#24292f" });
    try body(out, item.svg, out.id_prefix, instance);
    try out.add("</svg>");
}

pub const InlineIcon = struct { start: usize, end: usize, name: []const u8 };
pub fn inlineIcon(raw: []const u8, from: usize) ?InlineIcon {
    const colon = std.mem.indexOfPos(u8, raw, from, ":fa-") orelse return null;
    var start = colon;
    while (start > from and (std.ascii.isAlphanumeric(raw[start - 1]) or raw[start - 1] == '_' or raw[start - 1] == '-')) start -= 1;
    var end = colon + 4;
    while (end < raw.len and (std.ascii.isAlphanumeric(raw[end]) or raw[end] == '_' or raw[end] == '-')) end += 1;
    if (start == colon or end == colon + 4) return inlineIcon(raw, colon + 4);
    return .{ .start = start, .end = end, .name = raw[start..end] };
}
pub fn inlineText(out: *svg.Svg, registry: *const Registry, raw: []const u8, center: usize, y: usize, fg: []const u8, markdown: bool) d.Error!void {
    if (markdown) {
        const rich = @import("rich_text.zig");
        var glyphs: [512]rich.Glyph = undefined;
        const count = try rich.flatten(raw, &glyphs);
        var width: usize = 0;
        for (glyphs[0..count]) |glyph| width += rich.glyphWidth(glyph.text);
        var x = center - width / 2;
        var i: usize = 0;
        var run: std.ArrayList(u8) = .empty;
        defer run.deinit(out.allocator);
        while (i < count) {
            if (@import("math_text.zig").token(glyphs[i].text)) |_| {
                const layout = try @import("math_text.zig").Layout.init(glyphs[i].text);
                try layout.draw(out, @floatFromInt(x + 2), @as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(layout.pixelHeight())) / 2, fg);
                x += layout.pixelWidth() + 4;
                i += 1;
                continue;
            }
            if (@import("inline_image.zig").token(glyphs[i].text)) |item| {
                try out.add("<g role=\"img\" aria-label=\"");
                try out.escape(item.alt);
                try out.add("\">");
                if (item.name.len == 0) {
                    try out.fmt("<rect data-empty-image=\"true\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"none\" stroke=\"{s}\" stroke-dasharray=\"2 2\"/>", .{ x + 2, y - item.height / 2, item.width, item.height, fg });
                } else try draw(out, try registry.get(item.name), x + 2, y - item.height / 2, item.width, item.height);
                try out.add("</g>");
                x += item.width + 4;
                i += 1;
                continue;
            }
            if (inlineIcon(glyphs[i].text, 0)) |icon| {
                try draw(out, try registry.get(icon.name), x + 2, y - 8, 16, 16);
                x += 20;
                i += 1;
                continue;
            }
            const style = glyphs[i].style;
            run.clearRetainingCapacity();
            while (i < count and glyphs[i].style == style and inlineIcon(glyphs[i].text, 0) == null and @import("inline_image.zig").token(glyphs[i].text) == null and @import("math_text.zig").token(glyphs[i].text) == null) : (i += 1) try run.appendSlice(out.allocator, glyphs[i].text);
            const w = svg.textWidth(run.items);
            try rich.drawStyled(out, x + w / 2, y, run.items, fg, style);
            x += w;
        }
        return;
    }
    var at: usize = 0;
    var width: usize = 0;
    while (inlineIcon(raw, at)) |icon| {
        width += svg.textWidth(raw[at..icon.start]) + 20;
        at = icon.end;
    }
    width += svg.textWidth(raw[at..]);
    var x = center - width / 2;
    at = 0;
    while (inlineIcon(raw, at)) |icon| {
        const value = raw[at..icon.start];
        const w = svg.textWidth(value);
        if (markdown) try @import("rich_text.zig").draw(out, x + w / 2, y, value, fg) else try out.textColor(x + w / 2, y, value, fg);
        x += w;
        try draw(out, try registry.get(icon.name), x + 2, y - 8, 16, 16);
        x += 20;
        at = icon.end;
    }
    const value = raw[at..];
    if (markdown) try @import("rich_text.zig").draw(out, x + svg.textWidth(value) / 2, y, value, fg) else try out.textColor(x + svg.textWidth(value) / 2, y, value, fg);
}
