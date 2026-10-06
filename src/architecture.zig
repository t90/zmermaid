const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const icons = @import("icons.zig");
const Typography = @import("chart_text.zig").Text;
fn measure(value: f64) usize {
    return @intFromFloat(@ceil(value));
}
fn label(out: *svg.Svg, font: Typography, x: usize, y: usize, value: []const u8) d.Error!void {
    try font.draw(out, @floatFromInt(x), @floatFromInt(y), value);
}
const Node = struct { id: []const u8, label: []const u8, icon: []const u8 = "", icon_text: []const u8 = "", icon_box: usize = 64, parent: ?usize = null, group: bool = false, junction: bool = false, children: usize = 0, depth: usize = 0, x: usize = 0, y: usize = 0, w: usize = 0, h: usize = 0 };
const Edge = struct { from: usize, to: usize, side1: u8, side2: u8, start: bool = false, end: bool = false, group1: bool = false, group2: bool = false, label: []const u8 = "" };
const Rule = struct { x: bool, less: usize, more: usize };
const Axis = struct {
    parent: [256]usize = undefined,
    rank: [256]usize = .{0} ** 256,
    fn init() Axis {
        var axis: Axis = .{};
        for (0..256) |i| axis.parent[i] = i;
        return axis;
    }
    fn root(self: *const Axis, i: usize) usize {
        var r = i;
        while (self.parent[r] != r) r = self.parent[r];
        return r;
    }
    fn join(self: *Axis, a: usize, b: usize) void {
        self.parent[self.root(b)] = self.root(a);
    }
    fn get(self: *const Axis, i: usize) usize {
        return self.rank[self.root(i)];
    }
};
fn id(rest: *[]const u8) d.Error![]const u8 {
    rest.* = d.trim(rest.*);
    var i: usize = 0;
    while (i < rest.len and (std.ascii.isAlphanumeric(rest.*[i]) or rest.*[i] == '_' or rest.*[i] == '-')) : (i += 1) {}
    if (i == 0) return error.InvalidSyntax;
    const value = rest.*[0..i];
    rest.* = d.trim(rest.*[i..]);
    return value;
}
fn find(nodes: []Node, name: []const u8) d.Error!usize {
    for (nodes, 0..) |n, i| if (std.mem.eql(u8, n.id, name)) return i;
    return error.InvalidSyntax;
}
fn bracket(a: std.mem.Allocator, rest: *[]const u8, opening: u8, closing: u8) d.Error![]const u8 {
    if (rest.len == 0 or rest.*[0] != opening) return error.InvalidSyntax;
    var end: usize = 1;
    var quote: u8 = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest.*[end];
        if (c == '"' or c == '\'') {
            if (end == 1) quote = c else if (quote == c) quote = 0;
        }
        if (c == closing and quote == 0) break;
    }
    if (end == rest.len) return error.InvalidSyntax;
    const result = try txt.parse(a, d.unquote(rest.*[1..end]));
    rest.* = d.trim(rest.*[end + 1 ..]);
    return result;
}
fn side(rest: *[]const u8) d.Error!u8 {
    rest.* = d.trim(rest.*);
    if (rest.len == 0 or std.mem.indexOfScalar(u8, "LRTB", rest.*[0]) == null) return error.InvalidSyntax;
    const result = rest.*[0];
    rest.* = d.trim(rest.*[1..]);
    return result;
}
fn constraints(a: std.mem.Allocator, rules: *std.ArrayList(Rule), from: usize, to: usize, s: u8) !void {
    if (from == to) return;
    try rules.append(a, .{ .x = s == 'L' or s == 'R', .less = if (s == 'R' or s == 'B') from else to, .more = if (s == 'R' or s == 'B') to else from });
}
fn propagate(axis: *Axis, rules: []Rule, x: bool, count: usize) d.Error!void {
    for (0..count) |_| {
        var changed = false;
        for (rules) |rule| if (rule.x == x) {
            const less = axis.root(rule.less);
            const more = axis.root(rule.more);
            if (less == more) return error.InvalidSyntax;
            if (axis.rank[more] <= axis.rank[less]) {
                axis.rank[more] = axis.rank[less] + 1;
                changed = true;
            }
            if (axis.rank[more] > 2048) return error.LimitExceeded;
        };
        if (!changed) return;
    }
    return error.InvalidSyntax;
}
fn pull(axis: *Axis, edges: []Edge, rules: []Rule, x: bool, nodes: []Node) void {
    for (nodes, 0..) |n, i| {
        if (n.group) continue;
        const root = axis.root(i);
        var constrained = false;
        for (rules) |rule| if (rule.x == x and (axis.root(rule.less) == root or axis.root(rule.more) == root)) {
            constrained = true;
        };
        for (nodes, 0..) |_, j| if (j != i and axis.root(j) == root) {
            constrained = true;
        };
        if (constrained) continue;
        var sum: usize = 0;
        var count: usize = 0;
        for (edges) |edge| {
            if (edge.from == i) {
                sum += axis.get(edge.to);
                count += 1;
            } else if (edge.to == i) {
                sum += axis.get(edge.from);
                count += 1;
            }
        }
        if (count > 0) axis.rank[root] = (sum + count / 2) / count;
    }
}
const Point = struct { x: i64, y: i64 };
fn anchor(n: Node, s: u8) Point {
    const icon_size = n.icon_box;
    const cx = @as(i64, @intCast(n.x + n.w / 2));
    const cy = @as(i64, @intCast(n.y + if (n.group) n.h / 2 else if (n.junction) @as(usize, 8) else 8 + icon_size / 2));
    const rx = @as(i64, @intCast(if (n.group) n.w / 2 else if (n.junction) @as(usize, 6) else (icon_size + @as(usize, if (s == 'R') 1 else 0)) / 2));
    const ry = @as(i64, @intCast(if (n.group) n.h / 2 else if (n.junction) @as(usize, 6) else (icon_size + @as(usize, if (s == 'B') 1 else 0)) / 2));
    return .{ .x = cx + (if (s == 'L') -rx else if (s == 'R') rx else 0), .y = cy + (if (s == 'T') -ry else if (s == 'B') ry else 0) };
}
fn outward(p: Point, s: u8) Point {
    const dx: i64 = if (s == 'L') -36 else if (s == 'R') 36 else 0;
    const dy: i64 = if (s == 'T') -36 else if (s == 'B') 36 else 0;
    return .{ .x = p.x + dx, .y = p.y + dy };
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var nodes: std.ArrayList(Node) = .empty;
    var edges: std.ArrayList(Edge) = .empty;
    var rules: std.ArrayList(Rule) = .empty;
    var ax = Axis.init();
    var ay = Axis.init();
    const icon_size: usize = @intFromFloat(try doc.num("config.architecture.iconSize", 64, 8, 512));
    const group_icon = icon_size / 2;
    const padding: usize = @intFromFloat(try doc.num("config.architecture.padding", 40, 0, 2000));
    const font: Typography = .{ .size = try doc.num("config.architecture.fontSize", 14, 6, 96), .color = if (doc.theme == .dark) "#e0e0e0" else "#24292f" };
    var group_header = group_icon + 28;
    const randomize = try doc.flag("config.architecture.randomize", false);
    const requested_seed = try doc.num("config.architecture.seed", 1, 0, 4294967295);
    if (@floor(requested_seed) != requested_seed) return error.InvalidSyntax;
    var seed: u32 = if (requested_seed == 0) prefix else @intFromFloat(requested_seed);
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
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
        var rest = line;
        const command = try id(&rest);
        if (std.mem.eql(u8, command, "service") or std.mem.eql(u8, command, "group") or std.mem.eql(u8, command, "junction")) {
            const name = try id(&rest);
            for (nodes.items) |n| if (std.mem.eql(u8, n.id, name)) return error.InvalidSyntax;
            var n: Node = .{ .id = name, .label = name, .group = std.mem.eql(u8, command, "group"), .junction = std.mem.eql(u8, command, "junction") };
            if (txt.starts(rest, "(")) {
                n.icon = try bracket(temp, &rest, '(', ')');
                if (!icons.known(n.icon)) _ = try doc.assets.get(n.icon);
            } else if (txt.starts(rest, "\"") or txt.starts(rest, "'")) {
                if (n.group or n.junction) return error.InvalidSyntax;
                const quote = rest[0];
                n.icon_text = try bracket(temp, &rest, quote, quote);
            }
            if (txt.starts(rest, "[")) n.label = try bracket(temp, &rest, '[', ']');
            if (rest.len > 0) {
                const keyword = try id(&rest);
                if (!std.mem.eql(u8, keyword, "in")) return error.InvalidSyntax;
                n.parent = try find(nodes.items, try id(&rest));
                if (!nodes.items[n.parent.?].group) return error.InvalidSyntax;
                n.depth = nodes.items[n.parent.?].depth + 1;
                nodes.items[n.parent.?].children += 1;
            }
            if (rest.len > 0) return error.InvalidSyntax;
            if (nodes.items.len == 256 or n.depth > 16) return error.LimitExceeded;
            if (n.icon.len == 0 and n.icon_text.len == 0 and !n.junction) n.icon = if (n.group) "cloud" else "server";
            n.icon_box = if (n.group) group_icon else icon_size;
            if (n.icon_text.len > 0) n.icon_box = @max(n.icon_box, measure(@max(font.width(n.icon_text), font.height(n.icon_text))));
            n.w = @max(n.icon_box + 36, measure(@max(font.width(n.label), font.width(n.icon_text))) + 40);
            if (n.group) {
                n.w = @max(n.w, measure(font.width(n.label)) + n.icon_box + 64);
                group_header = @max(group_header, @max(n.icon_box + 28, measure(font.height(n.label)) + 24));
            }
            if (std.mem.indexOfScalar(u8, n.icon_text, '\n') != null) return error.UnsupportedSyntax;
            n.h = if (n.junction) 16 else @max(110, n.icon_box + 26 + measure(font.height(n.label)));
            if (n.junction) {
                n.w = 16;
                n.label = "";
            }
            try nodes.append(temp, n);
            continue;
        }
        if (std.mem.eql(u8, command, "align")) {
            const direction = try id(&rest);
            const axis = if (std.mem.eql(u8, direction, "row")) &ay else if (std.mem.eql(u8, direction, "column")) &ax else return error.InvalidSyntax;
            const first = try find(nodes.items, try id(&rest));
            if (nodes.items[first].group) return error.InvalidSyntax;
            var count: usize = 0;
            while (rest.len > 0) {
                const next = try find(nodes.items, try id(&rest));
                if (nodes.items[next].group) return error.InvalidSyntax;
                axis.join(first, next);
                count += 1;
            }
            if (count == 0) return error.InvalidSyntax;
            continue;
        }
        const from = try find(nodes.items, command);
        var edge: Edge = .{ .from = from, .to = undefined, .side1 = undefined, .side2 = undefined };
        if (txt.starts(rest, "{group}")) {
            edge.group1 = true;
            rest = d.trim(rest[7..]);
        }
        if (!txt.starts(rest, ":")) return error.InvalidSyntax;
        rest = rest[1..];
        edge.side1 = try side(&rest);
        if (txt.starts(rest, "<")) {
            edge.start = true;
            rest = d.trim(rest[1..]);
        }
        if (txt.starts(rest, "--")) rest = d.trim(rest[2..]) else {
            if (!txt.starts(rest, "-")) return error.InvalidSyntax;
            rest = d.trim(rest[1..]);
            edge.label = try bracket(temp, &rest, '[', ']');
            if (!txt.starts(rest, "-")) return error.InvalidSyntax;
            rest = d.trim(rest[1..]);
        }
        if (txt.starts(rest, ">")) {
            edge.end = true;
            rest = d.trim(rest[1..]);
        }
        edge.side2 = try side(&rest);
        if (!txt.starts(rest, ":")) return error.InvalidSyntax;
        rest = rest[1..];
        edge.to = try find(nodes.items, try id(&rest));
        if (txt.starts(rest, "{group}")) {
            edge.group2 = true;
            rest = d.trim(rest[7..]);
        }
        if (rest.len > 0) return error.InvalidSyntax;
        if ((edge.group1 and nodes.items[from].parent == null) or (edge.group2 and nodes.items[edge.to].parent == null)) return error.InvalidSyntax;
        if ((edge.group1 or edge.group2) and nodes.items[from].parent == nodes.items[edge.to].parent) return error.InvalidSyntax;
        if (nodes.items[from].group or nodes.items[edge.to].group) return error.UnsupportedSyntax;
        if (edges.items.len == 512) return error.LimitExceeded;
        try edges.append(temp, edge);
        try constraints(temp, &rules, from, edge.to, edge.side1);
        if ((edge.side1 == 'L' or edge.side1 == 'R') != (edge.side2 == 'L' or edge.side2 == 'R')) try constraints(temp, &rules, edge.to, from, edge.side2);
    }
    if (nodes.items.len == 0) return error.InvalidSyntax;
    // Port directions guide layout; they are not hard spatial constraints. Keep
    // explicit alignments, and route feedback edges without inventing a parse error.
    var effective: std.ArrayList(Rule) = .empty;
    for (rules.items) |rule| {
        const axis = if (rule.x) &ax else &ay;
        const less = axis.root(rule.less);
        const more = axis.root(rule.more);
        if (less == more) continue;
        var seen = [_]bool{false} ** 256;
        seen[more] = true;
        for (0..nodes.items.len) |_| {
            var changed = false;
            for (effective.items) |prior| if (prior.x == rule.x and seen[axis.root(prior.less)] and !seen[axis.root(prior.more)]) {
                seen[axis.root(prior.more)] = true;
                changed = true;
            };
            if (!changed) break;
        }
        if (!seen[less]) try effective.append(temp, rule);
    }
    rules = effective;
    if (randomize or requested_seed != 1) {
        // Vary initial grid ranks, then reapply explicit alignments and port
        // constraints. The seed controls our solver, not fcose geometry.
        for (0..nodes.items.len) |i| {
            seed = seed *% 1664525 +% 1013904223;
            if (ax.root(i) == i) ax.rank[i] = (seed >> 16) % 3;
            seed = seed *% 1664525 +% 1013904223;
            if (ay.root(i) == i) ay.rank[i] = (seed >> 16) % 3;
        }
    }
    try propagate(&ax, rules.items, true, nodes.items.len);
    try propagate(&ay, rules.items, false, nodes.items.len);
    for (0..3) |_| {
        pull(&ax, edges.items, rules.items, true, nodes.items);
        pull(&ay, edges.items, rules.items, false, nodes.items);
    }
    for (0..512) |attempt| {
        var collision = false;
        outer: for (nodes.items, 0..) |n, i| {
            if (n.group and n.children > 0) continue;
            for (nodes.items[0..i], 0..) |other, j| {
                if (other.group and other.children > 0) continue;
                if (ax.get(i) == ax.get(j) and ay.get(i) == ay.get(j)) {
                    if (ay.root(i) != ay.root(j)) ay.rank[ay.root(i)] += 1 else if (ax.root(i) != ax.root(j)) ax.rank[ax.root(i)] += 1 else return error.InvalidSyntax;
                    collision = true;
                    break :outer;
                }
            }
        }
        if (!collision) break;
        if (attempt == 511) return error.LimitExceeded;
        try propagate(&ax, rules.items, true, nodes.items.len);
        try propagate(&ay, rules.items, false, nodes.items.len);
    }
    var depth: usize = 0;
    var cell_w: usize = 180;
    var cell_h: usize = 180;
    for (nodes.items) |n| {
        depth = @max(depth, n.depth);
        cell_w = @max(cell_w, n.w + 100);
        cell_h = @max(cell_h, n.h + 100);
    }
    cell_w += depth * 80;
    cell_h += depth * @max(80, group_header + 32);
    const margin = padding + 40 + depth * (group_header + 4);
    for (nodes.items, 0..) |*n, i| {
        n.x = margin + ax.get(i) * cell_w + (cell_w - n.w) / 2;
        n.y = margin + ay.get(i) * cell_h;
    }
    var reverse = nodes.items.len;
    while (reverse > 0) {
        reverse -= 1;
        var n = &nodes.items[reverse];
        if (!n.group or n.children == 0) continue;
        var left: usize = std.math.maxInt(usize);
        var top = left;
        var right: usize = 0;
        var bottom: usize = 0;
        for (nodes.items) |child| if (child.parent == reverse) {
            left = @min(left, child.x);
            top = @min(top, child.y);
            right = @max(right, child.x + child.w);
            bottom = @max(bottom, child.y + child.h);
        };
        n.x = left - 32;
        n.y = top - group_header;
        n.w = @max(n.w, right - left + 64);
        n.h = bottom - top + group_header + 32;
    }
    var width: usize = 0;
    var height: usize = 0;
    for (nodes.items) |n| {
        width = @max(width, n.x + n.w + padding + 40);
        height = @max(height, n.y + n.h + padding + 40);
    }
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "architecture", prefix);
    try out.flowMarkers(prefix);
    for (nodes.items, 0..) |n, i| if (n.group) {
        try out.fmt("<g data-architecture-group=\"{d}\" data-parent=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"10\" fill=\"{s}\" fill-opacity=\"0.55\" stroke-dasharray=\"6 4\"/>", .{ i, n.parent orelse 256, n.x, n.y, n.w, n.h, if (doc.theme == .dark) "#1b2638" else "#eff4fb" });
        try icons.drawRegistered(&out, &doc.assets, n.icon, n.x + 16, n.y + 12, n.icon_box);
        try label(&out, font, n.x + (n.w + n.icon_box + 16) / 2, n.y + 12, n.label);
        try out.add("</g>");
    };
    for (edges.items, 0..) |edge, i| {
        const from = if (edge.group1) nodes.items[nodes.items[edge.from].parent.?] else nodes.items[edge.from];
        const to = if (edge.group2) nodes.items[nodes.items[edge.to].parent.?] else nodes.items[edge.to];
        const p = anchor(from, edge.side1);
        const q = anchor(to, edge.side2);
        const p1 = outward(p, edge.side1);
        const q1 = outward(q, edge.side2);
        try out.fmt("<path data-architecture-edge=\"{d}\" data-from-port=\"{c}\" data-to-port=\"{c}\" fill=\"none\"", .{ i, edge.side1, edge.side2 });
        if (edge.start) try out.fmt(" marker-start=\"url(#zm-{d}-arrow)\"", .{prefix});
        if (edge.end) try out.fmt(" marker-end=\"url(#zm-{d}-arrow)\"", .{prefix});
        try out.fmt(" d=\"M {d} {d} L {d} {d} ", .{ p.x, p.y, p1.x, p1.y });
        if ((edge.side1 == 'L' or edge.side1 == 'R') and (edge.side2 == 'L' or edge.side2 == 'R')) {
            const mid = @divTrunc(p1.x + q1.x, 2);
            try out.fmt("H {d} V {d} H {d} ", .{ mid, q1.y, q1.x });
        } else {
            const mid = @divTrunc(p1.y + q1.y, 2);
            try out.fmt("V {d} H {d} V {d} ", .{ mid, q1.x, q1.y });
        }
        try out.fmt("L {d} {d}\"/>", .{ q.x, q.y });
        if (edge.label.len > 0) try label(&out, font, @intCast(@divTrunc(p.x + q.x, 2)), @intCast(@divTrunc(p.y + q.y, 2) - 12), edge.label);
    }
    for (nodes.items, 0..) |n, i| if (!n.group) {
        try out.fmt("<g data-architecture-node=\"{d}\" data-parent=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\">", .{ i, n.parent orelse 256, n.x, n.y, n.w, n.h });
        if (n.junction) try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"6\"/>", .{ n.x + 8, n.y + 8 }) else {
            if (n.icon_text.len > 0) try label(&out, font, n.x + n.w / 2, n.y + 8 + (n.icon_box - measure(font.height(n.icon_text))) / 2, n.icon_text) else try icons.drawRegistered(&out, &doc.assets, n.icon, n.x + n.w / 2 - n.icon_box / 2, n.y + 8, n.icon_box);
            try label(&out, font, n.x + n.w / 2, n.y + n.icon_box + 18, n.label);
        }
        try out.add("</g>");
    };
    return out.finish();
}
