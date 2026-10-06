// SPDX-License-Identifier: EPL-2.0
// Mermaid 11.16.1 implementation/behavior references:
// https://github.com/mermaid-js/mermaid/blob/7ecca0cd7f1658ef74f4e7e91f925724ef403bbf/packages/mermaid/src/diagrams/state/
// Upstream copyright: (c) 2014 - 2022 Knut Sveidqvist.
// Upstream MIT notice: LICENSES/Mermaid-MIT.txt; project license: LICENSE.
const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const flow = @import("flowchart.zig");
const class = @import("class.zig");
const compound = @import("flow_compound.zig");
const Cursor = struct {
    rest: []const u8,
    fn trim(self: *Cursor) void {
        self.rest = d.trim(self.rest);
    }
    fn name(self: *Cursor) d.Error![]const u8 {
        self.trim();
        if (txt.starts(self.rest, "[*]")) {
            self.rest = self.rest[3..];
            return "[*]";
        }
        var end: usize = 0;
        while (end < self.rest.len and std.mem.indexOfScalar(u8, " \t\r\n:{}<", self.rest[end]) == null) : (end += 1) {
            if (txt.starts(self.rest[end..], "-->")) break;
        }
        if (end == 0) return error.InvalidSyntax;
        const result = self.rest[0..end];
        self.rest = self.rest[end..];
        return result;
    }
    fn quoted(self: *Cursor) d.Error![]const u8 {
        self.trim();
        if (self.rest.len < 2 or self.rest[0] != '"') return error.InvalidSyntax;
        const end = std.mem.indexOfScalarPos(u8, self.rest, 1, '"') orelse return error.InvalidSyntax;
        const result = self.rest[1..end];
        self.rest = self.rest[end + 1 ..];
        return result;
    }
};
const Scope = struct { id: usize, region: ?usize = null, count: usize = 0, direction: []const u8 = "TB" };
fn endpoint(graph: *flow.Parser, cur: *Cursor, parent: ?usize, final: bool) d.Error!usize {
    const raw = try cur.name();
    const pseudo = std.mem.eql(u8, raw, "[*]");
    const name = if (pseudo) (if (parent) |p| try std.fmt.allocPrint(graph.allocator, "{s}:{d}", .{ if (final) "end" else "start", p }) else if (final) "end" else "start") else raw;
    const id = try class.getNode(graph, name, parent, false);
    if (pseudo) {
        graph.nodes.items[id].label = "";
        graph.nodes.items[id].shape = if (final) .framed_circle else .small_circle;
    } else if (graph.nodes.items[id].shape == .box) graph.nodes.items[id].shape = .round;
    cur.trim();
    if (txt.starts(cur.rest, ":::")) {
        cur.rest = cur.rest[3..];
        const css = try cur.name();
        graph.nodes.items[id].classes = try std.fmt.allocPrint(graph.allocator, "{s}{s}{s}", .{ graph.nodes.items[id].classes, if (graph.nodes.items[id].classes.len > 0) "," else "", css });
        cur.trim();
    }
    return id;
}
fn region(graph: *flow.Parser, parent: usize, index: usize, direction: []const u8) d.Error!usize {
    const id = try class.getNode(graph, try std.fmt.allocPrint(graph.allocator, "region:{d}:{d}", .{ parent, index }), parent, false);
    graph.nodes.items[id].container = true;
    graph.nodes.items[id].region = true;
    graph.nodes.items[id].label = "";
    graph.nodes.items[id].direction = direction;
    return id;
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var graph: flow.Parser = .{ .allocator = temp, .kind = "state" };
    defer graph.deinit();
    const direction = try parse(&graph, doc);
    return compound.render(a, &graph, doc.theme, prefix, direction);
}

