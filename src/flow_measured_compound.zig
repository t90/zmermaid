// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/compound/CompoundGraphPreprocessor.java
// Upstream notice: Copyright (c) 2013, 2020 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// Bottom-up SEPARATE_CHILDREN layout. Uses the flat engine at every level;
// title space and container dimensions exist before the parent is placed.
const std = @import("std");
const flow = @import("flowchart.zig");
const measurement = @import("flow_measurement.zig");
const layout = @import("flow_layout.zig");
const pipeline = @import("flow_measured_layout.zig");
const scene = @import("flow_scene.zig");
const Level = struct { graph: scene.Scene, nodes: []const usize, edges: []const usize, top: f64 };
const Builder = struct {
    a: std.mem.Allocator,
    parser: *flow.Parser,
    measured: measurement.Input,
    levels: []?Level,
    fn level(self: *@This(), parent: ?usize, direction: []const u8, depth: usize) !Level {
        if (depth > 16) return error.InvalidHierarchy;
        var local: flow.Parser = .{ .allocator = self.a, .kind = self.parser.kind, .node_spacing = if (parent == null) 40 else 30 };
        var ids: std.ArrayList(usize) = .empty;
        var eids: std.ArrayList(usize) = .empty;
        var nodes: std.ArrayList(measurement.Node) = .empty;
        var edges: std.ArrayList(measurement.Edge) = .empty;
        var sizes: std.ArrayList(measurement.Size) = .empty;
        const map = try self.a.alloc(?usize, self.parser.nodes.items.len);
        @memset(map, null);
        for (self.parser.nodes.items, 0..) |node, id| if (node.parent == parent) {
            map[id] = ids.items.len;
            try ids.append(self.a, id);
            var copy = node;
            copy.container = false;
            copy.parent = null;
            try local.nodes.append(self.a, copy);
            try nodes.append(self.a, self.measured.nodes[id]);
            var size = try measurement.measuredNodeSize(self.measured, self.measured.nodes[id]);
            if (node.container) {
                const child = try self.level(id, node.direction orelse direction, depth + 1);
                self.levels[id] = child;
                size = .{ .width = child.graph.width + 24, .height = child.graph.height + child.top + 12 };
                // Mermaid's drawNodes expands an oversized title after ELK
                // layout, changing the group intersection/viewport boundary.
                // Keep that variant explicit until its paint boundary is ported.
                if (self.measured.nodes[id].text_width > size.width) return error.UnsupportedTitleExpansion;
            }
            try sizes.append(self.a, size);
        };
        if (ids.items.len == 0) return error.EmptyHierarchy;
        for (self.parser.edges.items, 0..) |edge, id| {
            if (map[edge.from] == null or map[edge.to] == null) continue;
            var copy = edge;
            copy.from = map[edge.from].?;
            copy.to = map[edge.to].?;
            try local.edges.append(self.a, copy);
            var m = self.measured.edges[id];
            m.index = edges.items.len;
            try edges.append(self.a, m);
            try eids.append(self.a, id);
        }
        var input = self.measured;
        input.nodes = nodes.items;
        input.edges = edges.items;
        input.direction = direction;
        const ordering = try flow.rankTraceParser(self.a, &local, direction);
        const Phase = struct {
            nodes: []const struct { id: []const u8, rank: usize },
            positioned: []const layout.PositionedEntry,
            port_order: []const layout.OrderedArc,
            routing_random_state_after_ordering: u64,
        };
        const phase = (try std.json.parseFromSlice(Phase, self.a, ordering, .{ .ignore_unknown_fields = true })).value;
        const ranks = try self.a.alloc(usize, ids.items.len);
        const endpoints = try self.a.alloc(pipeline.Edge, edges.items.len);
        for (phase.nodes, 0..) |node, i| ranks[i] = node.rank;
        for (local.edges.items, 0..) |edge, i| endpoints[i] = .{ .from = edge.from, .to = edge.to };
        const base: f64 = if (parent == null) 40 else 30;
        const placed = try pipeline.computeWithSizes(self.a, input, endpoints, ranks, phase.positioned, phase.port_order, base, base / 2, base / 10, sizes.items);
        const routed = try @import("flow_orthogonal.zig").computeSpacing(self.a, placed, phase.routing_random_state_after_ordering, base, base / 2);
        return .{ .graph = try scene.compute(self.a, input, placed, routed, phase.port_order), .nodes = ids.items, .edges = eids.items,
            // labelHelper subtracts 2 px; ELK adds its 5 px title gap.
            .top = if (parent) |id| if (self.measured.nodes[id].label.len > 0) self.measured.nodes[id].text_height + 15 else 12 else 0 };
    }
    fn flatten(self: *@This(), level_: Level, result: *scene.Scene, x: f64, y: f64) !void {
        for (level_.nodes, level_.graph.nodes) |id, box| {
            var b = box;
            b.x += x;
            b.y += y;
            result.nodes[id] = b;
            if (self.levels[id]) |child| try self.flatten(child, result, b.x + 12, b.y + child.top);
        }
        for (level_.edges, level_.graph.edges) |id, edge| {
            const points = try self.a.dupe(scene.Point, edge.points);
            for (points) |*p| { p.x += x; p.y += y; }
            var label = edge.label;
            if (label) |*b| { b.x += x; b.y += y; }
            result.edges[id] = .{ .points = points, .label = label };
        }
    }
};
pub fn compute(a: std.mem.Allocator, parser: *flow.Parser, measured: measurement.Input, direction: []const u8) !scene.Scene {
    const levels = try a.alloc(?Level, parser.nodes.items.len);
    @memset(levels, null);
    var builder: Builder = .{ .a = a, .parser = parser, .measured = measured, .levels = levels };
    const root = try builder.level(null, direction, 0);
    var result: scene.Scene = .{ .width = root.graph.width, .height = root.graph.height,
        .nodes = try a.alloc(scene.Box, measured.nodes.len), .edges = try a.alloc(scene.Edge, measured.edges.len) };
    try builder.flatten(root, &result, 0, 0);
    // Exercise the strict shared join boundary even while cross-level port
    // geometry remains gated. Same-level segments retain identical output.
    const hierarchy = @import("flow_hierarchy.zig");
    const plan = try hierarchy.split(a, parser.nodes.items, parser.edges.items);
    result.edges = try hierarchy.join(a, plan, result.edges, parser.edges.items.len);
    return result;
}

