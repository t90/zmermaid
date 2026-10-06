const std = @import("std");
const svg = @import("svg.zig");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const data = @import("chart_data.zig");
const ct = @import("chart_text.zig");
const Name = struct { id: []const u8, label: []const u8 };
const Curve = struct { name: Name, raw: []const u8, values: []f64 = &.{} };
const Cursor = struct {
    rest: []const u8,
    fn spaces(self: *Cursor) void {
        self.rest = std.mem.trimStart(u8, self.rest, " \t\r");
    }
    fn token(self: *Cursor) d.Error![]const u8 {
        self.spaces();
        const end = std.mem.indexOfAny(u8, self.rest, " \t\r\n,[]{}:") orelse self.rest.len;
        if (end == 0) return error.InvalidSyntax;
        const result = self.rest[0..end];
        self.rest = self.rest[end..];
        return result;
    }
    fn enclosed(self: *Cursor, open: u8, close: u8) d.Error![]const u8 {
        self.spaces();
        if (self.rest.len == 0 or self.rest[0] != open) return error.InvalidSyntax;
        var quoted = false;
        for (self.rest[1..], 1..) |c, i| {
            if (c == '"') quoted = !quoted;
            if (c == close and !quoted) {
                const result = self.rest[1..i];
                self.rest = self.rest[i + 1 ..];
                return result;
            }
        }
        return error.InvalidSyntax;
    }
    fn name(self: *Cursor, a: std.mem.Allocator) d.Error!Name {
        const id = try self.token();
        self.spaces();
        return .{ .id = id, .label = if (txt.starts(self.rest, "[")) try data.label(a, try self.enclosed('[', ']')) else try data.label(a, id) };
    }
};
const Pos = struct { x: f64, y: f64 };
fn polar(cx: f64, cy: f64, r: f64, i: usize, n: usize) Pos {
    const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) - std.math.pi / 2.0;
    return .{ .x = cx + r * @cos(angle), .y = cy + r * @sin(angle) };
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var cursor: Cursor = .{ .rest = doc.source };
    _ = try cursor.token();
    cursor.spaces();
    if (txt.starts(cursor.rest, ":")) cursor.rest = cursor.rest[1..];
    var axes: std.ArrayList(Name) = .empty;
    var curves: std.ArrayList(Curve) = .empty;
    var title: []const u8 = "";
    var min: f64 = 0;
    var max: ?f64 = null;
    var ticks: usize = 5;
    var legend = true;
    var polygon = false;
    while (true) {
        cursor.rest = std.mem.trimStart(u8, cursor.rest, " \t\r\n,");
        if (cursor.rest.len == 0) break;
        if (txt.starts(cursor.rest, "%%")) {
            cursor.rest = cursor.rest[std.mem.indexOfScalar(u8, cursor.rest, '\n') orelse cursor.rest.len ..];
            continue;
        }
        const command = try cursor.token();
        if (std.mem.eql(u8, command, "title")) {
            const end = std.mem.indexOfScalar(u8, cursor.rest, '\n') orelse cursor.rest.len;
            title = try data.label(temp, cursor.rest[0..end]);
            cursor.rest = cursor.rest[end..];
        } else if (std.mem.eql(u8, command, "axis") or std.mem.eql(u8, command, "curve")) {
            const is_axis = std.mem.eql(u8, command, "axis");
            while (true) {
                const name = try cursor.name(temp);
                if (is_axis) {
                    if (axes.items.len == 64) return error.LimitExceeded;
                    for (axes.items) |existing| if (std.mem.eql(u8, existing.id, name.id)) {
                        return error.InvalidSyntax;
                    };
                    try axes.append(temp, name);
                } else {
                    if (curves.items.len == 64) return error.LimitExceeded;
                    try curves.append(temp, .{ .name = name, .raw = try cursor.enclosed('{', '}') });
                }
                cursor.spaces();
                if (!txt.starts(cursor.rest, ",")) break;
                cursor.rest = cursor.rest[1..];
            }
        } else {
            const value = try cursor.token();
            if (std.mem.eql(u8, command, "min")) min = try d.number(value) else if (std.mem.eql(u8, command, "max")) max = try d.number(value) else if (std.mem.eql(u8, command, "ticks")) {
                ticks = try data.integer(try d.number(value));
                if (ticks == 0 or ticks > 32) return error.LimitExceeded;
            } else if (std.mem.eql(u8, command, "showLegend")) {
                if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.InvalidSyntax;
                legend = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, command, "graticule")) {
                if (!std.mem.eql(u8, value, "circle") and !std.mem.eql(u8, value, "polygon")) return error.InvalidSyntax;
                polygon = std.mem.eql(u8, value, "polygon");
            } else return error.UnsupportedSyntax;
        }
    }
    if (axes.items.len < 3 or curves.items.len == 0) return error.InvalidSyntax;
    var actual_max = min;
    for (curves.items) |*curve| {
        curve.values = try temp.alloc(f64, axes.items.len);
        var seen = [_]bool{false} ** 64;
        var parts: data.Parts = .{ .rest = curve.raw };
        var index: usize = 0;
        var named: ?bool = null;
        while (try parts.next()) |part| {
            var entry: Cursor = .{ .rest = part };
            const token = try entry.token();
            const is_named = d.trim(entry.rest).len > 0;
            if (named != null and named.? != is_named) return error.InvalidSyntax;
            named = is_named;
            var at = index;
            var value: f64 = undefined;
            if (is_named) {
                at = axes.items.len;
                for (axes.items, 0..) |axis, i| if (std.mem.eql(u8, axis.id, token)) {
                    at = i;
                };
                entry.spaces();
                if (txt.starts(entry.rest, ":")) entry.rest = entry.rest[1..];
                value = try d.number(entry.rest);
            } else value = try d.number(token);
            if (at >= axes.items.len or seen[at]) return error.InvalidSyntax;
            seen[at] = true;
            curve.values[at] = value;
            actual_max = @max(actual_max, value);
            index += 1;
        }
        if (index != axes.items.len) return error.InvalidSyntax;
    }
    const ceiling = max orelse if (actual_max == min) min + 1 else actual_max;
    if (ceiling <= min) return error.InvalidSyntax;
    const axis_scale = try doc.num("config.radar.axisScaleFactor", 1, 0, 4);
    const label_scale = try doc.num("config.radar.axisLabelFactor", 1.08, 1, 4);
    const tension = try doc.num("config.radar.curveTension", 0.17, 0, 1);
    const opacity = try doc.num("config.themeVariables.radar.curveOpacity", 0.15, 0, 1);
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const axis_color = try ct.color(doc, "config.themeVariables.radar.axisColor", fg);
    const grid_color = try ct.color(doc, "config.themeVariables.radar.graticuleColor", fg);
    const axis_width = try doc.num("config.themeVariables.radar.axisStrokeWidth", 1.5, 0, 100);
    const curve_width = try doc.num("config.themeVariables.radar.curveStrokeWidth", 2, 0, 100);
    const grid_width = try doc.num("config.themeVariables.radar.graticuleStrokeWidth", 1, 0, 100);
    const grid_opacity = try doc.num("config.themeVariables.radar.graticuleOpacity", 0, 0, 1);
    var title_size: f64 = 14;
    if (doc.get("config.themeVariables.fontSize")) |raw| {
        title_size = try d.number(if (std.mem.endsWith(u8, raw, "px")) raw[0 .. raw.len - 2] else raw);
        if (title_size < 1 or title_size > 256) return error.InvalidSyntax;
    }
    const title_style: ct.Text = .{ .size = title_size, .color = try ct.color(doc, "config.themeVariables.titleColor", fg) };
    const axis_style: ct.Text = .{ .size = try doc.num("config.themeVariables.radar.axisLabelFontSize", 14, 1, 256), .color = axis_color };
    const legend_style: ct.Text = .{ .size = try doc.num("config.themeVariables.radar.legendFontSize", 14, 1, 256), .color = fg };
    const margin_top = try doc.num("config.radar.marginTop", 50, 0, 2000);
    const margin_bottom = try doc.num("config.radar.marginBottom", 40, 0, 2000);
    const margin_left = try doc.num("config.radar.marginLeft", 40, 0, 2000);
    const margin_right = try doc.num("config.radar.marginRight", 40, 0, 2000);
    const w = try doc.num("config.radar.width", 400, 100, 10000);
    const h = try doc.num("config.radar.height", 400, 100, 10000);
    const radius = @min(w, h) / 2;
    var label_width: usize = 0;
    var label_height: usize = 0;
    for (axes.items) |axis| {
        label_width = @max(label_width, data.coord(axis_style.width(axis.label)));
        label_height = @max(label_height, data.coord(axis_style.height(axis.label)));
    }
    const extent = radius * @max(axis_scale, label_scale);
    var width = @max(data.coord(extent * 2 + margin_left + margin_right) + label_width * 2, data.coord(title_style.width(title)) + 40);
    if (legend) for (curves.items) |c| {
        width = @max(width, data.coord(legend_style.width(c.name.label)) + 90);
    };
    const top = data.coord(title_style.height(title) + margin_top) + label_height;
    const cx: f64 = (@as(f64, @floatFromInt(width)) + margin_left - margin_right) / 2;
    const cy: f64 = @as(f64, @floatFromInt(top)) + extent;
    var legend_height: usize = 0;
    if (legend) for (curves.items) |c| {
        legend_height += data.coord(legend_style.height(c.name.label)) + 12;
    };
    const chart_bottom = data.coord(cy + extent + margin_bottom) + label_height;
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, chart_bottom + legend_height + 20, "radar", prefix);
    if (title.len > 0) try title_style.draw(&out, @as(f64, @floatFromInt(width)) / 2, 12, title);
    try out.fmt("<g fill=\"{s}\" fill-opacity=\"{d}\" stroke=\"{s}\" stroke-width=\"{d}\">", .{ grid_color, grid_opacity, grid_color, grid_width });
    for (0..ticks) |i| {
        const r = radius * @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(ticks));
        if (polygon) {
            try out.add("<polygon data-grid=\"polygon\" points=\"");
            for (axes.items, 0..) |_, j| {
                const p = polar(cx, cy, r, j, axes.items.len);
                try out.fmt("{d:.2},{d:.2} ", .{ p.x, p.y });
            }
            try out.add("\"/>");
        } else try out.fmt("<circle data-grid=\"circle\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\"/>", .{ cx, cy, r });
    }
    try out.add("</g>");
    for (axes.items, 0..) |axis, i| {
        const p = polar(cx, cy, radius * axis_scale, i, axes.items.len);
        var lp = polar(cx, cy, radius * label_scale + 8, i, axes.items.len);
        if (lp.x > cx + 0.1) lp.x += axis_style.width(axis.label) / 2 else if (lp.x < cx - 0.1) lp.x -= axis_style.width(axis.label) / 2;
        if (lp.y > cy + 0.1) lp.y += axis_style.height(axis.label) / 2 else if (lp.y < cy - 0.1) lp.y -= axis_style.height(axis.label) / 2;
        try out.fmt("<path data-axis=\"{d}\" d=\"M {d:.2} {d:.2} L {d:.2} {d:.2}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ i, cx, cy, p.x, p.y, axis_color, axis_width });
        try axis_style.draw(&out, lp.x, lp.y - axis_style.height(axis.label) / 2, axis.label);
    }
    var legend_y = chart_bottom;
    for (curves.items, 0..) |curve, ci| {
        const color = try doc.palette(ci);
        var points: [64]Pos = undefined;
        for (curve.values, 0..) |value, i| points[i] = polar(cx, cy, radius * std.math.clamp((value - min) / (ceiling - min), 0, 1), i, axes.items.len);
        try out.fmt("<path data-curve=\"{d}\" fill=\"{s}\" fill-opacity=\"{d}\" stroke=\"{s}\" stroke-width=\"{d}\" d=\"M {d:.2} {d:.2} ", .{ ci, color, opacity, color, curve_width, points[0].x, points[0].y });
        const n = axes.items.len;
        for (0..n) |i| {
            const p = points[i];
            const next = points[(i + 1) % n];
            if (polygon) try out.fmt("L {d:.2} {d:.2} ", .{ next.x, next.y }) else {
                const prev = points[(i + n - 1) % n];
                const after = points[(i + 2) % n];
                try out.fmt("C {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} ", .{ p.x + (next.x - prev.x) * tension, p.y + (next.y - prev.y) * tension, next.x - (after.x - p.x) * tension, next.y - (after.y - p.y) * tension, next.x, next.y });
            }
        }
        try out.add("Z\"/>");
        for (curve.values, 0..) |value, i| try out.fmt("<circle data-curve-point=\"{d}\" data-axis=\"{d}\" data-value=\"{d}\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"3\" fill=\"{s}\" stroke=\"{s}\"/>", .{ ci, i, value, points[i].x, points[i].y, color, color });
        if (legend) {
            try out.fmt("<rect x=\"30\" y=\"{d}\" width=\"18\" height=\"18\" fill=\"{s}\"/>", .{ legend_y, color });
            try legend_style.draw(&out, 60 + legend_style.width(curve.name.label) / 2, @floatFromInt(legend_y), curve.name.label);
            legend_y += data.coord(legend_style.height(curve.name.label)) + 12;
        }
    }
    return out.finish();
}
