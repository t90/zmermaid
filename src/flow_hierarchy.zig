// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/compound/CompoundGraphPreprocessor.java
// Upstream notice: Copyright (c) 2013, 2020 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// Hierarchy-local edge splitting, mirroring ELK's compound preprocessor.
// Geometry is deliberately absent: a boundary endpoint is a port, not a
// fabricated coordinate or a replacement connection to a group center.
const std = @import("std");
const flow = @import("flowchart.zig");
const scene = @import("flow_scene.zig");
pub const Endpoint = struct {
    node: usize,
    boundary: ?usize = null,
};
pub const Port = struct { group: usize, endpoint: usize, input: bool };
pub const Segment = struct { edge: usize, level: ?usize, source: Endpoint, target: Endpoint, carries_label: bool = false };
pub const Plan = struct { ports: []const Port, segments: []const Segment };
fn common(nodes: []const flow.Node, x: ?usize, y: ?usize) !?usize {
    var a = x;
    for (0..18) |_| {
        var b = y;
        for (0..18) |_| {
            if (a == b) return a;
            b = if (b) |id| nodes[id].parent else break;
        }
        a = if (a) |id| nodes[id].parent else break;
    }
    return error.InvalidHierarchy;
}
fn port(a: std.mem.Allocator, ports: *std.ArrayList(Port), group: usize, endpoint: usize, input: bool) !usize {
    // Mermaid sets mergeHierarchyEdges on the root only. It is not inherited
    // by its compound children; ELK's child default is false. Distinct free
    // endpoint ports must therefore remain distinct even on the same node.
    const id = ports.items.len;
    try ports.append(a, .{ .group = group, .endpoint = endpoint, .input = input });
    return id;
}
pub fn split(a: std.mem.Allocator, nodes: []const flow.Node, edges: []const flow.Edge) !Plan {
    for (nodes, 0..) |node, id| {
        var parent = node.parent;
        var depth: usize = 0;
        while (parent) |p| {
            if (p >= nodes.len or p == id or depth >= 16 or !nodes[p].container) return error.InvalidHierarchy;
            depth += 1;
            parent = nodes[p].parent;
        }
    }
    var ports: std.ArrayList(Port) = .empty;
    var segments: std.ArrayList(Segment) = .empty;
    for (edges, 0..) |edge, id| {
        if (edge.from >= nodes.len or edge.to >= nodes.len) return error.InvalidHierarchy;
        const lca = try common(nodes, nodes[edge.from].parent, nodes[edge.to].parent);
        const first_segment = segments.items.len;
        var from: Endpoint = .{ .node = edge.from };
        var from_level = nodes[edge.from].parent;
        var visited: usize = 0;
        while (from_level != lca) {
            if (visited >= 16) return error.InvalidHierarchy;
            visited += 1;
            const group = from_level orelse return error.InvalidHierarchy;
            const p = try port(a, &ports, group, edge.from, false);
            try segments.append(a, .{ .edge = id, .level = group, .source = from, .target = .{ .node = group, .boundary = p } });
            from = .{ .node = group, .boundary = p };
            from_level = nodes[group].parent;
        }
        var tail: std.ArrayList(Segment) = .empty;
        var to: Endpoint = .{ .node = edge.to };
        var to_level = nodes[edge.to].parent;
        visited = 0;
        while (to_level != lca) {
            if (visited >= 16) return error.InvalidHierarchy;
            visited += 1;
            const group = to_level orelse return error.InvalidHierarchy;
            const p = try port(a, &ports, group, edge.to, true);
            try tail.append(a, .{ .edge = id, .level = group, .source = .{ .node = group, .boundary = p }, .target = to });
            to = .{ .node = group, .boundary = p };
            to_level = nodes[group].parent;
        }
        if (from.node == to.node and (from.boundary == null) != (to.boundary == null)) {
            // A connection to the parent itself ends at its boundary port,
            // not at a fabricated outer self-loop from the group to itself.
            if (segments.items.len > first_segment) segments.items[segments.items.len - 1].carries_label = true else if (tail.items.len > 0) tail.items[tail.items.len - 1].carries_label = true;
        } else try segments.append(a, .{ .edge = id, .level = lca, .source = from, .target = to, .carries_label = true });
        var j = tail.items.len;
        while (j > 0) { j -= 1; try segments.append(a, tail.items[j]); }
    }
    return .{ .ports = ports.items, .segments = segments.items };
}

