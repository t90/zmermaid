const std = @import("std");
const svg = @import("svg.zig");
const txt = @import("sequence_text.zig");
const d = @import("document.zig");

pub const Text = struct {
    size: f64 = 14,
    color: []const u8,
    class_name: []const u8 = "",
    pub fn width(self: Text, value: []const u8) f64 {
        return @as(f64, @floatFromInt(txt.width(value))) * self.size / 14;
    }
    pub fn height(self: Text, value: []const u8) f64 {
        return @as(f64, @floatFromInt(txt.height(value))) * self.size / 14;
    }
    pub fn draw(self: Text, out: *svg.Svg, x: f64, top: f64, value: []const u8) d.Error!void {
        var lines = std.mem.splitScalar(u8, value, '\n');
        var y = top + self.size * 10 / 14;
        while (lines.next()) |line| {
            try out.fmt("<text x=\"{d:.2}\" y=\"{d:.2}\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-family=\"Consolas,monospace\" font-size=\"{d}\" fill=\"", .{ x, y, self.size });
            try out.escape(self.color);
            try out.add("\" stroke=\"none\"");
            if (self.class_name.len > 0) {
                try out.add(" class=\"");
                try out.escape(self.class_name);
                try out.add("\"");
            }
            try out.add(">");
            try out.escape(line);
            try out.add("</text>");
            y += self.size * 20 / 14;
        }
    }
};

pub fn color(doc: *d.Document, key: []const u8, fallback: []const u8) d.Error![]const u8 {
    return if (doc.get(key)) |value| try d.color(value) else fallback;
}
