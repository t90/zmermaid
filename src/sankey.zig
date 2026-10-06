const std = @import("std");
const svg = @import("svg.zig");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const data = @import("chart_data.zig");
const Node = struct { label: []const u8, value_label: []const u8 = "", incoming: f64 = 0, outgoing: f64 = 0, value: f64 = 0, indegree: usize = 0, rank: usize = 0, x: f64 = 0, y: f64 = 0, height: f64 = 0, used_in: f64 = 0, used_out: f64 = 0, color: []const u8 = "" };
const Edge = struct { from: usize, to: usize, value: f64 };
fn id(a: std.mem.Allocator, nodes: *std.ArrayList(Node), label: []const u8) d.Error!usize {
    for (nodes.items, 0..) |node, i| if (std.mem.eql(u8, node.label, label)) return i;
    if (nodes.items.len == 256) return error.LimitExceeded;
    try nodes.append(a, .{ .label = label });
    return nodes.items.len - 1;
}
fn csv(a: std.mem.Allocator, part: []const u8) d.Error![]const u8 {
    const raw = d.trim(part);
    if (raw.len == 0) return error.InvalidSyntax;
    if (raw[0] != '"') {
        if (std.mem.indexOfScalar(u8, raw, '"') != null) return error.InvalidSyntax;
        return txt.parse(a, raw);
    }
    if (raw.len < 2 or raw[raw.len - 1] != '"') return error.InvalidSyntax;
    var decoded: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < raw.len - 1) : (i += 1) {
        if (raw[i] == '"') {
            if (i + 1 >= raw.len - 1 or raw[i + 1] != '"') return error.InvalidSyntax;
            i += 1;
        }
        try decoded.append(a, raw[i]);
    }
    return txt.parse(a, decoded.items);
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var nodes: std.ArrayList(Node) = .empty;
    var edges: std.ArrayList(Edge) = .empty;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        var fields: data.Parts = .{ .rest = line };
        const source = try csv(temp, (try fields.next()) orelse return error.InvalidSyntax);
        const target = try csv(temp, (try fields.next()) orelse return error.InvalidSyntax);
        const value = try d.number((try fields.next()) orelse return error.InvalidSyntax);
        if (try fields.next() != null or value < 0) return error.InvalidSyntax;
        const from = try id(temp, &nodes, source);
        const to = try id(temp, &nodes, target);
        if (from == to) return error.InvalidSyntax;
        if (edges.items.len == 1024) return error.LimitExceeded;
        try edges.append(temp, .{ .from = from, .to = to, .value = value });
        nodes.items[from].outgoing += value;
        nodes.items[to].incoming += value;
        nodes.items[to].indegree += 1;
    }
    if (edges.items.len == 0) return error.InvalidSyntax;
    var queue: [256]usize = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    for (nodes.items, 0..) |node, i| if (node.indegree == 0) {
        queue[tail] = i;
        tail += 1;
    };
    while (head < tail) : (head += 1) {
        const from = queue[head];
        for (edges.items) |edge| if (edge.from == from) {
            const dest = &nodes.items[edge.to];
            dest.rank = @max(dest.rank, nodes.items[from].rank + 1);
            dest.indegree -= 1;
            if (dest.indegree == 0) {
                queue[tail] = edge.to;
                tail += 1;
            }
        };
    }
    if (tail != nodes.items.len) return error.InvalidSyntax;
    const show = try doc.flag("config.sankey.showValues", true);
    const value_prefix = try txt.parse(temp, doc.get("config.sankey.prefix") orelse "");
    const value_suffix = try txt.parse(temp, doc.get("config.sankey.suffix") orelse "");
    const outlined = doc.get("config.sankey.labelStyle") orelse "legacy";
    if (!std.mem.eql(u8, outlined, "plain") and !std.mem.eql(u8, outlined, "legacy") and !std.mem.eql(u8, outlined, "outlined")) return error.UnsupportedSyntax;
    const link_color = doc.get("config.sankey.linkColor") orelse "gradient";
    const gradient = std.mem.eql(u8, link_color, "gradient");
    const from_color = std.mem.eql(u8, link_color, "source");
    const to_color = std.mem.eql(u8, link_color, "target");
    const fixed_color = if (!gradient and !from_color and !to_color) try d.color(link_color) else "";
    const node_width = try doc.num("config.sankey.nodeWidth", 16, 1, 200);
    const padding = try doc.num("config.sankey.nodePadding", 20, 0, 1000);
    const requested_width = try doc.num("config.sankey.width", 900, 100, 20000);
    const requested_height = try doc.num("config.sankey.height", 500, 100, 20000);
    const alignment = doc.get("config.sankey.nodeAlignment") orelse "justify";
    if (!std.mem.eql(u8, alignment, "justify") and !std.mem.eql(u8, alignment, "left") and !std.mem.eql(u8, alignment, "right") and !std.mem.eql(u8, alignment, "center")) return error.UnsupportedSyntax;
    var max_rank: usize = 0;
    for (nodes.items) |*node| {
        node.value = @max(node.incoming, node.outgoing);
        max_rank = @max(max_rank, node.rank);
    }
    if (std.mem.eql(u8, alignment, "justify")) for (nodes.items, 0..) |*node, i| {
        var sink = true;
        for (edges.items) |edge| if (edge.from == i) {
            sink = false;
        };
        if (sink) node.rank = max_rank;
    };
    if (std.mem.eql(u8, alignment, "right")) {
        // Reverse topological distances put every sink in the final column.
        var distance = [_]usize{0} ** 256;
        var remaining = tail;
        while (remaining > 0) {
            remaining -= 1;
            const from = queue[remaining];
            for (edges.items) |edge| if (edge.from == from) {
                distance[from] = @max(distance[from], distance[edge.to] + 1);
            };
        }
        for (nodes.items, 0..) |*node, i| node.rank = max_rank - distance[i];
    } else if (std.mem.eql(u8, alignment, "center")) {
        for (nodes.items, 0..) |*node, i| {
            var has_input = false;
            var first_target = max_rank;
            for (edges.items) |edge| {
                if (edge.to == i) has_input = true;
                if (edge.from == i) first_target = @min(first_target, nodes.items[edge.to].rank);
            }
            if (!has_input) node.rank = first_target -| 1;
        }
    }
    var sums = [_]f64{0} ** 256;
    var gaps = [_]f64{0} ** 256;
    var max_label: usize = 0;
    for (nodes.items, 0..) |*node, i| {
        sums[node.rank] += node.value;
        gaps[node.rank] += @as(f64, @floatFromInt(txt.height(node.label) + (if (show) @as(usize, 20) else 0))) + padding;
        max_label = @max(max_label, txt.width(node.label));
        if (show) {
            const amount = try data.format(temp, node.value);
            var end = amount.len;
            while (end > 0 and amount[end - 1] == '0') end -= 1;
            if (end > 0 and amount[end - 1] == '.') end -= 1;
            node.value_label = try std.fmt.allocPrint(temp, "{s}{s}{s}", .{ value_prefix, amount[0..end], value_suffix });
            max_label = @max(max_label, txt.width(node.value_label));
            gaps[node.rank] += @as(f64, @floatFromInt(txt.height(node.value_label) - 20));
        }
        const key = try std.fmt.allocPrint(temp, "config.sankey.nodeColors.{s}", .{node.label});
        node.color = if (doc.get(key)) |c| try d.color(c) else try doc.palette(i);
    }
    var peak: f64 = 0;
    var max_gap: f64 = 0;
    for (sums[0 .. max_rank + 1], gaps[0 .. max_rank + 1]) |sum, gap| {
        peak = @max(peak, sum);
        max_gap = @max(max_gap, gap);
    }
    if (peak <= 0) return error.InvalidSyntax;
    const chart_height = @max(requested_height, max_gap + 400);
    const scale = (chart_height - max_gap) / peak;
    const rank_step = @max(@as(f64, @floatFromInt(max_label + 100)), (requested_width - 80) / @as(f64, @floatFromInt(@max(max_rank, 1))));
    const left_margin: f64 = @floatFromInt(max_label + 40);
    const width = data.coord(rank_step * @as(f64, @floatFromInt(max_rank)) + node_width + 2 * left_margin);
    const height = data.coord(chart_height + 80);
    var offsets = [_]f64{40} ** 256;
    for (nodes.items) |*node| {
        node.x = left_margin + @as(f64, @floatFromInt(node.rank)) * rank_step;
        node.y = offsets[node.rank];
        node.height = node.value * scale;
        offsets[node.rank] += node.height + padding + @as(f64, @floatFromInt(txt.height(node.label) + (if (show) txt.height(node.value_label) else 0)));
    }
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "sankey", prefix);
    for (edges.items, 0..) |edge, i| {
        const source = &nodes.items[edge.from];
        const target = &nodes.items[edge.to];
        const thickness = edge.value * scale;
        const x1 = source.x + node_width;
        const x2 = target.x;
        const y1 = source.y + source.used_out;
        const y2 = target.y + target.used_in;
        const mid = (x1 + x2) / 2;
        const fill = if (gradient) try std.fmt.allocPrint(temp, "url(#zm-{d}-sankey-{d})", .{ prefix, i }) else if (from_color) source.color else if (to_color) target.color else fixed_color;
        if (gradient) try out.fmt("<defs><linearGradient id=\"zm-{d}-sankey-{d}\" gradientUnits=\"userSpaceOnUse\" x1=\"{d:.4}\" y1=\"0\" x2=\"{d:.4}\" y2=\"0\"><stop offset=\"0%\" stop-color=\"{s}\"/><stop offset=\"100%\" stop-color=\"{s}\"/></linearGradient></defs>", .{ prefix, i, x1, x2, source.color, target.color });
        try out.fmt("<path data-link=\"{d}\" data-source=\"{d}\" data-target=\"{d}\" data-value=\"{d}\" data-thickness=\"{d:.4}\" fill=\"{s}\" fill-opacity=\"0.4\" stroke=\"none\" d=\"M {d:.4} {d:.4} C {d:.4} {d:.4} {d:.4} {d:.4} {d:.4} {d:.4} L {d:.4} {d:.4} C {d:.4} {d:.4} {d:.4} {d:.4} {d:.4} {d:.4} Z\"/>", .{ i, edge.from, edge.to, edge.value, thickness, fill, x1, y1, mid, y1, mid, y2, x2, y2, x2, y2 + thickness, mid, y2 + thickness, mid, y1 + thickness, x1, y1 + thickness });
        source.used_out += thickness;
        target.used_in += thickness;
    }
    var central: usize = 0;
    for (nodes.items, 0..) |node, i| if (node.value > nodes.items[central].value) {
        central = i;
    };
    for (nodes.items, 0..) |node, i| {
        try out.fmt("<rect data-node=\"{d}\" data-value=\"{d}\" x=\"{d:.4}\" y=\"{d:.4}\" width=\"{d}\" height=\"{d:.4}\" fill=\"{s}\"/>", .{ i, node.value, node.x, node.y, node_width, node.height, node.color });
        const left_label = if (std.mem.eql(u8, outlined, "outlined")) node.rank < nodes.items[central].rank else node.rank * 2 >= max_rank;
        const label = if (show) try std.fmt.allocPrint(temp, "{s}\n{s}", .{ node.label, node.value_label }) else node.label;
        const label_y = data.coord(@max(0, node.y + node.height / 2 - @as(f64, @floatFromInt(txt.height(label))) / 2));
        var label_lines = std.mem.splitScalar(u8, label, '\n');
        var ly = label_y;
        while (label_lines.next()) |line| {
            const half: f64 = @as(f64, @floatFromInt(txt.width(line))) / 2;
            const label_x = data.coord(if (left_label) node.x - 8 - half else node.x + node_width + 8 + half);
            if (std.mem.eql(u8, outlined, "outlined")) {
                try out.fmt("<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-family=\"Consolas,monospace\" font-size=\"14\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"4\" paint-order=\"stroke\">", .{ label_x, ly + 10, if (doc.theme == .dark) "#e0e0e0" else "#24292f", if (doc.theme == .dark) "#0d1117" else "#ffffff" });
                try out.escape(line);
                try out.add("</text>");
            } else try txt.draw(&out, label_x, ly, line);
            ly += 20;
        }
    }
    return out.finish();
}