test "compound bounds and child routes exist before parent placement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parser: flow.Parser = .{ .allocator = a, .kind = "state" };
    try parser.nodes.appendSlice(a, &.{
        .{ .id = "P", .label = "Parent", .shape = .round, .container = true, .direction = "LR" },
        .{ .id = "A", .label = "A", .shape = .round, .parent = 0 },
        .{ .id = "B", .label = "B", .shape = .round, .parent = 0 },
        .{ .id = "Done", .label = "Done", .shape = .round },
    });
    try parser.edges.appendSlice(a, &.{ .{ .from = 1, .to = 2, .link = .{ .end = .arrow } }, .{ .from = 0, .to = 3, .link = .{ .end = .arrow } } });
    const nodes = try a.alloc(measurement.Node, 4);
    for (parser.nodes.items, 0..) |n, i| nodes[i] = .{ .id = n.id, .shape = n.shape, .label = n.label, .markdown = false, .text_width = 12, .text_height = 17, .font_size = 16, .lines = &.{n.label} };
    const input: measurement.Input = .{ .schema = "zmermaid-shaped-text-v1", .nodes = nodes,
        .edges = &.{ .{ .index = 0, .source = "A", .target = "B", .label = "", .markdown = false, .width = 0, .height = 0 }, .{ .index = 1, .source = "P", .target = "Done", .label = "", .markdown = false, .width = 0, .height = 0 } },
        .font_family = "Arial", .padding = 8, .direction = "TB", .diagram_family = .state };
    const graph = try compute(a, &parser, input, "TB");
    try std.testing.expectApproxEqAbs(@as(f64, 110), graph.nodes[0].width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 77), graph.nodes[0].height, 0.001);
    try std.testing.expectApproxEqAbs(graph.nodes[0].x + 12, graph.nodes[1].x, 0.001);
    try std.testing.expectApproxEqAbs(graph.nodes[0].y + 32, graph.nodes[1].y, 0.001);
    try std.testing.expectApproxEqAbs(graph.nodes[1].x + 58, graph.nodes[2].x, 0.001);
    try std.testing.expectApproxEqAbs(graph.nodes[0].y + 117, graph.nodes[3].y, 0.001);
    try std.testing.expectApproxEqAbs(graph.nodes[1].x + 28, graph.edges[0].points[0].x, 0.001);
    try std.testing.expectApproxEqAbs(graph.nodes[0].y + 77, graph.edges[1].points[0].y, 0.001);
}