pub fn join(a: std.mem.Allocator, plan: Plan, segments: []const scene.Edge, edge_count: usize) ![]scene.Edge {
    if (segments.len != plan.segments.len) return error.MissingSegment;
    for (plan.segments, segments) |segment, route| {
        if (segment.edge >= edge_count or route.points.len > 4096) return error.InvalidRoute;
        for (route.points) |p| if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return error.InvalidRoute;
        if (route.label) |b| {
            for ([_]f64{ b.x, b.y, b.width, b.height }) |v| if (!std.math.isFinite(v)) return error.InvalidRoute;
            if (b.width < 0 or b.height < 0) return error.InvalidRoute;
        }
    }
    const result = try a.alloc(scene.Edge, edge_count);
    for (result, 0..) |*edge, id| {
        var points: std.ArrayList(scene.Point) = .empty;
        var label: ?scene.Box = null;
        for (plan.segments, segments) |segment, route| {
            if (segment.edge != id) continue;
            if (route.points.len < 2) return error.MissingSegment;
            if (points.items.len > 0) {
                const end = points.items[points.items.len - 1];
                const start = route.points[0];
                if (@abs(end.x - start.x) > 0.001 or @abs(end.y - start.y) > 0.001) return error.DisconnectedBoundary;
            }
            // Keep collinear boundary points: ELK exports these junctions too.
            try points.appendSlice(a, route.points[@intFromBool(points.items.len > 0)..]);
            if (route.label) |b| {
                if (!segment.carries_label or label != null) return error.DuplicateHierarchyLabel;
                label = b;
            }
        }
        if (points.items.len < 2) return error.MissingSegment;
        edge.* = .{ .points = points.items, .label = label };
    }
    return result;
}

/// Mermaid state dataFetcher builds a root note-group around each note,
/// leaving the associated state in its original hierarchy. Left notes reverse
/// their no-arrow edge. This semantic adaptation must precede edge splitting.
pub fn normalizeNotes(parser: *flow.Parser) !void {
    const count = parser.nodes.items.len;
    for (0..count) |id| {
        const note = parser.nodes.items[id];
        if (note.note_for) |target| {
            if (target >= count) return error.InvalidHierarchy;
            const group_id = try std.fmt.allocPrint(parser.allocator, "note-group:{s}", .{note.id});
            const group = parser.nodes.items.len;
            try parser.nodes.append(parser.allocator, .{ .id = group_id, .label = note.label, .shape = .round, .container = true, .annotation = "note-group" });
            parser.nodes.items[id].parent = group;
            for (parser.edges.items) |*edge| if (edge.from == target and edge.to == id) {
                edge.link.start = .none;
                edge.link.end = .none;
                if (note.note_left) { edge.from = id; edge.to = target; }
            };
        }
    }
}

pub fn trace(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var doc = try @import("document.zig").Document.parse(scratch, source, .light);
    const trimmed = std.mem.trimStart(u8, doc.source, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "stateDiagram")) return error.UnsupportedSyntax;
    doc.source = trimmed;
    var parser: flow.Parser = .{ .allocator = scratch, .assets = &doc.assets, .defer_measurement = true };
    _ = try @import("state.zig").parse(&parser, &doc);
    try normalizeNotes(&parser);
    const plan = try split(scratch, parser.nodes.items, parser.edges.items);
    const TraceNode = struct { id: []const u8, parent: ?usize, container: bool, note_for: ?usize };
    const nodes = try scratch.alloc(TraceNode, parser.nodes.items.len);
    for (parser.nodes.items, 0..) |node, id| nodes[id] = .{ .id = node.id, .parent = node.parent, .container = node.container, .note_for = node.note_for };
    const edges = try scratch.alloc(struct { source: usize, target: usize, label: []const u8 }, parser.edges.items.len);
    for (parser.edges.items, 0..) |edge, id| edges[id] = .{ .source = edge.from, .target = edge.to, .label = edge.link.label };
    return std.json.Stringify.valueAlloc(a, .{ .schema = "zmermaid-hierarchy-preparation-v1", .nodes = nodes, .edges = edges, .ports = plan.ports, .segments = plan.segments }, .{});
}

