const std = @import("std");
const d = @import("document.zig");
const seq = @import("sequence.zig");
const txt = @import("sequence_text.zig");
// Independent parser based on the MIT Mermaid syntax documentation. It feeds
// our sequence engine; no ZenUML implementation or JavaScript is embedded.
const Token = struct { value: []const u8 = "", open: bool = false, close: bool = false, comment: bool = false, eof: bool = false };
const Lexer = struct {
    source: []const u8,
    at: usize = 0,
    held: ?Token = null,
    fn peek(self: *Lexer) d.Error!Token {
        if (self.held == null) self.held = try self.next();
        return self.held.?;
    }
    fn next(self: *Lexer) d.Error!Token {
        if (self.held) |t| {
            self.held = null;
            return t;
        }
        while (self.at < self.source.len and std.ascii.isWhitespace(self.source[self.at])) self.at += 1;
        if (self.at == self.source.len) return .{ .eof = true };
        if (self.source[self.at] == '}') {
            self.at += 1;
            return .{ .close = true };
        }
        if (std.mem.startsWith(u8, self.source[self.at..], "//")) {
            const start = self.at + 2;
            while (self.at < self.source.len and self.source[self.at] != '\n') self.at += 1;
            return .{ .value = d.trim(self.source[start..self.at]), .comment = true };
        }
        const start = self.at;
        var parens: usize = 0;
        var quote: u8 = 0;
        var escaped = false;
        var label = false;
        while (self.at < self.source.len) : (self.at += 1) {
            const c = self.source[self.at];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quote != 0) {
                if (c == '\\') escaped = true else if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or (c == '\'' and (self.at == start or !std.ascii.isAlphanumeric(self.source[self.at - 1])))) {
                quote = c;
                continue;
            }
            if (c == ':' and parens == 0) label = true;
            if (!label and c == '(') {
                parens += 1;
                if (parens > 32) return error.LimitExceeded;
            }
            if (!label and c == ')') {
                if (parens == 0) return error.InvalidSyntax;
                parens -= 1;
            }
            if (parens == 0 and (c == '{' or c == '}' or c == '\n' or c == ';')) {
                const value = d.trim(self.source[start..self.at]);
                if (c != '}') self.at += 1;
                return .{ .value = value, .open = c == '{' };
            }
        }
        if (parens != 0 or quote != 0) return error.InvalidSyntax;
        return .{ .value = d.trim(self.source[start..self.at]) };
    }
};
fn word(s: []const u8, key: []const u8) bool {
    return std.mem.startsWith(u8, s, key) and (s.len == key.len or std.mem.indexOfScalar(u8, " \t(", s[key.len]) != null);
}
fn identifier(id: []const u8) d.Error!void {
    if (id.len == 0) return error.InvalidSyntax;
    if (id.len > 512) return error.LimitExceeded;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.UnsupportedSyntax;
}
const Context = struct { actor: []const u8, caller: []const u8, sync: bool = false };
const Parser = struct {
    a: std.mem.Allocator,
    lex: Lexer,
    output: std.ArrayList(u8) = .empty,
    pending_comment: []const u8 = "",
    reply: bool = false,
    external: bool = false,
    declarations: [64][]const u8 = undefined,
    count: usize = 0,
    fn emit(self: *Parser, comptime format: []const u8, args: anytype) d.Error!void {
        const line = try std.fmt.allocPrint(self.a, format, args);
        if (self.output.items.len + line.len > 1024 * 1024) return error.LimitExceeded;
        try self.output.appendSlice(self.a, line);
    }
    fn label(self: *Parser, raw: []const u8) d.Error![]const u8 {
        if (raw.len > 512) return error.LimitExceeded;
        var out: std.ArrayList(u8) = .empty;
        for (raw) |c| switch (c) {
            '#' => try out.appendSlice(self.a, "#35;"),
            ';' => try out.appendSlice(self.a, "#59;"),
            '<' => try out.appendSlice(self.a, "#lt;"),
            '\n' => try out.appendSlice(self.a, "<br/>"),
            '\r' => {},
            else => try out.append(self.a, c),
        };
        return out.toOwnedSlice(self.a);
    }
    fn remember(self: *Parser, id: []const u8) d.Error!bool {
        try identifier(id);
        for (self.declarations[0..self.count]) |old| if (std.mem.eql(u8, old, id)) return false;
        if (self.count == 64) return error.LimitExceeded;
        self.declarations[self.count] = id;
        self.count += 1;
        return true;
    }
    fn caller(self: *Parser, context: Context) d.Error![]const u8 {
        if (context.actor.len > 0) return context.actor;
        if (!self.external) {
            if (!try self.remember("__zenuml_external")) return error.InvalidSyntax;
            try self.emit("participant __zenuml_external as External\n", .{});
            self.external = true;
        }
        return "__zenuml_external";
    }
    fn comments(self: *Parser, actor: []const u8) d.Error!void {
        if (self.pending_comment.len == 0) return;
        try self.emit("Note over {s}: {s}\n", .{ actor, try self.label(self.pending_comment) });
        self.pending_comment = "";
    }
    fn fragmentComments(self: *Parser, context: Context) d.Error!void {
        if (self.pending_comment.len == 0) return;
        const actor = if (context.actor.len > 0) context.actor else if (self.count > 0) self.declarations[0] else try self.caller(context);
        try self.comments(actor);
    }
    fn condition(self: *Parser, raw: []const u8) d.Error![]const u8 {
        const value = d.trim(raw);
        return self.label(if (value.len >= 2 and value[0] == '(' and value[value.len - 1] == ')') value[1 .. value.len - 1] else value);
    }
    fn block(self: *Parser, context: Context, depth: usize, nested: bool, parallel: bool) d.Error!void {
        if (depth > 16) return error.LimitExceeded;
        var branches: usize = 0;
        while (true) {
            const t = try self.lex.next();
            if (t.eof) {
                if (nested) return error.InvalidSyntax;
                return;
            }
            if (t.close) {
                if (!nested) return error.InvalidSyntax;
                return;
            }
            if (t.comment) {
                self.pending_comment = if (self.pending_comment.len == 0) t.value else try std.fmt.allocPrint(self.a, "{s}\n{s}", .{ self.pending_comment, t.value });
                continue;
            }
            if (t.value.len == 0) {
                if (t.open) return error.InvalidSyntax;
                continue;
            }
            if (parallel and branches > 0) try self.emit("and Concurrent\n", .{});
            branches += 1;
            try self.statement(t, context, depth);
        }
    }
    fn statement(self: *Parser, t: Token, context: Context, depth: usize) d.Error!void {
        var line = t.value;
        if (word(line, "title")) {
            if (t.open) return error.InvalidSyntax;
            try self.emit("title {s}\n", .{try self.label(d.trim(line[5..]))});
            self.pending_comment = "";
            return;
        }
        if (std.mem.eql(u8, line, "@return") or std.mem.eql(u8, line, "@reply")) {
            self.reply = true;
            return;
        }
        const decorators = .{ .{ "@Actor", "actor" }, .{ "@Database", "database" }, .{ "@Boundary", "boundary" }, .{ "@Control", "control" }, .{ "@Entity", "entity" }, .{ "@Queue", "queue" }, .{ "@Collections", "collections" } };
        inline for (decorators) |decorator| if (word(line, decorator[0])) {
            if (t.open) return error.InvalidSyntax;
            line = d.trim(line[decorator[0].len..]);
            const alias = std.mem.indexOf(u8, line, " as ");
            const id = d.trim(line[0 .. alias orelse line.len]);
            _ = try self.remember(id);
            try self.emit("participant {s}@{{\"type\":\"{s}\"}} as {s}\n", .{ id, decorator[1], try self.label(if (alias) |i| d.trim(line[i + 4 ..]) else id) });
            self.pending_comment = "";
            return;
        };
        if (word(line, "if")) {
            if (!t.open) return error.InvalidSyntax;
            try self.fragmentComments(context);
            try self.emit("alt {s}\n", .{try self.condition(line[2..])});
            try self.block(context, depth + 1, true, false);
            while (true) {
                const next = try self.lex.peek();
                if (!word(next.value, "else")) break;
                _ = try self.lex.next();
                if (!next.open) return error.InvalidSyntax;
                const rest = d.trim(next.value[4..]);
                if (rest.len > 0 and !word(rest, "if")) return error.InvalidSyntax;
                try self.emit("else {s}\n", .{if (rest.len > 0) try self.condition(rest[2..]) else "Otherwise"});
                try self.block(context, depth + 1, true, false);
            }
            try self.emit("end\n", .{});
            return;
        }
        inline for (.{ "while", "forEach", "foreach", "for", "loop", "opt", "par", "try" }) |key| if (word(line, key)) {
            if (!t.open) return error.InvalidSyntax;
            try self.fragmentComments(context);
            const fragment = if (std.mem.eql(u8, key, "opt")) "opt" else if (std.mem.eql(u8, key, "par")) "par" else if (std.mem.eql(u8, key, "try")) "critical" else "loop";
            const value = try self.condition(line[key.len..]);
            try self.emit("{s} {s}\n", .{ fragment, if (value.len > 0) value else key });
            try self.block(context, depth + 1, true, std.mem.eql(u8, key, "par"));
            if (std.mem.eql(u8, key, "try")) {
                const next = try self.lex.peek();
                if (word(next.value, "catch")) {
                    _ = try self.lex.next();
                    if (!next.open) return error.InvalidSyntax;
                    const detail = try self.condition(next.value[5..]);
                    try self.emit("option Catch {s}\n", .{detail});
                    try self.block(context, depth + 1, true, false);
                }
                try self.emit("end\n", .{});
                const final = try self.lex.peek();
                if (std.mem.eql(u8, final.value, "finally")) {
                    _ = try self.lex.next();
                    if (!final.open) return error.InvalidSyntax;
                    try self.emit("opt Finally\n", .{});
                    try self.block(context, depth + 1, true, false);
                    try self.emit("end\n", .{});
                }
            } else try self.emit("end\n", .{});
            return;
        };
        if (word(line, "return")) {
            if (!context.sync or t.open) return error.InvalidSyntax;
            try self.comments(context.actor);
            try self.emit("{s}-->>{s}: {s}\n", .{ context.actor, context.caller, try self.label(d.trim(line[6..])) });
            return;
        }
        var assigned: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const dot = std.mem.indexOfScalar(u8, line, '.') orelse line.len;
            const arrow = std.mem.indexOf(u8, line, "->") orelse line.len;
            if (eq < dot and eq < arrow) {
                assigned = try self.label(d.trim(line[0..eq]));
                line = d.trim(line[eq + 1 ..]);
            }
        }
        var explicit_from: ?[]const u8 = null;
        if (std.mem.indexOf(u8, line, "->")) |arrow| {
            explicit_from = d.trim(line[0..arrow]);
            line = d.trim(line[arrow + 2 ..]);
            _ = try self.remember(explicit_from.?);
        }
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            if (t.open or explicit_from == null or assigned.len > 0) return error.InvalidSyntax;
            const target = d.trim(line[0..colon]);
            _ = try self.remember(target);
            try self.comments(explicit_from.?);
            try self.emit("{s}{s}{s}: {s}\n", .{ explicit_from.?, if (self.reply) "-->>" else "-)", target, try self.label(d.trim(line[colon + 1 ..])) });
            self.reply = false;
            return;
        }
        const creating = word(line, "new");
        if (creating) line = d.trim(line[3..]);
        const dot = std.mem.indexOfScalar(u8, line, '.');
        const implicit_self = !creating and dot == null and std.mem.indexOfScalar(u8, line, '(') != null and context.actor.len > 0;
        if (creating or dot != null or implicit_self) {
            if (self.reply) return error.InvalidSyntax;
            const cut = if (creating) (std.mem.indexOfScalar(u8, line, '(') orelse line.len) else dot orelse 0;
            const target = if (implicit_self) context.actor else d.trim(line[0..cut]);
            if (!creating and !implicit_self and d.trim(line[cut + 1 ..]).len == 0) return error.InvalidSyntax;
            const fresh = try self.remember(target);
            if (creating and !fresh) return error.InvalidSyntax;
            const from = explicit_from orelse try self.caller(context);
            try self.comments(from);
            if (creating) try self.emit("create participant {s}\n", .{target});
            try self.emit("{s}->>{s}{s}: {s}{s}\n", .{ from, if (creating) "" else "+", target, if (creating) "new " else "", try self.label(if (creating or implicit_self) line else line[cut + 1 ..]) });
            if (t.open) try self.block(.{ .actor = target, .caller = from, .sync = true }, depth + 1, true, false);
            if (assigned.len > 0) try self.emit("{s}-->>{s}: {s}\n", .{ target, from, assigned });
            if (!creating) try self.emit("deactivate {s}\n", .{target});
            return;
        }
        if (t.open or explicit_from != null or assigned.len > 0 or self.reply) return error.InvalidSyntax;
        const alias = std.mem.indexOf(u8, line, " as ");
        const id = d.trim(line[0 .. alias orelse line.len]);
        _ = try self.remember(id);
        try self.emit("participant {s} as {s}\n", .{ id, try self.label(if (alias) |i| d.trim(line[i + 4 ..]) else id) });
        self.pending_comment = "";
    }
};
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const end = std.mem.indexOfAny(u8, doc.source, "\n;") orelse doc.source.len;
    if (!std.mem.eql(u8, d.trim(doc.source[0..end]), "zenuml")) return error.InvalidSyntax;
    var parser: Parser = .{ .a = arena.allocator(), .lex = .{ .source = doc.source[@min(end + 1, doc.source.len)..] } };
    try parser.emit("sequenceDiagram\n", .{});
    try parser.block(.{ .actor = "", .caller = "" }, 0, false, false);
    if (parser.reply) return error.InvalidSyntax;
    return seq.renderConfigured(a, parser.output.items, doc.theme, prefix, "zenuml", doc);
}
