// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/counting/CrossingsCounter.java
// Upstream notice: Copyright (c) 2016, 2018 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// ELK CrossingsCounter's WEST/EAST in-layer scan. Counts both overlapping
// same-layer arcs and inter-layer edges passing through their open intervals.
const std = @import("std");
pub const Node = struct { rank: usize, position: usize };
pub const Side = enum { WEST, EAST };
pub const Port = struct { node: usize, side: Side, ordinal: usize };
pub const Edge = struct { source: usize, target: usize };
pub const Input = struct { nodes: []const Node, ports: []const Port, edges: []const Edge };
pub const Count = struct { rank: usize, west: usize, east: usize };
pub fn compute(a: std.mem.Allocator, input: Input) ![]Count {
    if (input.nodes.len == 0 or input.nodes.len > 768 or input.ports.len > 8192 or input.edges.len > 4096) return error.InvalidCrossingGraph;
    var last: usize = 0;
    for (input.nodes, 0..) |node, i| {
        if (node.rank >= 768 or node.position >= 768) return error.InvalidCrossingGraph;
        for (input.nodes[0..i]) |other| if (other.rank == node.rank and other.position == node.position) return error.InvalidCrossingGraph;
        last = @max(last, node.rank);
    }
    for (input.ports, 0..) |p, i| {
        if (p.node >= input.nodes.len) return error.InvalidCrossingGraph;
        for (input.ports[0..i]) |other| if (other.node == p.node and other.side == p.side and other.ordinal == p.ordinal) return error.InvalidCrossingGraph;
    }
    for (input.edges) |e| {
        if (e.source >= input.ports.len or e.target >= input.ports.len) return error.InvalidCrossingGraph;
        const sp = input.ports[e.source]; const tp = input.ports[e.target];
        if (input.nodes[sp.node].rank == input.nodes[tp.node].rank and sp.side != tp.side) return error.UnsupportedInLayerSides;
    }
    const output = try a.alloc(Count, last + 1);
    const positions = try a.alloc(usize, input.ports.len);
    const active = try a.alloc(usize, input.ports.len);
    const pending = try a.alloc(usize, input.ports.len);
    for (0..last + 1) |rank| {
        output[rank] = .{ .rank = rank, .west = 0, .east = 0 };
        for ([_]Side{ .WEST, .EAST }) |side| {
            var order: std.ArrayList(usize) = .empty;
            for (input.ports, 0..) |p, id| if (input.nodes[p.node].rank == rank and p.side == side) { try order.append(a, id); };
            const Context = struct {
                nodes: []const Node, ports: []const Port, side: Side,
                fn less(c: @This(), x: usize, y: usize) bool {
                    const p = c.ports[x]; const q = c.ports[y];
                    if (c.nodes[p.node].position != c.nodes[q.node].position) return c.nodes[p.node].position < c.nodes[q.node].position;
                    return if (c.side == .EAST) p.ordinal < q.ordinal else p.ordinal > q.ordinal;
                }
            };
            std.mem.sort(usize, order.items, Context{ .nodes = input.nodes, .ports = input.ports, .side = side }, Context.less);
            for (order.items, 0..) |p, index| positions[p] = index;
            @memset(active, 0);
            var crossings: usize = 0;
            for (order.items, 0..) |p, index| {
                active[index] = 0;
                @memset(pending, 0);
                var between: usize = 0;
                // ELK combines incoming then outgoing incidences on a port.
                for ([_]bool{true, false}) |incoming| for (input.edges) |e| {
                    if ((if (incoming) e.target else e.source) != p) continue;
                    const other = if (incoming) e.source else e.target;
                    if (input.nodes[input.ports[other].node].rank == rank) {
                        const end = positions[other];
                        if (end > index) {
                            for (active[0..end]) |count| crossings += count;
                            pending[end] += 1;
                        }
                    } else between += 1;
                };
                for (active) |count| crossings += count * between;
                for (active, pending) |*count, extra| count.* += extra;
            }
            if (side == .WEST) output[rank].west = crossings else output[rank].east = crossings;
        }
    }
    return output;
}
pub fn trace(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const scratch = arena.allocator();
    const input = (try std.json.parseFromSlice(Input, scratch, source, .{})).value;
    return std.json.Stringify.valueAlloc(a, try compute(scratch, input), .{});
}

test "in-layer interval includes passing inter-layer lines but not its shared endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const result = try compute(arena.allocator(), .{
        .nodes = &.{ .{ .rank = 0, .position = 0 }, .{ .rank = 0, .position = 1 }, .{ .rank = 0, .position = 2 }, .{ .rank = 1, .position = 0 } },
        .ports = &.{ .{ .node = 0, .side = .WEST, .ordinal = 0 }, .{ .node = 1, .side = .WEST, .ordinal = 0 }, .{ .node = 2, .side = .WEST, .ordinal = 0 }, .{ .node = 3, .side = .EAST, .ordinal = 0 } },
        .edges = &.{ .{ .source = 0, .target = 2 }, .{ .source = 3, .target = 1 }, .{ .source = 3, .target = 0 } },
    });
    try std.testing.expectEqual(@as(usize, 1), result[0].west);
    try std.testing.expectEqual(@as(usize, 0), result[0].east);
}
