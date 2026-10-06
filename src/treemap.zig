const std = @import("std");
const svg = @import("svg.zig");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const data = @import("chart_data.zig");
const styles = @import("chart_style.zig");
const Rect = struct { x: f64 = 0, y: f64 = 0, w: f64 = 0, h: f64 = 0 };
const Node = struct { label: []const u8, class: []const u8 = "", parent: usize, leaf: bool, value: f64, rect: Rect = .{}, header: f64 = 0, depth: usize };
fn split(nodes: []Node, ids: []const usize, rect: Rect) void {
    if (ids.len == 1) {
        nodes[ids[0]].rect = rect;
        return;
    }
    var total: f64 = 0;
    for (ids) |i| total += nodes[i].value;
    var left = nodes[ids[0]].value;
    var at: usize = 1;
    while (at < ids.len - 1 and @abs(left + nodes[ids[at]].value - total / 2) < @abs(left - total / 2)) : (at += 1) left += nodes[ids[at]].value;
    const ratio = left / total;
    var r1 = rect;
    var r2 = rect;
    if (rect.w >= rect.h) {
        r1.w *= ratio;
        r2.x += r1.w;
        r2.w -= r1.w;
    } else {
        r1.h *= ratio;
        r2.y += r1.h;
        r2.h -= r1.h;
    }
    split(nodes, ids[0..at], r1);
    split(nodes, ids[at..], r2);
}
fn valueLabel(a: std.mem.Allocator, value: f64, format: []const u8) d.Error![]const u8 {
    if (std.mem.eql(u8, format, "$.1%")) return std.fmt.allocPrint(a, "${d:.1}%", .{value * 100});
    if (std.mem.eql(u8, format, ".1%")) return std.fmt.allocPrint(a, "{d:.1}%", .{value * 100});
    if (std.mem.eql(u8, format, "$0,0") or std.mem.eql(u8, format, ",")) {
        const raw = try std.fmt.allocPrint(a, "{d}", .{@as(u64, @intFromFloat(@round(value)))});
        var result: std.ArrayList(u8) = .empty;
        if (format[0] == '$') try result.append(a, '$');
        for (raw, 0..) |c, i| {
            if (i > 0 and (raw.len - i) % 3 == 0) try result.append(a, ',');
            try result.append(a, c);
        }
        return result.toOwnedSlice(a);
    }
    if (format.len == 0) return std.fmt.allocPrint(a, "{d}", .{value});
    return error.UnsupportedSyntax;
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var nodes: std.ArrayList(Node) = .empty;
    try nodes.append(temp, .{ .label = "", .parent = 0, .leaf = false, .value = 0, .depth = 0 });
    var classes: std.ArrayList(styles.Class) = .empty;
    var title: []const u8 = "";
    const Level = struct { indent: usize, id: usize };
    var stack: [32]Level = undefined;
    var depth: usize = 0;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (txt.starts(line, "title ")) {
            title = try data.label(temp, line[6..]);
            continue;
        }
        if (txt.starts(line, "classDef ")) {
            if (classes.items.len == 128) return error.LimitExceeded;
            try classes.append(temp, try styles.class(line[9..], false));
            continue;
        }
        const indent = raw.len - std.mem.trimStart(u8, raw, " \t").len;
        while (depth > 0 and stack[depth - 1].indent >= indent) depth -= 1;
        const parent = if (depth > 0) stack[depth - 1].id else 0;
        if (nodes.items[parent].leaf) return error.InvalidSyntax;
        if (line[0] != '"' and line[0] != '\'') return error.UnsupportedSyntax;
        const end = std.mem.indexOfScalarPos(u8, line, 1, line[0]) orelse return error.InvalidSyntax;
        var rest = d.trim(line[end + 1 ..]);
        const cls_at = std.mem.indexOf(u8, rest, ":::");
        const class = if (cls_at) |i| d.trim(rest[i + 3 ..]) else "";
        rest = d.trim(rest[0 .. cls_at orelse rest.len]);
        const leaf = rest.len > 0;
        var value: f64 = 0;
        if (leaf) {
            if (rest[0] != ':' and rest[0] != ',') return error.InvalidSyntax;
            var digits: std.ArrayList(u8) = .empty;
            for (rest[1..]) |c| if (c != '_' and c != ',') {
                try digits.append(temp, c);
            };
            value = try d.number(digits.items);
            if (value <= 0) return error.InvalidSyntax;
        }
        if (nodes.items.len == 513 or depth == stack.len) return error.LimitExceeded;
        const id = nodes.items.len;
        try nodes.append(temp, .{ .label = try txt.parse(temp, line[1..end]), .parent = parent, .leaf = leaf, .value = value, .class = class, .depth = depth + 1 });
        stack[depth] = .{ .indent = indent, .id = id };
        depth += 1;
    }
    if (nodes.items.len == 1) return error.InvalidSyntax;
    var i = nodes.items.len;
    while (i > 1) {
        i -= 1;
        nodes.items[nodes.items[i].parent].value += nodes.items[i].value;
    }
    if (nodes.items[0].value <= 0) return error.InvalidSyntax;
    const padding = try doc.num("config.treemap.diagramPadding", 20, 0, 2000);
    const content_w = try doc.num("config.treemap.width", 1000, 100, 20000);
    const content_h = try doc.num("config.treemap.height", 700, 100, 20000);
    const format = doc.get("config.treemap.valueFormat") orelse "";
    const top = padding + if (title.len > 0) @as(f64, @floatFromInt(txt.height(title) + 30)) else 0;
    nodes.items[0].rect = .{ .x = padding, .y = top, .w = content_w, .h = content_h };
    for (0..nodes.items.len) |parent| {
        if (nodes.items[parent].leaf or nodes.items[parent].value == 0) continue;
        var ids: std.ArrayList(usize) = .empty;
        for (nodes.items[1..], 1..) |node, index| if (node.parent == parent and node.value > 0) {
            try ids.append(temp, index);
        };
        if (ids.items.len == 0) return error.InvalidSyntax;
        var area = nodes.items[parent].rect;
        if (parent != 0) {
            const header = @min(area.h * 0.25, @as(f64, @floatFromInt(txt.height(nodes.items[parent].label) + 12)));
            nodes.items[parent].header = header;
            area.y += header;
            area.h -= header;
        }
        split(nodes.items, ids.items, area);
    }
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    const width = @max(data.coord(content_w + padding * 2), txt.width(title) + 40);
    try out.start(width, data.coord(top + content_h + padding), "treemap", prefix);
    if (title.len > 0) try txt.draw(&out, width / 2, data.coord(padding), title);
    for (nodes.items[1..], 1..) |node, index| {
        if (node.value == 0) continue;
        var style: styles.Style = .{};
        if (node.class.len > 0) {
            var found = false;
            for (classes.items) |cls| if (std.mem.eql(u8, cls.name, node.class)) {
                style.merge(cls.style);
                found = true;
            };
            if (!found) return error.InvalidSyntax;
        }
        var category = index;
        while (nodes.items[category].parent != 0) category = nodes.items[category].parent;
        const fill = style.fill orelse try doc.palette(category - 1);
        const fg = style.text orelse if (doc.theme == .dark) "#e0e0e0" else "#24292f";
        const stroke = style.stroke orelse if (doc.theme == .dark) "#0d1117" else "#ffffff";
        const r = node.rect;
        try @import("flow_paint.zig").begin(&out, style);
        try out.fmt("<g font-style=\"{s}\" font-weight=\"{s}\">", .{ if (style.italic orelse false) "italic" else "normal", if (style.bold orelse false) "bold" else "normal" });
        try out.fmt("<g data-item=\"{d}\" data-parent=\"{d}\" data-value=\"{d}\" data-leaf=\"{s}\"><title>", .{ index, node.parent, node.value, if (node.leaf) "true" else "false" });
        try out.escape(node.label);
        try out.add(": ");
        const value = try valueLabel(temp, node.value, format);
        try out.escape(value);
        try out.add("</title>");
        try out.fmt("<rect x=\"{d:.4}\" y=\"{d:.4}\" width=\"{d:.4}\" height=\"{d:.4}\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ r.x, r.y, r.w, r.h, fill, stroke, style.width orelse 2 });
        const label = if (node.leaf) try std.fmt.allocPrint(temp, "{s}\n{s}", .{ node.label, value }) else node.label;
        const lh = if (node.leaf) r.h else node.header;
        const factor = @max(0.01, @min(1, @min((r.w - 8) / @as(f64, @floatFromInt(@max(txt.width(label), 1))), (lh - 4) / @as(f64, @floatFromInt(txt.height(label))))));
        const label_x = r.x + r.w / 2;
        var label_y = r.y + (lh - @as(f64, @floatFromInt(txt.height(label))) * factor) / 2 + 10 * factor;
        var label_lines = std.mem.splitScalar(u8, label, '\n');
        while (label_lines.next()) |line| {
            try out.fmt("<text x=\"{d:.4}\" y=\"{d:.4}\" font-family=\"Consolas,monospace\" font-size=\"{d:.4}\" text-anchor=\"middle\" dominant-baseline=\"middle\" stroke=\"none\" fill=\"{s}\">", .{ label_x, label_y, 14 * factor, fg });
            try out.escape(line);
            try out.add("</text>");
            label_y += 20 * factor;
        }
        try out.add("</g></g></g>");
    }
    return out.finish();
}