test "split sibling and deep crossings in source to target order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]flow.Node{
        .{ .id = "P", .label = "P", .container = true },
        .{ .id = "Q", .label = "Q", .container = true },
        .{ .id = "A", .label = "A", .parent = 0 },
        .{ .id = "B", .label = "B", .parent = 1 },
        .{ .id = "Inner", .label = "Inner", .container = true, .parent = 0 },
        .{ .id = "C", .label = "C", .parent = 4 },
    };
    const plan = try split(arena.allocator(), &nodes, &.{ .{ .from = 2, .to = 3, .link = .{} }, .{ .from = 5, .to = 3, .link = .{} } });
    try std.testing.expectEqual(@as(usize, 7), plan.segments.len);
    try std.testing.expectEqual(@as(usize, 5), plan.ports.len);
    try std.testing.expectEqual(@as(?usize, 0), plan.segments[0].level);
    try std.testing.expectEqual(@as(?usize, null), plan.segments[1].level);
    try std.testing.expect(plan.segments[1].carries_label);
    try std.testing.expectEqual(@as(?usize, 1), plan.segments[2].level);
    try std.testing.expectEqual(@as(?usize, 4), plan.segments[3].level);
    try std.testing.expectEqual(@as(?usize, 0), plan.segments[4].level);
    try std.testing.expectEqual(@as(?usize, null), plan.segments[5].level);
    try std.testing.expect(plan.segments[2].source.boundary != plan.segments[6].source.boundary);
}

test "rejoin preserves boundary junctions and rejects disconnected or missing segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plan: Plan = .{ .ports = &.{}, .segments = &.{
        .{ .edge = 0, .level = 0, .source = .{ .node = 1 }, .target = .{ .node = 0 }, .carries_label = false },
        .{ .edge = 0, .level = null, .source = .{ .node = 0 }, .target = .{ .node = 2 }, .carries_label = true },
    } };
    const routes = [_]scene.Edge{
        .{ .points = &.{ .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 20 } }, .label = null },
        .{ .points = &.{ .{ .x = 30, .y = 20 }, .{ .x = 70, .y = 20 } }, .label = .{ .x = 40, .y = 10, .width = 10, .height = 10 } },
    };
    const result = try join(arena.allocator(), plan, &routes, 1);
    try std.testing.expectEqual(@as(usize, 3), result[0].points.len);
    try std.testing.expectEqual(@as(f64, 30), result[0].points[1].x);
    try std.testing.expect(result[0].label != null);
    var wrong = routes;
    wrong[1].points = &.{ .{ .x = 31, .y = 20 }, .{ .x = 70, .y = 20 } };
    try std.testing.expectError(error.DisconnectedBoundary, join(arena.allocator(), plan, &wrong, 1));
    try std.testing.expectError(error.MissingSegment, join(arena.allocator(), plan, routes[0..1], 1));
    wrong = routes;
    wrong[0].label = routes[1].label;
    try std.testing.expectError(error.DuplicateHierarchyLabel, join(arena.allocator(), plan, &wrong, 1));
    wrong = routes;
    wrong[0].points = &.{ .{ .x = std.math.nan(f64), .y = 20 }, .{ .x = 30, .y = 20 } };
    try std.testing.expectError(error.InvalidRoute, join(arena.allocator(), plan, &wrong, 1));
}

test "parent connections have no outer self-loop and own their inner label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]flow.Node{ .{ .id = "P", .label = "P", .container = true }, .{ .id = "A", .label = "A", .parent = 0 } };
    const plan = try split(arena.allocator(), &nodes, &.{ .{ .from = 0, .to = 1, .link = .{ .label = "enter" } }, .{ .from = 1, .to = 0, .link = .{ .label = "exit" } } });
    try std.testing.expectEqual(@as(usize, 2), plan.segments.len);
    for (plan.segments) |segment| {
        try std.testing.expectEqual(@as(?usize, 0), segment.level);
        try std.testing.expect(segment.carries_label);
        try std.testing.expect(segment.source.node != segment.target.node);
    }
}

test "hierarchy trace owns note-group adaptation and releases its source allocations" {
    const result = try trace(std.testing.allocator, "stateDiagram-v2\nA --> B\nnote left of A: note");
    defer std.testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const nodes = parsed.value.object.get("nodes").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expect(nodes[3].object.get("container").?.bool);
    try std.testing.expectEqual(@as(i64, 3), nodes[2].object.get("parent").?.integer);
    const edges = parsed.value.object.get("edges").?.array.items;
    try std.testing.expectEqual(@as(i64, 2), edges[1].object.get("source").?.integer);
    try std.testing.expectEqual(@as(i64, 0), edges[1].object.get("target").?.integer);
}

test "invalid parent chains are rejected before edge splitting" {
    const nodes = [_]flow.Node{ .{ .id = "P", .label = "P", .container = true, .parent = 1 }, .{ .id = "Q", .label = "Q", .container = true, .parent = 0 } };
    try std.testing.expectError(error.InvalidHierarchy, split(std.testing.allocator, &nodes, &.{}));
}