/// Shared semantic adapter. Measured and legacy renderers consume the same parser.
pub fn parse(graph: *flow.Parser, doc: *d.Document) d.Error![]const u8 {
    const temp = graph.allocator;
    graph.kind = "state";
    var direction: []const u8 = "TB";
    var stack: [16]Scope = undefined;
    var depth: usize = 0;
    var pending_container: ?usize = null;
    var clicks: std.ArrayList(struct { id: []const u8, action: @import("interaction.zig").Action }) = .empty;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        var line = d.trim(raw);
        var quoted = false;
        for (line, 0..) |c, i| {
            if (c == '"') quoted = !quoted;
            if (!quoted and txt.starts(line[i..], "%%")) {
                line = d.trim(line[0..i]);
                break;
            }
        }
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "{")) {
            const id = pending_container orelse return error.InvalidSyntax;
            if (depth == stack.len) return error.LimitExceeded;
            if (graph.nodes.items[id].container) return error.InvalidSyntax;
            graph.nodes.items[id].container = true;
            stack[depth] = .{ .id = id, .direction = direction };
            depth += 1;
            pending_container = null;
            continue;
        }
        pending_container = null;
        const parent = if (depth > 0) (stack[depth - 1].region orelse stack[depth - 1].id) else null;
        if (txt.starts(line, "accTitle:")) {
            doc.acc_title = d.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "accDescr:")) {
            doc.acc_description = d.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "accDescr {")) {
            var description: std.ArrayList(u8) = .empty;
            var rest = line[10..];
            while (true) {
                if (std.mem.indexOfScalar(u8, rest, '}')) |end| {
                    try description.appendSlice(temp, rest[0..end]);
                    if (d.trim(rest[end + 1 ..]).len > 0) return error.InvalidSyntax;
                    break;
                }
                try description.appendSlice(temp, rest);
                try description.append(temp, '\n');
                if (description.items.len > 4096) return error.LimitExceeded;
                rest = lines.next() orelse return error.InvalidSyntax;
            }
            doc.acc_description = try doc.a.dupe(u8, description.items);
            continue;
        }
        if (txt.starts(line, "direction ")) {
            const dir = d.trim(line[10..]);
            if (!compound.validDirection(dir)) return error.InvalidSyntax;
            if (parent) |p| {
                graph.nodes.items[p].direction = dir;
                stack[depth - 1].direction = dir;
            } else direction = dir;
            continue;
        }
        if (txt.starts(line, "classDef ") or txt.starts(line, "class ") or txt.starts(line, "style ")) {
            if (txt.starts(line, "class ")) {
                const rest = d.trim(std.mem.trimEnd(u8, line[6..], ";"));
                const split = std.mem.lastIndexOfAny(u8, rest, " \t") orelse return error.InvalidSyntax;
                var ids = std.mem.splitScalar(u8, rest[0..split], ',');
                while (ids.next()) |id| {
                    const node = try class.getNode(graph, d.trim(id), parent, false);
                    if (graph.nodes.items[node].shape == .box) graph.nodes.items[node].shape = .round;
                }
            }
            try graph.statement(std.mem.trimEnd(u8, line, ";"));
            continue;
        }
        if (txt.starts(line, "click ")) {
            var cur: Cursor = .{ .rest = std.mem.trimEnd(u8, line[6..], ";") };
            const id = try cur.name();
            cur.trim();
            if (txt.starts(cur.rest, "href ")) cur.rest = cur.rest[5..];
            const url = try cur.quoted();
            if (!@import("interaction.zig").safeUrl(url)) return error.UnsupportedSyntax;
            cur.trim();
            const tooltip = if (cur.rest.len > 0) try cur.quoted() else "";
            cur.trim();
            if (cur.rest.len > 0 or tooltip.len > 512) return error.InvalidSyntax;
            if (clicks.items.len == 512) return error.LimitExceeded;
            try clicks.append(temp, .{ .id = id, .action = .{ .href = url, .tooltip = tooltip } });
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            if (depth == 0) return error.InvalidSyntax;
            depth -= 1;
            continue;
        }
        if (std.mem.eql(u8, line, "--")) {
            if (depth == 0) return error.InvalidSyntax;
            const scope = &stack[depth - 1];
            if (scope.region == null) {
                const first = try region(graph, scope.id, 0, scope.direction);
                for (graph.nodes.items, 0..) |*node, i| if (i != first and node.parent == scope.id) {
                    node.parent = first;
                };
                scope.count = 1;
                graph.nodes.items[scope.id].direction = "LR";
            }
            scope.region = try region(graph, scope.id, scope.count, scope.direction);
            scope.count += 1;
            continue;
        }
        if (txt.starts(line, "note ")) {
            var cur: Cursor = .{ .rest = line[5..] };
            const side = try cur.name();
            if (!std.mem.eql(u8, side, "left") and !std.mem.eql(u8, side, "right")) return error.UnsupportedSyntax;
            if (!std.mem.eql(u8, try cur.name(), "of")) return error.InvalidSyntax;
            const target = try endpoint(graph, &cur, parent, false);
            cur.trim();
            var note: []const u8 = "";
            if (txt.starts(cur.rest, ":")) {
                note = try txt.parse(temp, d.trim(cur.rest[1..]));
            } else {
                if (cur.rest.len > 0) return error.InvalidSyntax;
                var body: std.ArrayList(u8) = .empty;
                var ended = false;
                while (lines.next()) |part| {
                    if (std.mem.eql(u8, d.trim(part), "end note")) {
                        ended = true;
                        break;
                    }
                    if (body.items.len > 0) try body.appendSlice(temp, "<br/>");
                    try body.appendSlice(temp, d.trim(part));
                    if (body.items.len > 512) return error.LimitExceeded;
                }
                if (!ended) return error.InvalidSyntax;
                note = try txt.parse(temp, body.items);
            }
            const id = try class.getNode(graph, try std.fmt.allocPrint(temp, "note:{d}", .{graph.nodes.items.len}), graph.nodes.items[target].parent, false);
            graph.nodes.items[id].label = note;
            graph.nodes.items[id].shape = .tagged_process;
            graph.nodes.items[id].note_for = target;
            graph.nodes.items[id].note_left = std.mem.eql(u8, side, "left");
            if (graph.edges.items.len == 512) return error.LimitExceeded;
            try graph.edges.append(temp, .{ .from = target, .to = id, .link = .{ .stroke = .dotted } });
            continue;
        }
        const declaration = txt.starts(line, "state ");
        var cur: Cursor = .{ .rest = if (declaration) line[6..] else line };
        cur.trim();
        var label: ?[]const u8 = null;
        if (declaration and txt.starts(cur.rest, "\"")) {
            label = try txt.parse(temp, try cur.quoted());
            if (!std.mem.eql(u8, try cur.name(), "as")) return error.InvalidSyntax;
        }
        const from = try endpoint(graph, &cur, parent, false);
        cur.trim();
        if (txt.starts(cur.rest, "&lt;&lt;") and std.mem.endsWith(u8, cur.rest, "&gt;&gt;")) cur.rest = try std.fmt.allocPrint(temp, "<<{s}>>", .{cur.rest[8 .. cur.rest.len - 8]});
        if (label) |value| {
            graph.nodes.items[from].label = value;
            graph.nodes.items[from].state_description_count = 1;
            graph.nodes.items[from].state_title = value;
        }
        if (std.mem.eql(u8, cur.rest, "{")) {
            if (!declaration) return error.InvalidSyntax;
            if (depth == stack.len) return error.LimitExceeded;
            if (graph.nodes.items[from].container) return error.InvalidSyntax;
            graph.nodes.items[from].container = true;
            stack[depth] = .{ .id = from, .direction = direction };
            depth += 1;
            continue;
        }
        if (declaration and ((txt.starts(cur.rest, "<<") and std.mem.endsWith(u8, cur.rest, ">>")) or (txt.starts(cur.rest, "[[") and std.mem.endsWith(u8, cur.rest, "]]")))) {
            const kind = cur.rest[2 .. cur.rest.len - 2];
            graph.nodes.items[from].shape = if (std.mem.eql(u8, kind, "choice")) .diamond else if (std.mem.eql(u8, kind, "fork") or std.mem.eql(u8, kind, "join")) .fork else return error.UnsupportedSyntax;
            graph.nodes.items[from].label = "";
            continue;
        }
        if (cur.rest.len == 0) {
            if (declaration) pending_container = from;
            continue;
        }
        if (txt.starts(cur.rest, ":")) {
            const value = try txt.parse(temp, d.trim(cur.rest[1..]));
            if (graph.nodes.items[from].state_description_count == 0) {
                graph.nodes.items[from].state_title = value;
            } else {
                graph.nodes.items[from].state_body = if (graph.nodes.items[from].state_body.len > 0)
                    try std.fmt.allocPrint(temp, "{s}\n{s}", .{ graph.nodes.items[from].state_body, value })
                else value;
            }
            graph.nodes.items[from].label = if (graph.nodes.items[from].state_description_count > 0) try std.fmt.allocPrint(temp, "{s}\n{s}", .{ graph.nodes.items[from].label, value }) else value;
            graph.nodes.items[from].state_description_count += 1;
            graph.nodes.items[from].annotation = "description";
            continue;
        }
        if (!txt.starts(cur.rest, "-->")) return error.UnsupportedSyntax;
        cur.rest = cur.rest[3..];
        const to = try endpoint(graph, &cur, parent, true);
        cur.trim();
        var edge_label: []const u8 = "";
        if (cur.rest.len > 0) {
            if (cur.rest[0] != ':') return error.InvalidSyntax;
            edge_label = d.trim(cur.rest[1..]);
        }
        if (graph.edges.items.len == 512) return error.LimitExceeded;
        try graph.edges.append(temp, .{ .from = from, .to = to, .link = .{ .end = .arrow, .label = edge_label } });
    }
    if (depth != 0 or graph.nodes.items.len == 0) return error.InvalidSyntax;
    for (clicks.items) |click| for (graph.nodes.items) |*node| if (std.mem.eql(u8, node.id, click.id)) {
        node.action = click.action;
    };
    try graph.resolveStyles();
    try doc.graphTheme(graph);
    return direction;
}
