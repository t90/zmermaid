const std = @import("std");
const svg = @import("svg.zig");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const data = @import("chart_data.zig");
const ct = @import("chart_text.zig");
const AxisStyle = struct {
    label: ct.Text,
    title: ct.Text,
    show_label: bool,
    show_title: bool,
    show_tick: bool,
    show_line: bool,
    label_padding: f64,
    title_padding: f64,
    tick_length: f64,
    tick_width: f64,
    line_width: f64,
    tick_color: []const u8,
    line_color: []const u8,
    fn read(doc: *d.Document, comptime name: []const u8, fg: []const u8) d.Error!AxisStyle {
        const key = "config.xyChart." ++ name ++ ".";
        const theme_key = "config.themeVariables.xyChart." ++ name;
        return .{
            .label = .{ .size = try doc.num(key ++ "labelFontSize", 14, 1, 256), .color = try ct.color(doc, theme_key ++ "LabelColor", fg) },
            .title = .{ .size = try doc.num(key ++ "titleFontSize", 14, 1, 256), .color = try ct.color(doc, theme_key ++ "TitleColor", fg) },
            .show_label = try doc.flag(key ++ "showLabel", true), .show_title = try doc.flag(key ++ "showTitle", true),
            .show_tick = try doc.flag(key ++ "showTick", true), .show_line = try doc.flag(key ++ "showAxisLine", true),
            .label_padding = try doc.num(key ++ "labelPadding", 5, 0, 1000), .title_padding = try doc.num(key ++ "titlePadding", 5, 0, 1000),
            .tick_length = try doc.num(key ++ "tickLength", 5, 0, 100), .tick_width = try doc.num(key ++ "tickWidth", 1, 0, 100),
            .line_width = try doc.num(key ++ "axisLineWidth", 1, 0, 100),
            .tick_color = try ct.color(doc, theme_key ++ "TickColor", fg), .line_color = try ct.color(doc, theme_key ++ "LineColor", fg),
        };
    }
    fn fit(self: *AxisStyle, space: f64, label_extent: f64, has_title: bool) f64 {
        var used: f64 = 0;
        if (self.show_line and used + self.line_width <= space) used += self.line_width else self.show_line = false;
        if (self.show_tick and used + self.tick_length <= space) used += self.tick_length else self.show_tick = false;
        if (self.show_label and used + label_extent + self.label_padding <= space) used += label_extent + self.label_padding else self.show_label = false;
        if (self.show_title and has_title and used + self.title.height("X") + self.title_padding <= space) used += self.title.height("X") + self.title_padding else self.show_title = false;
        return used;
    }
    fn tick(self: AxisStyle, out: *svg.Svg, x: f64, y: f64, bottom: bool, value: []const u8) d.Error!void {
        if (self.show_tick) try out.fmt("<path data-axis-tick=\"true\" d=\"M {d:.2} {d:.2} {s} {d:.2}\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ x, y, if (bottom) "v" else "h", if (bottom) self.tick_length else -self.tick_length, self.tick_color, self.tick_width });
        if (self.show_label) {
            const offset = (if (self.show_tick) self.tick_length else 0) + self.label_padding;
            try self.label.draw(out, if (bottom) x else x - offset - self.label.width(value) / 2, if (bottom) y + offset else y - self.label.height(value) / 2, value);
        }
    }
};
const Axis = struct { title: []const u8 = "", min: ?f64 = null, max: ?f64 = null, bands: std.ArrayList([]const u8) = .empty };
const Series = struct { bar: bool, title: []const u8, points: []data.Point };
fn axis(a: std.mem.Allocator, raw: []const u8, categorical: bool) d.Error!Axis {
    var result: Axis = .{};
    var rest = d.trim(raw);
    if (rest.len == 0) return error.InvalidSyntax;
    if (rest[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.InvalidSyntax;
        result.title = try data.label(a, rest[0 .. end + 1]);
        rest = d.trim(rest[end + 1 ..]);
    }
    if (rest.len == 0) return result;
    if (std.mem.indexOfScalar(u8, rest, '[')) |start| {
        if (!categorical or rest[rest.len - 1] != ']') return error.InvalidSyntax;
        if (start > 0) result.title = try data.label(a, rest[0..start]);
        var parts: data.Parts = .{ .rest = rest[start + 1 .. rest.len - 1] };
        while (try parts.next()) |part| {
            if (result.bands.items.len == 1024) return error.LimitExceeded;
            try result.bands.append(a, try data.label(a, part));
        }
        if (result.bands.items.len == 0) return error.InvalidSyntax;
    } else if (std.mem.indexOf(u8, rest, "-->")) |arrow| {
        result.min = try d.number(rest[0..arrow]);
        result.max = try d.number(rest[arrow + 3 ..]);
        if (result.max.? <= result.min.?) return error.InvalidSyntax;
    } else result.title = try data.label(a, rest);
    return result;
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var series: std.ArrayList(Series) = .empty;
    var xaxis: Axis = .{};
    var yaxis: Axis = .{};
    var title: []const u8 = "";
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    var header = std.mem.tokenizeAny(u8, d.trim(lines.next().?), " \t");
    _ = header.next();
    const orientation = header.next() orelse doc.get("config.xyChart.chartOrientation") orelse "vertical";
    if (doc.get("config.xyChart.chartOrientation")) |value| if (!std.mem.eql(u8, value, "vertical") and !std.mem.eql(u8, value, "horizontal")) return error.InvalidSyntax;
    if (header.next() != null or (!std.mem.eql(u8, orientation, "vertical") and !std.mem.eql(u8, orientation, "horizontal"))) return error.InvalidSyntax;
    const horizontal = std.mem.eql(u8, orientation, "horizontal");
    var count: usize = 0;
    var bar_count: usize = 0;
    var low: f64 = 0;
    var high: f64 = 0;
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (txt.starts(line, "title ")) {
            title = try data.label(temp, line[6..]);
            continue;
        }
        if (txt.starts(line, "x-axis ")) {
            xaxis = try axis(temp, line[7..], true);
            continue;
        }
        if (txt.starts(line, "y-axis ")) {
            yaxis = try axis(temp, line[7..], false);
            continue;
        }
        const bar = txt.starts(line, "bar ");
        if (!bar and !txt.starts(line, "line ")) return error.UnsupportedSyntax;
        const rest = d.trim(line[if (bar) @as(usize, 4) else 5..]);
        const open = std.mem.indexOfScalar(u8, rest, '[') orelse return error.InvalidSyntax;
        if (rest[rest.len - 1] != ']') return error.InvalidSyntax;
        const points = try data.values(temp, rest[open + 1 .. rest.len - 1]);
        if (count != 0 and count != points.len) return error.InvalidSyntax;
        count = points.len;
        for (points) |point| {
            low = @min(low, point.value);
            high = @max(high, point.value);
        }
        if (series.items.len == 64) return error.LimitExceeded;
        try series.append(temp, .{ .bar = bar, .title = try data.label(temp, rest[0..open]), .points = points });
        if (bar) bar_count += 1;
    }
    if (count == 0) return error.InvalidSyntax;
    if (xaxis.bands.items.len != 0 and xaxis.bands.items.len != count) return error.InvalidSyntax;
    low = yaxis.min orelse low;
    high = yaxis.max orelse if (high == low) low + 1 else high;
    const show_values = try doc.flag("config.xyChart.showDataLabel", false);
    const outside = try doc.flag("config.xyChart.showDataLabelOutsideBar", false);
    var palette: std.ArrayList([]const u8) = .empty;
    if (doc.get("config.themeVariables.xyChart.plotColorPalette")) |raw| {
        var colors: data.Parts = .{ .rest = raw };
        while (try colors.next()) |c| try palette.append(temp, try d.color(c));
        if (palette.items.len == 0) return error.InvalidSyntax;
    }
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const title_style: ct.Text = .{ .size = try doc.num("config.xyChart.titleFontSize", 20, 1, 256), .color = try ct.color(doc, "config.themeVariables.xyChart.titleColor", fg) };
    const data_style: ct.Text = .{ .color = try ct.color(doc, "config.themeVariables.xyChart.dataLabelColor", fg) };
    const background = try ct.color(doc, "config.themeVariables.xyChart.backgroundColor", if (doc.theme == .dark) "#0d1117" else "#ffffff");
    const title_padding = try doc.num("config.xyChart.titlePadding", 10, 0, 1000);
    const reserve = try doc.num("config.xyChart.plotReservedSpacePercent", 50, 0, 100) / 100;
    const plot_border = try doc.num("config.xyChart.plotBorderWidth", 0, 0, 100);
    var xs = try AxisStyle.read(doc, "xAxis", fg);
    var ys = try AxisStyle.read(doc, "yAxis", fg);
    var label_w: f64 = 30;
    var label_h: f64 = 20;
    for (xaxis.bands.items) |label| {
        label_w = @max(label_w, xs.label.width(label));
        label_h = @max(label_h, xs.label.height(label));
    }
    var tick_w: f64 = 0;
    for (0..6) |i| tick_w = @max(tick_w, ys.label.width(try data.format(temp, low + (high - low) * @as(f64, @floatFromInt(i)) / 5)));
    const width = try data.integer(try doc.num("config.xyChart.width", 800, 1, 20000));
    const height = try data.integer(try doc.num("config.xyChart.height", 500, 1, 20000));
    const wf: f64 = @floatFromInt(width);
    const hf: f64 = @floatFromInt(height);
    const bottom_style = if (horizontal) &ys else &xs;
    const side_style = if (horizontal) &xs else &ys;
    const bottom_title = if (horizontal) yaxis.title else xaxis.title;
    const side_title = if (horizontal) xaxis.title else yaxis.title;
    const top_space = if (title.len > 0 and title_style.height(title) + title_padding * 2 < hf * (1 - reserve)) title_style.height(title) + title_padding * 2 else 0;
    const bottom_space = bottom_style.fit(hf * (1 - reserve) - top_space, if (horizontal) ys.label.height("X") else label_h, bottom_title.len > 0);
    const left_space = side_style.fit(wf * (1 - reserve), if (horizontal) label_w else tick_w, side_title.len > 0);
    const left = data.coord(@ceil(left_space));
    const top = data.coord(@ceil(@max(top_space, if (!horizontal and ys.show_label) ys.label.height("X") / 2 else 0)));
    const bottom = data.coord(@ceil(bottom_space));
    const right_space = if (horizontal and ys.show_label) tick_w / 2 else 0;
    const pw: f64 = @floatFromInt(@max(width -| left -| data.coord(@ceil(right_space)), 1));
    const ph: f64 = @floatFromInt(@max(height -| top -| bottom, 1));
    const step = (if (horizontal) ph else pw) / @as(f64, @floatFromInt(count));
    var legend_height: usize = 0;
    for (series.items) |s| if (s.title.len > 0) {
        legend_height += txt.height(s.title) + 12;
    };
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height + legend_height, "xychart", prefix);
    try out.fmt("<rect width=\"100%\" height=\"100%\" fill=\"{s}\" stroke=\"none\"/>", .{background});
    if (top_space > 0) try title_style.draw(&out, wf / 2, title_padding, title);
    const lx: f64 = @floatFromInt(left);
    const ty: f64 = @floatFromInt(top);
    for (0..6) |i| {
        const f = @as(f64, @floatFromInt(i)) / 5;
        const pos = if (horizontal) lx + f * pw else ty + (1 - f) * ph;
        const value = try data.format(temp, low + f * (high - low));
        try ys.tick(&out, if (horizontal) pos else lx, if (horizontal) ty + ph else pos, horizontal, value);
    }
    for (0..count) |i| {
        const label = if (xaxis.bands.items.len > 0) xaxis.bands.items[i] else try data.format(temp, (xaxis.min orelse 0) + ((xaxis.max orelse @as(f64, @floatFromInt(count - 1))) - (xaxis.min orelse 0)) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(count - 1, 1))));
        const pos = (@as(f64, @floatFromInt(i)) + 0.5) * step;
        try xs.tick(&out, if (horizontal) lx else lx + pos, if (horizontal) ty + pos else ty + ph, !horizontal, label);
    }
    if (bottom_style.show_line) try out.fmt("<path data-axis-line=\"bottom\" d=\"M {d:.2} {d:.2} H {d:.2}\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ lx, ty + ph, lx + pw, bottom_style.line_color, bottom_style.line_width });
    if (side_style.show_line) try out.fmt("<path data-axis-line=\"left\" d=\"M {d:.2} {d:.2} V {d:.2}\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ lx, ty, ty + ph, side_style.line_color, side_style.line_width });
    if (plot_border > 0) try out.fmt("<rect data-plot-border=\"true\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ lx, ty, pw, ph, fg, plot_border });
    const baseline = std.math.clamp((0 - low) / (high - low), 0, 1);
    // Series outside an explicit axis range are clipped to the plot, not rescaled.
    try out.fmt("<defs><clipPath id=\"zm-{d}-plot\"><rect x=\"{d}\" y=\"{d}\" width=\"{d:.2}\" height=\"{d:.2}\"/></clipPath></defs>", .{ prefix, left, top, pw, ph });
    var bar_index: usize = 0;
    var legend_y = height + 10;
    for (series.items, 0..) |s, si| {
        const color = if (palette.items.len > 0) palette.items[si % palette.items.len] else try doc.palette(si);
        try out.fmt("<g data-series=\"{d}\" clip-path=\"url(#zm-{d}-plot)\" fill=\"{s}\" stroke=\"{s}\">", .{ si, prefix, color, color });
        if (!s.bar) {
            try out.add("<path fill=\"none\" stroke-width=\"2.5\" d=\"");
            for (s.points, 0..) |p, i| {
                const cat = (@as(f64, @floatFromInt(i)) + 0.5) * step;
                const val = (p.value - low) / (high - low);
                try out.fmt("{s} {d:.2} {d:.2} ", .{ if (i == 0) "M" else "L", lx + if (horizontal) val * pw else cat, ty + if (horizontal) cat else (1 - val) * ph });
            }
            try out.add("\"/>");
        }
        for (s.points, 0..) |p, i| {
            const cat = (@as(f64, @floatFromInt(i)) + 0.5) * step;
            const val = (p.value - low) / (high - low);
            const x = lx + if (horizontal) val * pw else cat;
            const y = ty + if (horizontal) cat else (1 - val) * ph;
            if (s.bar) {
                const bw = step * 0.7 / @as(f64, @floatFromInt(bar_count));
                const bc = cat - step * 0.35 + @as(f64, @floatFromInt(bar_index)) * bw;
                try out.fmt("<rect data-point=\"{d}\" data-value=\"{d}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>", .{ i, p.value, lx + if (horizontal) @min(val, baseline) * pw else bc, ty + if (horizontal) bc else (1 - @max(val, baseline)) * ph, if (horizontal) @abs(val - baseline) * pw else bw, if (horizontal) bw else @abs(val - baseline) * ph });
            } else try out.fmt("<circle data-point=\"{d}\" data-value=\"{d}\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"3\"/>", .{ i, p.value, x, y });
        }
        try out.add("</g>");
        for (s.points, 0..) |p, i| {
            if (p.label.len == 0 and !show_values) continue;
            if (p.value < low or p.value > high) continue;
            var cat = (@as(f64, @floatFromInt(i)) + 0.5) * step;
            if (s.bar) cat += -step * 0.35 + (@as(f64, @floatFromInt(bar_index)) + 0.5) * step * 0.7 / @as(f64, @floatFromInt(bar_count));
            const val = (p.value - low) / (high - low);
            const label = if (p.label.len > 0) p.label else try data.format(temp, p.value);
            const label_x = lx + if (horizontal) val * pw + (if (s.bar and !outside) @as(f64, -20) else 20) else cat;
            const label_y = ty + if (horizontal) cat else (1 - val) * ph + (if (s.bar and !outside) @as(f64, 16) else -16);
            try data_style.draw(&out, std.math.clamp(label_x, data_style.width(label) / 2, @max(data_style.width(label) / 2, wf - data_style.width(label) / 2)), std.math.clamp(label_y - 10, 0, @max(0, hf - data_style.height(label))), label);
        }
        if (s.bar) bar_index += 1;
        if (s.title.len > 0) {
            try out.fmt("<rect x=\"30\" y=\"{d}\" width=\"18\" height=\"18\" fill=\"{s}\"/>", .{ legend_y, color });
            try txt.draw(&out, 60 + txt.width(s.title) / 2, legend_y, s.title);
            legend_y += txt.height(s.title) + 12;
        }
    }
    if (bottom_style.show_title) try bottom_style.title.draw(&out, lx + pw / 2, hf - bottom_style.title.height(bottom_title), bottom_title);
    if (side_style.show_title) {
        try out.fmt("<g transform=\"translate(18 {d}) rotate(-90)\">", .{top + data.coord(ph / 2)});
        try side_style.title.draw(&out, 0, -side_style.title.height(side_title) / 2, side_title);
        try out.add("</g>");
    }
    return out.finish();
}
