const std = @import("std");
const d = @import("document.zig");
const data = @import("chart_data.zig");
pub const Style = struct {
    fill: ?[]const u8 = null,
    text: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    width: ?f64 = null,
    radius: ?f64 = null,
    dash: ?[]const u8 = null,
    italic: ?bool = null,
    bold: ?bool = null,
    offset: ?f64 = null,
    animation: ?f64 = null,
    font_size: ?f64 = null,
    pub fn measure(self: Style, value: usize) usize {
        return @intFromFloat(@ceil(@as(f64, @floatFromInt(value)) * (self.font_size orelse 14) / 14));
    }
    pub fn merge(self: *Style, other: Style) void {
        inline for (std.meta.fields(Style)) |f| if (@field(other, f.name)) |v| {
            @field(self, f.name) = v;
        };
    }
};
pub const Class = struct { name: []const u8, style: Style };
pub const CssParts = struct {
    rest: []const u8,
    pub fn next(self: *CssParts) d.Error!?[]const u8 {
        if (self.rest.len == 0) return null;
        var depth: usize = 0;
        for (self.rest, 0..) |c, i| {
            if (c == '(') {
                depth += 1;
                if (depth > 16) return error.LimitExceeded;
            }
            if (c == ')') {
                if (depth == 0) return error.InvalidSyntax;
                depth -= 1;
            }
            if (c != ',' or depth > 0 or (i > 0 and self.rest[i - 1] == '\\')) continue;
            const remaining = d.trim(self.rest[i + 1 ..]);
            if (remaining.len == 0) return error.InvalidSyntax;
            // Commas inside a numeric dash list belong to the same property.
            if (std.ascii.isDigit(remaining[0]) or remaining[0] == '.') continue;
            const result = d.trim(self.rest[0..i]);
            self.rest = remaining;
            return result;
        }
        if (depth != 0) return error.InvalidSyntax;
        const result = d.trim(self.rest);
        self.rest = "";
        return result;
    }
};
pub fn parse(raw: []const u8, point: bool) d.Error!Style {
    return parseImpl(raw, point, false);
}
pub fn parseGraph(raw: []const u8) d.Error!Style {
    return parseImpl(raw, false, true);
}
fn parseImpl(raw: []const u8, point: bool, graph: bool) d.Error!Style {
    var style: Style = .{};
    var parts: CssParts = .{ .rest = std.mem.trim(u8, raw, " \t\r\n;") };
    while (try parts.next()) |part| {
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidSyntax;
        const key = d.trim(part[0..colon]);
        const value = d.trim(part[colon + 1 ..]);
        if (std.mem.eql(u8, key, "fill") or std.mem.eql(u8, key, "background") or std.mem.eql(u8, key, "background-color")) style.fill = try d.color(value) else if (std.mem.eql(u8, key, "border")) {
            var words = std.mem.tokenizeAny(u8, value, " \t");
            const width = words.next() orelse return error.InvalidSyntax;
            const pattern = words.next() orelse return error.InvalidSyntax;
            const color_value = d.trim(words.rest());
            style.width = try d.number(if (std.mem.endsWith(u8, width, "px")) width[0 .. width.len - 2] else width);
            if (style.width.? < 0 or style.width.? > 100) return error.InvalidSyntax;
            style.stroke = try d.color(color_value);
            if (std.mem.eql(u8, pattern, "dashed")) style.dash = "5 4" else if (std.mem.eql(u8, pattern, "dotted")) style.dash = "2 3" else if (!std.mem.eql(u8, pattern, "solid")) return error.UnsupportedSyntax;
        } else if (std.mem.eql(u8, key, "color")) {
            if (point) style.fill = try d.color(value) else style.text = try d.color(value);
        } else if (std.mem.eql(u8, key, "stroke") or std.mem.eql(u8, key, "stroke-color")) style.stroke = try d.color(value) else if (std.mem.eql(u8, key, "stroke-width") or std.mem.eql(u8, key, "radius")) {
            const n = try d.number(if (std.mem.endsWith(u8, value, "px")) value[0 .. value.len - 2] else value);
            if (n < 0 or n > 100) return error.InvalidSyntax;
            if (std.mem.eql(u8, key, "radius")) {
                if (!point) return error.UnsupportedSyntax;
                style.radius = n;
            } else style.width = n;
        } else if (std.mem.eql(u8, key, "stroke-dasharray")) {
            if (point) return error.UnsupportedSyntax;
            var nums = std.mem.tokenizeAny(u8, value, " \t,\\");
            var count: usize = 0;
            while (nums.next()) |num| {
                const n = try d.number(num);
                if (n < 0 or n > 1000) return error.InvalidSyntax;
                count += 1;
            }
            if (count == 0 or count > 16) return error.InvalidSyntax;
            style.dash = value;
        } else if (std.mem.eql(u8, key, "stroke-dashoffset")) {
            if (point) return error.UnsupportedSyntax;
            const n = try d.number(value);
            if (@abs(n) > 100000) return error.InvalidSyntax;
            style.offset = n;
        } else if (std.mem.eql(u8, key, "animation")) {
            if (point) return error.UnsupportedSyntax;
            var words = std.mem.tokenizeAny(u8, value, " \t");
            const name = words.next() orelse return error.InvalidSyntax;
            if (!std.mem.eql(u8, name, "dash")) return error.UnsupportedSyntax;
            const duration = words.next() orelse return error.InvalidSyntax;
            const ms = std.mem.endsWith(u8, duration, "ms");
            if (!std.mem.endsWith(u8, duration, "s")) return error.UnsupportedSyntax;
            const n = try d.number(duration[0 .. duration.len - (if (ms) @as(usize, 2) else 1)]);
            const seconds = n / (if (ms) @as(f64, 1000) else 1);
            if (seconds <= 0 or seconds > 3600) return error.InvalidSyntax;
            if (!std.mem.eql(u8, words.next() orelse "", "linear") or !std.mem.eql(u8, words.next() orelse "", "infinite") or words.next() != null) return error.UnsupportedSyntax;
            style.animation = seconds;
        } else if (std.mem.eql(u8, key, "font-size") and graph) {
            const n = try d.number(if (std.mem.endsWith(u8, value, "px")) value[0 .. value.len - 2] else value);
            if (n < 1 or n > 256) return error.InvalidSyntax;
            style.font_size = n;
        } else if (std.mem.eql(u8, key, "font-style") or std.mem.eql(u8, key, "font-weight")) {
            if (point) return error.UnsupportedSyntax;
            const italic = std.mem.eql(u8, key, "font-style");
            if (!std.mem.eql(u8, value, "normal") and !std.mem.eql(u8, value, if (italic) "italic" else "bold")) return error.UnsupportedSyntax;
            if (italic) style.italic = std.mem.eql(u8, value, "italic") else style.bold = std.mem.eql(u8, value, "bold");
        } else return error.UnsupportedSyntax;
    }
    return style;
}
pub fn class(raw: []const u8, point: bool) d.Error!Class {
    const rest = d.trim(raw);
    const split = std.mem.indexOfAny(u8, rest, " \t") orelse return error.InvalidSyntax;
    return .{ .name = rest[0..split], .style = try parse(rest[split + 1 ..], point) };
}
pub fn graphClass(raw: []const u8) d.Error!Class {
    const rest = d.trim(raw);
    const split = std.mem.indexOfAny(u8, rest, " \t") orelse return error.InvalidSyntax;
    return .{ .name = rest[0..split], .style = try parseGraph(rest[split + 1 ..]) };
}
