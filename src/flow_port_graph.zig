// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/bk/BKNodePlacer.java
// Upstream notice: Copyright (c) 2012, 2015 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// Explicit prepared-port graph handoff. Same-layer arcs are retained;
// BK itself excludes them from alignment neighbours, as ELK does.
const std = @import("std");
const prep = @import("flow_preparation.zig");
const bk = @import("flow_bk.zig");
pub const Connection = struct { from: usize, source_port: usize, to: usize, target_port: usize, priority: i32 = 0 };
pub const Input = struct { nodes: []const prep.Node, connections: []const Connection };
pub fn compute(a: std.mem.Allocator, input: Input) !bk.Input {
    if (input.nodes.len == 0 or input.nodes.len > 4096 or input.connections.len > 16384) return error.InvalidPortGraph;
    const arcs = try a.alloc(bk.Arc, input.connections.len);
    for (input.connections, 0..) |c, id| {
        if (c.from >= input.nodes.len or c.to >= input.nodes.len) return error.InvalidPortGraph;
        const source = input.nodes[c.from]; const target = input.nodes[c.to];
        if (c.source_port >= source.ports.len or c.target_port >= target.ports.len) return error.InvalidPortGraph;
        const sp = source.ports[c.source_port]; const tp = target.ports[c.target_port];
        const sy = sp.y + sp.anchor_y; const ty = tp.y + tp.anchor_y;
        if (!std.math.isFinite(sy) or !std.math.isFinite(ty)) return error.InvalidPortGraph;
        arcs[id] = .{ .from = c.from, .to = c.to, .source_y = sy, .target_y = ty, .priority = c.priority };
    }
    const nodes = try a.alloc(bk.Node, input.nodes.len);
    for (input.nodes, 0..) |n, id| {
        if (n.id != id) return error.InvalidPortGraph;
        var incoming: std.ArrayList(usize) = .empty; var outgoing: std.ArrayList(usize) = .empty; var connected: std.ArrayList(usize) = .empty;
        // LNode iterates clockwise ports; each LPort combines incoming then outgoing.
        // Do not infer side from direction: inverted EAST inputs / WEST outputs
        // and multiple edges on the same port must retain their actual identity.
        for (n.ports, 0..) |p, port| {
            if (p.order != port) return error.InvalidPortGraph;
            for (input.connections, 0..) |c, edge| if (c.to == id and c.target_port == port) {
                try incoming.append(a, edge); try connected.append(a, edge);
            };
            for (input.connections, 0..) |c, edge| if (c.from == id and c.source_port == port) {
                try outgoing.append(a, edge); try connected.append(a, edge);
            };
        }
        nodes[id] = .{ .rank = n.rank, .position = n.position, .extent = n.height, .top = n.top, .bottom = n.bottom,
            .long_edge = std.mem.eql(u8, n.type, "LONG_EDGE"), .incoming = incoming.items, .outgoing = outgoing.items, .connected = connected.items };
    }
    return .{ .nodes = nodes, .arcs = arcs };
}
pub fn trace(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const scratch = arena.allocator();
    const input = (try std.json.parseFromSlice(Input, scratch, source, .{})).value;
    return std.json.Stringify.valueAlloc(a, try compute(scratch, input), .{});
}

test "explicit ports preserve same-layer arcs and anchors without inventing direction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ports = [_]prep.Port{.{ .order = 0, .side = "WEST", .x = 0, .y = 12.25, .anchor_x = 0, .anchor_y = 0.5, .width = 0, .height = 0, .connected = true }};
    const nodes = [_]prep.Node{
        .{ .id = 0, .rank = 0, .position = 0, .type = "NORMAL", .width = 40, .height = 30, .top = 0, .bottom = 0, .left = 0, .right = 0, .label_side = null, .ports = &ports },
        .{ .id = 1, .rank = 0, .position = 1, .type = "LONG_EDGE", .width = 0, .height = 0, .top = 0, .bottom = 0, .left = 0, .right = 0, .label_side = null, .ports = &ports },
    };
    const graph = try compute(a, .{ .nodes = &nodes, .connections = &.{.{ .from = 0, .source_port = 0, .to = 1, .target_port = 0 }} });
    try std.testing.expectEqual(@as(f64, 12.75), graph.arcs[0].source_y);
    try std.testing.expectEqualSlices(usize, &.{0}, graph.nodes[0].outgoing);
    try std.testing.expectEqualSlices(usize, &.{0}, graph.nodes[1].incoming);
    const alignment = try bk.compute(a, graph);
    try std.testing.expectEqual(@as(usize, 0), alignment.right_neighbors[0].len);
    try std.testing.expectEqual(@as(usize, 0), alignment.left_neighbors[1].len);
    const measured = @import("flow_measured_layout.zig");
    const result: measured.Result = .{ .nodes = @constCast(&nodes), .graph = graph, .cross = &.{ 0, 50 }, .real = &.{ 0, null }, .edge = &.{ null, 0 }, .gaps = &.{} };
    try std.testing.expectError(error.InLayerRoutingRequired, @import("flow_orthogonal.zig").computeSpacing(a, result, 0, 40, 20));
    try std.testing.expectError(error.InvalidPortGraph, compute(a, .{ .nodes = &nodes, .connections = &.{.{ .from = 0, .source_port = 1, .to = 1, .target_port = 0 }} }));
}
