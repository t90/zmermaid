// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/bk/BKNodePlacer.java
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/LabelAndNodeSizeProcessor.java
// Upstream notice: Copyright (c) 2012, 2015 Kiel University and others.
// Upstream notice: Copyright (c) 2010, 2020 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// Measured proper-graph adapter. All geometry is in ELK's internal LR axis.
// Ordering is discrete; no legacy packed coordinate or rounded size is used.
const std = @import("std");
const measurement = @import("flow_measurement.zig");
const prep = @import("flow_preparation.zig");
const bk = @import("flow_bk.zig");
const compaction = @import("flow_compaction.zig");
const selection = @import("flow_selection.zig");
const layout = @import("flow_layout.zig");
const port_graph = @import("flow_port_graph.zig");

pub const Edge = struct { from: usize, to: usize };
pub const PortPoint = struct { x: f64, y: f64 };
pub const FixedPorts = struct { source: ?PortPoint = null, target: ?PortPoint = null };
pub const Result = struct { nodes: []prep.Node, graph: bk.Input, cross: []const f64, real: []const ?usize, edge: []const ?usize, gaps: []const compaction.Spacing, connections: []const port_graph.Connection = &.{} };
fn endpoint(entries: []const layout.PositionedEntry, real_ranks: []const usize, edges: []const Edge, edge: usize, rank: usize) !usize {
    const e = edges[edge];
    const low = if (real_ranks[e.from] < real_ranks[e.to]) e.from else e.to;
    const high = if (low == e.from) e.to else e.from;
    for (entries, 0..) |entry, id| {
        if (entry.rank != rank) continue;
        if (entry.real == low or entry.real == high or (entry.real == null and entry.edge == edge)) return id;
    }
    return error.InvalidProperGraph;
}
pub fn compute(a: std.mem.Allocator, measured: measurement.Input, edges: []const Edge, real_ranks: []const usize, entries: []const layout.PositionedEntry, ordered_arcs: []const layout.OrderedArc, node_spacing: f64, edge_spacing: f64, label_spacing: f64) !Result {
    return computeWithSizes(a, measured, edges, real_ranks, entries, ordered_arcs, node_spacing, edge_spacing, label_spacing, null);
}
// Size overrides are constructed inside the native compound adapter. The
// text host cannot supply a container size or arbitrary placement geometry.
pub fn computeWithSizes(a: std.mem.Allocator, measured: measurement.Input, edges: []const Edge, real_ranks: []const usize, entries: []const layout.PositionedEntry, ordered_arcs: []const layout.OrderedArc, node_spacing: f64, edge_spacing: f64, label_spacing: f64, sizes: ?[]const measurement.Size) !Result {
    return computeGeometry(a, measured, edges, real_ranks, entries, ordered_arcs, node_spacing, edge_spacing, label_spacing, sizes, null, null);
}
pub fn computeGeometry(a: std.mem.Allocator, measured: measurement.Input, edges: []const Edge, real_ranks: []const usize, entries: []const layout.PositionedEntry, ordered_arcs: []const layout.OrderedArc, node_spacing: f64, edge_spacing: f64, label_spacing: f64, sizes: ?[]const measurement.Size, fixed: ?[]const FixedPorts, external: ?[]const bool) !Result {
    if (edges.len != measured.edges.len or real_ranks.len != measured.nodes.len or entries.len == 0 or entries.len > 4096) return error.InvalidProperGraph;
    for ([_]f64{ node_spacing, edge_spacing, label_spacing }) |gap| if (!std.math.isFinite(gap) or gap < 0) return error.InvalidSpacing;
    const n = entries.len;
    const horizontal = std.mem.eql(u8, measured.direction, "LR") or std.mem.eql(u8, measured.direction, "RL");
    const nodes = try a.alloc(prep.Node, n);
    const real = try a.alloc(?usize, n);
    const edge_map = try a.alloc(?usize, n);
    const outgoing = try a.alloc(std.ArrayList(usize), n);
    const incoming = try a.alloc(std.ArrayList(usize), n);
    const arcs = try a.alloc(bk.Arc, ordered_arcs.len);
    for (0..n) |id| {
        outgoing[id] = .empty;
        incoming[id] = .empty;
    }
    for (ordered_arcs, 0..) |arc, id| {
        if (arc.edge >= edges.len) return error.InvalidProperGraph;
        const from = arc.from orelse try endpoint(entries, real_ranks, edges, arc.edge, arc.rank);
        const to = arc.to orelse try endpoint(entries, real_ranks, edges, arc.edge, arc.rank + 1);
        if (from >= n or to >= n) return error.InvalidProperGraph;
        arcs[id] = .{ .from = from, .to = to, .source_y = 0, .target_y = 0, .priority = 0 };
        try outgoing[from].append(a, id);
        try incoming[to].append(a, id);
    }
    const C = struct {
        arcs: []const layout.OrderedArc,
        input: bool,
        fn less(c: @This(), x: usize, y: usize) bool {
            return if (c.input) c.arcs[x].input < c.arcs[y].input else c.arcs[x].output < c.arcs[y].output;
        }
    };
    var infos: std.ArrayList(prep.Info) = .empty;
    for (entries, 0..) |entry, id| {
        std.mem.sort(usize, outgoing[id].items, C{ .arcs = ordered_arcs, .input = false }, C.less);
        std.mem.sort(usize, incoming[id].items, C{ .arcs = ordered_arcs, .input = true }, C.less);
        real[id] = entry.real;
        edge_map[id] = entry.edge;
        var width: f64 = 0;
        var height: f64 = if (entry.inverted) 0 else 1;
        if (entry.real) |r| {
            if (r >= measured.nodes.len) return error.InvalidProperGraph;
            const m = measured.nodes[r];
            const size = if (sizes) |values| values[r] else try measurement.measuredNodeSize(measured, m);
            width = if (horizontal) size.width else size.height;
            height = if (horizontal) size.height else size.width;
        } else {
            const e = entry.edge orelse return error.InvalidProperGraph;
            if (e >= measured.edges.len) return error.InvalidProperGraph;
            if (entry.label) {
                width = if (horizontal) measured.edges[e].width else measured.edges[e].height;
                // Splitter initializes thickness. Horizontal label stacking
                // adds to it; vertical stacking takes max before clearance.
                height = (if (horizontal) measured.edges[e].height + 1 else @max(@as(f64, 1), measured.edges[e].width)) + label_spacing + 1;
            }
            var source: ?usize = null;
            var target: ?usize = null;
            for (entries, 0..) |other, index| {
                if (other.real == edges[e].from) source = index;
                if (other.real == edges[e].to) target = index;
            }
            try infos.append(a, .{ .id = id, .@"inline" = entry.label, .thickness = 1, .source = source, .target = target, .rightward = real_ranks[edges[e].from] < real_ranks[edges[e].to] });
        }
        const ports = try a.alloc(prep.Port, outgoing[id].items.len + incoming[id].items.len);
        for (outgoing[id].items, 0..) |_, ordinal| ports[ordinal] = .{ .order = ordinal, .side = "EAST", .x = if (entry.real != null) width else 0, .y = if (entry.real != null) height * @as(f64, @floatFromInt(ordinal + 1)) / @as(f64, @floatFromInt(outgoing[id].items.len + 1)) else 0, .anchor_x = 0, .anchor_y = 0, .width = 0, .height = 0, .connected = true };
        for (incoming[id].items, 0..) |_, ordinal| {
            const order = outgoing[id].items.len + ordinal;
            ports[order] = .{ .order = order, .side = "WEST", .x = 0, .y = if (entry.real != null) height * @as(f64, @floatFromInt(incoming[id].items.len - ordinal)) / @as(f64, @floatFromInt(incoming[id].items.len + 1)) else 0, .anchor_x = 0, .anchor_y = 0, .width = 0, .height = 0, .connected = true };
        }
        for (outgoing[id].items, 0..) |arc, ordinal| {
            const east = ordered_arcs[arc].source_east;
            ports[ordinal].side = if (east) "EAST" else "WEST";
            ports[ordinal].x = if (east and entry.real != null) width else 0;
        }
        for (incoming[id].items, 0..) |arc, ordinal| {
            const east = ordered_arcs[arc].target_east;
            ports[outgoing[id].items.len + ordinal].side = if (east) "EAST" else "WEST";
            ports[outgoing[id].items.len + ordinal].x = if (east and entry.real != null) width else 0;
        }
        nodes[id] = .{ .id = id, .rank = entry.rank, .position = entry.position, .type = if (entry.real != null) "NORMAL" else if (entry.label) "LABEL" else "LONG_EDGE", .width = width, .height = height, .top = 0, .bottom = 0, .left = 0, .right = 0, .label_side = .UNKNOWN, .ports = ports };
        if (entry.real) |r| {
            const loop_plan = try @import("flow_self_loops.zig").plan(a, measured, r, width);
            nodes[id].top = loop_plan.top;
            nodes[id].left = loop_plan.left;
            nodes[id].right = loop_plan.right;
            if (external) |flags| if (flags[r]) { nodes[id].type = "EXTERNAL_PORT"; };
            if (fixed) |values| {
                for (outgoing[id].items, 0..) |arc, ordinal| {
                    const e = ordered_arcs[arc].edge;
                    const point = if (edges[e].from == r) values[e].source else values[e].target;
                    if (point) |p| { nodes[id].ports[ordinal].x = p.x; nodes[id].ports[ordinal].y = p.y; }
                }
                for (incoming[id].items, 0..) |arc, ordinal| {
                    const e = ordered_arcs[arc].edge;
                    const point = if (edges[e].to == r) values[e].target else values[e].source;
                    if (point) |p| { nodes[id].ports[outgoing[id].items.len + ordinal].x = p.x; nodes[id].ports[outgoing[id].items.len + ordinal].y = p.y; }
                }
                for (nodes[id].ports) |p| {
                    nodes[id].left = @max(nodes[id].left, -p.x);
                    nodes[id].right = @max(nodes[id].right, p.x - width);
                }
            }
        }
    }
    const prepared = try prep.compute(a, .{ .schema = "zmermaid-preparation-input-v1", .nodes = nodes, .label_info = infos.items, .mode = .SMART_UP, .spacing = label_spacing });
    const connections = try a.alloc(port_graph.Connection, arcs.len);
    for (arcs, 0..) |arc, id| {
        var source_port: ?usize = null;
        var target_port: ?usize = null;
        for (outgoing[arc.from].items, 0..) |edge, port| if (edge == id) { source_port = port; };
        for (incoming[arc.to].items, 0..) |edge, port| if (edge == id) { target_port = outgoing[arc.to].items.len + port; };
        connections[id] = .{ .from = arc.from, .to = arc.to, .source_port = source_port orelse return error.InvalidProperGraph, .target_port = target_port orelse return error.InvalidProperGraph };
    }
    const graph = try port_graph.compute(a, .{ .nodes = prepared.nodes, .connections = connections });
    const graph_nodes = graph.nodes;
    var gaps: std.ArrayList(compaction.Spacing) = .empty;
    for (prepared.nodes, 0..) |node, id| {
        if (node.position > 0) {
            var previous: ?usize = null;
            for (prepared.nodes[0..id], 0..) |other, p| if (other.rank == node.rank and other.position + 1 == node.position) {
                previous = p;
            };
            const p = previous orelse return error.InvalidProperGraph;
            // NORMAL/LABEL uses node-node spacing, not a narrow corridor.
            const node_pair = (std.mem.eql(u8, prepared.nodes[p].type, "NORMAL") and (std.mem.eql(u8, node.type, "NORMAL") or entries[id].label)) or (std.mem.eql(u8, node.type, "NORMAL") and entries[p].label);
            try gaps.append(a, .{ .before = p, .after = id, .value = if (node_pair) node_spacing else edge_spacing });
        }
    }
    const alignment = try bk.compute(a, graph);
    var candidates: [4]selection.Candidate = undefined;
    for (alignment.layouts, 0..) |candidate, index| candidates[index] = .{ .left = candidate.left, .up = candidate.up, .mode = "IMPROVE_STRAIGHTNESS", .alignment = .{ .root = candidate.root, .inner_shift = candidate.inner_shift, .block_size = candidate.block_size }, .final = .{ .block_y = try compaction.compact(a, graph, gaps.items, node_spacing, candidate, true) } };
    const chosen = try selection.compute(a, graph_nodes, candidates);
    return .{ .nodes = prepared.nodes, .graph = graph, .cross = chosen.policies[0].node_y, .real = real, .edge = edge_map, .gaps = gaps.items, .connections = connections };
}

