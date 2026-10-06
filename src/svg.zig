const std = @import("std");
pub const Theme = enum(u32) { light = 0, dark = 1 };
pub const Svg = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    theme: Theme,
    id_prefix: u32 = 0,
    asset_instance: usize = 0,
    pub fn deinit(self: *Svg) void {
        self.bytes.deinit(self.allocator);
    }
    pub fn add(self: *Svg, value: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, value);
    }
    pub fn fmt(self: *Svg, comptime format: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(formatted);
        try self.add(formatted);
    }
    pub fn escape(self: *Svg, value: []const u8) !void {
        for (value) |ch| switch (ch) {
            '&' => try self.add("&amp;"),
            '<' => try self.add("&lt;"),
            '>' => try self.add("&gt;"),
            '"' => try self.add("&quot;"),
            '\'' => try self.add("&apos;"),
            else => {
                if (ch >= 32 or ch == 10 or ch == 9) try self.bytes.append(self.allocator, ch);
            },
        };
    }
    pub fn start(self: *Svg, width: usize, height: usize, kind: []const u8, prefix: u32) !void {
        self.id_prefix = prefix;
        try self.fmt("<svg xmlns=\"http://www.w3.org/2000/svg\" id=\"zm-{d}-css\" viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\" role=\"img\" aria-label=\"{s} diagram\" style=\"max-width:100%;height:auto\">", .{ prefix, width, height, width, height, kind });
        const bg = if (self.theme == .dark) "#0d1117" else "#ffffff";
        const line = "#9ca3af";
        const fill = if (self.theme == .dark) "#16213e" else "#eef4ff";
        try self.fmt("<rect width=\"100%\" height=\"100%\" fill=\"{s}\"/><defs><marker id=\"zm-{d}\" viewBox=\"0 0 10 10\" refX=\"10\" refY=\"5\" markerWidth=\"8\" markerHeight=\"8\" markerUnits=\"userSpaceOnUse\" orient=\"auto-start-reverse\"><path d=\"M 1 1 L 9 5 L 1 9 z\" fill=\"{s}\"/></marker></defs><g fill=\"{s}\" stroke=\"{s}\" stroke-width=\"1.25\">", .{ bg, prefix, line, fill, line });
    }
    pub fn flowMarkers(self: *Svg, prefix: u32) !void {
        // Symbols have fixed drawing-unit sizes, independent of stroke weight.
        // Arrow tips coincide with the shaft endpoint; crosses/circles leave
        // six units to the node border along the shared straight terminal.
        const fg = "#9ca3af";
        try self.add("<defs>");
        for ([_][]const u8{ "arrow", "circle", "cross" }) |kind| {
            try self.fmt("<marker id=\"zm-{d}-{s}\" viewBox=\"0 0 10 10\" refX=\"{d}\" refY=\"5\" markerWidth=\"8\" markerHeight=\"8\" markerUnits=\"userSpaceOnUse\" orient=\"auto-start-reverse\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"1.25\">", .{ prefix, kind, if (std.mem.eql(u8, kind, "cross") or std.mem.eql(u8, kind, "circle")) @as(usize, 15) else 9, fg, fg });
            if (std.mem.eql(u8, kind, "arrow")) try self.add("<path d=\"M 1 1 L 9 5 L 1 9 z\"/>") else if (std.mem.eql(u8, kind, "circle")) try self.add("<circle cx=\"5\" cy=\"5\" r=\"4\"/>") else try self.add("<path d=\"M 1 1 L 9 9 M 1 9 L 9 1\" fill=\"none\"/>");
            try self.add("</marker>");
        }
        try self.add("</defs>");
        try self.relationshipMarkers(prefix);
    }
    fn relationshipMarkers(self: *Svg, prefix: u32) !void {
        const fg = if (self.theme == .dark) "#e0e0e0" else "#24292f";
        const bg = if (self.theme == .dark) "#0d1117" else "#ffffff";
        try self.add("<defs>");
        for ([_][]const u8{ "inheritance", "composition", "aggregation", "open", "lollipop", "exactly_one", "zero_one", "one_many", "zero_many", "contains", "md_parent" }) |kind| {
            const cardinality = std.mem.eql(u8, kind, "exactly_one") or std.mem.startsWith(u8, kind, "zero_") or std.mem.eql(u8, kind, "one_many");
            try self.fmt("<marker id=\"zm-{d}-{s}\" viewBox=\"0 0 18 12\" refX=\"{d}\" refY=\"6\" markerWidth=\"{d}\" markerHeight=\"{d}\" markerUnits=\"{s}\" orient=\"auto-start-reverse\" stroke=\"{s}\" fill=\"{s}\" stroke-width=\"1.2\">", .{ prefix, kind, if (cardinality) @as(usize, 17) else if (std.mem.eql(u8, kind, "lollipop") or std.mem.eql(u8, kind, "contains")) @as(usize, 21) else 17, @as(usize, 18), @as(usize, 12), "userSpaceOnUse", fg, bg });
            if (std.mem.eql(u8, kind, "inheritance")) try self.add("<path d=\"M 1 1 L 17 6 L 1 11 Z\"/>") else if (std.mem.eql(u8, kind, "composition") or std.mem.eql(u8, kind, "aggregation")) try self.fmt("<path d=\"M 1 6 L 9 1 L 17 6 L 9 11 Z\" fill=\"{s}\"/>", .{if (std.mem.eql(u8, kind, "composition")) fg else bg}) else if (std.mem.eql(u8, kind, "open")) try self.add("<path d=\"M 8 1 L 17 6 L 8 11\" fill=\"none\"/>") else if (std.mem.eql(u8, kind, "lollipop")) try self.add("<circle cx=\"11\" cy=\"6\" r=\"5\"/>") else {
                if (std.mem.eql(u8, kind, "md_parent")) {
                    try self.add("<path d=\"M 1 6 L 9 1 L 17 6 L 9 11 Z\"/>");
                    try self.add("</marker>");
                    continue;
                }
                if (std.mem.eql(u8, kind, "contains")) {
                    try self.add("<circle cx=\"11\" cy=\"6\" r=\"5\"/><path d=\"M 7 6 H 15 M 11 2 V 10\"/>");
                    try self.add("</marker>");
                    continue;
                }
                const many = std.mem.endsWith(u8, kind, "many");
                const zero = std.mem.startsWith(u8, kind, "zero");
                if (many) try self.add("<path d=\"M 17 1 L 7 6 L 17 11 M 7 6 H 17\" fill=\"none\"/>") else if (zero) try self.add("<path d=\"M 15 1 V 11\"/>") else try self.add("<path d=\"M 11 1 V 11\"/>");
                if (zero) try self.add("<circle cx=\"4\" cy=\"6\" r=\"3\"/>") else if (many) try self.add("<path d=\"M 4 1 V 11\"/>") else try self.add("<path d=\"M 7 1 V 11\"/>");
            }
            try self.add("</marker>");
        }
        try self.add("</defs>");
    }
    pub fn sequenceMarkers(self: *Svg, prefix: u32) !void {
        const fg = if (self.theme == .dark) "#e0e0e0" else "#24292f";
        try self.add("<defs>");
        for ([_][]const u8{ "arrow", "cross", "open", "top", "bottom", "stick_top", "stick_bottom" }) |kind| {
            try self.fmt("<marker id=\"zm-{d}-seq-{s}\" viewBox=\"0 0 10 10\" refX=\"{d}\" refY=\"5\" markerWidth=\"10\" markerHeight=\"10\" markerUnits=\"userSpaceOnUse\" orient=\"auto-start-reverse\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"1.5\">", .{ prefix, kind, if (std.mem.eql(u8, kind, "cross") or std.mem.eql(u8, kind, "circle")) @as(usize, 15) else 9, fg, fg });
            if (std.mem.eql(u8, kind, "arrow")) try self.add("<path d=\"M 1 1 L 9 5 L 1 9 z\"/>") else if (std.mem.eql(u8, kind, "cross")) try self.add("<path d=\"M 1 1 L 9 9 M 1 9 L 9 1\" fill=\"none\"/>") else if (std.mem.eql(u8, kind, "top")) try self.add("<path d=\"M 1 1 L 9 5 H 1 Z\"/>") else if (std.mem.eql(u8, kind, "bottom")) try self.add("<path d=\"M 1 9 L 9 5 H 1 Z\"/>") else if (std.mem.eql(u8, kind, "stick_top")) try self.add("<path d=\"M 1 1 L 9 5\" fill=\"none\"/>") else if (std.mem.eql(u8, kind, "stick_bottom")) try self.add("<path d=\"M 1 9 L 9 5\" fill=\"none\"/>") else try self.add("<path d=\"M 1 1 L 9 5 L 1 9\" fill=\"none\"/>");
            try self.add("</marker>");
        }
        try self.add("</defs>");
    }
    pub fn text(self: *Svg, x: usize, y: usize, label: []const u8) !void {
        const fg = if (self.theme == .dark) "#e0e0e0" else "#24292f";
        try self.textColor(x, y, label, fg);
    }
    pub fn textColor(self: *Svg, x: usize, y: usize, label: []const u8, fg: []const u8) !void {
        try self.textSource(x, y, label, fg, "");
    }
    pub fn textSource(self: *Svg, x: usize, y: usize, label: []const u8, fg: []const u8, source_id: []const u8) !void {
        try self.fmt("<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-family=\"Arial,Helvetica,sans-serif\" font-size=\"14\" fill=\"", .{ x, y });
        try self.escape(fg);
        try self.add("\" stroke=\"none\"");
        if (source_id.len > 0) {
            try self.add(" data-source-id=\"");
            try self.escape(source_id);
            try self.add("\"");
        }
        try self.add(">");
        try self.escape(label);
        try self.add("</text>");
    }
    pub fn finish(self: *Svg) ![]u8 {
        try self.add("</g></svg>");
        return self.bytes.toOwnedSlice(self.allocator);
    }
};
pub fn textWidth(text: []const u8) usize {
    // Conservative deterministic measurement. The rendered face is
    // proportional, but this stable upper bound keeps layout independent of
    // whichever compatible system font the host selects.
    var width: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) width += if (byte >= 0xe0) 16 else 9;
    }
    return width;
}
