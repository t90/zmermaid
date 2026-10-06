// Independent, deterministic FreeMind-inspired layout. No force simulation or DOM.
const std = @import("std");
const d = @import("document.zig");
const svg = @import("svg.zig");
const rich = @import("rich_text.zig");
const paint = @import("flow_paint.zig");
const Shape = enum { fork, oval, rect, rounded, circle, cloud, bang, hexagon };
const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: Shape = .fork,
    classes: []const u8 = "",
    icon: []const u8 = "",
    parent: ?usize = null,
    indent: usize = 0,
    depth: usize = 0,
    side: usize = 0,
    branch: usize = 0,
    x: i64 = 0,
    y: i64 = 0,
    w: usize = 0,
    h: usize = 0,
    children_height: usize = 0,
    span: usize = 0,
};
fn int(v: usize) i64 {
    return @intCast(v);
}
fn pos(v: i64) usize {
    return @intCast(v);
}
fn decorate(n: *Node, raw: []const u8) d.Error!void {
    if (std.mem.startsWith(u8, raw, "::icon(")) {
        if (!std.mem.endsWith(u8, raw, ")")) return error.InvalidSyntax;
        n.icon = d.trim(raw[7 .. raw.len - 1]);
        if (n.icon.len == 0 or n.icon.len > 128) return error.InvalidSyntax;
    } else if (std.mem.startsWith(u8, raw, ":::")) {
        n.classes = d.trim(raw[3..]);
        if (n.classes.len == 0 or n.classes.len > 256) return error.InvalidSyntax;
        for (n.classes) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != ' ' and c != '\t') return error.InvalidSyntax;
    } else return error.InvalidSyntax;
}
fn label(a: std.mem.Allocator, value: []const u8, width: usize, auto_wrap: bool) d.Error![]const u8 {
    var raw = d.trim(value);
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw = raw[1 .. raw.len - 1];
    const markdown = raw.len >= 2 and raw[0] == '`' and raw[raw.len - 1] == '`';
    if (markdown) raw = raw[1 .. raw.len - 1];
    if (raw.len == 0) return error.InvalidSyntax;
    var decoded: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < raw.len) {
        // This spelling occurs in upstream's serialized E2E examples.
        if (std.mem.startsWith(u8, raw[at..], "&lt;br/>")) {
            try decoded.append(a, '\n');
            at += 8;
            continue;
        }
        if (!markdown and std.mem.indexOfScalar(u8, "*_`\\", raw[at]) != null) try decoded.append(a, '\\');
        try decoded.append(a, raw[at]);
        at += 1;
    }
    const parsed = try rich.parse(a, decoded.items);
    return rich.wrap(a, parsed, if (auto_wrap or !markdown) width else 8192);
}
fn parse(a: std.mem.Allocator, source: []const u8, width: usize, auto_wrap: bool) d.Error![]Node {
    var nodes: std.ArrayList(Node) = .empty;
    var at = (std.mem.indexOfScalar(u8, source, '\n') orelse return error.InvalidSyntax) + 1;
    while (at < source.len) {
        var indent: usize = 0;
        while (at < source.len and (source[at] == ' ' or source[at] == '\t')) : (at += 1) indent += if (source[at] == '\t') @as(usize, 4) else 1;
        const start = at;
        var quote: u8 = 0;
        var end = at;
        var decoration: ?usize = null;
        while (at < source.len) : (at += 1) {
            const c = source[at];
            if (quote != 0) {
                if (c == quote and (at == 0 or source[at - 1] != '\\')) quote = 0;
            } else {
                if (c == '\n') break;
                if (std.mem.startsWith(u8, source[at..], "%%")) {
                    end = at;
                    while (at < source.len and source[at] != '\n') : (at += 1) {}
                    break;
                }
                if (c == '"' or c == '`') quote = c;
                if (at > start and std.mem.startsWith(u8, source[at..], "::") and decoration == null) decoration = at;
            }
            end = at + 1;
        }
        if (quote != 0) return error.InvalidSyntax;
        if (at < source.len) at += 1;
        const raw = d.trim(source[start..end]);
        if (raw.len == 0) continue;
        if (std.mem.startsWith(u8, raw, "::")) {
            if (nodes.items.len == 0) return error.InvalidSyntax;
            try decorate(&nodes.items[nodes.items.len - 1], raw);
            continue;
        }
        if (nodes.items.len == 1024) return error.LimitExceeded;
        const body = d.trim(source[start .. decoration orelse end]);
        if (body.len == 0) return error.InvalidSyntax;
        var n: Node = .{ .id = body, .label = body, .indent = indent };
        if (std.mem.indexOfAny(u8, body, "[(){")) |open| {
            const forms = .{ .{ "((", "))", Shape.circle }, .{ "))", "((", Shape.bang }, .{ "{{", "}}", Shape.hexagon }, .{ "[", "]", Shape.rect }, .{ "(", ")", Shape.rounded }, .{ ")", "(", Shape.cloud } };
            var matched = false;
            inline for (forms) |form| {
                if (!matched and std.mem.startsWith(u8, body[open..], form[0]) and std.mem.endsWith(u8, body, form[1]) and body.len >= open + form[0].len + form[1].len) {
                    n.shape = form[2];
                    n.label = body[open + form[0].len .. body.len - form[1].len];
                    n.id = d.trim(body[0..open]);
                    matched = true;
                }
            }
            if (!matched) return error.InvalidSyntax;
        }
        n.label = try label(a, n.label, width, auto_wrap);
        if (n.id.len == 0) n.id = n.label;
        if (nodes.items.len > 0) {
            var p = nodes.items.len;
            while (p > 0) {
                p -= 1;
                if (nodes.items[p].indent < indent) {
                    n.parent = p;
                    break;
                }
            }
            const parent = n.parent orelse return error.InvalidSyntax;
            n.depth = nodes.items[parent].depth + 1;
            if (n.depth > 64) return error.LimitExceeded;
        } else if (n.shape == .fork) n.shape = .oval;
        if (decoration) |idx| try decorate(&n, d.trim(source[idx..end]));
        try nodes.append(a, n);
    }
    if (nodes.items.len == 0) return error.InvalidSyntax;
    return nodes.toOwnedSlice(a);
}
fn place(nodes: []Node, index: usize, x: i64, top: i64) void {
    const n = &nodes[index];
    n.x = x;
    n.y = top + int((n.span - n.h) / 2);
    var child_top = top + int((n.span - n.children_height) / 2);
    for (nodes, 0..) |child, i| if (child.parent == index) {
        place(nodes, i, if (child.side == 0) x + int(n.w) + 44 else x - 44 - int(child.w), child_top);
        child_top += int(child.span + 14);
    };
}
fn builtin(name: []const u8) ?[]const u8 {
    const names = .{ .{ "fa fa-book", "book" }, .{ "mdi mdi-skull-outline", "skull" }, .{ "bomb", "bomb" }, .{ "fa fa-wallet", "wallet" }, .{ "fa fa-person-hiking", "hiking" } };
    inline for (names) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
    return null;
}
// Small original line symbols, not icon-font/library artwork.
fn icon(out: *svg.Svg, doc: *d.Document, name: []const u8, x: usize, y: usize) d.Error!void {
    if (builtin(name)) |key| {
        try out.fmt("<g data-mindmap-icon=\"{s}\" transform=\"translate({d} {d})\" fill=\"none\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\">", .{ key, x, y });
        if (std.mem.eql(u8, key, "book")) try out.add("<path d=\"M10 4 Q5 1 1 4 V17 Q5 14 10 18 Q15 14 19 17 V4 Q15 1 10 4 V18 M4 7 L7 8 M13 8 L16 7\"/>") else if (std.mem.eql(u8, key, "skull")) try out.add("<path d=\"M5 14 C-3 0 23 0 15 14 V18 H5 Z M8 15 V18 M12 15 V18\"/><circle cx=\"6\" cy=\"10\" r=\"2\"/><circle cx=\"14\" cy=\"10\" r=\"2\"/>") else if (std.mem.eql(u8, key, "wallet")) try out.add("<rect x=\"1\" y=\"5\" width=\"18\" height=\"13\" rx=\"2\"/><path d=\"M2 5 L15 2 V5 M19 9 H13 V14 H19\"/><circle cx=\"15\" cy=\"11.5\" r=\".6\"/>") else if (std.mem.eql(u8, key, "hiking")) try out.add("<circle cx=\"11\" cy=\"3\" r=\"2\"/><path d=\"M10 6 L8 12 L4 19 M8 12 L13 16 V19 M10 6 L14 10 H18 M17 8 V19 M7 6 L4 10 L6 12\"/>") else try out.add("<circle cx=\"9\" cy=\"12\" r=\"7\"/><path d=\"M13 6 L15 3 L18 4 M17 1 L19 2 M6 8 L4 10\"/>");
        try out.add("</g>");
    } else try @import("assets.zig").draw(out, try doc.assets.get(name), x, y, 20, 20);
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    if (doc.font_family.len == 0) doc.font_family = "Segoe UI,Arial,sans-serif";
    const padding: usize = @intFromFloat(try doc.num("config.mindmap.padding", 10, 0, 100));
    const max_width: usize = @intFromFloat(try doc.num("config.mindmap.maxNodeWidth", 200, 32, 2048));
    doc.max_width = try doc.flag("config.mindmap.useMaxWidth", doc.max_width);
    if (doc.get("config.mindmap.layoutAlgorithm")) |algorithm| {
        if (!std.mem.eql(u8, algorithm, "cose-bilkent") and !std.mem.eql(u8, algorithm, "tidy-tree")) return error.UnsupportedSyntax;
        if (doc.layout_hint.len == 0) doc.layout_hint = algorithm;
    }
    const nodes = try parse(temp, doc.source, max_width, try doc.flag("config.markdownAutoWrap", true));
    for (nodes) |*n| {
        n.w = @max(40, rich.width(n.label) + 2 * padding + if (n.icon.len > 0) @as(usize, 28) else 0);
        n.h = @max(30, paint.labelHeight(n.label) + 2 * padding);
        if (n.shape == .circle) {
            // Fit the entire label rectangle, including multiline corner glyphs.
            const diagonal: usize = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(n.w * n.w + n.h * n.h)))));
            const diameter = (diagonal + 3) / 2 * 2;
            n.w = diameter;
            n.h = diameter;
        }
        if (n.shape == .oval) {
            n.w = (n.w * 3 / 2 + 1) / 2 * 2;
            n.h = (n.h * 3 / 2 + 1) / 2 * 2;
        }
        if (n.shape == .hexagon or n.shape == .cloud or n.shape == .bang) {
            n.w += 32;
            n.h += 20;
        }
        if (n.shape == .cloud) {
            n.w = n.w * 5 / 4;
            n.h = n.h * 5 / 4;
        }
    }
    var reverse = nodes.len;
    while (reverse > 0) {
        reverse -= 1;
        const n = &nodes[reverse];
        n.span = @max(n.h, n.children_height);
        if (n.parent) |p| {
            if (nodes[p].children_height > 0) nodes[p].children_height += 14;
            nodes[p].children_height += n.span;
        }
    }
    var heights = [2]usize{ 0, 0 };
    var branch: usize = 0;
    for (nodes[1..]) |*n| {
        const p = n.parent.?;
        if (p == 0) {
            n.side = if (heights[0] <= heights[1]) 0 else 1;
            n.branch = branch;
            branch += 1;
            heights[n.side] += n.span + 14;
        } else {
            n.side = nodes[p].side;
            n.branch = nodes[p].branch;
        }
    }
    nodes[0].x = -int(nodes[0].w / 2);
    nodes[0].y = -int(nodes[0].h / 2);
    var tops = [2]i64{ -int((heights[0] -| 14) / 2), -int((heights[1] -| 14) / 2) };
    for (nodes[1..], 1..) |n, i| if (n.parent == 0) {
        place(nodes, i, if (n.side == 0) nodes[0].x + int(nodes[0].w) + 64 else nodes[0].x - 64 - int(n.w), tops[n.side]);
        tops[n.side] += int(n.span + 14);
    };
    var min_x: i64 = 0;
    var max_x: i64 = 0;
    var min_y: i64 = 0;
    var max_y: i64 = 0;
    for (nodes) |n| {
        min_x = @min(min_x, n.x);
        min_y = @min(min_y, n.y);
        max_x = @max(max_x, n.x + int(n.w));
        max_y = @max(max_y, n.y + int(n.h));
    }
    for (nodes) |*n| {
        n.x += 32 - min_x;
        n.y += 32 - min_y;
    }
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(pos(max_x - min_x + 64), pos(max_y - min_y + 64), "mindmap", prefix);
    try out.add("<g data-mindmap-layout=\"freemind\" stroke-linecap=\"round\" stroke-linejoin=\"round\">");
    const colors = if (doc.theme == .dark) [_][]const u8{ "#79b7d8", "#dcb56c", "#92bf95", "#d9989a", "#b6a0d4", "#70b9ae" } else [_][]const u8{ "#4885a6", "#b98936", "#68936b", "#b87679", "#8e77ac", "#4e998c" };
    var palette: [6][]const u8 = undefined;
    for (&palette, 0..) |*c, i| {
        var buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "config.themeVariables.cScale{d}", .{i}) catch unreachable;
        c.* = if (doc.get(key)) |v| try d.color(v) else if (std.mem.eql(u8, doc.style, "neutral")) "#8b929b" else colors[i];
    }
    doc.palette_used = true;
    for (nodes[1..], 1..) |n, i| {
        const p = nodes[n.parent.?];
        const sx = p.x + if (n.side == 0) int(p.w) else 0;
        const sy = p.y + if (p.shape == .fork) int(p.h) else int(p.h / 2);
        const ex = n.x + if (n.side == 1) int(n.w) else 0;
        const ey = n.y + if (n.shape == .fork) int(n.h) else int(n.h / 2);
        const bend = @divTrunc(ex - sx, 2);
        try out.fmt("<path data-mindmap-edge=\"{d}\" data-parent=\"{d}\" d=\"M {d} {d} C {d} {d} {d} {d} {d} {d}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ i, n.parent.?, sx, sy, sx + bend, sy, ex - bend, ey, ex, ey, palette[n.branch % 6], if (n.depth == 1) @as(f64, 2.2) else 1.5 });
    }
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const bg = if (doc.theme == .dark) "#0d1117" else "#ffffff";
    for (nodes, 0..) |n, i| {
        const x = pos(n.x);
        const y = pos(n.y);
        const w = n.w;
        const h = n.h;
        try out.fmt("<g id=\"zm-{d}-mind-{d}\" data-mindmap-node=\"{d}\" data-parent=\"{d}\" data-depth=\"{d}\" data-side=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\" data-shape=\"{s}\" data-source-id=\"", .{ prefix, i, i, n.parent orelse 1024, n.depth, n.side, x, y, w, h, @tagName(n.shape) });
        try out.escape(n.id);
        try out.add("\" class=\"mindmap-node ");
        try out.escape(n.classes);
        try out.fmt("\" stroke=\"{s}\" fill=\"{s}\">", .{ if (i == 0) fg else palette[n.branch % 6], bg });
        switch (n.shape) {
            .fork => try out.fmt("<path d=\"M {d} {d} H {d}\" fill=\"none\"/>", .{ x, y + h, x + w }),
            .oval => try out.fmt("<ellipse cx=\"{d}\" cy=\"{d}\" rx=\"{d}\" ry=\"{d}\"/>", .{ x + w / 2, y + h / 2, w / 2, h / 2 }),
            .circle => try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"{d}\"/>", .{ x + w / 2, y + h / 2, w / 2 }),
            .rect, .rounded => try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"{d}\"/>", .{ x, y, w, h, if (n.shape == .rounded) @as(usize, 10) else 0 }),
            .hexagon => try out.fmt("<path d=\"M {d} {d} L {d} {d} H {d} L {d} {d} L {d} {d} H {d} Z\"/>", .{ x, y + h / 2, x + 16, y, x + w - 16, x + w, y + h / 2, x + w - 16, y + h, x + 16 }),
            .cloud => try out.fmt("<path transform=\"translate({d} {d}) scale({d:.5} {d:.5})\" d=\"M0 50 C0 30 8 22 15 25 C10 0 40 0 45 12 C60 -2 85 0 86 25 C95 23 100 35 100 50 C100 72 95 80 87 78 C90 100 62 100 56 88 C40 102 15 98 15 78 C5 80 0 65 0 50 Z\"/>", .{ x, y, @as(f64, @floatFromInt(w)) / 100, @as(f64, @floatFromInt(h)) / 100 }),
            .bang => try out.fmt("<path d=\"M {d} {d} L {d} {d} L {d} {d} L {d} {d} L {d} {d} L {d} {d} L {d} {d} L {d} {d} L {d} {d} L {d} {d} L {d} {d} L {d} {d} Z\"/>", .{ x, y + h / 2, x + 12, y + 12, x + 8, y, x + w / 2, y + 8, x + w - 8, y, x + w - 12, y + 12, x + w, y + h / 2, x + w - 12, y + h - 12, x + w - 8, y + h, x + w / 2, y + h - 8, x + 8, y + h, x + 12, y + h - 12 }),
        }
        const label_w = rich.width(n.label);
        const icon_w: usize = if (n.icon.len > 0) 28 else 0;
        if (n.icon.len > 0) try icon(&out, doc, n.icon, x + (w - label_w - icon_w) / 2, y + (h - 20) / 2);
        try paint.textAssets(&out, x + (w + icon_w) / 2, y + (h - paint.labelHeight(n.label)) / 2, n.label, .{ .text = fg }, true, &doc.assets);
        try out.add("</g>");
    }
    try out.add("</g>");
    return out.finish();
}
