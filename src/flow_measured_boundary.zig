// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/compound/CompoundGraphPreprocessor.java
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/InvertedPortProcessor.java
// Upstream notice: Copyright (c) 2013, 2020 Kiel University and others.
// Upstream notice: Copyright (c) 2011, 2019 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// Hierarchy-local external-port layout and global edge reassembly.
const std = @import("std");
const flow = @import("flowchart.zig");
const hierarchy = @import("flow_hierarchy.zig");
const measurement = @import("flow_measurement.zig");
const pipeline = @import("flow_measured_layout.zig");
const layout = @import("flow_layout.zig");
const scene = @import("flow_scene.zig");
const Level = struct { graph: scene.Scene, ids: []const usize, segments: []const usize, top: f64 };
fn horizontal(d: []const u8) bool { return std.mem.eql(u8, d, "LR") or std.mem.eql(u8, d, "RL"); }
fn ancestor(nodes: []const flow.Node, group: usize, id: usize) bool {
    var p: ?usize = id;
    while (p) |n| { if (n == group) return true; p = nodes[n].parent; }
    return false;
}
fn clearRoutes(parser: *flow.Parser, graph: scene.Scene) !void {
    for (graph.edges, parser.edges.items) |route, edge| {
        for (graph.nodes, parser.nodes.items, 0..) |box, node, id| {
            if (id == edge.from or id == edge.to or std.mem.eql(u8, node.annotation, "note-group") or (node.container and (ancestor(parser.nodes.items, id, edge.from) or ancestor(parser.nodes.items, id, edge.to)))) continue;
            const left = box.x + 0.5; const right = box.x + box.width - 0.5;
            const top = box.y + 0.5; const bottom = box.y + box.height - 0.5;
            for (route.points[1..], 1..) |p, i| {
                const q = route.points[i - 1];
                if (@abs(p.x - q.x) < 0.001 and p.x > left and p.x < right and @max(p.y, q.y) > top and @min(p.y, q.y) < bottom) return error.NodeObstructsRoute;
                if (@abs(p.y - q.y) < 0.001 and p.y > top and p.y < bottom and @max(p.x, q.x) > left and @min(p.x, q.x) < right) return error.NodeObstructsRoute;
            }
        }
    }
}
const Builder = struct {
    a: std.mem.Allocator,
    parser: *flow.Parser,
    measured: measurement.Input,
    plan: hierarchy.Plan,
    levels: []?Level,
    ports: []scene.Point,
    routes: []scene.Edge,
    root_random_state: u64,
    port_order: []?usize,
    order_changed: bool = false,
    fn endpointId(self: *@This(), endpoint: hierarchy.Endpoint, parent: ?usize) usize {
        return if (endpoint.boundary != null and parent == endpoint.node) self.parser.nodes.items.len + endpoint.boundary.? else endpoint.node;
    }
    fn exportedPort(self: *@This(), p: usize) bool {
        const group = self.plan.ports[p].group;
        for (self.plan.segments) |segment| if (segment.source.boundary == p or segment.target.boundary == p) {
            const edge = self.parser.edges.items[segment.edge];
            if (edge.from == group or edge.to == group) return false;
        };
        return true;
    }
    fn level(self: *@This(), parent: ?usize, direction: []const u8, depth: usize) anyerror!Level {
        if (depth > 16) return error.InvalidHierarchy;
        const count = self.parser.nodes.items.len;
        var local: flow.Parser = .{ .allocator = self.a, .kind = "state", .node_spacing = if (parent == null) 40 else 30, .ordering_model = parent == null, .ordering_parent_state = if (parent == null) null else self.root_random_state };
        var ids: std.ArrayList(usize) = .empty;
        var segments: std.ArrayList(usize) = .empty;
        var nodes: std.ArrayList(measurement.Node) = .empty;
        var sizes: std.ArrayList(measurement.Size) = .empty;
        var external: std.ArrayList(bool) = .empty;
        const map = try self.a.alloc(?usize, count + self.plan.ports.len);
        @memset(map, null);
        for (self.parser.nodes.items, 0..) |node, id| if (node.parent == parent) {
            map[id] = ids.items.len;
            try ids.append(self.a, id);
            var copy = node; copy.container = false; copy.parent = null;
            try local.nodes.append(self.a, copy);
            try nodes.append(self.a, self.measured.nodes[id]);
            try external.append(self.a, false);
            var size = try measurement.measuredNodeSize(self.measured, self.measured.nodes[id]);
            if (node.container) {
                // North/south ports require their own constraint processor
                // when the child's axis differs from its parent.
                const child_direction = node.direction orelse direction;
                for (self.plan.ports) |port| if (port.group == id and !std.mem.eql(u8, child_direction, direction)) return error.UnsupportedPortDirection;
                const child = try self.level(id, child_direction, depth + 1);
                self.levels[id] = child;
                size = .{ .width = child.graph.width + 24, .height = child.graph.height + child.top + 12 };
                if (self.measured.nodes[id].text_width > size.width) return error.UnsupportedTitleExpansion;
            }
            try sizes.append(self.a, size);
        };
        for (self.plan.ports, 0..) |port, p| if (parent == port.group) {
            const id = count + p;
            map[id] = ids.items.len;
            try ids.append(self.a, id);
            const name = try std.fmt.allocPrint(self.a, "boundary:{d}", .{p});
            try local.nodes.append(self.a, .{ .id = name, .label = "", .shape = .text, .external_input = port.input, .external_order = self.port_order[p] });
            try nodes.append(self.a, .{ .id = name, .shape = .text, .label = "", .markdown = false, .text_width = 0, .text_height = 0, .font_size = 16, .lines = &.{} });
            try sizes.append(self.a, .{ .width = 0, .height = 0 });
            try external.append(self.a, true);
        };
        if (ids.items.len == 0 or ids.items.len > 256) return error.InvalidHierarchy;
        var edges: std.ArrayList(measurement.Edge) = .empty;
        var fixed: std.ArrayList(pipeline.FixedPorts) = .empty;
        for (self.plan.segments, 0..) |segment, id| if (segment.level == parent) {
            const from = map[self.endpointId(segment.source, parent)] orelse return error.InvalidHierarchy;
            const to = map[self.endpointId(segment.target, parent)] orelse return error.InvalidHierarchy;
            var edge = self.parser.edges.items[segment.edge];
            edge.from = from; edge.to = to;
            if (!segment.carries_label) edge.link.label = "";
            try local.edges.append(self.a, edge);
            var measured_edge = self.measured.edges[segment.edge];
            measured_edge.index = edges.items.len;
            measured_edge.source = nodes.items[from].id; measured_edge.target = nodes.items[to].id;
            if (!segment.carries_label) {
                measured_edge.label = ""; measured_edge.width = 0; measured_edge.height = 0;
                measured_edge.text_width = 0; measured_edge.text_height = 0; measured_edge.lines = &.{}; measured_edge.runs = &.{};
            }
            try edges.append(self.a, measured_edge);
            try segments.append(self.a, id);
            var pins: pipeline.FixedPorts = .{};
            if (segment.source.boundary) |p| if (parent != segment.source.node) {
                const point = self.ports[p];
                pins.source = .{ .x = if (horizontal(direction)) (if (std.mem.eql(u8, direction, "RL")) sizes.items[from].width - point.x else point.x) else (if (std.mem.eql(u8, direction, "BT")) sizes.items[from].height - point.y else point.y), .y = if (horizontal(direction)) point.y else point.x };
            };
            if (segment.target.boundary) |p| if (parent != segment.target.node) {
                const point = self.ports[p];
                pins.target = .{ .x = if (horizontal(direction)) (if (std.mem.eql(u8, direction, "RL")) sizes.items[to].width - point.x else point.x) else (if (std.mem.eql(u8, direction, "BT")) sizes.items[to].height - point.y else point.y), .y = if (horizontal(direction)) point.y else point.x };
            };
            try fixed.append(self.a, pins);
        };
        var input = self.measured; input.nodes = nodes.items; input.edges = edges.items; input.direction = direction;
        const sides = try self.a.alloc(layout.EdgeSides, fixed.items.len);
        for (fixed.items, 0..) |pins, e| sides[e] = .{ .source = if (pins.source) |p| p.x > 0 else null, .target = if (pins.target) |p| p.x > 0 else null, .source_y = if (pins.source) |p| p.y else null, .target_y = if (pins.target) |p| p.y else null };
        local.ordering_sides = sides;
        const phase_json = try flow.rankTraceParser(self.a, &local, direction);
        const Phase = struct { nodes: []const struct { id: []const u8, rank: usize }, positioned: []const layout.PositionedEntry, port_order: []const layout.OrderedArc, routing_random_state_after_ordering: u64 };
        const phase = (try std.json.parseFromSlice(Phase, self.a, phase_json, .{ .ignore_unknown_fields = true })).value;
        // Propagate the parent's discrete order before geometry. On a WEST
        // side clockwise ordinals run opposite to increasing coordinates.
        for (segments.items, 0..) |sid, e| {
            const segment = self.plan.segments[sid];
            for ([_]bool{true, false}) |source| {
                const endpoint = if (source) segment.source else segment.target;
                if (endpoint.boundary) |p| if (parent != endpoint.node) {
                    var ordinal: ?usize = null;
                    const real = map[endpoint.node].?;
                    for (phase.port_order) |arc| if (arc.edge == e) {
                        const from = arc.from orelse return error.InvalidHierarchy;
                        const to = arc.to orelse return error.InvalidHierarchy;
                        const is_output = phase.positioned[from].real == real;
                        if (!is_output and phase.positioned[to].real != real) continue;
                        const east = if (is_output) arc.source_east else arc.target_east;
                        const key = if (is_output) arc.output else arc.input;
                        var count_ports: usize = 0; var before: usize = 0;
                        for (phase.port_order) |other| {
                            const other_id = (if (is_output) other.from else other.to) orelse continue;
                            if (phase.positioned[other_id].real != real or (if (is_output) other.source_east else other.target_east) != east) continue;
                            count_ports += 1;
                            if ((if (is_output) other.output else other.input) < key) before += 1;
                        }
                        if (count_ports == 0 or before >= count_ports) return error.InvalidHierarchy;
                        ordinal = if (is_output) before else count_ports - 1 - before;
                    };
                    if (ordinal) |value| {
                        if (self.port_order[p] != value) self.order_changed = true;
                        self.port_order[p] = value;
                    }
                };
            }
        }
        const ranks = try self.a.alloc(usize, ids.items.len);
        const endpoints = try self.a.alloc(pipeline.Edge, edges.items.len);
        for (phase.nodes, 0..) |node, i| ranks[i] = node.rank;
        for (local.edges.items, 0..) |edge, i| endpoints[i] = .{ .from = edge.from, .to = edge.to };
        const base: f64 = if (parent == null) 40 else 30;
        const placed = try pipeline.computeGeometry(self.a, input, endpoints, ranks, phase.positioned, phase.port_order, base, base / 2, base / 10, sizes.items, fixed.items, external.items);
        const routed = try @import("flow_orthogonal.zig").computeSpacing(self.a, placed, phase.routing_random_state_after_ordering, base, base / 2);
        var graph = try scene.computeWithBendpoints(self.a, input, placed, routed, phase.port_order, parent == null);
        const top: f64 = if (parent) |p| if (self.measured.nodes[p].label.len > 0) self.measured.nodes[p].text_height + 15 else 12 else 0;
        // External dummies occupy boundary layers, not child content. ELK's
        // hierarchical resize removes those layers and restores graph padding.
        var has_external = false;
        var low: f64 = std.math.inf(f64); var high: f64 = -std.math.inf(f64);
        for (graph.nodes, ids.items, 0..) |box, id, r| {
            if (id >= count) { has_external = true; continue; }
            var left: f64 = 0; var right: f64 = 0;
            for (placed.real, placed.nodes) |real, node| if (real == r) { left = node.left; right = node.right; };
            const forward = std.mem.eql(u8, direction, "LR") or std.mem.eql(u8, direction, "TB");
            low = @min(low, (if (horizontal(direction)) box.x else box.y) - (if (forward) left else right));
            high = @max(high, (if (horizontal(direction)) box.x + box.width else box.y + box.height) + (if (forward) right else left));
        }
        if (has_external) {
            // Routing bands between external dummies and content belong to
            // the group's content area. Only zero-size external layers are
            // removed; cropping to real boxes would erase fan-in/out lanes.
            low = 0;
            high = if (horizontal(direction)) graph.width else graph.height;
            // Labels on inside-parent connections occupy the group's content
            // area. Removing the external layers must not remove label bands.
            for (graph.edges) |edge| if (edge.label) |box| {
                low = @min(low, if (horizontal(direction)) box.x else box.y);
                high = @max(high, if (horizontal(direction)) box.x + box.width else box.y + box.height);
            };
            for (graph.nodes) |*box| { if (horizontal(direction)) box.x -= low else box.y -= low; }
            for (graph.edges) |*edge| {
                const points = try self.a.dupe(scene.Point, edge.points);
                for (points) |*p| { if (horizontal(direction)) p.x -= low else p.y -= low; }
                edge.points = points;
                if (edge.label) |*box| { if (horizontal(direction)) box.x -= low else box.y -= low; }
            }
            if (horizontal(direction)) graph.width = high - low else graph.height = high - low;
            const offset = base / 4; // createExternalPortProperties: edge-edge spacing / 2
            for (ids.items, graph.nodes, 0..) |id, box, n| if (id >= count) {
                const p = id - count; const port = self.plan.ports[p];
                const forward = std.mem.eql(u8, direction, "LR") or std.mem.eql(u8, direction, "TB");
                const leading = port.input == forward;
                var point: scene.Point = .{ .x = box.x, .y = box.y };
                const border_offset: f64 = if (self.exportedPort(p)) offset else 0;
                if (horizontal(direction)) point.x = if (leading) -12 - border_offset else graph.width + 12 + border_offset else point.y = if (leading) -top - border_offset else graph.height + 12 + border_offset;
                self.ports[p] = .{ .x = point.x + 12, .y = point.y + top };
                graph.nodes[n].x = point.x; graph.nodes[n].y = point.y;
                for (segments.items, graph.edges) |sid, *edge| {
                    const segment = self.plan.segments[sid];
                    if (segment.source.boundary == p and segment.source.node == parent) {
                        const points = @constCast(edge.points); points[0] = point;
                    }
                    if (segment.target.boundary == p and segment.target.node == parent) {
                        const points = @constCast(edge.points); points[points.len - 1] = point;
                    }
                }
            };
        }
        return .{ .graph = graph, .ids = ids.items, .segments = segments.items, .top = top };
    }
    fn flatten(self: *@This(), level_: Level, result: *scene.Scene, x: f64, y: f64) anyerror!void {
        for (level_.ids, level_.graph.nodes) |id, box| {
            if (id >= self.parser.nodes.items.len) continue;
            var b = box; b.x += x; b.y += y; result.nodes[id] = b;
            if (self.levels[id]) |child| try self.flatten(child, result, b.x + 12, b.y + child.top);
        }
        for (level_.segments, level_.graph.edges) |id, route| {
            const points = try self.a.dupe(scene.Point, route.points);
            for (points) |*p| { p.x += x; p.y += y; }
            var label = route.label; if (label) |*b| { b.x += x; b.y += y; }
            self.routes[id] = .{ .points = points, .label = label };
        }
    }
};
pub fn compute(a: std.mem.Allocator, parser: *flow.Parser, measured: measurement.Input, direction: []const u8) !scene.Scene {
    const plan = try hierarchy.split(a, parser.nodes.items, parser.edges.items);
    // The hierarchy-wide crossing phase takes its sweep seed from the root,
    // while each child keeps its own cycle-breaker RNG for barycenters.
    var root_nodes: std.ArrayList(flow.Node) = .empty;
    var root_edges: std.ArrayList(flow.Edge) = .empty;
    const root_map = try a.alloc(usize, parser.nodes.items.len);
    for (parser.nodes.items, 0..) |node, id| if (node.parent == null) {
        root_map[id] = root_nodes.items.len; try root_nodes.append(a, node);
    };
    for (plan.segments) |segment| if (segment.level == null) {
        var edge = parser.edges.items[segment.edge];
        edge.from = root_map[segment.source.node]; edge.to = root_map[segment.target.node];
        if (!segment.carries_label) edge.link.label = "";
        try root_edges.append(a, edge);
    };
    var root_detail: @import("flow_rank.zig").SimplexDetail = .{};
    _ = @import("flow_rank.zig").assignDetailed(root_nodes.items, root_edges.items, &root_detail);
    const levels = try a.alloc(?Level, parser.nodes.items.len); @memset(levels, null);
    const port_order = try a.alloc(?usize, plan.ports.len); @memset(port_order, null);
    var builder: Builder = .{ .a = a, .parser = parser, .measured = measured, .plan = plan, .levels = levels,
        .ports = try a.alloc(scene.Point, plan.ports.len), .routes = try a.alloc(scene.Edge, plan.segments.len), .root_random_state = root_detail.random_state, .port_order = port_order };
    var root: Level = undefined;
    for (0..18) |_| {
        builder.order_changed = false;
        root = try builder.level(null, direction, 0);
        if (!builder.order_changed) break;
    } else return error.HierarchyOrderingDidNotConverge;
    var result: scene.Scene = .{ .width = root.graph.width, .height = root.graph.height, .nodes = try a.alloc(scene.Box, measured.nodes.len), .edges = &.{} };
    try builder.flatten(root, &result, 0, 0);
    result.edges = try hierarchy.join(a, plan, builder.routes, parser.edges.items.len);
    try clearRoutes(parser, result);
    return result;
}
