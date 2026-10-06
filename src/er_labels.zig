const paint = @import("flow_paint.zig");
const shapes = @import("flow_shapes.zig");
const svg = @import("svg.zig");
pub const Box = struct { x: usize = 0, y: usize = 0, w: usize = 0, h: usize = 0, active: bool = false, leader: bool = false, ax: usize = 0, ay: usize = 0 };
pub const Plan = struct { boxes: [512]Box = @splat(.{}), w: usize, h: usize };
fn overlaps(a: Box, b: Box, margin: usize) bool {
    return a.x < b.x + b.w + margin and b.x < a.x + a.w + margin and a.y < b.y + b.h + margin and b.y < a.y + a.h + margin;
}
fn clear(box: Box, nodes: anytype, previous: []const Box) bool {
    // The clearance also protects cardinality symbols beside the entity border.
    for (nodes) |n| if (overlaps(box, .{ .x = n.x, .y = n.y, .w = n.w, .h = n.h }, 20)) return false;
    for (previous) |b| if (b.active and overlaps(box, b, 6)) return false;
    return true;
}
fn coord(value: f64) usize {
    return @intFromFloat(@max(0, @round(value)));
}
pub fn plan(parser: anytype, width: usize, height: usize) Plan {
    var result: Plan = .{ .w = width, .h = height };
    for (parser.edges.items, 0..) |edge, i| {
        if (edge.link.label.len == 0 or edge.link.stroke == .invisible) continue;
        const from = parser.nodes.items[edge.from];
        const to = parser.nodes.items[edge.to];
        const dx = @as(i64, @intCast(to.x + to.w / 2)) - @as(i64, @intCast(from.x + from.w / 2));
        const dy = @as(i64, @intCast(to.y + to.h / 2)) - @as(i64, @intCast(from.y + from.h / 2));
        const gx = @as(i64, @intCast(@max(from.x, to.x))) - @as(i64, @intCast(@min(from.x + from.w, to.x + to.w)));
        const gy = @as(i64, @intCast(@max(from.y, to.y))) - @as(i64, @intCast(@min(from.y + from.h, to.y + to.h)));
        const horizontal = if (from.rank != to.rank) parser.entity_horizontal else gx > gy;
        const side: shapes.Side = if (horizontal) (if (dx >= 0) .right else .left) else (if (dy >= 0) .bottom else .top);
        const opposite: shapes.Side = switch (side) {
            .left => .right,
            .right => .left,
            .top => .bottom,
            .bottom => .top,
        };
        const p = shapes.anchor(from.shape, from.x, from.y, from.w, from.h, side);
        const q = shapes.anchor(to.shape, to.x, to.y, to.w, to.h, opposite);
        const px: f64 = @floatFromInt(p.x);
        const py: f64 = @floatFromInt(p.y);
        const qx: f64 = @floatFromInt(q.x);
        const qy: f64 = @floatFromInt(q.y);
        const step: f64 = if (if (horizontal) q.x >= p.x else q.y >= p.y) 20 else -20;
        const ax = px + if (horizontal) step else 0;
        const ay = py + if (horizontal) 0 else step;
        const bx = qx - if (horizontal) step else 0;
        const by = qy - if (horizontal) 0 else step;
        var box: Box = .{ .active = true, .w = edge.style.measure(paint.labelWidth(edge.link.label, edge.link.markdown)) + 12, .h = edge.style.measure(paint.labelHeight(edge.link.label)) + 8 };
        var found = false;
        // Prefer labels directly on the middle curve. Move along it before
        // considering a small perpendicular offset; never overlap another label.
        search: for ([_]f64{ 0, -18, 18, -36, 36 }) |offset| {
            for ([_]f64{ 0.5, 0.3, 0.7, 0.15, 0.85 }) |t| {
                const u = 1 - t;
                const c1x = if (horizontal) (ax + bx) / 2 else ax;
                const c1y = if (horizontal) ay else (ay + by) / 2;
                const c2x = if (horizontal) c1x else bx;
                const c2y = if (horizontal) by else c1y;
                const x = u * u * u * ax + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * bx;
                const y = u * u * u * ay + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * by;
                box.ax = coord(x);
                box.ay = coord(y);
                const cx = x + if (horizontal) @as(f64, 0) else offset;
                const cy = y + if (horizontal) offset else @as(f64, 0);
                if (cx < @as(f64, @floatFromInt(box.w)) / 2 + 8 or cy < @as(f64, @floatFromInt(box.h)) / 2 + 8) continue;
                box.x = coord(cx - @as(f64, @floatFromInt(box.w)) / 2);
                box.y = coord(cy - @as(f64, @floatFromInt(box.h)) / 2);
                if (edge.from != edge.to and clear(box, parser.nodes.items, result.boxes[0..i])) {
                    box.leader = offset != 0;
                    found = true;
                    break :search;
                }
            }
        }
        if (!found) {
            // A crowded or self-referencing relationship gets a clear side label
            // with a leader instead of unreadable overlapping text.
            box.x = width + 12;
            box.y = (p.y + q.y) / 2;
            box.ax = if (edge.from == edge.to) from.x + from.w + 40 else (p.x + q.x) / 2;
            box.ay = if (edge.from == edge.to) from.y + from.h / 2 else (p.y + q.y) / 2;
            box.leader = true;
            while (!clear(box, parser.nodes.items, result.boxes[0..i])) box.y += box.h + 8;
        }
        result.boxes[i] = box;
        result.w = @max(result.w, box.x + box.w + 16);
        result.h = @max(result.h, box.y + box.h + 16);
    }
    return result;
}
pub fn draw(out: *svg.Svg, parser: anytype, placement: *const Plan) !void {
    const bg = if (out.theme == .dark) "#0d1117" else "#ffffff";
    const fg = if (out.theme == .dark) "#8b949e" else "#57606a";
    // Draw all leaders before all labels, just as with relationship connectors.
    for (parser.edges.items, 0..) |_, i| {
        const box = placement.boxes[i];
        if (!box.active) continue;
        if (box.leader) try out.fmt("<path data-label-leader=\"{d}\" d=\"M {d} {d} L {d} {d}\" stroke=\"{s}\" stroke-width=\"1\" fill=\"none\"/>", .{ i, box.ax, box.ay, box.x + box.w / 2, box.y + box.h / 2, fg });
    }
    for (parser.edges.items, 0..) |edge, i| {
        const box = placement.boxes[i];
        if (!box.active) continue;
        try out.fmt("<g data-er-label=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"3\" fill=\"{s}\" stroke=\"none\"/>", .{ i, box.x, box.y, box.w, box.h, bg });
        try paint.textAssets(out, box.x + box.w / 2, box.y + 4, edge.link.label, edge.style, edge.link.markdown, parser.assets);
        try out.add("</g>");
    }
}
