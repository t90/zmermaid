// Fractional SVG boundary. The font host's rows and glyph bounds are the
// rendering inputs; no text is re-wrapped or measured with byte counts.
const std = @import("std");
const svg = @import("svg.zig");
const shapes = @import("flow_shapes.zig");
const paint = @import("flow_paint.zig");
const measurement = @import("flow_measurement.zig");
const scene = @import("flow_scene.zig");
const Point = scene.Point;
fn distance(a: Point, b: Point) f64 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}
fn toward(a: Point, b: Point, amount: f64) Point {
    const length = distance(a, b);
    if (length < 1e-9) return a;
    return .{ .x = a.x + (b.x - a.x) * amount / length, .y = a.y + (b.y - a.y) * amount / length };
}
fn intersect(shape: shapes.Shape, b: scene.Box, p: Point) Point {
    const cx = b.x + b.width / 2;
    const cy = b.y + b.height / 2;
    const dx = p.x - cx;
    const dy = p.y - cy;
    var scale: f64 = 1;
    if (shape == .diamond) {
        scale = 1 / (@abs(dx) / (b.width / 2) + @abs(dy) / (b.height / 2));
        // question.ts calcIntersect adjusts the polygon hit by half a pixel.
        return .{ .x = cx + dx * scale - 0.5, .y = cy + dy * scale - 0.5 };
    } else if (shape == .small_circle or shape == .framed_circle) {
        scale = (b.width / 2) / @sqrt(dx * dx + dy * dy);
    } else if (shapes.circular(shape)) {
        scale = 1 / @sqrt(dx * dx / (b.width * b.width / 4) + dy * dy / (b.height * b.height / 4));
    } else if (shape == .stadium) {
        const radius = b.height / 2;
        const offset = @max(@as(f64, 0), b.width / 2 - radius);
        scale = if (@abs(dy) > 1e-9) radius / @abs(dy) else std.math.inf(f64);
        if (@abs(dx * scale) > offset or !std.math.isFinite(scale)) {
            const length = dx * dx + dy * dy;
            const projection = @abs(dx) * offset;
            scale = (projection + @sqrt(@max(@as(f64, 0), projection * projection - length * (offset * offset - radius * radius)))) / length;
        }
    } else {
        scale = @min(if (@abs(dx) > 1e-9) (b.width / 2) / @abs(dx) else std.math.inf(f64), if (@abs(dy) > 1e-9) (b.height / 2) / @abs(dy) else std.math.inf(f64));
    }
    return .{ .x = cx + dx * scale, .y = cy + dy * scale };
}
fn text(out: *svg.Svg, item: anytype, box: scene.Box, family: []const u8, style: anytype) !void {
    if (item.lines.len == 0) return;
    try out.fmt("<g transform=\"translate({d} {d})\"><text y=\"-10.1\" text-anchor=\"middle\" stroke=\"none\" font-size=\"{d}\" font-family=\"", .{ box.x + box.width / 2 - item.text_x - item.text_width / 2, box.y + (box.height - item.text_height) / 2 - item.text_y, item.font_size });
    try out.escape(family);
    try out.add("\" fill=\"");
    try out.escape(style.text orelse if (out.theme == .dark) "#e0e0e0" else "#24292f");
    try out.fmt("\" font-weight=\"{s}\" font-style=\"{s}\">", .{ if (style.bold orelse false) "bold" else "normal", if (style.italic orelse false) "italic" else "normal" });
    for (item.lines, 0..) |line, i| {
        try out.fmt("<tspan x=\"0\" y=\"{d}em\" dy=\"1.1em\">", .{@as(f64, @floatFromInt(i)) * 1.1 - 0.1});
        if (item.runs.len > i) {
            for (item.runs[i], 0..) |run, j| {
                try out.fmt("<tspan font-weight=\"{s}\" font-style=\"{s}\">", .{ if (run.type == .strong or (style.bold orelse false)) "bold" else "normal", if (run.type == .em or (style.italic orelse false)) "italic" else "normal" });
                if (j > 0) try out.add(" ");
                try out.escape(run.content);
                try out.add("</tspan>");
            }
        } else try out.escape(line);
        try out.add("</tspan>");
    }
    try out.add("</text></g>");
}
fn path(out: *svg.Svg, points: []const Point) !void {
    try out.fmt("M {d} {d}", .{ points[0].x, points[0].y });
    for (points[1 .. points.len - 1], 1..) |p, i| {
        const before = points[i - 1];
        const after = points[i + 1];
        const len1 = distance(before, p);
        const len2 = distance(p, after);
        const dot = if (len1 > 1e-9 and len2 > 1e-9) ((p.x - before.x) * (after.x - p.x) + (p.y - before.y) * (after.y - p.y)) / (len1 * len2) else @as(f64, 1);
        const angle = std.math.acos(std.math.clamp(dot, -1, 1));
        const r = @min(if (angle > 1e-5) @as(f64, 5) / @sin(angle / 2) else @as(f64, 0), @min(len1 / 2, len2 / 2));
        const a = toward(p, before, r);
        const b = toward(p, after, r);
        if (r < 1e-6 or @abs((p.x - before.x) * (after.y - p.y) - (p.y - before.y) * (after.x - p.x)) < 1e-6) try out.fmt(" L {d} {d}", .{ p.x, p.y }) else try out.fmt(" L {d} {d} Q {d} {d} {d} {d}", .{ a.x, a.y, p.x, p.y, b.x, b.y });
    }
    const last = points[points.len - 1];
    try out.fmt(" L {d} {d}", .{ last.x, last.y });
}
pub fn render(a: std.mem.Allocator, measured: measurement.Input, graph: scene.Scene, nodes: anytype, edges: anytype, theme: svg.Theme, prefix: u32) ![]u8 {
    // Other outlines need their own intersections, not a rectangle approximation.
    for (nodes) |node| switch (node.shape) {
        .box, .round, .stadium, .diamond, .circle, .double_circle, .text, .small_circle, .framed_circle, .fork => {},
        .tagged_process => if (node.note_for == null) return error.UnsupportedShapeIntersection,
        else => return error.UnsupportedShapeIntersection,
    };
    var out: svg.Svg = .{ .allocator = a, .theme = theme, .id_prefix = prefix };
    errdefer out.deinit();
    // Match intrinsic CSS pixels to SVG units. A fractional viewport subtly
    // rescales hinted glyphs even before responsive downscaling is applied.
    const viewport_w = @ceil(graph.width + 24);
    const viewport_h = @ceil(graph.height + 24);
    try out.fmt("<svg xmlns=\"http://www.w3.org/2000/svg\" data-layout=\"measured-elk\" viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\" role=\"img\" aria-label=\"flowchart diagram\" style=\"max-width:100%;height:auto\">", .{ viewport_w, viewport_h, viewport_w, viewport_h });
    try out.flowMarkers(prefix);
    try out.fmt("<g transform=\"translate(12 12)\" fill=\"{s}\" stroke=\"#9ca3af\" stroke-width=\"1.25\">", .{if (theme == .dark) "#16213e" else "#eef4ff"});
    // Groups sit behind routes and their children, never overpaint them.
    for (nodes, graph.nodes, 0..) |node, b, i| if (node.container) {
        if (std.mem.eql(u8, node.annotation, "note-group")) {
            try out.fmt("<g data-container=\"{d}\" data-note-group=\"true\"/>", .{i});
            continue;
        }
        try out.fmt("<g data-container=\"{d}\" fill=\"{s}\">", .{ i, if (theme == .dark) "#111827" else "#f8fafc" });
        try paint.begin(&out, node.style);
        try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"5\"/>", .{ b.x, b.y, b.width, b.height });
        try text(&out, measured.nodes[i], .{ .x = b.x, .y = b.y + 5, .width = b.width, .height = measured.nodes[i].text_height }, measured.font_family, node.style);
        try out.add("</g></g>");
    };
    for (edges, 0..) |edge, i| {
        if (edge.link.stroke == .invisible) continue;
        // Mermaid prepends node centers, cuts to shape boundaries, then drops duplicates.
        var points: std.ArrayList(Point) = .empty;
        defer points.deinit(a);
        const raw = graph.edges[i].points;
        try points.append(a, intersect(nodes[edge.from].shape, graph.nodes[edge.from], raw[0]));
        for (raw) |p| if (distance(points.items[points.items.len - 1], p) > 1e-6) try points.append(a, p);
        const hit = intersect(nodes[edge.to].shape, graph.nodes[edge.to], raw[raw.len - 1]);
        if (distance(points.items[points.items.len - 1], hit) > 1e-6) try points.append(a, hit);
        try out.fmt("<g data-edge-group=\"{d}\">", .{i});
        try paint.begin(&out, edge.style);
        try out.fmt("<path data-edge=\"{d}\" data-from=\"{d}\" data-to=\"{d}\" fill=\"none\" d=\"", .{ i, edge.from, edge.to });
        try path(&out, points.items);
        try out.add("\"");
        if (edge.link.end != .none) try out.fmt(" marker-end=\"url(#zm-{d}-{s})\"", .{ prefix, @tagName(edge.link.end) });
        if (edge.link.start != .none) try out.fmt(" marker-start=\"url(#zm-{d}-{s})\"", .{ prefix, @tagName(edge.link.start) });
        if (edge.link.stroke == .dotted and edge.style.dash == null) try out.add(" stroke-dasharray=\"5 4\"");
        if (edge.link.stroke == .thick and edge.style.width == null) try out.add(" stroke-width=\"3\"");
        try out.add("/></g></g>");
    }
    for (nodes, graph.nodes, 0..) |node, b, i| {
        if (node.container) continue;
        try out.fmt("<g data-node=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\" data-mermaid-id=\"", .{ i, b.x, b.y, b.width, b.height });
        try out.escape(node.id);
        try out.add("\">");
        try paint.begin(&out, node.style);
        const default_decision = try paint.beginDecision(&out, node.shape, node.style);
        const sections = measured.nodes[i].sections;
        if (sections.len == 2) {
            try out.fmt("<g data-shape=\"state-description\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\"/><path data-section-divider=\"true\" d=\"M {d} {d} H {d}\" fill=\"none\"/></g>", .{ b.x, b.y, b.width, b.height, b.x, b.y + sections[0].text_height + measured.padding / 2, b.x + b.width });
        } else if (node.note_for != null) {
            try out.fmt("<rect data-shape=\"note\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\"/>", .{ b.x, b.y, b.width, b.height, node.style.fill orelse if (theme == .dark) "#3f3418" else "#fff5ad" });
        } else if (!try shapes.drawMeasuredSymbol(&out, node.shape, b.x, b.y, b.width, b.height))
            try shapes.drawFractional(&out, node.shape, b.x, b.y, b.width, b.height);
        if (default_decision) try out.add("</g>");
        if (sections.len == 2) {
            const title_top = b.y + sections[0].text_y + 3;
            try out.add("<g data-section=\"title\">");
            try text(&out, sections[0], .{ .x = b.x, .y = title_top, .width = b.width, .height = sections[0].text_height }, measured.font_family, node.style);
            try out.add("</g><g data-section=\"body\">");
            try text(&out, sections[1], .{ .x = b.x, .y = title_top + sections[0].text_height + measured.padding / 2 + 5, .width = b.width, .height = sections[1].text_height }, measured.font_family, node.style);
            try out.add("</g>");
        } else if (measurement.hasLabel(node.shape)) try text(&out, measured.nodes[i], b, measured.font_family, node.style);
        try out.add("</g></g>");
    }
    // Inline labels use the space reserved by ELK, not post-hoc midpoint search.
    for (graph.edges, 0..) |edge, i| if (edge.label) |b| {
        try out.fmt("<g data-edge-label=\"{d}\"><rect data-label-for=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"3\" fill=\"{s}\" stroke=\"none\"/>", .{ i, i, b.x, b.y, b.width, b.height, if (theme == .dark) "#0d1117" else "#ffffff" });
        try text(&out, measured.edges[i], b, measured.font_family, edges[i].style);
        try out.add("</g>");
    };
    return out.finish();
}
