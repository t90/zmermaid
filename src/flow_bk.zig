// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/bk/BKAligner.java
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/bk/BKNodePlacer.java
// Upstream notice: Copyright (c) 2015 Kiel University and others.
// Upstream notice: Copyright (c) 2012, 2015 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// BK phase mechanics follow ELK 0.10 NeighborhoodInformation, BKNodePlacer
// conflict marking and BKAligner. Compaction/thresholds are separate stages.
const std = @import("std");
pub const Node = struct {
    rank: usize, position: usize, extent: f64, top: f64, bottom: f64,
    long_edge: bool, incoming: []const usize, outgoing: []const usize, connected: []const usize,
};
pub const Arc = struct { from: usize, to: usize, source_y: f64, target_y: f64, priority: i32 };
pub const Input = struct { nodes: []const Node, arcs: []const Arc };
pub const Layout = struct {
    left: bool, up: bool, root: []usize, @"align": []usize,
    inner_shift: []f64, block_size: []?f64, only_dummies: []bool,
};
pub const Result = struct { left_neighbors: [][]usize, right_neighbors: [][]usize, conflicts: []bool, layouts: [4]Layout };

fn neighbors(a: std.mem.Allocator, graph: Input, id: usize, left: bool) ![]usize {
    const incident = if (left) graph.nodes[id].incoming else graph.nodes[id].outgoing;
    var result: std.ArrayList(usize) = .empty;
    var priority: i32 = 0;
    for (incident) |index| {
        const edge = graph.arcs[index];
        if (graph.nodes[edge.from].rank == graph.nodes[edge.to].rank) continue;
        if (edge.priority > priority) { result.clearRetainingCapacity(); priority = edge.priority; }
        if (edge.priority == priority) try result.append(a, index);
    }
    // Stable ordering matters when several edges have the same neighbour.
    const Context = struct {
        graph: Input, left: bool,
        fn less(c: @This(), x: usize, y: usize) bool {
            const ex = c.graph.arcs[x]; const ey = c.graph.arcs[y];
            return c.graph.nodes[if (c.left) ex.from else ex.to].position < c.graph.nodes[if (c.left) ey.from else ey.to].position;
        }
    };
    std.mem.sort(usize, result.items, Context{ .graph = graph, .left = left }, Context.less);
    return result.toOwnedSlice(a);
}

fn inner(graph: Input, id: usize) bool {
    if (!graph.nodes[id].long_edge) return false;
    for (graph.nodes[id].incoming) |index| {
        const from = graph.arcs[index].from;
        if (graph.nodes[from].long_edge and graph.nodes[from].rank + 1 == graph.nodes[id].rank) return true;
    }
    return false;
}

pub fn compute(a: std.mem.Allocator, graph: Input) !Result {
    const n = graph.nodes.len;
    if (n == 0 or n > 4096 or graph.arcs.len > 16384) return error.UnsupportedGraph;
    var highest: usize = 0;
    for (graph.nodes, 0..) |node, id| {
        if (node.rank > 4095 or !std.math.isFinite(node.extent) or node.extent < 0 or
            !std.math.isFinite(node.top) or !std.math.isFinite(node.bottom) or node.top < 0 or node.bottom < 0) return error.InvalidGraph;
        highest = @max(highest, node.rank);
        for (node.incoming) |index| if (index >= graph.arcs.len or graph.arcs[index].to != id) { return error.InvalidGraph; };
        for (node.outgoing) |index| if (index >= graph.arcs.len or graph.arcs[index].from != id) { return error.InvalidGraph; };
        for (node.connected) |index| if (index >= graph.arcs.len or (graph.arcs[index].from != id and graph.arcs[index].to != id)) { return error.InvalidGraph; };
    }
    for (graph.arcs) |edge| if (edge.from >= n or edge.to >= n or
        !std.math.isFinite(edge.source_y) or !std.math.isFinite(edge.target_y)) { return error.InvalidGraph; };
    const layers = try a.alloc(std.ArrayList(usize), highest + 1);
    for (layers) |*layer| layer.* = .empty;
    for (graph.nodes, 0..) |node, id| {
        if (node.position != layers[node.rank].items.len) return error.InvalidGraph;
        try layers[node.rank].append(a, id);
    }
    for (layers) |layer| if (layer.items.len == 0) { return error.InvalidGraph; };
    const left = try a.alloc([]usize, n); const right = try a.alloc([]usize, n);
    for (0..n) |id| { left[id] = try neighbors(a, graph, id, true); right[id] = try neighbors(a, graph, id, false); }
    const marked = try a.alloc(bool, graph.arcs.len); @memset(marked, false);
    if (highest >= 2) for (2..highest + 1) |rank| {
        var k0: usize = 0; var scan: usize = 0;
        for (layers[rank].items, 0..) |id, boundary| {
            const is_inner = inner(graph, id);
            if (boundary + 1 != layers[rank].items.len and !is_inner) continue;
            var k1 = layers[rank - 1].items.len - 1;
            if (is_inner) {
                if (left[id].len == 0) return error.InvalidGraph;
                k1 = graph.nodes[graph.arcs[left[id][0]].from].position;
            }
            while (scan <= boundary) : (scan += 1) {
                const current = layers[rank].items[scan];
                if (inner(graph, current)) continue;
                for (left[current]) |edge| {
                    const k = graph.nodes[graph.arcs[edge].from].position;
                    if (k < k0 or k > k1) marked[edge] = true;
                }
            }
            k0 = k1;
        }
    };
    var result: Result = .{ .left_neighbors = left, .right_neighbors = right, .conflicts = marked, .layouts = undefined };
    for (0..4) |direction| {
        const hleft = direction >= 2; const up = direction % 2 == 1;
        const roots = try a.alloc(usize, n); const aligns = try a.alloc(usize, n);
        const shifts = try a.alloc(f64, n); const sizes = try a.alloc(?f64, n);
        const dummies = try a.alloc(bool, n);
        for (0..n) |id| { roots[id] = id; aligns[id] = id; }
        @memset(shifts, 0); @memset(sizes, null); @memset(dummies, true);
        for (0..layers.len) |layer_step| {
            const rank = if (hleft) highest - layer_step else layer_step;
            const layer = layers[rank].items;
            var previous: isize = if (up) std.math.maxInt(isize) else -1;
            for (0..layer.len) |step| {
                const id = layer[if (up) layer.len - 1 - step else step];
                const ns = if (hleft) right[id] else left[id];
                if (ns.len == 0) continue;
                const low = (ns.len - 1) / 2; const high = ns.len / 2;
                for (0..high - low + 1) |median_step| {
                    if (aligns[id] != id) break;
                    const arc_id = ns[if (up) high - median_step else low + median_step];
                    const edge = graph.arcs[arc_id];
                    const neighbor = if (hleft) edge.to else edge.from;
                    const pos: isize = @intCast(graph.nodes[neighbor].position);
                    if (!marked[arc_id] and (if (up) previous > pos else previous < pos)) {
                        aligns[neighbor] = id; roots[id] = roots[neighbor]; aligns[id] = roots[id];
                        dummies[roots[id]] = dummies[roots[id]] and graph.nodes[id].long_edge;
                        previous = pos;
                    }
                }
            }
        }
        for (0..n) |root| {
            if (roots[root] != root) continue;
            var above = graph.nodes[root].top;
            var below = graph.nodes[root].extent + graph.nodes[root].bottom;
            var current = root; var guard: usize = 0;
            while (aligns[current] != root) {
                const next = aligns[current];
                var edge_id: ?usize = null;
                for (graph.nodes[current].connected) |index| {
                    const edge = graph.arcs[index];
                    if (edge.from == next or edge.to == next) { edge_id = index; break; }
                }
                const edge = graph.arcs[edge_id orelse return error.InvalidGraph];
                const delta = if (hleft) edge.target_y - edge.source_y else edge.source_y - edge.target_y;
                shifts[next] = shifts[current] + delta;
                above = @max(above, graph.nodes[next].top - shifts[next]);
                below = @max(below, shifts[next] + graph.nodes[next].extent + graph.nodes[next].bottom);
                current = next; guard += 1; if (guard >= n) return error.InvalidGraph;
            }
            current = root;
            while (true) { shifts[current] += above; current = aligns[current]; if (current == root) break; }
            sizes[root] = above + below;
        }
        result.layouts[direction] = .{ .left = hleft, .up = up, .root = roots, .@"align" = aligns,
            .inner_shift = shifts, .block_size = sizes, .only_dummies = dummies };
    }
    return result;
}

