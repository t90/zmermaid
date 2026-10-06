const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const data = @import("chart_data.zig");
const Node = struct { name: []const u8, label: []const u8, x: f64, y: f64, anchor: bool = false, pipeline: ?usize = null, pipeline_parent: bool = false, inertia: bool = false, strategy: []const u8 = "", dx: f64 = 12, dy: f64 = -12, evolve: ?f64 = null };
const Item = struct { label: []const u8, x: f64, y: f64, kind: enum { note, annotation, accelerator, deaccelerator }, number: usize = 0 };
const Edge = struct { from: usize, to: usize, label: []const u8 = "", flow: u2 = 0, dotted: bool = false };
const Stage = struct { label: []const u8, boundary: f64 };
const Point = struct { x: f64, y: f64 };
fn unit(raw: []const u8) d.Error!f64 {
    const n = try d.number(raw);
    if (n < 0 or n > 100) return error.InvalidSyntax;
    return if (n <= 1) n else n / 100;
}
fn coords(rest: *[]const u8, normalized: bool) d.Error!Point {
    rest.* = d.trim(rest.*);
    if (!txt.starts(rest.*, "[")) return error.InvalidSyntax;
    const end = std.mem.indexOfScalar(u8, rest.*, ']') orelse return error.InvalidSyntax;
    const comma = std.mem.indexOfScalar(u8, rest.*[0..end], ',') orelse return error.InvalidSyntax;
    const first = if (normalized) try unit(rest.*[1..comma]) else try d.number(rest.*[1..comma]);
    const second = if (normalized) try unit(rest.*[comma + 1 .. end]) else try d.number(rest.*[comma + 1 .. end]);
    rest.* = d.trim(rest.*[end + 1 ..]);
    return .{ .x = first, .y = second };
}
fn find(nodes: []Node, name: []const u8) d.Error!usize {
    const key = d.unquote(name);
    for (nodes, 0..) |n, i| if (std.mem.eql(u8, key, n.name)) return i;
    for (nodes, 0..) |n, i| if (std.mem.eql(u8, key, n.label)) return i;
    return error.InvalidSyntax;
}
fn point(x: f64, y: f64, w: f64, h: f64) Point {
    return .{ .x = 80 + x * w, .y = 60 + (1 - y) * h };
}
fn radius(n: Node) f64 {
    return if (n.anchor) 4 else if (n.strategy.len > 0) 17 else 8;
}
fn text(out: *svg.Svg, x: f64, y: f64, label: []const u8, anchor: []const u8, fg: []const u8) !void {
    var parts = std.mem.splitScalar(u8, label, '\n');
    var py = y;
    while (parts.next()) |part| {
        try out.fmt("<text x=\"{d:.2}\" y=\"{d:.2}\" font-family=\"Consolas,monospace\" font-size=\"14\" text-anchor=\"{s}\" fill=\"{s}\" stroke=\"none\">", .{ x, py, anchor, fg });
        try out.escape(part);
        try out.add("</text>");
        py += 20;
    }
}
fn color(doc: *d.Document, name: []const u8, default: []const u8) d.Error![]const u8 {
    return if (doc.get(name)) |v| try d.color(v) else default;
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var nodes: std.ArrayList(Node) = .empty;
    var items: std.ArrayList(Item) = .empty;
    var edges: std.ArrayList(Edge) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    var stages: std.ArrayList(Stage) = .empty;
    var width: f64 = 1100;
    var height: f64 = 750;
    var pipeline: ?usize = null;
    var annotations: ?Point = null;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        var line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        var quote: u8 = 0;
        for (line, 0..) |c, i| {
            if (c == '"') {
                if (quote == 0) quote = c else if (quote == c) quote = 0;
            }
            if (quote == 0 and txt.starts(line[i..], "%%")) {
                line = d.trim(line[0..i]);
                break;
            }
        }
        if (txt.starts(line, "title ")) {
            doc.title = try txt.parse(doc.a, d.unquote(line[6..]));
            continue;
        }
        if (txt.starts(line, "accTitle:")) {
            doc.acc_title = d.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "accDescr:")) {
            doc.acc_description = d.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "size ")) {
            var rest = line[5..];
            const size = try coords(&rest, false);
            if (rest.len > 0 or size.x < 300 or size.y < 300 or size.x > 10000 or size.y > 10000) return error.InvalidSyntax;
            width = size.x;
            height = size.y;
            continue;
        }
        if (txt.starts(line, "evolution ")) {
            if (stages.items.len > 0) return error.InvalidSyntax;
            var parts = std.mem.splitSequence(u8, line[10..], "->");
            while (parts.next()) |part| {
                if (stages.items.len == 16) return error.LimitExceeded;
                const v = d.trim(part);
                var name = v;
                var boundary: f64 = -1;
                if (std.mem.indexOfScalar(u8, v, '@')) |at| {
                    name = d.trim(v[0..at]);
                    const tail = v[at + 1 ..];
                    const slash = std.mem.indexOfScalar(u8, tail, '/');
                    boundary = try unit(if (slash) |s| tail[0..s] else tail);
                    if (slash) |s| name = try std.fmt.allocPrint(temp, "{s} / {s}", .{ name, d.trim(tail[s + 1 ..]) });
                }
                if (name.len == 0) return error.InvalidSyntax;
                try stages.append(temp, .{ .label = try txt.parse(temp, d.unquote(name)), .boundary = boundary });
            }
            continue;
        }
        if (txt.starts(line, "pipeline ")) {
            if (pipeline != null or !std.mem.endsWith(u8, line, "{")) return error.InvalidSyntax;
            pipeline = try find(nodes.items, line[9 .. line.len - 1]);
            if (nodes.items[pipeline.?].pipeline_parent) return error.InvalidSyntax;
            nodes.items[pipeline.?].pipeline_parent = true;
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            if (pipeline == null) return error.InvalidSyntax;
            pipeline = null;
            continue;
        }
        if (txt.starts(line, "component ") or txt.starts(line, "anchor ")) {
            const is_anchor = txt.starts(line, "anchor ");
            if (pipeline != null and is_anchor) return error.InvalidSyntax;
            var rest = d.trim(line[if (is_anchor) @as(usize, 7) else 10..]);
            const bracket = std.mem.indexOfScalar(u8, rest, '[') orelse return error.InvalidSyntax;
            const name = d.unquote(rest[0..bracket]);
            if (name.len == 0 or name.len > 512) return error.InvalidSyntax;
            rest = rest[bracket..];
            var pos: Point = undefined;
            if (pipeline) |p| {
                const end = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidSyntax;
                pos = .{ .x = nodes.items[p].y, .y = try unit(rest[1..end]) };
                rest = d.trim(rest[end + 1 ..]);
            } else pos = try coords(&rest, true);
            const key = if (pipeline) |p| try std.fmt.allocPrint(temp, "{s}_{s}", .{ nodes.items[p].name, name }) else name;
            for (nodes.items) |n| if (std.mem.eql(u8, n.name, key)) return error.InvalidSyntax;
            var node: Node = .{ .name = key, .label = try txt.parse(temp, name), .x = pos.y, .y = pos.x, .anchor = is_anchor, .pipeline = pipeline };
            if (is_anchor) {
                node.dx = 0;
                node.dy = -8;
            }
            if (pipeline != null) node.dy = 36;
            while (rest.len > 0) {
                if (txt.starts(rest, "label ")) {
                    rest = rest[6..];
                    const offset = try coords(&rest, false);
                    if (@abs(offset.x) > 10000 or @abs(offset.y) > 10000) return error.LimitExceeded;
                    node.dx = offset.x;
                    node.dy = offset.y;
                } else if (std.mem.eql(u8, rest, "inertia")) {
                    node.inertia = true;
                    rest = "";
                } else if (rest[0] == '(') {
                    const end = std.mem.indexOfScalar(u8, rest, ')') orelse return error.InvalidSyntax;
                    const word = d.trim(rest[1..end]);
                    if (std.mem.eql(u8, word, "inertia")) node.inertia = true else if (std.mem.eql(u8, word, "build") or std.mem.eql(u8, word, "buy") or std.mem.eql(u8, word, "outsource") or std.mem.eql(u8, word, "market")) node.strategy = word else return error.UnsupportedSyntax;
                    rest = d.trim(rest[end + 1 ..]);
                } else return error.UnsupportedSyntax;
            }
            if (nodes.items.len == 512) return error.LimitExceeded;
            try nodes.append(temp, node);
            continue;
        }
        if (pipeline != null) return error.InvalidSyntax;
        if (txt.starts(line, "annotations ")) {
            var rest = line[12..];
            const p = try coords(&rest, true);
            if (rest.len > 0) return error.InvalidSyntax;
            annotations = .{ .x = p.y, .y = p.x };
            continue;
        }
        const annotation = txt.starts(line, "annotation ");
        const note = txt.starts(line, "note ");
        const accelerator = txt.starts(line, "accelerator ");
        const deaccelerator = txt.starts(line, "deaccelerator ");
        if (annotation or note or accelerator or deaccelerator) {
            var rest = d.trim(line[if (annotation) @as(usize, 11) else if (note) 5 else if (accelerator) 12 else 14..]);
            var label: []const u8 = "";
            var number: usize = 0;
            if (annotation) {
                const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return error.InvalidSyntax;
                number = std.fmt.parseInt(usize, d.trim(rest[0..comma]), 10) catch return error.InvalidSyntax;
                if (number > 999) return error.LimitExceeded;
                rest = d.trim(rest[comma + 1 ..]);
            } else {
                const bracket = std.mem.indexOfScalar(u8, rest, '[') orelse return error.InvalidSyntax;
                label = d.unquote(rest[0..bracket]);
                rest = rest[bracket..];
            }
            const p = try coords(&rest, true);
            if (annotation) label = d.unquote(rest) else if (rest.len > 0) return error.InvalidSyntax;
            if (items.items.len == 512) return error.LimitExceeded;
            try items.append(temp, .{ .label = try txt.parse(temp, label), .x = p.y, .y = p.x, .kind = if (annotation) .annotation else if (note) .note else if (accelerator) .accelerator else .deaccelerator, .number = number });
            continue;
        }
        if (pending.items.len == 1024) return error.LimitExceeded;
        try pending.append(temp, line);
    }
    if (pipeline != null) return error.InvalidSyntax;
    for (pending.items) |line| {
        if (txt.starts(line, "evolve ")) {
            const rest = d.trim(line[7..]);
            const space = std.mem.lastIndexOfAny(u8, rest, " \t") orelse return error.InvalidSyntax;
            const node = try find(nodes.items, rest[0..space]);
            nodes.items[node].evolve = try unit(rest[space + 1 ..]);
            continue;
        }
        var at: usize = 0;
        var quoted = false;
        while (at < line.len) : (at += 1) {
            if (line[at] == '"') quoted = !quoted;
            if (!quoted and (line[at] == '+' or line[at] == '>' or txt.starts(line[at..], "->") or txt.starts(line[at..], "-->") or txt.starts(line[at..], "-.->"))) break;
        }
        if (at == line.len) return error.UnsupportedSyntax;
        const from = try find(nodes.items, line[0..at]);
        var rest = line[at..];
        var edge: Edge = .{ .from = from, .to = undefined };
        if (rest[0] == '+') {
            rest = rest[1..];
            if (txt.starts(rest, "'")) {
                const end = std.mem.indexOfScalarPos(u8, rest, 1, '\'') orelse return error.InvalidSyntax;
                edge.label = try txt.parse(temp, rest[1..end]);
                rest = rest[end + 1 ..];
            }
            if (txt.starts(rest, "<>")) {
                edge.flow = 3;
                rest = rest[2..];
            } else if (txt.starts(rest, ">")) {
                edge.flow = 2;
                rest = rest[1..];
            } else if (txt.starts(rest, "<")) {
                edge.flow = 1;
                rest = rest[1..];
            } else return error.InvalidSyntax;
            rest = d.trim(rest);
        }
        if (txt.starts(rest, "-.->")) {
            edge.dotted = true;
            rest = rest[4..];
        } else if (txt.starts(rest, "-->")) rest = rest[3..] else if (txt.starts(rest, "->")) rest = rest[2..] else if (txt.starts(rest, ">")) rest = rest[1..] else if (edge.flow == 0) return error.InvalidSyntax;
        if (std.mem.indexOfScalar(u8, rest, ';')) |semi| {
            if (edge.label.len == 0) edge.label = try txt.parse(temp, d.trim(rest[semi + 1 ..]));
            rest = rest[0..semi];
        }
        rest = d.trim(rest);
        for ([_][]const u8{ "+<>", "+>", "+<" }, 0..) |suffix, i| if (std.mem.endsWith(u8, rest, suffix)) {
            if (edge.flow == 0) edge.flow = if (i == 0) 3 else if (i == 1) 2 else 1;
            rest = d.trim(rest[0 .. rest.len - suffix.len]);
            break;
        };
        edge.to = try find(nodes.items, rest);
        if (edges.items.len == 1024) return error.LimitExceeded;
        try edges.append(temp, edge);
    }
    if (stages.items.len == 0) {
        for ([_][]const u8{ "Genesis", "Custom built", "Product / rental", "Commodity / utility" }, 0..) |name, i| try stages.append(temp, .{ .label = name, .boundary = @as(f64, @floatFromInt(i + 1)) / 4 });
    } else {
        var previous: f64 = 0;
        for (stages.items, 0..) |*stage, i| {
            if (stage.boundary < 0) stage.boundary = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(stages.items.len));
            if (stage.boundary <= previous or stage.boundary > 1) return error.InvalidSyntax;
            previous = stage.boundary;
        }
        if (@abs(previous - 1) > 0.000001) return error.InvalidSyntax;
    }
    const w = width - 160;
    const h = height - 180;
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const bg = if (doc.theme == .dark) "#0d1117" else "#ffffff";
    const axis_color = try color(doc, "config.themeVariables.wardley.axisColor", fg);
    const axis_text = try color(doc, "config.themeVariables.wardley.axisTextColor", fg);
    const grid_color = try color(doc, "config.themeVariables.wardley.gridColor", if (doc.theme == .dark) "#36445c" else "#d5dce5");
    const component_fill = try color(doc, "config.themeVariables.wardley.componentFill", bg);
    const component_stroke = try color(doc, "config.themeVariables.wardley.componentStroke", fg);
    const label_color = try color(doc, "config.themeVariables.wardley.componentLabelColor", fg);
    const link_color = try color(doc, "config.themeVariables.wardley.linkStroke", fg);
    const evolve_color = try color(doc, "config.themeVariables.wardley.evolutionStroke", if (doc.theme == .dark) "#ff9191" else "#b52735");
    var minx: f64 = 0;
    var miny: f64 = 0;
    var maxx = width;
    var maxy = height;
    for (nodes.items) |n| {
        const p = point(n.x, n.y, w, h);
        const lx = p.x + n.dx - (if (n.anchor) @as(f64, @floatFromInt(txt.width(n.label))) / 2 else 0);
        minx = @min(minx, lx - 16);
        miny = @min(miny, p.y + n.dy - 24 - (if (n.pipeline_parent) @as(f64, 22) else 0));
        maxx = @max(maxx, lx + @as(f64, @floatFromInt(txt.width(n.label))) + 16);
        maxy = @max(maxy, p.y + n.dy + @as(f64, @floatFromInt(txt.height(n.label))) + 16);
    }
    var annotation_height: usize = 0;
    var annotation_width: usize = 0;
    for (items.items) |item| {
        const p = point(item.x, item.y, w, h);
        if (item.kind == .annotation) {
            annotation_height += txt.height(item.label) + 12;
            annotation_width = @max(annotation_width, txt.width(item.label) + 70);
        } else {
            minx = @min(minx, p.x - @as(f64, @floatFromInt(txt.width(item.label))) / 2 - 20);
            maxx = @max(maxx, p.x + @as(f64, @floatFromInt(txt.width(item.label))) / 2 + 20);
            miny = @min(miny, p.y - 30);
            maxy = @max(maxy, p.y + @as(f64, @floatFromInt(txt.height(item.label))) + 30);
        }
    }
    const annotation_pos = if (annotations) |p| point(p.x, p.y, w, h) else Point{ .x = 80, .y = height };
    if (annotation_height > 0) {
        maxx = @max(maxx, annotation_pos.x + @as(f64, @floatFromInt(annotation_width)) + 20);
        maxy = @max(maxy, annotation_pos.y + @as(f64, @floatFromInt(annotation_height)) + 30);
    }
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(data.coord(maxx - minx), data.coord(maxy - miny), "wardley", prefix);
    try out.flowMarkers(prefix);
    try out.fmt("<g transform=\"translate({d:.2} {d:.2})\">", .{ -minx, -miny });
    try out.fmt("<path d=\"M 80 60 V {d} H {d}\" fill=\"none\" stroke=\"{s}\"/>", .{ 60 + h, 80 + w, axis_color });
    try text(&out, 80 + w / 2, 60 + h + 74, "Evolution", "middle", axis_text);
    try out.fmt("<g transform=\"translate(24 {d}) rotate(-90)\">", .{60 + h / 2});
    try text(&out, 0, 0, "Visibility", "middle", axis_text);
    try out.add("</g>");
    var previous: f64 = 0;
    for (stages.items, 0..) |stage, i| {
        if (i + 1 < stages.items.len) try out.fmt("<path data-stage-boundary=\"{d}\" d=\"M {d} 60 V {d}\" fill=\"none\" stroke=\"{s}\" stroke-dasharray=\"4 5\"/>", .{ stage.boundary, 80 + stage.boundary * w, 60 + h, grid_color });
        const split = std.mem.indexOfScalar(u8, stage.label, '/');
        const sx = 80 + (previous + stage.boundary) * w / 2;
        try text(&out, sx, 60 + h + 28, if (split) |s| d.trim(stage.label[0..s]) else stage.label, "middle", axis_text);
        if (split) |s| try text(&out, sx, 60 + h + 48, d.trim(stage.label[s + 1 ..]), "middle", axis_text);
        previous = stage.boundary;
    }
    for (nodes.items, 0..) |parent, i| if (parent.pipeline_parent) {
        var left: f64 = 1;
        var right: f64 = 0;
        var count: usize = 0;
        for (nodes.items) |n| if (n.pipeline == i) {
            left = @min(left, n.x);
            right = @max(right, n.x);
            count += 1;
        };
        if (count == 0) return error.InvalidSyntax;
        const p = point(left, parent.y, w, h);
        const q = point(right, parent.y, w, h);
        try out.fmt("<rect data-pipeline=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"50\" rx=\"3\" fill=\"none\" stroke=\"{s}\"/><path d=\"M {d} {d} H {d}\" fill=\"none\" stroke-dasharray=\"4 4\"/>", .{ i, p.x - 20, p.y - 25, q.x - p.x + 40, grid_color, p.x, p.y, q.x });
    };
    for (edges.items, 0..) |edge, i| {
        var p = point(nodes.items[edge.from].x, nodes.items[edge.from].y, w, h);
        var q = point(nodes.items[edge.to].x, nodes.items[edge.to].y, w, h);
        const dx = q.x - p.x;
        const dy = q.y - p.y;
        const length = @sqrt(dx * dx + dy * dy);
        try out.fmt("<path data-wardley-link=\"{d}\"", .{i});
        if (length < 1) {
            const r = radius(nodes.items[edge.from]);
            try out.add(" ");
            try @import("flow_links.zig").terminalCubic(&out, .{ .x = p.x - r, .y = p.y }, .{ .x = p.x - 45, .y = p.y - 48 }, .{ .x = p.x + 45, .y = p.y - 48 }, .{ .x = p.x + r, .y = p.y });
        } else {
            const r1 = @min(radius(nodes.items[edge.from]), length / 3);
            const r2 = @min(radius(nodes.items[edge.to]), length / 3);
            p.x += dx / length * r1;
            p.y += dy / length * r1;
            q.x -= dx / length * r2;
            q.y -= dy / length * r2;
            try out.fmt(" d=\"M {d} {d} L {d} {d}\"", .{ p.x, p.y, q.x, q.y });
        }
        try out.fmt(" fill=\"none\" stroke=\"{s}\"", .{link_color});
        if (edge.flow & 1 != 0) try out.fmt(" marker-start=\"url(#zm-{d}-arrow)\"", .{prefix});
        if (edge.flow & 2 != 0) try out.fmt(" marker-end=\"url(#zm-{d}-arrow)\"", .{prefix});
        if (edge.dotted) try out.add(" stroke-dasharray=\"5 4\"");
        try out.add("/>");
        if (edge.label.len > 0) try text(&out, (p.x + q.x) / 2, (p.y + q.y) / 2 - 10, edge.label, "middle", label_color);
    }
    for (nodes.items, 0..) |n, i| {
        const p = point(n.x, n.y, w, h);
        try out.fmt("<g data-wardley-node=\"{d}\" data-evolution=\"{d}\" data-visibility=\"{d}\" data-x=\"{d}\" data-y=\"{d}\">", .{ i, n.x, n.y, p.x, p.y });
        if (n.evolve) |target| {
            const q = point(target, n.y, w, h);
            const sign: f64 = if (q.x >= p.x) 1 else -1;
            const inset = @min(@abs(q.x - p.x) / 3, 8);
            try out.fmt("<path data-evolve=\"{d}\" d=\"M {d} {d} H {d}\" fill=\"none\" stroke=\"{s}\" stroke-dasharray=\"5 4\" marker-end=\"url(#zm-{d}-arrow)\"/><circle cx=\"{d}\" cy=\"{d}\" r=\"7\" fill=\"{s}\" stroke=\"{s}\"/>", .{ target, p.x + sign * inset, p.y, q.x - sign * inset, evolve_color, prefix, q.x, q.y, component_fill, evolve_color });
        }
        if (!n.anchor) {
            if (n.strategy.len > 0) {
                try out.fmt("<circle data-strategy=\"{s}\" cx=\"{d}\" cy=\"{d}\" r=\"16\" fill=\"{s}\" stroke=\"{s}\"/>", .{ n.strategy, p.x, p.y, if (std.mem.eql(u8, n.strategy, "outsource")) "#666666" else if (std.mem.eql(u8, n.strategy, "buy")) "#cccccc" else component_fill, component_stroke });
            }
            if (n.pipeline_parent) try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"14\" height=\"14\" fill=\"{s}\" stroke=\"{s}\"/>", .{ p.x - 7, p.y - 7, component_fill, component_stroke }) else if (std.mem.eql(u8, n.strategy, "market")) {
                try out.fmt("<path d=\"M {d} {d} l -8 14 h 16 Z\" fill=\"none\"/>", .{ p.x, p.y - 9 });
                for ([_]Point{ .{ .x = 0, .y = -9 }, .{ .x = -8, .y = 5 }, .{ .x = 8, .y = 5 } }) |o| try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"4\" fill=\"{s}\"/>", .{ p.x + o.x, p.y + o.y, component_fill });
            } else try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"7\" fill=\"{s}\" stroke=\"{s}\"/>", .{ p.x, p.y, component_fill, component_stroke });
            if (n.inertia) try out.fmt("<path data-inertia=\"true\" d=\"M {d} {d} v 20\" stroke=\"{s}\" stroke-width=\"5\"/>", .{ p.x + 24, p.y - 10, component_stroke });
        }
        if (n.anchor) try out.add("<g font-weight=\"bold\">");
        try text(&out, p.x + n.dx, p.y + n.dy - (if (n.pipeline_parent) @as(f64, 22) else 0), n.label, if (n.anchor) "middle" else "start", label_color);
        if (n.anchor) try out.add("</g>");
        try out.add("</g>");
    }
    if (annotation_height > 0) try out.fmt("<rect data-annotation-legend=\"true\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" fill=\"{s}\" stroke=\"{s}\"/>", .{ annotation_pos.x - 12, annotation_pos.y - 4, annotation_width + 24, annotation_height + 24, bg, grid_color });
    var annotation_y = annotation_pos.y + 20;
    for (items.items) |item| {
        const p = point(item.x, item.y, w, h);
        switch (item.kind) {
            .annotation => {
                try out.fmt("<circle data-annotation=\"{d}\" cx=\"{d}\" cy=\"{d}\" r=\"11\" fill=\"{s}\"/>", .{ item.number, p.x, p.y, bg });
                const number = try std.fmt.allocPrint(temp, "{d}", .{item.number});
                try text(&out, p.x, p.y + 5, number, "middle", fg);
                try text(&out, annotation_pos.x, annotation_y, try std.fmt.allocPrint(temp, "{d}. {s}", .{ item.number, item.label }), "start", fg);
                annotation_y += @as(f64, @floatFromInt(txt.height(item.label))) + 12;
            },
            .note => {
                const nw = @as(f64, @floatFromInt(txt.width(item.label) + 24));
                const nh = @as(f64, @floatFromInt(txt.height(item.label) + 16));
                try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"3\" fill=\"{s}\" stroke=\"{s}\"/>", .{ p.x - nw / 2, p.y - 20, nw, nh, if (doc.theme == .dark) "#3a3526" else "#fff5cc", grid_color });
                try text(&out, p.x, p.y, item.label, "middle", fg);
            },
            .accelerator, .deaccelerator => {
                const sign: f64 = if (item.kind == .accelerator) 1 else -1;
                try out.fmt("<g data-force=\"{s}\" transform=\"translate({d} {d}) scale({d} 1)\"><path d=\"M -18 -10 L -6 0 L -18 10 M -4 -10 L 8 0 L -4 10 M 10 -10 L 22 0 L 10 10\" fill=\"none\" stroke=\"{s}\" stroke-width=\"3\"/></g>", .{ @tagName(item.kind), p.x, p.y, sign, if (item.kind == .accelerator) "#25948d" else "#cc8043" });
                try text(&out, p.x, p.y - 20, item.label, "middle", fg);
            },
        }
    }
    try out.add("</g>");
    return out.finish();
}
