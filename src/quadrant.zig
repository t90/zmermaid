const std = @import("std");
const svg = @import("svg.zig");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const data = @import("chart_data.zig");
const styles = @import("chart_style.zig");
const ct = @import("chart_text.zig");
const Point = struct { label: []const u8, x: f64, y: f64, class: []const u8, style: styles.Style };
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var title: []const u8 = "";
    var quadrants = [_][]const u8{""} ** 4;
    var axes = [_][]const u8{""} ** 4;
    var points: std.ArrayList(Point) = .empty;
    var classes: std.ArrayList(styles.Class) = .empty;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (txt.starts(line, "title ")) {
            title = try data.label(temp, line[6..]);
            continue;
        }
        if (txt.starts(line, "classDef ")) {
            if (classes.items.len == 128) return error.LimitExceeded;
            try classes.append(temp, try styles.class(line[9..], true));
            continue;
        }
        if (txt.starts(line, "x-axis ") or txt.starts(line, "y-axis ")) {
            const index: usize = if (line[0] == 'x') 0 else 2;
            const rest = line[7..];
            const arrow = std.mem.indexOf(u8, rest, "-->");
            axes[index] = try data.label(temp, rest[0 .. arrow orelse rest.len]);
            if (arrow) |at| axes[index + 1] = try data.label(temp, rest[at + 3 ..]);
            continue;
        }
        if (txt.starts(line, "quadrant-")) {
            if (line.len < 11 or line[9] < '1' or line[9] > '4' or line[10] != ' ') return error.InvalidSyntax;
            quadrants[line[9] - '1'] = try data.label(temp, line[11..]);
            continue;
        }
        const open = std.mem.indexOfScalar(u8, line, '[') orelse return error.UnsupportedSyntax;
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, ']') orelse return error.InvalidSyntax;
        const head = d.trim(line[0..open]);
        if (head.len == 0 or head[head.len - 1] != ':') return error.InvalidSyntax;
        const name = d.trim(head[0 .. head.len - 1]);
        const cls = std.mem.indexOf(u8, name, ":::");
        const coords = try data.values(temp, line[open + 1 .. close]);
        if (coords.len != 2 or coords[0].label.len > 0 or coords[1].label.len > 0) return error.InvalidSyntax;
        if (coords[0].value < 0 or coords[0].value > 1 or coords[1].value < 0 or coords[1].value > 1) return error.InvalidSyntax;
        if (points.items.len == 512) return error.LimitExceeded;
        try points.append(temp, .{ .label = try data.label(temp, name[0 .. cls orelse name.len]), .class = if (cls) |at| d.trim(name[at + 3 ..]) else "", .x = coords[0].value, .y = coords[1].value, .style = try styles.parse(line[close + 1 ..], true) });
    }
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const title_text: ct.Text = .{ .size = try doc.num("config.quadrantChart.titleFontSize", 20, 1, 256), .color = try ct.color(doc, "config.themeVariables.quadrantTitleFill", fg) };
    var quadrant_text: ct.Text = .{ .size = try doc.num("config.quadrantChart.quadrantLabelFontSize", 16, 1, 256), .color = fg };
    const x_text: ct.Text = .{ .size = try doc.num("config.quadrantChart.xAxisLabelFontSize", 16, 1, 256), .color = try ct.color(doc, "config.themeVariables.quadrantXAxisTextFill", fg) };
    const y_text: ct.Text = .{ .size = try doc.num("config.quadrantChart.yAxisLabelFontSize", 16, 1, 256), .color = try ct.color(doc, "config.themeVariables.quadrantYAxisTextFill", fg) };
    const point_text: ct.Text = .{ .size = try doc.num("config.quadrantChart.pointLabelFontSize", 12, 1, 256), .color = try ct.color(doc, "config.themeVariables.quadrantPointTextFill", fg) };
    const point_fill = try ct.color(doc, "config.themeVariables.quadrantPointFill", fg);
    const internal_fill = try ct.color(doc, "config.themeVariables.quadrantInternalBorderStrokeFill", fg);
    const external_fill = try ct.color(doc, "config.themeVariables.quadrantExternalBorderStrokeFill", fg);
    const internal_width = try doc.num("config.quadrantChart.quadrantInternalBorderStrokeWidth", 1, 0, 100);
    const external_width = try doc.num("config.quadrantChart.quadrantExternalBorderStrokeWidth", 2, 0, 100);
    const title_padding = try doc.num("config.quadrantChart.titlePadding", 10, 0, 1000);
    const padding = try doc.num("config.quadrantChart.quadrantPadding", 5, 0, 1000);
    const qtop = try doc.num("config.quadrantChart.quadrantTextTopPadding", 5, 0, 1000);
    const xpadding = try doc.num("config.quadrantChart.xAxisLabelPadding", 5, 0, 1000);
    const ypadding = try doc.num("config.quadrantChart.yAxisLabelPadding", 5, 0, 1000);
    const point_padding = try doc.num("config.quadrantChart.pointTextPadding", 5, 0, 1000);
    const point_radius = try doc.num("config.quadrantChart.pointRadius", 5, 0, 100);
    const xpos = doc.get("config.quadrantChart.xAxisPosition") orelse "top";
    const ypos = doc.get("config.quadrantChart.yAxisPosition") orelse "left";
    if (!std.mem.eql(u8, xpos, "top") and !std.mem.eql(u8, xpos, "bottom")) return error.InvalidSyntax;
    if (!std.mem.eql(u8, ypos, "left") and !std.mem.eql(u8, ypos, "right")) return error.InvalidSyntax;
    const xbottom = points.items.len > 0 or std.mem.eql(u8, xpos, "bottom");
    const yright = std.mem.eql(u8, ypos, "right");
    var cw = try doc.num("config.quadrantChart.chartWidth", 500, 100, 10000);
    var ch = try doc.num("config.quadrantChart.chartHeight", 500, 100, 10000);
    var label_height: usize = 20;
    for (quadrants) |q| {
        cw = @max(cw, quadrant_text.width(q) * 2 + padding * 4 + 40);
        label_height = @max(label_height, data.coord(quadrant_text.height(q)));
    }
    ch = @max(ch, @as(f64, @floatFromInt(label_height * 4 + 120)));
    ch = @max(ch, (qtop + @as(f64, @floatFromInt(label_height)) + padding) * 4);
    const yspace = @max(y_text.height(axes[2]), y_text.height(axes[3])) + ypadding + 20;
    const xspace = @max(x_text.height(axes[0]), x_text.height(axes[1])) + xpadding + 20;
    const left: usize = data.coord(@max(40, yspace));
    const top = data.coord((if (title.len > 0) title_text.height(title) + 2 * title_padding else 20) + xspace);
    var width = @max(left + data.coord(cw + yspace), data.coord(title_text.width(title)) + 40);
    for (points.items) |point| width = @max(width, data.coord(point_text.width(point.label)) + 40);
    const height = top + data.coord(ch + @max(xspace, point_text.size * 2 + point_radius + point_padding + 20));
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "quadrant", prefix);
    if (title.len > 0) try title_text.draw(&out, @as(f64, @floatFromInt(width)) / 2, title_padding, title);
    const lx: f64 = @floatFromInt(left);
    const ty: f64 = @floatFromInt(top);
    for (quadrants, 0..) |q, i| {
        var buf: [80]u8 = undefined;
        const fill_key = std.fmt.bufPrint(&buf, "config.themeVariables.quadrant{d}Fill", .{i + 1}) catch return error.LimitExceeded;
        const fill = if (doc.get(fill_key)) |c| try d.color(c) else try doc.palette(i);
        const text_key = std.fmt.bufPrint(&buf, "config.themeVariables.quadrant{d}TextFill", .{i + 1}) catch return error.LimitExceeded;
        const text_color = if (doc.get(text_key)) |c| try d.color(c) else fg;
        const x = lx + if (i == 0 or i == 3) cw / 2 else 0;
        const y = ty + if (i >= 2) ch / 2 else 0;
        try out.fmt("<rect data-quadrant=\"{d}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\"/>", .{ i + 1, x, y, cw / 2, ch / 2, fill });
        quadrant_text.color = text_color;
        try quadrant_text.draw(&out, x + cw / 4, y + qtop + padding, q);
    }
    try out.fmt("<path data-quadrant-border=\"internal\" d=\"M {d:.2} {d:.2} V {d:.2} M {d:.2} {d:.2} H {d:.2}\" stroke=\"{s}\" stroke-width=\"{d}\" fill=\"none\"/>", .{ lx + cw / 2, ty, ty + ch, lx, ty + ch / 2, lx + cw, internal_fill, internal_width });
    try out.fmt("<rect data-quadrant-border=\"external\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" stroke=\"{s}\" stroke-width=\"{d}\" fill=\"none\"/>", .{ lx, ty, cw, ch, external_fill, external_width });
    try out.fmt("<g data-x-axis=\"{s}\">", .{if (xbottom) "bottom" else "top"});
    const xy = if (xbottom) ty + ch + xpadding else ty - xspace + 10;
    try x_text.draw(&out, lx + cw / 4, xy, axes[0]);
    try x_text.draw(&out, lx + cw * 0.75, xy, axes[1]);
    try out.add("</g>");
    for (2..4) |i| {
        try out.fmt("<g data-y-axis=\"{s}\" transform=\"translate({d:.2} {d:.2}) rotate(-90)\">", .{ if (yright) "right" else "left", if (yright) lx + cw + ypadding + 10 else lx - yspace + 10, ty + ch * if (i == 2) @as(f64, 0.75) else 0.25 });
        try y_text.draw(&out, 0, 0, axes[i]);
        try out.add("</g>");
    }
    for (points.items, 0..) |point, i| {
        var style: styles.Style = .{};
        if (point.class.len > 0) {
            var found = false;
            for (classes.items) |cls| if (std.mem.eql(u8, cls.name, point.class)) {
                style.merge(cls.style);
                found = true;
            };
            if (!found) return error.InvalidSyntax;
        }
        style.merge(point.style);
        const px = lx + point.x * cw;
        const py = ty + (1 - point.y) * ch;
        const radius = style.radius orelse point_radius;
        try out.fmt("<circle data-point=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d}\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ i, point.x, point.y, px, py, radius, style.fill orelse point_fill, style.stroke orelse point_fill, style.width orelse 1 });
        const text_x = std.math.clamp(px, point_text.width(point.label) / 2 + 10, @as(f64, @floatFromInt(width)) - point_text.width(point.label) / 2 - 10);
        try point_text.draw(&out, text_x, py + radius + point_padding, point.label);
    }
    return out.finish();
}