pub fn trace(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator); defer arena.deinit();
    const a = arena.allocator();
    const graph = try std.json.parseFromSlice(Input, a, source, .{});
    const result = try compute(a, graph.value);
    return std.json.Stringify.valueAlloc(allocator, result, .{});
}

test "BK block shifts straighten asymmetric ports and include margins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const nodes = [_]Node{
        .{ .rank = 0, .position = 0, .extent = 100, .top = 2, .bottom = 3, .long_edge = false, .incoming = &.{}, .outgoing = &.{0}, .connected = &.{0} },
        .{ .rank = 1, .position = 0, .extent = 40, .top = 4, .bottom = 5, .long_edge = false, .incoming = &.{0}, .outgoing = &.{}, .connected = &.{0} },
    };
    const arcs = [_]Arc{.{ .from = 0, .to = 1, .source_y = 70, .target_y = 10, .priority = 0 }};
    const result = try compute(arena.allocator(), .{ .nodes = &nodes, .arcs = &arcs });
    for (result.layouts) |layout| {
        try std.testing.expectApproxEqAbs(layout.inner_shift[0] + 70, layout.inner_shift[1] + 10, 0.00001);
        try std.testing.expectApproxEqAbs(@as(f64, 107), layout.block_size[layout.root[0]].?, 0.00001);
    }
}

test "BK neighbourhood retains only highest straightness priority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const nodes = [_]Node{
        .{ .rank = 0, .position = 0, .extent = 50, .top = 0, .bottom = 0, .long_edge = false, .incoming = &.{}, .outgoing = &.{0}, .connected = &.{0} },
        .{ .rank = 0, .position = 1, .extent = 50, .top = 0, .bottom = 0, .long_edge = false, .incoming = &.{}, .outgoing = &.{1}, .connected = &.{1} },
        .{ .rank = 1, .position = 0, .extent = 50, .top = 0, .bottom = 0, .long_edge = false, .incoming = &.{ 0, 1 }, .outgoing = &.{}, .connected = &.{ 0, 1 } },
    };
    const arcs = [_]Arc{
        .{ .from = 0, .to = 2, .source_y = 25, .target_y = 25, .priority = 0 },
        .{ .from = 1, .to = 2, .source_y = 25, .target_y = 25, .priority = 2 },
    };
    const result = try compute(arena.allocator(), .{ .nodes = &nodes, .arcs = &arcs });
    try std.testing.expectEqualSlices(usize, &.{1}, result.left_neighbors[2]);
}

test "BK rejects missing layers and malformed incidences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const nodes = [_]Node{.{ .rank = 1, .position = 0, .extent = 10, .top = 0, .bottom = 0,
        .long_edge = false, .incoming = &.{}, .outgoing = &.{}, .connected = &.{} }};
    try std.testing.expectError(error.InvalidGraph, compute(arena.allocator(), .{ .nodes = &nodes, .arcs = &.{} }));
}
