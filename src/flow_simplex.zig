// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p2layers/NetworkSimplexLayerer.java
// Upstream notice: Copyright (c) 2010, 2020 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
const std = @import("std");

const real_node_limit = 256;
const real_edge_limit = 512;
const node_limit = real_node_limit + real_edge_limit;
const edge_limit = real_edge_limit * 2;

/// Internal nodes created while expanding labelled or long edges, including
/// their ranks in the simplex constraint graph.
pub const Detail = struct {
    order_count: usize = 0,
    order: [node_limit]usize = undefined,
    random_state: u64 = 0,
    node_count: usize = 0,
    real_node_count: usize = 0,
    ranks: [node_limit]isize = [_]isize{0} ** node_limit,
    source_edge: [node_limit]?usize = [_]?usize{null} ** node_limit,
    segment: [node_limit]usize = [_]usize{0} ** node_limit,
    label_dummy: [node_limit]bool = [_]bool{false} ** node_limit,
};

const Edge = struct { from: usize, to: usize, active: bool = true, tree: bool = false };

const Graph = struct {
    node_count: usize,
    edge_count: usize,
    rank: [node_limit]isize = [_]isize{0} ** node_limit,
    edges: [edge_limit]Edge = undefined,
    active_node: [node_limit]bool = [_]bool{false} ** node_limit,
    base_order: [node_limit]usize = undefined,
    base_count: usize = 0,
    node_order: [node_limit]usize = undefined,
    order_count: usize = 0,
    edge_order: [edge_limit]usize = undefined,
    ordered_edges: usize = 0,
    tree_order: [node_limit]usize = undefined,
    tree_count: usize = 0,
    tree_node: [node_limit]bool = [_]bool{false} ** node_limit,
    edge_visited: [edge_limit]bool = [_]bool{false} ** edge_limit,
    po: [node_limit]usize = [_]usize{0} ** node_limit,
    low: [node_limit]usize = [_]usize{0} ** node_limit,
    post_order: usize = 1,
    cut: [edge_limit]isize = [_]isize{0} ** edge_limit,
    removed_nodes: [node_limit]usize = undefined,
    removed_edges: [node_limit]usize = undefined,
    removed_count: usize = 0,

    fn connectedDegree(self: *const Graph, node: usize) usize {
        var count: usize = 0;
        for (self.edges[0..self.edge_count]) |edge| if (edge.active and (edge.from == node or edge.to == node)) {
            count += 1;
        };
        return count;
    }

    fn oneConnectedEdge(self: *const Graph, node: usize) ?usize {
        for (self.edges[0..self.edge_count], 0..) |edge, edge_i| if (edge.active and (edge.from == node or edge.to == node)) return edge_i;
        return null;
    }

    fn removeSubtrees(self: *Graph) void {
        if (self.node_count < 40) return;
        var queue: [edge_limit * 2]usize = undefined;
        var read: usize = 0;
        var write: usize = 0;
        for (0..self.node_count) |node| if (self.connectedDegree(node) == 1) {
            queue[write] = node;
            write += 1;
        };
        while (read < write) {
            const node = queue[read];
            read += 1;
            if (!self.active_node[node]) continue;
            const edge_i = self.oneConnectedEdge(node) orelse continue;
            const edge = self.edges[edge_i];
            const other = if (edge.from == node) edge.to else edge.from;
            self.edges[edge_i].active = false;
            self.active_node[node] = false;
            self.removed_nodes[self.removed_count] = node;
            self.removed_edges[self.removed_count] = edge_i;
            self.removed_count += 1;
            if (self.active_node[other] and self.connectedDegree(other) == 1) {
                queue[write] = other;
                write += 1;
            }
        }
    }

    fn rebuildOrder(self: *Graph) void {
        self.order_count = 0;
        for (self.base_order[0..self.base_count]) |node| if (self.active_node[node]) {
            self.node_order[self.order_count] = node;
            self.order_count += 1;
        };
        self.ordered_edges = 0;
        for (self.node_order[0..self.order_count]) |node| {
            for (self.edges[0..self.edge_count], 0..) |edge, edge_i| if (edge.active and edge.from == node) {
                self.edge_order[self.ordered_edges] = edge_i;
                self.ordered_edges += 1;
            };
        }
    }

    fn topologicalRanks(self: *Graph) void {
        var incident = [_]usize{0} ** node_limit;
        for (self.edge_order[0..self.ordered_edges]) |edge_i| incident[self.edges[edge_i].to] += 1;
        var queue: [node_limit]usize = undefined;
        var read: usize = 0;
        var write: usize = 0;
        for (self.node_order[0..self.order_count]) |node| if (incident[node] == 0) {
            queue[write] = node;
            write += 1;
        };
        while (read < write) {
            const node = queue[read];
            read += 1;
            for (self.edge_order[0..self.ordered_edges]) |edge_i| {
                const edge = self.edges[edge_i];
                if (edge.from != node) continue;
                self.rank[edge.to] = @max(self.rank[edge.to], self.rank[node] + 1);
                incident[edge.to] -= 1;
                if (incident[edge.to] == 0) {
                    queue[write] = edge.to;
                    write += 1;
                }
            }
        }
    }

    fn visitConnected(self: *Graph, node: usize, visitor: anytype) void {
        // NNode.getConnectedEdges() concatenates each node's insertion-ordered
        // incoming list with its insertion-ordered outgoing list. This is not
        // the same as NetworkSimplex's source-grouped global edge order.
        for (self.edge_order[0..self.ordered_edges]) |edge_i| {
            const edge = self.edges[edge_i];
            if (edge.active and edge.to == node) visitor.call(self, edge_i, edge.from);
        }
        for (self.edge_order[0..self.ordered_edges]) |edge_i| {
            const edge = self.edges[edge_i];
            if (edge.active and edge.from == node) visitor.call(self, edge_i, edge.to);
        }
    }

    fn componentDfs(self: *Graph, node: usize, seen: *[node_limit]bool) void {
        seen[node] = true;
        self.base_order[self.base_count] = node;
        self.base_count += 1;
        // Layered ELK discovers connected components through LNode ports. The
        // ports retain model edge order, including after an edge is reversed.
        for (self.edges[0..self.edge_count]) |edge| {
            if (edge.from != node and edge.to != node) continue;
            const other = if (edge.from == node) edge.to else edge.from;
            if (!seen[other]) self.componentDfs(other, seen);
        }
    }

    fn buildBaseOrder(self: *Graph) void {
        var seen = [_]bool{false} ** node_limit;
        self.base_count = 0;
        // Layerless nodes contain all real nodes first and label dummies in
        // LabelDummyInserter order after them.
        for (0..self.node_count) |node| if (!seen[node]) self.componentDfs(node, &seen);
    }

    fn addTreeEdge(self: *Graph, edge_i: usize) void {
        self.edges[edge_i].tree = true;
        self.tree_order[self.tree_count] = edge_i;
        self.tree_count += 1;
    }

    fn tightTreeDfs(self: *Graph, node: usize) usize {
        self.tree_node[node] = true;
        var count: usize = 1;
        const Walk = struct {
            count: *usize,
            fn call(ctx: @This(), graph: *Graph, edge_i: usize, opposite: usize) void {
                if (graph.edge_visited[edge_i]) return;
                graph.edge_visited[edge_i] = true;
                const edge = graph.edges[edge_i];
                if (edge.tree) {
                    ctx.count.* += graph.tightTreeDfs(opposite);
                } else if (!graph.tree_node[opposite] and graph.rank[edge.to] - graph.rank[edge.from] == 1) {
                    graph.addTreeEdge(edge_i);
                    ctx.count.* += graph.tightTreeDfs(opposite);
                }
            }
        }{ .count = &count };
        self.visitConnected(node, Walk);
        return count;
    }

    fn minimalSlack(self: *const Graph) ?usize {
        var result: ?usize = null;
        var minimum: isize = std.math.maxInt(isize);
        for (self.edge_order[0..self.ordered_edges]) |edge_i| {
            const edge = self.edges[edge_i];
            if (self.tree_node[edge.from] == self.tree_node[edge.to]) continue;
            const slack = self.rank[edge.to] - self.rank[edge.from] - 1;
            if (slack < minimum) {
                minimum = slack;
                result = edge_i;
            }
        }
        return result;
    }

    fn postorder(self: *Graph, node: usize) usize {
        var lowest: usize = std.math.maxInt(usize);
        const Walk = struct {
            lowest: *usize,
            fn call(ctx: @This(), graph: *Graph, edge_i: usize, opposite: usize) void {
                if (!graph.edges[edge_i].tree or graph.edge_visited[edge_i]) return;
                graph.edge_visited[edge_i] = true;
                ctx.lowest.* = @min(ctx.lowest.*, graph.postorder(opposite));
            }
        }{ .lowest = &lowest };
        self.visitConnected(node, Walk);
        self.po[node] = self.post_order;
        self.low[node] = @min(lowest, self.post_order);
        self.post_order += 1;
        return self.low[node];
    }

    fn inHead(self: *const Graph, node: usize, edge_i: usize) bool {
        const edge = self.edges[edge_i];
        const source = edge.from;
        const target = edge.to;
        if (self.low[source] <= self.po[node] and self.po[node] <= self.po[source] and
            self.low[target] <= self.po[node] and self.po[node] <= self.po[target])
        {
            return self.po[source] >= self.po[target];
        }
        return self.po[source] < self.po[target];
    }

    fn cutvalues(self: *Graph) void {
        for (self.tree_order[0..self.tree_count]) |tree_edge| {
            var value: isize = 0;
            for (self.edge_order[0..self.ordered_edges]) |edge_i| {
                const edge = self.edges[edge_i];
                const source_head = self.inHead(edge.from, tree_edge);
                const target_head = self.inHead(edge.to, tree_edge);
                if (!source_head and target_head) value += 1;
                if (source_head and !target_head) value -= 1;
            }
            self.cut[tree_edge] = value;
        }
    }

    fn recomputeTreeData(self: *Graph) void {
        @memset(&self.edge_visited, false);
        self.post_order = 1;
        _ = self.postorder(self.node_order[0]);
        self.cutvalues();
    }

    fn feasibleTree(self: *Graph) void {
        self.topologicalRanks();
        if (self.ordered_edges == 0) return;
        @memset(&self.edge_visited, false);
        while (self.tightTreeDfs(self.node_order[0]) < self.order_count) {
            const edge_i = self.minimalSlack() orelse return;
            const edge = self.edges[edge_i];
            var slack = self.rank[edge.to] - self.rank[edge.from] - 1;
            if (self.tree_node[edge.to]) slack = -slack;
            for (self.node_order[0..self.order_count]) |node| {
                if (self.tree_node[node]) self.rank[node] += slack;
            }
            @memset(&self.edge_visited, false);
        }
        self.recomputeTreeData();
    }

    fn leaveEdge(self: *const Graph) ?usize {
        for (self.tree_order[0..self.tree_count]) |edge_i| if (self.edges[edge_i].tree and self.cut[edge_i] < 0) return edge_i;
        return null;
    }

    fn enterEdge(self: *const Graph, leave: usize) ?usize {
        var result: ?usize = null;
        var minimum: isize = std.math.maxInt(isize);
        for (self.edge_order[0..self.ordered_edges]) |edge_i| {
            const edge = self.edges[edge_i];
            if (self.inHead(edge.from, leave) and !self.inHead(edge.to, leave)) {
                const slack = self.rank[edge.to] - self.rank[edge.from] - 1;
                if (slack < minimum) {
                    minimum = slack;
                    result = edge_i;
                }
            }
        }
        return result;
    }

    fn exchange(self: *Graph, leave: usize, enter: usize) void {
        self.edges[leave].tree = false;
        var at: usize = 0;
        while (at < self.tree_count and self.tree_order[at] != leave) : (at += 1) {}
        if (at < self.tree_count) {
            for (at..self.tree_count - 1) |i| self.tree_order[i] = self.tree_order[i + 1];
            self.tree_count -= 1;
        }
        self.addTreeEdge(enter);
        const entering = self.edges[enter];
        var delta = self.rank[entering.to] - self.rank[entering.from] - 1;
        if (!self.inHead(entering.to, leave)) delta = -delta;
        for (self.node_order[0..self.order_count]) |node| {
            if (!self.inHead(node, leave)) self.rank[node] += delta;
        }
        self.recomputeTreeData();
    }

    fn reattachSubtrees(self: *Graph) void {
        while (self.removed_count > 0) {
            self.removed_count -= 1;
            const node = self.removed_nodes[self.removed_count];
            const edge_i = self.removed_edges[self.removed_count];
            const edge = self.edges[edge_i];
            const other = if (edge.from == node) edge.to else edge.from;
            self.rank[node] = if (edge.to == node) self.rank[other] + 1 else self.rank[other] - 1;
            self.active_node[node] = true;
            self.edges[edge_i].active = true;
            self.node_order[self.order_count] = node;
            self.order_count += 1;
        }
    }

    fn normalizeAndBalance(self: *Graph) void {
        var lowest: isize = std.math.maxInt(isize);
        var highest: isize = std.math.minInt(isize);
        for (self.node_order[0..self.order_count]) |node| {
            lowest = @min(lowest, self.rank[node]);
            highest = @max(highest, self.rank[node]);
        }
        var filling = [_]usize{0} ** 4096;
        if (highest - lowest >= filling.len) return;
        for (self.node_order[0..self.order_count]) |node| {
            self.rank[node] -= lowest;
            filling[@intCast(self.rank[node])] += 1;
        }
        for (self.node_order[0..self.order_count]) |node| {
            var incoming: usize = 0;
            var outgoing: usize = 0;
            var min_in: isize = std.math.maxInt(isize);
            var min_out: isize = std.math.maxInt(isize);
            for (self.edges[0..self.edge_count]) |edge| if (edge.active) {
                const span = self.rank[edge.to] - self.rank[edge.from];
                if (edge.to == node) { incoming += 1; min_in = @min(min_in, span); }
                if (edge.from == node) { outgoing += 1; min_out = @min(min_out, span); }
            };
            if (incoming != outgoing or incoming == 0) continue;
            var new_rank = self.rank[node];
            var candidate = self.rank[node] - min_in + 1;
            const end = self.rank[node] + min_out;
            while (candidate < end) : (candidate += 1) {
                if (filling[@intCast(candidate)] < filling[@intCast(new_rank)]) new_rank = candidate;
            }
            if (filling[@intCast(new_rank)] < filling[@intCast(self.rank[node])]) {
                filling[@intCast(self.rank[node])] -= 1;
                filling[@intCast(new_rank)] += 1;
                self.rank[node] = new_rank;
            }
        }
    }

    fn execute(self: *Graph) void {
        self.removeSubtrees();
        self.rebuildOrder();
        if (self.order_count > 0) {
            self.feasibleTree();
            var root: usize = self.node_count;
            while (root * root > self.node_count) root -= 1;
            const limit = 28 * root;
            var iteration: usize = 0;
            while (iteration < limit) : (iteration += 1) {
                const leave = self.leaveEdge() orelse break;
                const enter = self.enterEdge(leave) orelse break;
                self.exchange(leave, enter);
            }
        }
        self.reattachSubtrees();
        self.normalizeAndBalance();
    }
};

