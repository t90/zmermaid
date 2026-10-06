const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
pub const Point = struct { value: f64, label: []const u8 = "" };
pub fn label(a: std.mem.Allocator, raw: []const u8) d.Error![]const u8 {
    const s = d.trim(raw);
    if (s.len > 0 and s[0] == '"' and (s.len < 2 or s[s.len - 1] != '"')) return error.InvalidSyntax;
    return txt.parse(a, d.unquote(s));
}
pub const Parts = struct {
    rest: []const u8,
    pub fn next(self: *Parts) d.Error!?[]const u8 {
        if (self.rest.len == 0) return null;
        var quoted = false;
        for (self.rest, 0..) |c, i| {
            if (c == '"') quoted = !quoted;
            if (c == ',' and !quoted) {
                const result = d.trim(self.rest[0..i]);
                self.rest = self.rest[i + 1 ..];
                if (result.len == 0 or d.trim(self.rest).len == 0) return error.InvalidSyntax;
                return result;
            }
        }
        if (quoted) return error.InvalidSyntax;
        const result = d.trim(self.rest);
        self.rest = "";
        if (result.len == 0) return error.InvalidSyntax;
        return result;
    }
};
pub fn values(a: std.mem.Allocator, raw: []const u8) d.Error![]Point {
    var result: std.ArrayList(Point) = .empty;
    var parts: Parts = .{ .rest = raw };
    while (try parts.next()) |part| {
        if (result.items.len == 1024) return error.LimitExceeded;
        const quote = std.mem.indexOfScalar(u8, part, '"');
        try result.append(a, .{ .value = try d.number(part[0 .. quote orelse part.len]), .label = if (quote) |q| try label(a, part[q..]) else "" });
    }
    if (result.items.len == 0) return error.InvalidSyntax;
    return result.toOwnedSlice(a);
}
pub fn integer(n: f64) d.Error!usize {
    if (n < 0 or n > 1000000 or @floor(n) != n) return error.InvalidSyntax;
    return @intFromFloat(n);
}
pub fn coord(n: f64) usize {
    return @intFromFloat(@max(0, @round(n)));
}
pub fn format(a: std.mem.Allocator, n: f64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d:.2}", .{n});
}
