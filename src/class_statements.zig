const std = @import("std");
const d = @import("document.zig");

// Class/namespace braces are structural; quoted notes and escaped identifiers
// may contain delimiters or newlines. No preprocessing or upstream parser.
pub const Statements = struct {
    source: []const u8,
    pos: usize = 0,
    pub fn next(self: *Statements) d.Error!?[]const u8 {
        while (self.pos < self.source.len) {
            while (self.pos < self.source.len and std.mem.indexOfScalar(u8, " \t\r\n;", self.source[self.pos]) != null) self.pos += 1;
            if (self.pos == self.source.len) return null;
            if (std.mem.startsWith(u8, self.source[self.pos..], "%%")) {
                self.pos = std.mem.indexOfScalarPos(u8, self.source, self.pos, '\n') orelse self.source.len;
                continue;
            }
            const start = self.pos;
            var quote: u8 = 0;
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];
                if (quote != 0) {
                    self.pos += 1;
                    if (c == quote) quote = 0;
                    continue;
                }
                if (c == '"' or c == '`') {
                    quote = c;
                    self.pos += 1;
                    continue;
                }
                if (c == '&') {
                    var end = self.pos + 1;
                    while (end < self.source.len and end - self.pos <= 32 and (std.ascii.isAlphanumeric(self.source[end]) or self.source[end] == '#')) end += 1;
                    if (end > self.pos + 1 and end < self.source.len and self.source[end] == ';') {
                        self.pos = end + 1;
                        continue;
                    }
                }
                if (c == '}') {
                    if (self.pos == start) self.pos += 1;
                    return d.trim(self.source[start..self.pos]);
                }
                if (c == '{') {
                    self.pos += 1;
                    return d.trim(self.source[start..self.pos]);
                }
                if (c == '\n' or c == ';') {
                    const result = d.trim(self.source[start..self.pos]);
                    self.pos += 1;
                    return result;
                }
                if (std.mem.startsWith(u8, self.source[self.pos..], "%%")) {
                    const result = d.trim(self.source[start..self.pos]);
                    self.pos = std.mem.indexOfScalarPos(u8, self.source, self.pos, '\n') orelse self.source.len;
                    return result;
                }
                self.pos += 1;
            }
            if (quote != 0) return error.InvalidSyntax;
            return d.trim(self.source[start..self.pos]);
        }
        return null;
    }
};