pub fn assign(nodes: anytype, edges: anytype, reversed: anytype, output: []usize, detail: ?*Detail) bool {
    if (nodes.len == 0 or nodes.len > real_node_limit or edges.len > real_edge_limit or output.len < nodes.len) return false;
    var graph: Graph = undefined;
    graph = .{ .node_count = nodes.len, .edge_count = 0 };
    for (0..graph.node_count) |node| graph.active_node[node] = true;
    var first_dummy = [_]?usize{null} ** real_edge_limit;
    var segment_counts = [_]usize{0} ** real_edge_limit;

    // LabelDummyInserter walks layerless nodes and each node's outgoing edges,
    // after cycle breaking. Dummy IDs therefore follow source-node order, not
    // the original statement order.
    for (0..nodes.len) |source| {
        for (edges, 0..) |edge, edge_i| {
            if (edge.from == edge.to) continue;
            const from = if (reversed[edge_i]) edge.to else edge.from;
            if (from != source) continue;
            const Link = @TypeOf(edge.link);
            const labelled = if (@hasField(Link, "label")) edge.link.label.len > 0 else false;
            const segments = edge.link.length + @as(usize, @intFromBool(labelled));
            if (segments == 0 or graph.node_count + segments - 1 > node_limit or graph.edge_count + segments > edge_limit) return false;
            segment_counts[edge_i] = segments;
            if (segments > 1) first_dummy[edge_i] = graph.node_count;
            for (1..segments) |segment| {
                const dummy = graph.node_count;
                graph.node_count += 1;
                graph.active_node[dummy] = true;
                if (detail) |trace| {
                    trace.source_edge[dummy] = edge_i;
                    trace.segment[dummy] = segment;
                    trace.label_dummy[dummy] = labelled and segment == edge.link.length;
                }
            }
        }
    }

    // The LGraph still stores ports in model edge order. Build the expanded
    // edges in that order so component DFS sees the same port traversal.
    for (edges, 0..) |edge, edge_i| {
        if (edge.from == edge.to) continue;
        const from = if (reversed[edge_i]) edge.to else edge.from;
        const to = if (reversed[edge_i]) edge.from else edge.to;
        const segments = segment_counts[edge_i];
        var previous = from;
        for (1..segments) |segment| {
            const dummy = first_dummy[edge_i].? + segment - 1;
            graph.edges[graph.edge_count] = .{ .from = previous, .to = dummy };
            graph.edge_count += 1;
            previous = dummy;
        }
        graph.edges[graph.edge_count] = .{ .from = previous, .to = to };
        graph.edge_count += 1;
    }
    graph.buildBaseOrder();

    // The layered ranker invokes network simplex per weakly connected
    // component. Keep the old fallback until multi-component state sharing is
    // represented here; connected flowcharts use this exact ELK path.
    var seen = [_]bool{false} ** node_limit;
    var queue: [node_limit]usize = undefined;
    var read: usize = 0;
    var write: usize = 1;
    queue[0] = 0;
    seen[0] = true;
    while (read < write) {
        const node = queue[read]; read += 1;
        for (graph.edges[0..graph.edge_count]) |edge| if (edge.from == node or edge.to == node) {
            const other = if (edge.from == node) edge.to else edge.from;
            if (!seen[other]) { seen[other] = true; queue[write] = other; write += 1; }
        };
    }
    for (seen[0..graph.node_count]) |visited| if (!visited) return false;

    graph.execute();
    for (0..nodes.len) |node| output[node] = @intCast(graph.rank[node]);
    if (detail) |trace| {
        trace.node_count = graph.node_count;
        trace.real_node_count = nodes.len;
        trace.order_count = graph.order_count;
        @memcpy(trace.order[0..graph.order_count], graph.node_order[0..graph.order_count]);
        @memcpy(trace.ranks[0..graph.node_count], graph.rank[0..graph.node_count]);
    }
    return true;
}
