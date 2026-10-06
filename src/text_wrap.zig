const std = @import("std");
const txt = @import("sequence_text.zig");
// Deterministic word wrapping with UTF-8-safe fallback for long tokens.
pub fn wrap(a: std.mem.Allocator, s: []const u8, max_width: usize) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var line: usize = 0;
    var at: usize = 0;
    while (at < s.len) {
        if (s[at] == '\n') {
            try out.append(a, '\n');
            line = 0;
            at += 1;
            continue;
        }
        if (s[at] == ' ' or s[at] == '\t') {
            at += 1;
            continue;
        }
        var end = at;
        while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != '\n') : (end += 1) {}
        const word = s[at..end];
        const width = txt.width(word);
        if (line > 0 and line + 9 + width > max_width) {
            try out.append(a, '\n');
            line = 0;
        }
        if (line > 0) {
            try out.append(a, ' ');
            line += 9;
        }
        var i: usize = 0;
        while (i < word.len) {
            const len = std.unicode.utf8ByteSequenceLength(word[i]) catch 1;
            const char = word[i..@min(i + len, word.len)];
            const w = txt.width(char);
            if (line > 0 and line + w > max_width) {
                try out.append(a, '\n');
                line = 0;
            }
            try out.appendSlice(a, char);
            line += w;
            i += len;
        }
        at = end;
    }
    return out.toOwnedSlice(a);
}
