// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/LongEdgeJoiner.java
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/LabelDummyRemover.java
// Upstream notice: Copyright (c) 2010, 2015 Kiel University and others.
// Upstream notice: Copyright (c) 2012, 2020 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// Reassemble ELK's proper graph: LongEdgeJoiner, LabelDummyRemover,
// ReversedEdgeRestorer and the final direction transform. No geometry repair.
const std = @import("std");
const measurement = @import("flow_measurement.zig");
const placement = @import("flow_measured_layout.zig");
const orthogonal = @import("flow_orthogonal.zig");
const layout = @import("flow_layout.zig");
pub const Point = struct { x: f64, y: f64 };
pub const Box = struct { x: f64, y: f64, width: f64, height: f64 };
pub const Edge = struct { points: []const Point, label: ?Box };
pub const Scene = struct { width: f64, height: f64, nodes: []Box, edges: []Edge };
fn portX(placed: placement.Result, node: usize, arc: usize, output: bool) f64 {
    if (placed.connections.len == placed.graph.arcs.len) {
        const c = placed.connections[arc];
        const p = placed.nodes[node].ports[if (output) c.source_port else c.target_port];
        return p.x + p.anchor_x;
    }
    const list = if (output) placed.graph.nodes[node].outgoing else placed.graph.nodes[node].incoming;
    for (list, 0..) |id, ordinal| if (id == arc) return placed.nodes[node].ports[ordinal + (if (output) @as(usize, 0) else placed.graph.nodes[node].outgoing.len)].x;
    return 0;
}
fn transform(p: Point, direction: []const u8, width: f64, height: f64) Point {
    _ = height;
    if (std.mem.eql(u8, direction, "TB")) return .{ .x = p.y, .y = p.x };
    if (std.mem.eql(u8, direction, "BT")) return .{ .x = p.y, .y = width - p.x };
    if (std.mem.eql(u8, direction, "RL")) return .{ .x = width - p.x, .y = p.y };
    return p;
}
fn boxTransform(b: Box, direction: []const u8, width: f64, height: f64) Box {
    const p = transform(.{ .x = b.x, .y = b.y }, direction, width, height);
    if (std.mem.eql(u8, direction, "TB")) return .{ .x = p.x, .y = p.y, .width = b.height, .height = b.width };
    if (std.mem.eql(u8, direction, "BT")) return .{ .x = p.x, .y = p.y - b.width, .width = b.height, .height = b.width };
    if (std.mem.eql(u8, direction, "RL")) return .{ .x = p.x - b.width, .y = p.y, .width = b.width, .height = b.height };
    return b;
}
pub fn compute(a: std.mem.Allocator, measured: measurement.Input, placed: placement.Result, routed: orthogonal.Result, arcs: []const layout.OrderedArc) !Scene {
    return computeWithBendpoints(a, measured, placed, routed, arcs, true);
}
pub fn computeWithBendpoints(a: std.mem.Allocator, measured: measurement.Input, placed: placement.Result, routed: orthogonal.Result, arcs: []const layout.OrderedArc, unnecessary_bendpoints: bool) !Scene {
    var minimum = std.math.inf(f64);
    var maximum: f64 = -std.math.inf(f64);
    for (placed.nodes, 0..) |n, id| {
        minimum = @min(minimum, placed.cross[id] - n.top);
        maximum = @max(maximum, placed.cross[id] + n.height + n.bottom);
    }
    const cross_size = maximum - minimum;
    const nodes = try a.alloc(Box, measured.nodes.len);
    for (placed.nodes, 0..) |n, id| if (placed.real[id]) |real| {
        nodes[real] = boxTransform(.{ .x = routed.along[id], .y = placed.cross[id] - minimum, .width = n.width, .height = n.height }, measured.direction, routed.width, cross_size);
    };
    const edges = try a.alloc(Edge, measured.edges.len);
    for (measured.edges, 0..) |edge, index| {
        if (std.mem.eql(u8, edge.source, edge.target)) {
            var real: ?usize = null;
            for (measured.nodes, 0..) |node, r| if (std.mem.eql(u8, node.id, edge.source)) { real = r; break; };
            var proper: ?usize = null;
            for (placed.real, 0..) |r, p| if (r == real) { proper = p; break; };
            const p = proper orelse return error.InvalidRoute;
            const plan = try @import("flow_self_loops.zig").plan(a, measured, real orelse return error.InvalidRoute, placed.nodes[p].width);
            for (plan.loops) |loop| if (loop.edge == index) {
                const x = routed.along[p];
                const y = placed.cross[p] - minimum;
                const points = try a.alloc(Point, 4);
                points[0] = .{ .x = x + loop.source, .y = y };
                points[1] = .{ .x = x + loop.source, .y = y + loop.slot };
                points[2] = .{ .x = x + loop.target, .y = y + loop.slot };
                points[3] = .{ .x = x + loop.target, .y = y };
                for (points) |*point| point.* = transform(point.*, measured.direction, routed.width, cross_size);
                edges[index] = .{ .points = points, .label = if (loop.label_height > 0) boxTransform(.{ .x = x + loop.label_x, .y = y + loop.label_y, .width = loop.label_width, .height = loop.label_height }, measured.direction, routed.width, cross_size) else null };
                break;
            };
            continue;
        }
        var points: std.ArrayList(Point) = .empty;
        var label: ?Box = null;
        var previous: ?usize = null;
        var last: ?Point = null;
        var reverse = false;
        const visited = try a.alloc(bool, arcs.len); @memset(visited, false);
        var traversed: usize = 0;
        // Walk the transformed chain; in-layer links do not sort by rank.
        while (true) {
            var next: ?usize = null;
            for (arcs, 0..) |candidate, id| {
                if (candidate.edge != index or visited[id]) continue;
                const arc = placed.graph.arcs[id];
                if (if (previous) |p| arc.from == p else placed.real[arc.from] != null) { next = id; break; }
            }
            const id = next orelse break;
            visited[id] = true; traversed += 1;
            const arc = placed.graph.arcs[id];
            const from = placed.nodes[arc.from];
            const start: Point = .{ .x = routed.along[arc.from] + portX(placed, arc.from, id, true), .y = placed.cross[arc.from] - minimum + arc.source_y };
            const end: Point = .{ .x = routed.along[arc.to] + portX(placed, arc.to, id, false), .y = placed.cross[arc.to] - minimum + arc.target_y };
            if (previous == null) {
                reverse = !std.mem.eql(u8, measured.nodes[placed.real[arc.from] orelse return error.InvalidRoute].id, edge.source);
                try points.append(a, start);
            } else if (previous.? != arc.from) return error.InvalidRoute;
            // Long edge dummies get the optional collinear bend; label dummies do not.
            if (unnecessary_bendpoints and previous != null and std.mem.eql(u8, from.type, "LONG_EDGE")) try points.append(a, start);
            if (@abs(start.y - end.y) >= 1e-3) {
                try points.append(a, .{ .x = routed.lane[id], .y = start.y });
                try points.append(a, .{ .x = routed.lane[id], .y = end.y });
            }
            if (std.mem.eql(u8, from.type, "LABEL")) {
                const vertical = std.mem.eql(u8, measured.direction, "TB") or std.mem.eql(u8, measured.direction, "BT");
                const lw = if (vertical) edge.height else edge.width;
                const lh = if (vertical) edge.width else edge.height;
                label = boxTransform(.{ .x = routed.along[arc.from] + (from.width - lw) / 2, .y = placed.cross[arc.from] - minimum + (if (vertical) (from.height - lh) / 2 else @as(f64, 0)), .width = lw, .height = lh }, measured.direction, routed.width, cross_size);
            }
            last = end;
            previous = arc.to;
        }
        for (arcs, 0..) |arc, id| if (arc.edge == index and !visited[id]) return error.InvalidRoute;
        if (traversed == 0) return error.InvalidRoute;
        try points.append(a, last orelse return error.InvalidRoute);
        if (reverse) std.mem.reverse(Point, points.items);
        for (points.items) |*p| p.* = transform(p.*, measured.direction, routed.width, cross_size);
        edges[index] = .{ .points = points.items, .label = label };
    }
    const vertical = std.mem.eql(u8, measured.direction, "TB") or std.mem.eql(u8, measured.direction, "BT");
    return .{ .width = if (vertical) cross_size else routed.width, .height = if (vertical) routed.width else cross_size, .nodes = nodes, .edges = edges };
}