test "fractional proper-graph placement consumes measured ports and verified BK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const measured: measurement.Input = .{ .schema = "zmermaid-shaped-text-v1", .nodes = &.{
        .{ .id = "A", .shape = .box, .label = "A", .markdown = false, .text_width = 10.125, .text_height = 17.75, .font_size = 16, .lines = &.{"A"} },
        .{ .id = "B", .shape = .box, .label = "B", .markdown = false, .text_width = 20.375, .text_height = 17.75, .font_size = 16, .lines = &.{"B"} },
    }, .edges = &.{.{ .index = 0, .source = "A", .target = "B", .label = "", .markdown = false, .width = 0, .height = 0 }}, .font_family = "Arial", .padding = 15, .direction = "LR" };
    const entries = [_]layout.PositionedEntry{
        .{ .rank = 0, .position = 0, .real = 0, .edge = null, .label = false, .cross = 999, .cross_size = 999, .along_size = 999 },
        .{ .rank = 1, .position = 0, .real = 1, .edge = null, .label = false, .cross = 999, .cross_size = 999, .along_size = 999 },
    };
    const result = try compute(a, measured, &.{.{ .from = 0, .to = 1 }}, &.{ 0, 1 }, &entries, &.{.{ .edge = 0, .rank = 0, .output = 0, .input = 0 }}, 40, 10, 10);
    try std.testing.expectEqual(@as(f64, 70.125), result.nodes[0].width);
    try std.testing.expectEqual(@as(f64, 23.875), result.graph.arcs[0].source_y);
    try std.testing.expectApproxEqAbs(result.cross[0], result.cross[1], 1e-9);
}
