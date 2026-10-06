const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const wrap = @import("text_wrap.zig");
const svg = @import("svg.zig");
const data = @import("chart_data.zig");
const Node = struct { label: []const u8, indent: usize, parent: usize = 0, depth: usize = 0, children: usize = 0, drawn: usize = 0, x: f64 = 0, y: f64 = 0, endx: f64 = 0, endy: f64 = 0, ly: f64 = 0 };
fn order(nodes: []Node, parent: usize, cursor: *f64) void {
    for (nodes, 0..) |*n, i| if (i != 0 and n.parent == parent) {
        if (n.depth % 2 == 1) order(nodes, i, cursor);
        const h: f64 = @floatFromInt(txt.height(n.label) + 24);
        n.ly = cursor.* + h / 2;
        cursor.* += h;
        if (n.depth % 2 == 0) order(nodes, i, cursor);
    };
}
fn label(out: *svg.Svg, x: f64, y: f64, value: []const u8, anchor: []const u8, color: []const u8) !void {
    var lines = std.mem.splitScalar(u8, value, '\n');
    var py = y - @as(f64, @floatFromInt(txt.height(value))) / 2 + 15;
    while (lines.next()) |line| {
        try out.fmt("<text x=\"{d}\" y=\"{d}\" text-anchor=\"{s}\" fill=\"{s}\" stroke=\"none\" font-family=\"Consolas,monospace\" font-size=\"14\">", .{ x, py, anchor, color });
        try out.escape(line);
        try out.add("</text>");
        py += 20;
    }
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var nodes: std.ArrayList(Node) = .empty;
    var stack: [17]usize = @splat(0);
    var depth: usize = 0;
    var base: usize = 0;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (txt.starts(line, "accTitle:")) {
            doc.acc_title = d.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "accDescr:")) {
            doc.acc_description = d.trim(line[9..]);
            continue;
        }
        if (std.mem.indexOfScalar(u8, raw, '\t') != null) return error.UnsupportedSyntax;
        const indent = raw.len - std.mem.trimStart(u8, raw, " ").len;
        var n: Node = .{ .label = try wrap.wrap(temp, try txt.parse(temp, line), 162), .indent = indent };
        if (nodes.items.len > 0) {
            if (nodes.items.len == 1) base = indent;
            while (depth > 0 and (indent <= base or indent <= nodes.items[stack[depth]].indent)) depth -= 1;
            n.parent = stack[depth];
            n.depth = depth + 1;
            if (n.depth > 16) return error.LimitExceeded;
            nodes.items[n.parent].children += 1;
            depth += 1;
            stack[depth] = nodes.items.len;
        }
        if (nodes.items.len == 512) return error.LimitExceeded;
        try nodes.append(temp, n);
    }
    if (nodes.items.len == 0) return error.InvalidSyntax;
    const padding = try doc.num("config.ishikawa.diagramPadding", 24, 0, 200);
    _ = try doc.flag("config.ishikawa.useMaxWidth", true);
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const fill = if (std.mem.eql(u8, doc.style, "forest") or std.mem.eql(u8, doc.style, "neutral")) try doc.palette(0) else if (doc.theme == .dark) "#16213e" else "#eef4ff";
    var left: f64 = -80;
    var pair_left = left;
    var category: usize = 0;
    var minx: f64 = -100;
    var miny: f64 = -70;
    var maxy: f64 = 70;
    for (nodes.items, 0..) |*n, i| if (i != 0 and n.parent == 0) {
        if (category % 2 == 0) left = pair_left - 70;
        const sign: f64 = if (category % 2 == 0) -1 else 1;
        var cursor: f64 = 50;
        order(nodes.items, i, &cursor);
        n.x = left;
        n.y = 0;
        n.endx = left - 80;
        n.endy = sign * (cursor + 40);
        n.ly = n.endy + sign * (@as(f64, @floatFromInt(txt.height(n.label))) / 2 + 20);
        var child_index = i + 1;
        while (child_index < nodes.items.len and nodes.items[child_index].depth > 1) : (child_index += 1) {
            const child = &nodes.items[child_index];
            const parent = &nodes.items[child.parent];
            child.endy = sign * child.ly;
            if (child.depth % 2 == 0) {
                const t = (child.endy - parent.y) / (parent.endy - parent.y);
                child.x = parent.x + (parent.endx - parent.x) * t;
                child.y = child.endy;
                child.endx = child.x - 40 - @as(f64, @floatFromInt(child.children)) * 65;
            } else {
                const t = @as(f64, @floatFromInt(parent.drawn + 1)) / @as(f64, @floatFromInt(parent.children + 1));
                parent.drawn += 1;
                child.x = parent.x + (parent.endx - parent.x) * t;
                child.y = parent.y;
                child.endx = child.x - @abs(child.endy - child.y) * 0.18;
            }
            child.ly = child.endy;
            pair_left = @min(pair_left, child.endx - @as(f64, @floatFromInt(txt.width(child.label))) - 20);
        }
        pair_left = @min(pair_left, n.endx - @as(f64, @floatFromInt(txt.width(n.label))) / 2 - 20);
        category += 1;
    };
    minx = @min(minx, pair_left - 20);
    for (nodes.items[1..]) |n| {
        miny = @min(miny, n.ly - @as(f64, @floatFromInt(txt.height(n.label))) / 2 - 15);
        maxy = @max(maxy, n.ly + @as(f64, @floatFromInt(txt.height(n.label))) / 2 + 15);
    }
    const headw: f64 = @floatFromInt(txt.width(nodes.items[0].label) + 56);
    const headh: f64 = @max(70, @as(f64, @floatFromInt(txt.height(nodes.items[0].label) + 32)));
    miny = @min(miny, -headh / 2);
    maxy = @max(maxy, headh / 2);
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(data.coord(headw - minx + 2 * padding), data.coord(maxy - miny + 2 * padding), "ishikawa", prefix);
    try out.fmt("<g transform=\"translate({d} {d})\"><path data-fishbone-spine=\"true\" d=\"M {d} 0 H 0\" fill=\"none\" stroke-width=\"3\" marker-end=\"url(#zm-{d})\"/>", .{ padding - minx, padding - miny, minx + 10, prefix });
    for (nodes.items[1..], 1..) |n, i| {
        try out.fmt("<path data-ishikawa-node=\"{d}\" data-parent=\"{d}\" data-depth=\"{d}\" d=\"M {d} {d} L {d} {d}\" fill=\"none\" marker-end=\"url(#zm-{d})\"/>", .{ i, n.parent, n.depth, n.endx, n.endy, n.x, n.y, prefix });
    }
    try out.fmt("<path data-ishikawa-effect=\"true\" d=\"M 0 {d} H {d} L {d} 0 L {d} {d} H 0 Z\" fill=\"{s}\"/>", .{ -headh / 2, headw - 24, headw, headw - 24, headh / 2, fill });
    try label(&out, headw / 2 - 8, 0, nodes.items[0].label, "middle", fg);
    for (nodes.items[1..]) |n| {
        if (n.depth == 1) {
            const nw: f64 = @floatFromInt(txt.width(n.label) + 24);
            const nh: f64 = @floatFromInt(txt.height(n.label) + 16);
            try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" fill=\"{s}\"/>", .{ n.endx - nw / 2, n.ly - nh / 2, nw, nh, fill });
        }
        try label(&out, if (n.depth == 1) n.endx else n.endx - 8, n.ly, n.label, if (n.depth == 1) "middle" else "end", fg);
    }
    try out.add("</g>");
    return out.finish();
}
