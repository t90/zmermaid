const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const flow = @import("flowchart.zig");
const class = @import("class.zig");
const compound = @import("flow_compound.zig");
const links = @import("flow_links.zig");
const Cursor = struct {
    rest: []const u8,
    fn trim(self: *Cursor) void {
        self.rest = d.trim(self.rest);
    }
    fn quoted(self: *Cursor) d.Error![]const u8 {
        self.trim();
        if (self.rest.len < 2) return error.InvalidSyntax;
        const quote = self.rest[0];
        if (quote != '"' and quote != '`') return error.InvalidSyntax;
        const end = std.mem.indexOfScalarPos(u8, self.rest, 1, quote) orelse return error.InvalidSyntax;
        const result = self.rest[1..end];
        self.rest = self.rest[end + 1 ..];
        return result;
    }
    fn name(self: *Cursor) d.Error![]const u8 {
        self.trim();
        if (self.rest.len == 0) return error.InvalidSyntax;
        if (self.rest[0] == '"' or self.rest[0] == '`') return self.quoted();
        var end: usize = 0;
        while (end < self.rest.len and std.mem.indexOfScalar(u8, " \t\r\n|{}[]:", self.rest[end]) == null) : (end += 1) {}
        if (end == 0) return error.InvalidSyntax;
        const result = self.rest[0..end];
        self.rest = self.rest[end..];
        return result;
    }
    fn word(self: *Cursor) d.Error![]const u8 {
        self.trim();
        if (self.rest.len == 0) return error.InvalidSyntax;
        if (self.rest[0] == '`') return self.quoted();
        const end = std.mem.indexOfAny(u8, self.rest, " \t") orelse self.rest.len;
        const result = self.rest[0..end];
        self.rest = self.rest[end..];
        return result;
    }
};
fn endpoint(graph: *flow.Parser, cur: *Cursor) d.Error!usize {
    const name = try cur.name();
    const parent = if (graph.depth > 0) graph.stack[graph.depth - 1] else null;
    const id = try class.getNode(graph, name, parent, true);
    graph.nodes.items[id].entity = true;
    graph.nodes.items[id].hide_empty = true;
    graph.nodes.items[id].markdown = true;
    cur.trim();
    if (txt.starts(cur.rest, "[")) {
        const end = std.mem.indexOfScalar(u8, cur.rest, ']') orelse return error.InvalidSyntax;
        graph.nodes.items[id].label = try txt.parse(graph.allocator, d.unquote(cur.rest[1..end]));
        cur.rest = cur.rest[end + 1 ..];
        cur.trim();
    }
    if (txt.starts(cur.rest, ":::")) {
        cur.rest = cur.rest[3..];
        graph.nodes.items[id].classes = try cur.name();
        cur.trim();
    }
    return id;
}
fn attributes(graph: *flow.Parser, id: usize, raw: []const u8) d.Error!void {
    var cur: Cursor = .{ .rest = d.trim(raw) };
    while (cur.rest.len > 0) {
        const ty = try cur.word();
        const name = try cur.word();
        cur.trim();
        var keys: []const u8 = "";
        var comment: []const u8 = "";
        const key_start = cur.rest;
        var consumed: usize = 0;
        var count: usize = 0;
        while (cur.rest.len > 0) {
            var end: usize = 0;
            while (end < cur.rest.len and std.mem.indexOfScalar(u8, " ,\t\"", cur.rest[end]) == null) end += 1;
            const key = cur.rest[0..end];
            if (!std.mem.eql(u8, key, "PK") and !std.mem.eql(u8, key, "FK") and !std.mem.eql(u8, key, "UK")) break;
            count += 1;
            if (count > 3) return error.InvalidSyntax;
            consumed = key_start.len - cur.rest.len + end;
            cur.rest = d.trim(cur.rest[end..]);
            if (cur.rest.len > 0 and cur.rest[0] == ',') {
                cur.rest = d.trim(cur.rest[1..]);
                if (!txt.starts(cur.rest, "PK") and !txt.starts(cur.rest, "FK") and !txt.starts(cur.rest, "UK")) return error.InvalidSyntax;
            }
        }
        if (count > 0) keys = key_start[0..consumed];
        if (txt.starts(cur.rest, "\"")) comment = try cur.quoted();
        if (graph.nodes.items[id].members.items.len == 256) return error.LimitExceeded;
        try graph.nodes.items[id].members.append(graph.allocator, .{ .text = name, .cells = .{ ty, name, keys, comment } });
        cur.trim();
    }
}
fn cardinal(cur: *Cursor) d.Error!links.Marker {
    cur.trim();
    const entries = [_]struct { raw: []const u8, marker: links.Marker }{
        .{ .raw = "zero or more", .marker = .zero_many }, .{ .raw = "zero or many", .marker = .zero_many },
        .{ .raw = "one or more", .marker = .one_many },   .{ .raw = "one or many", .marker = .one_many },
        .{ .raw = "zero or one", .marker = .zero_one },   .{ .raw = "one or zero", .marker = .zero_one },
        .{ .raw = "only one", .marker = .exactly_one },   .{ .raw = "many(0)", .marker = .zero_many },
        .{ .raw = "many(1)", .marker = .one_many },       .{ .raw = "||", .marker = .exactly_one },
        .{ .raw = "o|", .marker = .zero_one },            .{ .raw = "|o", .marker = .zero_one },
        .{ .raw = "o{", .marker = .zero_many },           .{ .raw = "}o", .marker = .zero_many },
        .{ .raw = "|{", .marker = .one_many },            .{ .raw = "}|", .marker = .one_many },
        .{ .raw = "0+", .marker = .zero_many },           .{ .raw = "1+", .marker = .one_many },
        .{ .raw = "many", .marker = .zero_many },         .{ .raw = "one", .marker = .exactly_one },
        .{ .raw = "1", .marker = .exactly_one },          .{ .raw = "u", .marker = .md_parent },
    };
    for (entries) |entry| if (txt.starts(cur.rest, entry.raw)) {
        cur.rest = cur.rest[entry.raw.len..];
        return entry.marker;
    };
    return error.UnsupportedSyntax;
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var graph: flow.Parser = .{ .allocator = temp, .kind = "entity" };
    defer graph.deinit();
    var direction: []const u8 = "TB";
    var active: ?usize = null;
    var lines = std.mem.splitScalar(u8, doc.source["erDiagram".len..], '\n');
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (active) |id| {
            if (std.mem.eql(u8, line, "}")) {
                active = null;
                continue;
            }
            if (std.mem.endsWith(u8, line, "}")) {
                try attributes(&graph, id, d.trim(line[0 .. line.len - 1]));
                active = null;
            } else try attributes(&graph, id, line);
            continue;
        }
        if (txt.starts(line, "subgraph ") or std.mem.eql(u8, line, "end") or txt.starts(line, "style ") or txt.starts(line, "classDef ") or txt.starts(line, "class ")) {
            try graph.statement(line);
            continue;
        }
        if (txt.starts(line, "direction ")) {
            if (graph.depth > 0) {
                try graph.statement(line);
            } else {
                direction = d.trim(line[10..]);
                if (!compound.validDirection(direction)) return error.InvalidSyntax;
            }
            continue;
        }
        var cur: Cursor = .{ .rest = line };
        const from = try endpoint(&graph, &cur);
        cur.trim();
        if (cur.rest.len == 0) continue;
        if (std.mem.eql(u8, cur.rest, "{")) {
            active = from;
            continue;
        }
        if (std.mem.eql(u8, cur.rest, "{}")) continue;
        if (txt.starts(cur.rest, "{") and std.mem.endsWith(u8, cur.rest, "}")) {
            try attributes(&graph, from, cur.rest[1 .. cur.rest.len - 1]);
            continue;
        }
        const left = try cardinal(&cur);
        cur.trim();
        var stroke: links.Stroke = .normal;
        if (txt.starts(cur.rest, "optionally to")) {
            stroke = .dotted;
            cur.rest = cur.rest[13..];
        } else if (txt.starts(cur.rest, "..") or txt.starts(cur.rest, ".-") or txt.starts(cur.rest, "-.")) {
            stroke = .dotted;
            cur.rest = cur.rest[2..];
        } else if (txt.starts(cur.rest, "--") or txt.starts(cur.rest, "to")) {
            cur.rest = cur.rest[2..];
        } else return error.InvalidSyntax;
        const right = try cardinal(&cur);
        const to = try endpoint(&graph, &cur);
        cur.trim();
        if (!txt.starts(cur.rest, ":")) return error.InvalidSyntax;
        const label = d.unquote(cur.rest[1..]);
        if (graph.edges.items.len == 512) return error.LimitExceeded;
        try graph.edges.append(temp, .{ .from = from, .to = to, .link = .{ .start = left, .end = right, .stroke = stroke, .label = label } });
    }
    if (active != null or graph.depth != 0 or graph.nodes.items.len == 0) return error.InvalidSyntax;
    try graph.resolveStyles();
    try doc.graphTheme(&graph);
    return compound.render(a, &graph, doc.theme, prefix, direction);
}
