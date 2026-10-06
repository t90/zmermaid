const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const eq = std.mem.eql;
const Mode = enum { explicit, ebnf, abnf, peg };
const Kind = enum { terminal, nonterminal, special, sequence, choice, optional, repeat, assertion, exception };
const Node = struct { kind: Kind, label: []const u8 = "", children: std.ArrayList(usize) = .empty, min: usize = 1, max: ?usize = null, w: usize = 0, h: usize = 0, baseline: usize = 0 };
const Rule = struct { name: []const u8, node: usize };
const Parser = struct {
    a: std.mem.Allocator,
    source: []const u8,
    mode: Mode,
    nodes: std.ArrayList(Node) = .empty,
    fn space(self: *Parser) d.Error!void {
        while (true) {
            self.source = std.mem.trimStart(u8, self.source, " \t\r\n");
            if (txt.starts(self.source, "%%") or (self.mode == .peg and txt.starts(self.source, "#"))) {
                if (txt.starts(self.source, "%%{")) return error.UnsupportedSyntax;
                self.source = self.source[std.mem.indexOfScalar(u8, self.source, '\n') orelse self.source.len ..];
            } else if (txt.starts(self.source, "/*") or (self.mode == .ebnf and txt.starts(self.source, "(*"))) {
                const end = std.mem.indexOf(u8, self.source, if (self.source[0] == '/') "*/" else "*)") orelse return error.InvalidSyntax;
                self.source = self.source[end + 2 ..];
            } else break;
        }
    }
    fn eat(self: *Parser, value: []const u8) d.Error!bool {
        try self.space();
        if (!std.mem.startsWith(u8, self.source, value)) return false;
        self.source = self.source[value.len..];
        return true;
    }
    fn need(self: *Parser, value: []const u8) d.Error!void {
        if (!try self.eat(value)) return error.InvalidSyntax;
    }
    fn id(self: *Parser) d.Error![]const u8 {
        try self.space();
        if (self.source.len == 0 or (!std.ascii.isAlphabetic(self.source[0]) and (self.source[0] != '_' or self.mode == .abnf))) return error.InvalidSyntax;
        var end: usize = 1;
        while (end < self.source.len and (std.ascii.isAlphanumeric(self.source[end]) or self.source[end] == '_' or self.source[end] == '-')) : (end += 1) {}
        if (end > 512) return error.LimitExceeded;
        const value = self.source[0..end];
        self.source = self.source[end..];
        return value;
    }
    fn string(self: *Parser) d.Error![]const u8 {
        try self.space();
        if (self.source.len == 0 or (self.source[0] != '"' and self.source[0] != '\'')) return error.InvalidSyntax;
        const quote = self.source[0];
        if (self.mode == .abnf and quote != '"') return error.InvalidSyntax;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < self.source.len and self.source[i] != quote) : (i += 1) {
            var c = self.source[i];
            if (c == '\\' and self.mode != .abnf) {
                i += 1;
                if (i == self.source.len) return error.InvalidSyntax;
                c = switch (self.source[i]) {
                    'n' => 10,
                    'r' => 13,
                    't' => 9,
                    else => self.source[i],
                };
            }
            try out.append(self.a, c);
            if (out.items.len > 512) return error.LimitExceeded;
        }
        if (i == self.source.len) return error.InvalidSyntax;
        self.source = self.source[i + 1 ..];
        return out.toOwnedSlice(self.a);
    }
    fn add(self: *Parser, k: Kind, label: []const u8, children: []const usize) d.Error!usize {
        if (self.nodes.items.len == 4096) return error.LimitExceeded;
        var n: Node = .{ .kind = k, .label = label };
        try n.children.appendSlice(self.a, children);
        try self.nodes.append(self.a, n);
        return self.nodes.items.len - 1;
    }
    fn unary(self: *Parser, k: Kind, child: usize) d.Error!usize {
        return self.add(k, "", &.{child});
    }
    fn repeat(self: *Parser, child: usize, min: usize, max: ?usize) d.Error!usize {
        if (min > 9999 or (max != null and max.? > 9999)) return error.LimitExceeded;
        if (max) |m| if (m < min) return error.InvalidSyntax;
        const n = try self.unary(.repeat, child);
        self.nodes.items[n].min = min;
        self.nodes.items[n].max = max;
        return n;
    }
    fn explicit(self: *Parser, depth: usize) d.Error!usize {
        if (depth > 32) return error.LimitExceeded;
        const name = try self.id();
        try self.need("(");
        for ([_]Kind{ .terminal, .nonterminal, .special }) |k| if (eq(u8, name, @tagName(k))) {
            const value = try self.string();
            try self.need(")");
            return self.add(k, value, &.{});
        };
        if (eq(u8, name, "sequence") or eq(u8, name, "choice")) {
            var children: std.ArrayList(usize) = .empty;
            try children.append(self.a, try self.explicit(depth + 1));
            while (try self.eat(",")) try children.append(self.a, try self.explicit(depth + 1));
            try self.need(")");
            return self.add(if (eq(u8, name, "sequence")) .sequence else .choice, "", children.items);
        }
        if (!eq(u8, name, "optional") and !eq(u8, name, "oneOrMore") and !eq(u8, name, "zeroOrMore")) return error.UnsupportedSyntax;
        const child = try self.explicit(depth + 1);
        try self.need(")");
        return if (eq(u8, name, "optional")) self.unary(.optional, child) else self.repeat(child, if (eq(u8, name, "oneOrMore")) 1 else 0, null);
    }
    fn primary(self: *Parser, depth: usize) d.Error!usize {
        if (depth > 32) return error.LimitExceeded;
        try self.space();
        if (self.source.len == 0) return error.InvalidSyntax;
        if (self.source[0] == '"' or self.source[0] == '\'') return self.add(.terminal, try self.string(), &.{});
        if (try self.eat("(")) {
            const node = try self.expression(depth + 1);
            try self.need(")");
            return node;
        }
        if (self.mode != .peg and try self.eat("[")) {
            const node = try self.expression(depth + 1);
            try self.need("]");
            return self.unary(.optional, node);
        }
        if (self.mode == .ebnf and try self.eat("{")) {
            const node = try self.expression(depth + 1);
            try self.need("}");
            return self.repeat(node, 0, null);
        }
        if (self.mode == .ebnf and try self.eat("?")) {
            const end = std.mem.indexOfScalar(u8, self.source, '?') orelse return error.InvalidSyntax;
            const value = d.trim(self.source[0..end]);
            if (value.len == 0 or value.len > 512 or std.mem.indexOfScalar(u8, value, ';') != null) return error.InvalidSyntax;
            self.source = self.source[end + 1 ..];
            return self.add(.special, value, &.{});
        }
        if (self.mode == .peg and try self.eat(".")) return self.add(.special, "any character", &.{});
        if (self.mode == .abnf and txt.starts(self.source, "%")) {
            var end: usize = 1;
            while (end < self.source.len and (std.ascii.isAlphanumeric(self.source[end]) or self.source[end] == '-' or self.source[end] == '.')) : (end += 1) {}
            const value = self.source[0..end];
            if (value.len < 3 or value.len > 512) return error.InvalidSyntax;
            const base: u8 = switch (std.ascii.toLower(value[1])) {
                'b' => 2,
                'd' => 10,
                'x' => 16,
                else => return error.InvalidSyntax,
            };
            var nums = std.mem.tokenizeAny(u8, value[2..], "-.");
            var count: usize = 0;
            while (nums.next()) |n| {
                _ = std.fmt.parseInt(u32, n, base) catch return error.InvalidSyntax;
                count += 1;
            }
            if (count == 0 or value[value.len - 1] == '-' or value[value.len - 1] == '.') return error.InvalidSyntax;
            self.source = self.source[end..];
            return self.add(.terminal, value, &.{});
        }
        return self.add(.nonterminal, try self.id(), &.{});
    }
    fn term(self: *Parser, depth: usize) d.Error!usize {
        try self.space();
        var prefix: u8 = 0;
        if (self.mode == .peg and self.source.len > 0 and (self.source[0] == '&' or self.source[0] == '!')) {
            prefix = self.source[0];
            self.source = self.source[1..];
        }
        var min: ?usize = null;
        var max: ?usize = null;
        if (self.mode == .abnf and self.source.len > 0 and (std.ascii.isDigit(self.source[0]) or self.source[0] == '*')) {
            var at: usize = 0;
            while (at < self.source.len and std.ascii.isDigit(self.source[at])) : (at += 1) {}
            min = if (at == 0) 0 else std.fmt.parseInt(usize, self.source[0..at], 10) catch return error.LimitExceeded;
            if (at < self.source.len and self.source[at] == '*') {
                at += 1;
                const start = at;
                while (at < self.source.len and std.ascii.isDigit(self.source[at])) : (at += 1) {}
                if (at > start) max = std.fmt.parseInt(usize, self.source[start..at], 10) catch return error.LimitExceeded;
            } else max = min;
            self.source = self.source[at..];
        }
        var node = try self.primary(depth);
        if (min) |m| node = try self.repeat(node, m, max);
        if (self.mode != .abnf) {
            var count: usize = 0;
            while (true) {
                if (count == 32) return error.LimitExceeded;
                try self.space();
                // ISO special sequences take lexical precedence over postfix '?'.
                if (self.mode == .ebnf and txt.starts(self.source, "?")) {
                    const stop = std.mem.indexOfAny(u8, self.source[1..], "?;");
                    if (stop) |end| {
                        if (self.source[end + 1] == '?' and d.trim(self.source[1 .. end + 1]).len > 0) break;
                    }
                }
                if (try self.eat("?")) node = try self.unary(.optional, node) else if (try self.eat("*")) node = try self.repeat(node, 0, null) else if (try self.eat("+")) node = try self.repeat(node, 1, null) else if (self.mode == .ebnf and try self.eat("-")) {
                    node = try self.add(.exception, "except", &.{ node, try self.primary(depth + 1) });
                } else break;
                count += 1;
                if (self.mode == .peg) break;
            }
        }
        if (prefix != 0) node = try self.add(.assertion, if (prefix == '!') "Must not match (lookahead)" else "Must match (lookahead)", &.{node});
        return node;
    }
    fn sequence(self: *Parser, depth: usize) d.Error!usize {
        var children: std.ArrayList(usize) = .empty;
        while (true) {
            try self.space();
            if (self.source.len == 0) break;
            const c = self.source[0];
            if (c == ';' or c == ')' or c == ']' or c == '}' or c == '|' or c == '/') break;
            if (c == ',') {
                if (self.mode != .ebnf or children.items.len == 0) return error.InvalidSyntax;
                self.source = self.source[1..];
                try self.space();
                if (self.source.len == 0 or std.mem.indexOfScalar(u8, ";|)}]", self.source[0]) != null) return error.InvalidSyntax;
            }
            try children.append(self.a, try self.term(depth));
        }
        if (children.items.len == 0) return error.InvalidSyntax;
        return if (children.items.len == 1) children.items[0] else self.add(.sequence, "", children.items);
    }
    fn expression(self: *Parser, depth: usize) d.Error!usize {
        if (depth > 32) return error.LimitExceeded;
        var children: std.ArrayList(usize) = .empty;
        try children.append(self.a, try self.sequence(depth));
        while (try self.eat(if (self.mode == .ebnf) "|" else "/")) try children.append(self.a, try self.sequence(depth));
        return if (children.items.len == 1) children.items[0] else self.add(.choice, if (self.mode == .peg) "ordered" else "", children.items);
    }
};
fn measure(nodes: []Node, id: usize, depth: usize) d.Error!void {
    if (depth > 96) return error.LimitExceeded;
    const n = &nodes[id];
    for (n.children.items) |child| try measure(nodes, child, depth + 1);
    switch (n.kind) {
        .terminal, .nonterminal, .special => {
            n.w = @max(60, txt.width(n.label) + 32);
            n.h = @max(40, txt.height(n.label) + 20);
            n.baseline = n.h / 2;
        },
        .sequence => {
            var below: usize = 0;
            for (n.children.items) |i| {
                const c = nodes[i];
                n.w += c.w + 24;
                n.baseline = @max(n.baseline, c.baseline);
                below = @max(below, c.h - c.baseline);
            }
            n.w -= 24;
            n.h = n.baseline + below;
        },
        .choice => {
            for (n.children.items) |i| {
                const c = nodes[i];
                n.w = @max(n.w, c.w + 96);
                n.h += c.h + 28;
            }
            n.h -= 28;
            n.baseline = nodes[n.children.items[0]].baseline;
        },
        .optional => {
            const c = nodes[n.children.items[0]];
            n.w = c.w + 80;
            n.h = c.h + 40;
            n.baseline = c.baseline + 40;
        },
        .repeat => {
            const c = nodes[n.children.items[0]];
            const top: usize = if (n.min == 0) 40 else 0;
            n.w = c.w + 100;
            n.h = c.h + top + 64;
            n.baseline = c.baseline + top;
            if (n.max == 0) n.baseline = 20;
        },
        .assertion => {
            const c = nodes[n.children.items[0]];
            n.w = @max(c.w + 80, txt.width(n.label) + 24);
            n.h = c.h + 90;
            n.baseline = n.h - 16;
        },
        .exception => {
            const c = nodes[n.children.items[0]];
            const e = nodes[n.children.items[1]];
            n.w = @max(c.w, e.w) + 80;
            n.h = c.h + e.h + 76;
            n.baseline = c.baseline;
        },
    }
    if (n.w > 2000000 or n.h > 2000000) return error.LimitExceeded;
}
fn line(out: *svg.Svg, x: usize, y: usize, to: usize) !void {
    if (x != to) try out.fmt("<path d=\"M {d} {d} H {d}\" fill=\"none\"/>", .{ x, y, to });
}
fn text(out: *svg.Svg, x: usize, y: usize, value: []const u8, fg: []const u8) !void {
    var parts = std.mem.splitScalar(u8, value, '\n');
    var py = y;
    while (parts.next()) |part| {
        try out.fmt("<text xml:space=\"preserve\" x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" font-family=\"Consolas,monospace\" font-size=\"14\" fill=\"{s}\" stroke=\"none\">", .{ x, py, fg });
        try out.escape(part);
        try out.add("</text>");
        py += 20;
    }
}
fn draw(out: *svg.Svg, nodes: []Node, id: usize, x: usize, y: usize, prefix: u32, fg: []const u8, fill: []const u8) d.Error!void {
    const n = nodes[id];
    const base = y + n.baseline;
    try out.fmt("<g data-railroad-node=\"{d}\" data-kind=\"{s}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\" data-baseline=\"{d}\">", .{ id, @tagName(n.kind), x, y, n.w, n.h, base });
    switch (n.kind) {
        .terminal, .nonterminal, .special => {
            try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"{d}\" fill=\"{s}\"{s}/>", .{ x, y, n.w, n.h, if (n.kind == .terminal) @as(usize, 18) else 3, fill, if (n.kind == .special) " stroke-dasharray=\"4 3\"" else "" });
            try text(out, x + n.w / 2, y + (n.h - txt.height(n.label)) / 2 + 15, n.label, fg);
        },
        .sequence => {
            var px = x;
            for (n.children.items) |i| {
                const c = nodes[i];
                try draw(out, nodes, i, px, base - c.baseline, prefix, fg, fill);
                px += c.w;
                if (px < x + n.w) {
                    try line(out, px, base, px + 24);
                    px += 24;
                }
            }
        },
        .choice => {
            var top = y;
            for (n.children.items, 0..) |i, k| {
                const c = nodes[i];
                const cy = top + c.baseline;
                const left = x + 48 + (n.w - 96 - c.w) / 2;
                if (k == 0) {
                    try line(out, x, base, left);
                    try line(out, left + c.w, base, x + n.w);
                } else {
                    try out.fmt("<path d=\"M {d} {d} Q {d} {d} {d} {d} V {d} Q {d} {d} {d} {d} H {d} M {d} {d} H {d} Q {d} {d} {d} {d} V {d} Q {d} {d} {d} {d}\" fill=\"none\"/>", .{ x, base, x + 20, base, x + 20, base + 20, cy - 20, x + 20, cy, x + 40, cy, left, left + c.w, cy, x + n.w - 40, x + n.w - 20, cy, x + n.w - 20, cy - 20, base + 20, x + n.w - 20, base, x + n.w, base });
                }
                if (n.label.len > 0) {
                    const order_label = try std.fmt.allocPrint(out.allocator, "{d}", .{k + 1});
                    defer out.allocator.free(order_label);
                    try text(out, x + 32, cy - 5, order_label, fg);
                }
                try draw(out, nodes, i, left, top, prefix, fg, fill);
                top += c.h + 28;
            }
        },
        .optional, .repeat => {
            const i = n.children.items[0];
            const c = nodes[i];
            const offset: usize = if (n.kind == .optional or n.min == 0) 40 else 0;
            const inset = (n.w - c.w) / 2;
            if (n.kind == .repeat and n.max == 0) {
                try line(out, x, base, x + n.w);
                try out.add("<g opacity=\"0.5\">");
                try draw(out, nodes, i, x + inset, y + 40, prefix, fg, fill);
                try out.add("</g>");
                try text(out, x + n.w / 2, y + c.h + 88, "0 times (omitted)", fg);
                try out.add("</g>");
                return;
            }
            try line(out, x, base, x + inset);
            try draw(out, nodes, i, x + inset, y + offset, prefix, fg, fill);
            try line(out, x + inset + c.w, base, x + n.w);
            if (offset > 0) try out.fmt("<path data-bypass=\"true\" d=\"M {d} {d} Q {d} {d} {d} {d} H {d} Q {d} {d} {d} {d}\" fill=\"none\"/>", .{ x, base, x + 20, y + 20, x + 40, y + 20, x + n.w - 40, x + n.w - 20, y + 20, x + n.w, base });
            if (n.kind == .repeat) {
                const bottom = y + offset + c.h + 26;
                try out.fmt("<path data-repeat-return=\"true\" d=\"M {d} {d} Q {d} {d} {d} {d} H {d} Q {d} {d} {d} {d}\" fill=\"none\"/><path d=\"M {d} {d} h -18\" marker-end=\"url(#zm-{d})\"/>", .{ x + n.w - 10, base, x + n.w - 10, bottom, x + n.w - 40, bottom, x + 40, x + 10, bottom, x + 10, base, x + n.w / 2 + 9, bottom, prefix });
                const count = if (n.max) |max| if (max == n.min) try std.fmt.allocPrint(out.allocator, "{d} times", .{max}) else try std.fmt.allocPrint(out.allocator, "{d}..{d} times", .{ n.min, max }) else try std.fmt.allocPrint(out.allocator, "{d}+ times", .{n.min});
                defer out.allocator.free(count);
                try text(out, x + n.w / 2, bottom + 24, count, fg);
            }
        },
        .assertion => {
            const i = n.children.items[0];
            const c = nodes[i];
            try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" fill=\"none\" stroke-dasharray=\"4 4\"/>", .{ x + 8, y, n.w - 16, n.h - 36 });
            try text(out, x + n.w / 2, y + 18, n.label, fg);
            try draw(out, nodes, i, x + (n.w - c.w) / 2, y + 32, prefix, fg, fill);
            try line(out, x, base, x + n.w);
        },
        .exception => {
            const first = n.children.items[0];
            const second = n.children.items[1];
            const c = nodes[first];
            const e = nodes[second];
            const left = x + (n.w - c.w) / 2;
            try line(out, x, base, left);
            try draw(out, nodes, first, left, y, prefix, fg, fill);
            try line(out, left + c.w, base, x + n.w);
            try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" fill=\"none\" stroke-dasharray=\"4 4\"/>", .{ x + 8, y + c.h + 12, n.w - 16, e.h + 52 });
            try text(out, x + n.w / 2, y + c.h + 32, "Except", fg);
            try draw(out, nodes, second, x + (n.w - e.w) / 2, y + c.h + 44, prefix, fg, fill);
        },
    }
    try out.add("</g>");
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const header = std.mem.indexOfAny(u8, doc.source, " \t\r\n") orelse doc.source.len;
    const keyword = doc.source[0..header];
    const mode: Mode = if (eq(u8, keyword, "railroad-ebnf-beta")) .ebnf else if (eq(u8, keyword, "railroad-abnf-beta")) .abnf else if (eq(u8, keyword, "railroad-peg-beta")) .peg else .explicit;
    var p: Parser = .{ .a = temp, .source = doc.source[header..], .mode = mode };
    var rules: std.ArrayList(Rule) = .empty;
    while (true) {
        try p.space();
        if (p.source.len == 0) break;
        if (mode == .abnf and txt.starts(p.source, ";")) {
            p.source = p.source[std.mem.indexOfScalar(u8, p.source, '\n') orelse p.source.len ..];
            continue;
        }
        const name = try p.id();
        if (eq(u8, name, "title") or eq(u8, name, "accTitle") or eq(u8, name, "accDescr")) {
            if (eq(u8, name, "accDescr") and try p.eat("{")) {
                const end = std.mem.indexOfScalar(u8, p.source, '}') orelse return error.InvalidSyntax;
                doc.acc_description = d.trim(p.source[0..end]);
                p.source = p.source[end + 1 ..];
                continue;
            }
            if (!eq(u8, name, "title")) try p.need(":");
            const end = std.mem.indexOfScalar(u8, p.source, '\n') orelse p.source.len;
            const value = d.unquote(p.source[0..end]);
            p.source = p.source[end..];
            if (eq(u8, name, "title")) doc.title = value else if (eq(u8, name, "accTitle")) doc.acc_title = value else doc.acc_description = value;
            continue;
        }
        for (rules.items) |rule| if (eq(u8, rule.name, name)) return error.InvalidSyntax;
        if (mode == .peg) try p.need("<-") else if (mode == .ebnf and try p.eat("::=")) {} else try p.need("=");
        const node = if (mode == .explicit) try p.explicit(0) else try p.expression(0);
        try p.need(";");
        if (rules.items.len == 128) return error.LimitExceeded;
        try rules.append(temp, .{ .name = name, .node = node });
    }
    if (rules.items.len == 0) return error.InvalidSyntax;
    var width: usize = 320;
    var height: usize = 40;
    for (rules.items) |rule| {
        try measure(p.nodes.items, rule.node, 0);
        const n = p.nodes.items[rule.node];
        width = @max(width, @max(n.w + 160, txt.width(rule.name) + 80));
        height += n.h + 90;
    }
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const fill = if (doc.theme == .dark) "#213449" else "#e8f2fc";
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "railroad", prefix);
    var top: usize = 40;
    for (rules.items, 0..) |rule, i| {
        const n = p.nodes.items[rule.node];
        try out.fmt("<g data-railroad-rule=\"{d}\">", .{i});
        try text(&out, 40 + txt.width(rule.name) / 2, top, rule.name, fg);
        top += 28;
        const base = top + n.baseline;
        try out.fmt("<path d=\"M 36 {d} v 16 M 42 {d} v 16\" fill=\"none\"/>", .{ base - 8, base - 8 });
        try line(&out, 42, base, 80);
        try draw(&out, p.nodes.items, rule.node, 80, top, prefix, fg, fill);
        try out.fmt("<path d=\"M {d} {d} H {d}\" fill=\"none\" marker-end=\"url(#zm-{d})\"/><path d=\"M {d} {d} v 16\" fill=\"none\"/>", .{ 80 + n.w, base, 120 + n.w, prefix, 124 + n.w, base - 8 });
        try out.add("</g>");
        top += n.h + 62;
    }
    return out.finish();
}
