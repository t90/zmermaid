const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const flow = @import("flowchart.zig");
const compound = @import("flow_compound.zig");
const links = @import("flow_links.zig");
const data = @import("chart_data.zig");
const Cursor = struct {
    rest: []const u8,
    fn trim(self: *Cursor) void {
        self.rest = d.trim(self.rest);
    }
    fn name(self: *Cursor) d.Error![]const u8 {
        self.trim();
        if (self.rest.len == 0) return error.InvalidSyntax;
        if (self.rest[0] == '`') {
            const end = std.mem.indexOfScalarPos(u8, self.rest, 1, '`') orelse return error.InvalidSyntax;
            const result = self.rest[1..end];
            self.rest = self.rest[end + 1 ..];
            return result;
        }
        var end: usize = 0;
        while (end < self.rest.len and (std.ascii.isAlphanumeric(self.rest[end]) or self.rest[end] == '_' or self.rest[end] == '-' or self.rest[end] == '.' or self.rest[end] >= 128)) : (end += 1) {
            if (std.mem.startsWith(u8, self.rest[end..], "--") or std.mem.startsWith(u8, self.rest[end..], "..")) break;
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
pub fn getNode(graph: *flow.Parser, id: []const u8, parent: ?usize, table: bool) d.Error!usize {
    if (id.len == 0 or id.len > 512) return error.InvalidSyntax;
    for (graph.nodes.items, 0..) |*node, i| if (std.mem.eql(u8, node.id, id)) {
        if (node.parent == null and parent != null and !node.container) node.parent = parent;
        return i;
    };
    if (graph.nodes.items.len == 256) return error.LimitExceeded;
    try graph.nodes.append(graph.allocator, .{ .id = id, .label = id, .parent = parent, .table = table });
    return graph.nodes.items.len - 1;
}
fn generic(a: std.mem.Allocator, raw: []const u8) d.Error![]const u8 {
    if (raw.len > 512) return error.LimitExceeded;
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    for (raw, 0..) |c, i| {
        if (c == '~') {
            const opens = i + 1 < raw.len and (std.ascii.isAlphanumeric(raw[i + 1]) or raw[i + 1] == '_') and (depth == 0 or (i > 0 and raw[i - 1] != '~'));
            if (opens) {
                depth += 1;
                try out.append(a, '<');
            } else {
                if (depth == 0) return error.InvalidSyntax;
                depth -= 1;
                try out.append(a, '>');
            }
        } else try out.append(a, c);
    }
    if (depth != 0) return error.InvalidSyntax;
    return out.toOwnedSlice(a);
}
fn member(graph: *flow.Parser, id: usize, raw: []const u8) d.Error!void {
    var value = d.trim(raw);
    if (value.len == 0) return;
    if (txt.starts(value, "<<") and std.mem.endsWith(u8, value, ">>")) {
        graph.nodes.items[id].annotation = value;
        return;
    }
    if (graph.nodes.items[id].members.items.len == 256) return error.LimitExceeded;
    const method = std.mem.indexOfScalar(u8, value, '(') != null;
    const italic = method and std.mem.endsWith(u8, value, "*");
    const underlined = std.mem.endsWith(u8, value, "$");
    if (italic or underlined) value = value[0 .. value.len - 1];
    // A leading tilde is package visibility, not a generic delimiter.
    const package = value.len > 0 and value[0] == '~';
    const decoded = try generic(graph.allocator, if (package) value[1..] else value);
    const text = if (package) try std.fmt.allocPrint(graph.allocator, "~{s}", .{decoded}) else decoded;
    try graph.nodes.items[id].members.append(graph.allocator, .{ .text = text, .method = method, .italic = italic, .underlined = underlined, .markdown = true });
}
fn genericLabel(graph: *flow.Parser, id: usize, cur: *Cursor) d.Error!void {
    if (!txt.starts(cur.rest, "~")) return;
    var depth: usize = 0;
    for (cur.rest, 0..) |c, i| {
        if (c != '~') continue;
        const opens = i + 1 < cur.rest.len and (std.ascii.isAlphanumeric(cur.rest[i + 1]) or cur.rest[i + 1] == '_') and (depth == 0 or (i > 0 and cur.rest[i - 1] != '~'));
        if (opens) depth += 1 else {
            if (depth == 0) return error.InvalidSyntax;
            depth -= 1;
            if (depth == 0) {
                const value = try std.fmt.allocPrint(graph.allocator, "{s}{s}", .{ graph.nodes.items[id].id, cur.rest[0 .. i + 1] });
                graph.nodes.items[id].label = try generic(graph.allocator, value);
                cur.rest = cur.rest[i + 1 ..];
                cur.trim();
                return;
            }
        }
    }
    return error.InvalidSyntax;
}
fn marker(raw: []const u8) d.Error!links.Marker {
    if (raw.len == 0) return .none;
    if (std.mem.eql(u8, raw, "<|") or std.mem.eql(u8, raw, "|>")) return .inheritance;
    if (std.mem.eql(u8, raw, "*")) return .composition;
    if (std.mem.eql(u8, raw, "o")) return .aggregation;
    if (std.mem.eql(u8, raw, "<") or std.mem.eql(u8, raw, ">")) return .open;
    if (std.mem.eql(u8, raw, "()")) return .lollipop;
    return error.InvalidSyntax;
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var graph: flow.Parser = .{ .allocator = temp, .kind = "class" };
    defer graph.deinit();
    var direction: []const u8 = "TB";
    const hide_empty = try doc.flag("config.class.hideEmptyMembersBox", false);
    const hierarchical = try doc.flag("config.class.hierarchicalNamespaces", true);
    var scopes: [16]usize = undefined;
    var scope_depth: usize = 0;
    var active: ?usize = null;
    var lines: @import("class_statements.zig").Statements = .{ .source = doc.source };
    _ = try lines.next();
    while (try lines.next()) |raw| {
        var line = d.trim(raw);
        if (txt.starts(line, "note ")) {
            var quote_count = std.mem.count(u8, line, "\"");
            while (quote_count % 2 != 0) {
                const next = try lines.next() orelse return error.InvalidSyntax;
                if (line.len + next.len > 4096) return error.LimitExceeded;
                line = try std.fmt.allocPrint(temp, "{s}\n{s}", .{ line, d.trim(next) });
                quote_count += std.mem.count(u8, next, "\"");
            }
        }
        if (txt.starts(line, "&lt;&lt;")) {
            const end = std.mem.indexOf(u8, line, "&gt;&gt;") orelse return error.InvalidSyntax;
            line = try std.fmt.allocPrint(temp, "<<{s}>>{s}", .{ line[8..end], line[end + 8 ..] });
        }
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        const parent = if (scope_depth > 0) scopes[scope_depth - 1] else null;
        if (active) |id| {
            if (std.mem.eql(u8, line, "}")) {
                active = null;
                continue;
            }
            if (std.mem.indexOfScalar(u8, line, '}') != null) return error.UnsupportedSyntax;
            try member(&graph, id, line);
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            if (scope_depth == 0) return error.InvalidSyntax;
            scope_depth -= 1;
            continue;
        }
        if (txt.starts(line, "direction ")) {
            direction = d.trim(line[10..]);
            if (!compound.validDirection(direction)) return error.InvalidSyntax;
            continue;
        }
        if (txt.starts(line, "classDef ") or txt.starts(line, "style ")) {
            try graph.statement(std.mem.trimEnd(u8, line, ";"));
            continue;
        }
        if (txt.starts(line, "click ") or txt.starts(line, "callback ") or txt.starts(line, "link ")) {
            try graph.statement(std.mem.trimEnd(u8, line, ";"));
            continue;
        }
        if (txt.starts(line, "cssClass ")) {
            var css: Cursor = .{ .rest = line[9..] };
            const ids = try css.quoted();
            const statement = try std.fmt.allocPrint(temp, "class {s} {s}", .{ ids, d.trim(css.rest) });
            try graph.statement(statement);
            continue;
        }
        if (txt.starts(line, "namespace ")) {
            if (scope_depth == 16) return error.LimitExceeded;
            var cur: Cursor = .{ .rest = line[10..] };
            const name = try cur.name();
            cur.trim();
            var label = name;
            if (txt.starts(cur.rest, "[")) {
                cur.rest = cur.rest[1..];
                label = try cur.quoted();
                cur.trim();
                if (!txt.starts(cur.rest, "]")) return error.InvalidSyntax;
                cur.rest = cur.rest[1..];
                cur.trim();
            }
            if (!std.mem.eql(u8, cur.rest, "{")) return error.InvalidSyntax;
            var container_parent = parent;
            var id: usize = undefined;
            if (hierarchical) {
                var parts = std.mem.splitScalar(u8, name, '.');
                var path: []const u8 = if (parent) |p| graph.nodes.items[p].id[10..] else "";
                while (parts.next()) |part| {
                    path = try std.fmt.allocPrint(temp, "{s}{s}{s}", .{ path, if (path.len > 0) "." else "", part });
                    id = try getNode(&graph, try std.fmt.allocPrint(temp, "namespace:{s}", .{path}), container_parent, false);
                    graph.nodes.items[id].label = part;
                    graph.nodes.items[id].container = true;
                    container_parent = id;
                }
                if (!std.mem.eql(u8, label, name)) graph.nodes.items[id].label = label;
            } else {
                const key = try std.fmt.allocPrint(temp, "namespace:{d}:{s}", .{ parent orelse 256, name });
                id = try getNode(&graph, key, parent, false);
                graph.nodes.items[id].label = label;
                graph.nodes.items[id].container = true;
            }
            graph.containers += 1;
            scopes[scope_depth] = id;
            scope_depth += 1;
            continue;
        }
        if (txt.starts(line, "note ")) {
            var cur: Cursor = .{ .rest = line[5..] };
            var target: ?usize = null;
            if (txt.starts(cur.rest, "for ")) {
                cur.rest = cur.rest[4..];
                target = try getNode(&graph, try cur.name(), parent, true);
            }
            const note = try txt.parse(temp, try cur.quoted());
            cur.trim();
            if (cur.rest.len > 0) return error.InvalidSyntax;
            const id = try getNode(&graph, try std.fmt.allocPrint(temp, "note:{d}", .{graph.nodes.items.len}), parent, false);
            graph.nodes.items[id].label = note;
            graph.nodes.items[id].shape = .tagged_process;
            graph.nodes.items[id].note_for = target;
            if (target) |to| graph.nodes.items[id].parent = graph.nodes.items[to].parent;
            if (target) |to| {
                if (graph.edges.items.len == 512) return error.LimitExceeded;
                try graph.edges.append(temp, .{ .from = to, .to = id, .link = .{ .stroke = .dotted } });
            }
            continue;
        }
        if (txt.starts(line, "<<")) {
            const end = std.mem.indexOf(u8, line, ">>") orelse return error.InvalidSyntax;
            const id = try getNode(&graph, d.trim(line[end + 2 ..]), parent, true);
            graph.nodes.items[id].annotation = line[0 .. end + 2];
            continue;
        }
        const declaration = txt.starts(line, "class ");
        var cur: Cursor = .{ .rest = if (declaration) line[6..] else line };
        const name = try cur.name();
        const id = try getNode(&graph, name, parent, true);
        cur.trim();
        try genericLabel(&graph, id, &cur);
        if (txt.starts(cur.rest, "[")) {
            cur.rest = cur.rest[1..];
            graph.nodes.items[id].label = try txt.parse(temp, try cur.quoted());
            cur.trim();
            if (!txt.starts(cur.rest, "]")) return error.InvalidSyntax;
            cur.rest = cur.rest[1..];
            cur.trim();
        }
        if (txt.starts(cur.rest, ":::")) {
            cur.rest = cur.rest[3..];
            graph.nodes.items[id].classes = try cur.name();
            cur.trim();
        }
        if (declaration) {
            if (cur.rest.len == 0) continue;
            if (std.mem.eql(u8, cur.rest, "{}")) continue;
            if (std.mem.eql(u8, cur.rest, "{")) {
                active = id;
                continue;
            }
            if (txt.starts(cur.rest, "{") and std.mem.endsWith(u8, cur.rest, "}")) {
                var members = std.mem.splitScalar(u8, cur.rest[1 .. cur.rest.len - 1], ';');
                while (members.next()) |value| try member(&graph, id, value);
                continue;
            }
            if (txt.starts(cur.rest, "<<") and std.mem.endsWith(u8, cur.rest, ">>")) {
                graph.nodes.items[id].annotation = cur.rest;
                continue;
            }
            return error.UnsupportedSyntax;
        }
        if (txt.starts(cur.rest, ":")) {
            try member(&graph, id, cur.rest[1..]);
            continue;
        }
        if (cur.rest.len == 0) continue;
        var left_label: []const u8 = "";
        var right_label: []const u8 = "";
        if (txt.starts(cur.rest, "\"")) {
            left_label = try cur.quoted();
            cur.trim();
        }
        const solid = std.mem.indexOf(u8, cur.rest, "--");
        const dashed = std.mem.indexOf(u8, cur.rest, "..");
        const middle = solid orelse dashed orelse return error.UnsupportedSyntax;
        if (middle > 2) return error.UnsupportedSyntax;
        var split = middle + 2;
        if (std.mem.startsWith(u8, cur.rest[split..], "|>") or std.mem.startsWith(u8, cur.rest[split..], "()")) split += 2 else if (split < cur.rest.len and std.mem.indexOfScalar(u8, ">o*", cur.rest[split]) != null) split += 1;
        const arrow = cur.rest[0..split];
        cur.rest = cur.rest[split..];
        cur.trim();
        const start_marker = try marker(arrow[0..middle]);
        const end_marker = try marker(arrow[middle + 2 ..]);
        if (txt.starts(cur.rest, "\"")) {
            right_label = try cur.quoted();
            cur.trim();
        }
        const target = try getNode(&graph, try cur.name(), parent, true);
        cur.trim();
        try genericLabel(&graph, target, &cur);
        var label: []const u8 = "";
        if (cur.rest.len > 0) {
            if (cur.rest[0] != ':') return error.UnsupportedSyntax;
            label = d.unquote(cur.rest[1..]);
        }
        if (graph.edges.items.len == 512) return error.LimitExceeded;
        try graph.edges.append(temp, .{ .from = id, .to = target, .link = .{ .start = start_marker, .end = end_marker, .stroke = if (dashed != null) .dotted else .normal, .label = label }, .left_label = left_label, .right_label = right_label });
        if (start_marker == .lollipop) {
            graph.nodes.items[id].table = false;
            graph.nodes.items[id].shape = .text;
        }
        if (end_marker == .lollipop) {
            graph.nodes.items[target].table = false;
            graph.nodes.items[target].shape = .text;
        }
    }
    if (active != null or scope_depth != 0 or graph.nodes.items.len == 0) return error.InvalidSyntax;
    for (graph.nodes.items) |*node| node.hide_empty = hide_empty;
    try graph.resolveStyles();
    try doc.graphTheme(&graph);
    return compound.render(a, &graph, doc.theme, prefix, direction);
}
