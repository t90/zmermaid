// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/InvertedPortProcessor.java
// Upstream notice: Copyright (c) 2011, 2019 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// Semantic InvertedPortProcessor stage. No coordinates or routing repairs.
// ELK visits each layer's NORMAL nodes, EAST inputs, then WEST outputs.
const std = @import("std");
pub const Side = enum { WEST, EAST, NORTH, SOUTH };
pub const Node = struct { rank: usize, normal: bool = true, fixed: bool = true };
pub const Port = struct { node: usize, side: Side };
pub const Edge = struct { source: usize, target: usize, original: usize, head: usize = 0, center: usize = 0, tail: usize = 0, junctions: bool = false };
pub const Input = struct { nodes: []const Node, ports: []const Port, edges: []const Edge };
pub const Result = struct { nodes: []const Node, ports: []const Port, edges: []const Edge };
pub fn compute(a: std.mem.Allocator, input: Input) !Result {
    if (input.nodes.len > 4096 or input.ports.len > 8192 or input.edges.len > 8192) return error.LimitExceeded;
    for (input.nodes) |n| if (n.rank > 4096) return error.InvalidGraph;
    for (input.ports) |p| if (p.node >= input.nodes.len) return error.InvalidGraph;
    for (input.edges) |e| if (e.source >= input.ports.len or e.target >= input.ports.len) return error.InvalidGraph;
    var nodes: std.ArrayList(Node) = .empty; try nodes.appendSlice(a, input.nodes);
    var ports: std.ArrayList(Port) = .empty; try ports.appendSlice(a, input.ports);
    var edges: std.ArrayList(Edge) = .empty; try edges.appendSlice(a, input.edges);
    var last: usize = 0; for (input.nodes) |n| last = @max(last, n.rank);
    for (0..last + 1) |rank| for (input.nodes, 0..) |node, id| {
        if (node.rank != rank or !node.normal or !node.fixed) continue;
        for ([_]Side{ .EAST, .WEST }) |side| for (input.ports, 0..) |port, p| {
            if (port.node != id or port.side != side) continue;
            const end = edges.items.len; // ELK copies the incident list first.
            for (0..end) |e| {
                const edge = edges.items[e];
                if ((side == .EAST and edge.target != p) or (side == .WEST and edge.source != p)) continue;
                if (ports.items[edge.source].node == ports.items[edge.target].node) continue;
                const dummy = nodes.items.len;
                try nodes.append(a, .{ .rank = rank, .normal = false, .fixed = true });
                const west = ports.items.len;
                try ports.append(a, .{ .node = dummy, .side = .WEST });
                const east = ports.items.len;
                try ports.append(a, .{ .node = dummy, .side = .EAST });
                // Both variants replace the target of the original edge.
                // WEST source -> WEST dummy is an in-layer connection;
                // EAST dummy -> EAST target is the opposite in-layer case.
                edges.items[e].target = west;
                edges.items[e].head = 0;
                try edges.append(a, .{ .source = east, .target = edge.target, .original = edge.original, .head = edge.head });
            }
        };
    };
    return .{ .nodes = nodes.items, .ports = ports.items, .edges = edges.items };
}
pub fn trace(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const scratch = arena.allocator();
    const input = (try std.json.parseFromSlice(Input, scratch, source, .{})).value;
    return std.json.Stringify.valueAlloc(a, try compute(scratch, input), .{});
}
test "both inverted endpoints split through same-layer dummies and retain label ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const r = try compute(arena.allocator(), .{ .nodes = &.{ .{ .rank = 0 }, .{ .rank = 1 } }, .ports = &.{ .{ .node = 0, .side = .WEST }, .{ .node = 1, .side = .EAST } }, .edges = &.{.{ .source = 0, .target = 1, .original = 0, .head = 1, .center = 2, .tail = 3, .junctions = true }} });
    try std.testing.expectEqual(@as(usize, 4), r.nodes.len);
    try std.testing.expectEqual(@as(usize, 3), r.edges.len);
    try std.testing.expectEqual(@as(usize, 2), r.edges[0].center);
    try std.testing.expectEqual(@as(usize, 3), r.edges[0].tail);
    try std.testing.expectEqual(@as(usize, 1), r.edges[2].head);
    try std.testing.expect(r.edges[0].junctions);
    try std.testing.expect(!r.edges[1].junctions and !r.edges[2].junctions);
}
test "invalid inverted-port endpoints are rejected" {
    try std.testing.expectError(error.InvalidGraph, compute(std.testing.allocator, .{ .nodes = &.{}, .ports = &.{.{ .node = 0, .side = .WEST }}, .edges = &.{} }));
}
