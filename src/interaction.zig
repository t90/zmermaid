const std = @import("std");
const d = @import("document.zig");
const svg = @import("svg.zig");
pub const Action = struct { href: []const u8 = "", callback: []const u8 = "", args: []const u8 = "", tooltip: []const u8 = "", target: []const u8 = "" };
const Cursor = struct {
    rest: []const u8,
    fn token(self: *Cursor) d.Error![]const u8 {
        self.rest = d.trim(self.rest);
        if (self.rest.len == 0) return error.InvalidSyntax;
        if (self.rest[0] == '"' or self.rest[0] == '\'') {
            const quote = self.rest[0];
            const stop = std.mem.indexOfScalarPos(u8, self.rest, 1, quote) orelse return error.InvalidSyntax;
            const result = self.rest[1..stop];
            self.rest = d.trim(self.rest[stop + 1 ..]);
            return result;
        }
        const stop = std.mem.indexOfAny(u8, self.rest, " \t") orelse self.rest.len;
        const result = self.rest[0..stop];
        self.rest = d.trim(self.rest[stop..]);
        return result;
    }
};
pub fn safeUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > 2048) return false;
    for (value) |c| if (c < 32 or c == 127) return false;
    if (@import("sequence_text.zig").starts(value, "https://") or @import("sequence_text.zig").starts(value, "http://") or value[0] == '#') return true;
    if (std.mem.indexOfScalar(u8, value, '\\') != null or std.mem.startsWith(u8, value, "//")) return false;
    const scheme_end = std.mem.indexOfAny(u8, value, "/?#") orelse value.len;
    return std.mem.indexOfScalar(u8, value[0..scheme_end], ':') == null;
}
pub fn parse(graph: anytype, source: []const u8) d.Error!void {
    var cur: Cursor = .{ .rest = source };
    const command = try cur.token();
    const id = try cur.token();
    var node: ?usize = null;
    for (graph.nodes.items, 0..) |n, i| if (std.mem.eql(u8, n.id, id)) {
        node = i;
    };
    var action: Action = .{};
    var mode = command;
    if (std.mem.eql(u8, command, "click")) {
        if (std.mem.startsWith(u8, cur.rest, "href ")) {
            _ = try cur.token();
            mode = "link";
        } else if (std.mem.startsWith(u8, cur.rest, "call ")) {
            _ = try cur.token();
            mode = "call";
        } else if (cur.rest.len > 0 and (cur.rest[0] == '"' or cur.rest[0] == '\'')) {
            mode = "link";
        } else {
            mode = "callback";
        }
    }
    if (std.mem.eql(u8, mode, "link")) {
        action.href = try cur.token();
        if (!safeUrl(action.href)) return error.UnsupportedSyntax;
    } else {
        if (std.mem.eql(u8, mode, "call")) {
            const open = std.mem.indexOfScalar(u8, cur.rest, '(') orelse return error.InvalidSyntax;
            var close = open + 1;
            var quote: u8 = 0;
            while (close < cur.rest.len) : (close += 1) {
                const c = cur.rest[close];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '"' or c == '\'') quote = c else if (c == ')') break else if (c == '(') return error.UnsupportedSyntax;
            }
            if (close == cur.rest.len) return error.InvalidSyntax;
            action.callback = d.trim(cur.rest[0..open]);
            const args = d.trim(cur.rest[open + 1 .. close]);
            var values: std.ArrayList([]const u8) = .empty;
            defer values.deinit(graph.allocator);
            var parts = @import("chart_data.zig").Parts{ .rest = args };
            while (try parts.next()) |part| {
                if (values.items.len == 32) return error.LimitExceeded;
                try values.append(graph.allocator, d.unquote(part));
            }
            const json = try std.json.Stringify.valueAlloc(graph.allocator, values.items, .{});
            errdefer graph.allocator.free(json);
            try graph.labels.append(graph.allocator, json);
            action.args = json;
            cur.rest = d.trim(cur.rest[close + 1 ..]);
        } else action.callback = try cur.token();
        if (action.callback.len == 0 or action.callback.len > 256) return error.InvalidSyntax;
        for (action.callback) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '$') return error.UnsupportedSyntax;
    }
    if (cur.rest.len > 0 and (cur.rest[0] == '"' or cur.rest[0] == '\'')) action.tooltip = try cur.token();
    if (cur.rest.len > 0) {
        if (action.href.len == 0) return error.InvalidSyntax;
        action.target = try cur.token();
        if (action.target.len > 64) return error.LimitExceeded;
        for (action.target) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.UnsupportedSyntax;
    }
    if (cur.rest.len > 0) return error.InvalidSyntax;
    if (action.tooltip.len > 512) return error.LimitExceeded;
    // Syntax and URL policy still apply, but an absent endpoint is a no-op.
    if (node) |index| graph.nodes.items[index].action = action;
}
pub fn classAttribute(out: *svg.Svg, classes: []const u8) !void {
    if (classes.len > 0) {
        try out.add(" class=\"");
        for (classes) |c| if (c == ',') {
            try out.add(" ");
        } else {
            try out.escape(&.{c});
        };
        try out.add("\"");
    }
}
// Gantt allows href and call in either order on the same click statement.
pub fn parseGantt(graph: anytype, source: []const u8) d.Error!void {
    var cur: Cursor = .{ .rest = source };
    if (!std.mem.eql(u8, try cur.token(), "click")) return error.InvalidSyntax;
    const id = try cur.token();
    var index: ?usize = null;
    for (graph.nodes.items, 0..) |n, i| if (std.mem.eql(u8, n.id, id)) {
        index = i;
    };
    const node = index orelse return error.InvalidSyntax;
    var combined = graph.nodes.items[node].action;
    var count: usize = 0;
    while (cur.rest.len > 0) {
        if (count == 2) return error.InvalidSyntax;
        const href = std.mem.startsWith(u8, cur.rest, "href ");
        if (!href and !std.mem.startsWith(u8, cur.rest, "call ")) return error.InvalidSyntax;
        var quote: u8 = 0;
        var depth: usize = 0;
        var stop = cur.rest.len;
        for (cur.rest, 0..) |c, i| {
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            if (c == '\'' or c == '"') {
                quote = c;
                continue;
            }
            if (c == '(') depth += 1;
            if (c == ')') {
                if (depth == 0) return error.InvalidSyntax;
                depth -= 1;
            }
            if (i > 0 and depth == 0 and (std.mem.startsWith(u8, cur.rest[i..], " href ") or std.mem.startsWith(u8, cur.rest[i..], " call "))) {
                stop = i;
                break;
            }
        }
        if (quote != 0 or depth != 0) return error.InvalidSyntax;
        const statement = try std.fmt.allocPrint(graph.allocator, "click {s} {s}", .{ id, cur.rest[0..stop] });
        // parse() stores slices into its input, so retain the statement.
        try graph.labels.append(graph.allocator, statement);
        try parse(graph, statement);
        const part = graph.nodes.items[node].action;
        if (href) {
            if (combined.href.len > 0) return error.InvalidSyntax;
            combined.href = part.href;
            combined.target = part.target;
        } else {
            if (combined.callback.len > 0) return error.InvalidSyntax;
            combined.callback = part.callback;
            combined.args = part.args;
        }
        cur.rest = d.trim(cur.rest[stop..]);
        count += 1;
    }
    if (count == 0) return error.InvalidSyntax;
    graph.nodes.items[node].action = combined;
}
pub fn begin(out: *svg.Svg, action: Action, id: []const u8, classes: []const u8) !void {
    try out.add("<g data-mermaid-id=\"");
    try out.escape(id);
    try out.add("\"");
    try classAttribute(out, classes);
    if (action.callback.len > 0) {
        try out.add(" role=\"button\" tabindex=\"0\" data-zm-callback=\"");
        try out.escape(action.callback);
        try out.add("\"");
        if (action.args.len > 0) {
            try out.add(" data-zm-args=\"");
            try out.escape(action.args);
            try out.add("\"");
        }
    }
    try out.add(">");
    if (action.href.len > 0) {
        try out.add("<a href=\"");
        try out.escape(action.href);
        try out.add("\"");
        if (action.target.len > 0) {
            try out.add(" target=\"");
            try out.escape(action.target);
            try out.add("\" rel=\"noopener noreferrer\"");
        }
        try out.add(">");
    }
    if (action.tooltip.len > 0) {
        try out.add("<title>");
        try out.escape(action.tooltip);
        try out.add("</title>");
    }
}
pub fn end(out: *svg.Svg, action: Action) !void {
    if (action.href.len > 0) try out.add("</a>");
    try out.add("</g>");
}
