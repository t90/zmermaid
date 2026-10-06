const std = @import("std");
const d = @import("document.zig");
const Reader = struct {
    doc: *d.Document,
    source: []const u8,
    at: usize = 0,
    fn space(self: *Reader) void {
        while (self.at < self.source.len and std.ascii.isWhitespace(self.source[self.at])) self.at += 1;
    }
    fn string(self: *Reader) d.Error![]const u8 {
        return @import("yaml_scalar.zig").quoted(self.doc.a, self.source, &self.at);
    }
    fn object(self: *Reader, path: []const u8, depth: usize) d.Error!void {
        if (depth > 32) return error.LimitExceeded;
        self.space();
        if (self.at == self.source.len or self.source[self.at] != '{') return error.InvalidSyntax;
        self.at += 1;
        while (true) {
            self.space();
            if (self.at == self.source.len) return error.InvalidSyntax;
            if (self.source[self.at] == '}') {
                self.at += 1;
                return;
            }
            var key: []const u8 = undefined;
            if (self.source[self.at] == '"' or self.source[self.at] == '\'') key = try self.string() else {
                const start = self.at;
                while (self.at < self.source.len and (std.ascii.isAlphanumeric(self.source[self.at]) or self.source[self.at] == '_')) self.at += 1;
                key = self.source[start..self.at];
            }
            if (key.len == 0 or key.len > 256) return error.InvalidSyntax;
            for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.UnsupportedSyntax;
            if (std.mem.eql(u8, key, "__proto__") or std.mem.eql(u8, key, "constructor") or std.mem.eql(u8, key, "prototype")) return error.UnsupportedSyntax;
            self.space();
            if (self.at == self.source.len or self.source[self.at] != ':') return error.InvalidSyntax;
            self.at += 1;
            self.space();
            if (self.at == self.source.len) return error.InvalidSyntax;
            const full = try std.fmt.allocPrint(self.doc.a, "{s}.{s}", .{ path, key });
            if (self.source[self.at] == '{') try self.object(full, depth + 1) else {
                var value: []const u8 = undefined;
                if (self.source[self.at] == '"' or self.source[self.at] == '\'') value = try self.string() else {
                    const start = self.at;
                    while (self.at < self.source.len and self.source[self.at] != ',' and self.source[self.at] != '}') self.at += 1;
                    value = d.trim(self.source[start..self.at]);
                    if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false") and !std.mem.eql(u8, value, "null")) _ = try d.number(value);
                }
                var replaced = false;
                for (self.doc.entries.items) |*entry| if (std.mem.eql(u8, entry.key, full)) {
                    entry.value = value;
                    replaced = true;
                    break;
                };
                if (!replaced) {
                    if (self.doc.entries.items.len == 128) return error.LimitExceeded;
                    try self.doc.entries.append(self.doc.a, .{ .key = full, .value = value });
                }
            }
            self.space();
            if (self.at == self.source.len) return error.InvalidSyntax;
            if (self.source[self.at] == '}') {
                self.at += 1;
                return;
            }
            if (self.source[self.at] != ',') return error.InvalidSyntax;
            self.at += 1;
        }
    }
};
pub fn parse(doc: *d.Document, path: []const u8, source: []const u8) d.Error!void {
    var reader: Reader = .{ .doc = doc, .source = source };
    try reader.object(path, 0);
    reader.space();
    if (reader.at != source.len) return error.InvalidSyntax;
}
pub fn directives(doc: *d.Document) d.Error!void {
    if (std.mem.indexOf(u8, doc.source, "%%{") == null) return;
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < doc.source.len) {
        const end = std.mem.indexOfScalarPos(u8, doc.source, at, '\n') orelse doc.source.len;
        const line = d.trim(doc.source[at..end]);
        if (!std.mem.startsWith(u8, line, "%%{")) {
            try out.appendSlice(doc.a, doc.source[at..@min(end + 1, doc.source.len)]);
            at = @min(end + 1, doc.source.len);
            continue;
        }
        const start = at + (std.mem.indexOf(u8, doc.source[at..end], "%%{").?) + 3;
        var close = start;
        var quote: u8 = 0;
        var escaped = false;
        while (close < doc.source.len) : (close += 1) {
            const c = doc.source[close];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quote != 0) {
                if (c == '\\') escaped = true else if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or c == '\'') {
                quote = c;
                continue;
            }
            if (std.mem.startsWith(u8, doc.source[close..], "}%%")) break;
        }
        if (close == doc.source.len) return error.InvalidSyntax;
        const body = d.trim(doc.source[start..close]);
        const colon = std.mem.indexOfScalar(u8, body, ':') orelse return error.UnsupportedSyntax;
        const name = d.trim(body[0..colon]);
        if (!std.mem.eql(u8, name, "init") and !std.mem.eql(u8, name, "initialize")) return error.UnsupportedSyntax;
        try parse(doc, "config", d.trim(body[colon + 1 ..]));
        at = close + 3;
        try out.append(doc.a, '\n');
    }
    doc.source = d.trim(try out.toOwnedSlice(doc.a));
}
