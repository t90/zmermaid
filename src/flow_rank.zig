// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p1cycles/GreedyCycleBreaker.java
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p2layers/NetworkSimplexLayerer.java
// Upstream notice: Copyright (c) 2010, 2015 Kiel University and others.
// Upstream notice: Copyright (c) 2010, 2020 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
const std = @import("std");
const flow_simplex = @import("flow_simplex.zig");

const node_limit = 256;
pub const edge_limit = 512;

fn endpoints(edge: anytype, reversed: bool) struct { from: usize, to: usize } {
    return if (reversed) .{ .from = edge.to, .to = edge.from } else .{ .from = edge.from, .to = edge.to };
}

fn minLength(edge: anytype) usize {
    // ELK inserts a LABEL dummy before network-simplex layering. A centered
    // edge label therefore occupies a layer of its own and makes the edge span
    // at least two ranks. Keeping this in the constraint graph is essential:
    // adding only extra pixels after layering leaves branches on the wrong
    // ranks and forces the orthogonal router to cross them.
    const Link = @TypeOf(edge.link);
    const labelled = if (@hasField(Link, "label")) edge.link.label.len > 0 else false;
    return edge.link.length + @as(usize, @intFromBool(labelled));
}

const JavaRandom = struct {
    state: u64,
    fn init(seed: u64) JavaRandom {
        return .{ .state = (seed ^ 0x5deece66d) & ((@as(u64, 1) << 48) - 1) };
    }
    fn next(self: *JavaRandom, bits: u6) u32 {
        self.state = (self.state *% 0x5deece66d +% 0xb) & ((@as(u64, 1) << 48) - 1);
        return @intCast(self.state >> @intCast(48 - bits));
    }
    fn nextInt(self: *JavaRandom, bound: usize) usize {
        // java.util.Random.nextInt(1) still advances the generator.  ELK calls
        // it even when the maximum-outflow set contains one node, so skipping
        // that draw shifts every later tie and can reverse a different edge.
        if (bound == 0) return 0;
        if ((bound & (bound - 1)) == 0) return @intCast((@as(u64, bound) * self.next(31)) >> 31);
        while (true) {
            const bits: u32 = self.next(31);
            const value: u32 = bits % @as(u32, @intCast(bound));
            if (@as(u64, bits) - value + (bound - 1) < (@as(u64, 1) << 31)) return value;
        }
    }
};

// Eades/Lin/Smyth greedy feedback-arc heuristic, used by ELK's GREEDY cycle
// breaker. Strip sources and sinks first; in a cyclic core, remove the vertex
// with maximum (out - in) and reverse its incoming arcs.
fn breakCycles(edges: anytype, node_count: usize, reversed: *[edge_limit]bool) u64 {
    var indegree = [_]isize{0} ** node_limit;
    var outdegree = [_]isize{0} ** node_limit;
    var mark = [_]isize{0} ** node_limit;
    var sources: [node_limit]usize = undefined;
    var sinks: [node_limit]usize = undefined;
    var source_read: usize = 0;
    var source_write: usize = 0;
    var sink_read: usize = 0;
    var sink_write: usize = 0;
    for (edges) |edge| {
        if (edge.from == edge.to) continue;
        outdegree[edge.from] += 1;
        indegree[edge.to] += 1;
    }
    for (0..node_count) |node| {
        if (outdegree[node] == 0) {
            sinks[sink_write] = node;
            sink_write += 1;
        } else if (indegree[node] == 0) {
            sources[source_write] = node;
            source_write += 1;
        }
    }

    const Update = struct {
        fn neighbors(graph_edges: anytype, node: usize, marks: *[node_limit]isize, in: *[node_limit]isize, out: *[node_limit]isize, source_queue: *[node_limit]usize, source_end: *usize, sink_queue: *[node_limit]usize, sink_end: *usize) void {
            for (graph_edges) |edge| {
                if (edge.from == edge.to) continue;
                if (edge.from == node and marks[edge.to] == 0) {
                    in[edge.to] -= 1;
                    if (in[edge.to] <= 0 and out[edge.to] > 0) {
                        source_queue[source_end.*] = edge.to;
                        source_end.* += 1;
                    }
                } else if (edge.to == node and marks[edge.from] == 0) {
                    out[edge.from] -= 1;
                    if (out[edge.from] <= 0 and in[edge.from] > 0) {
                        sink_queue[sink_end.*] = edge.from;
                        sink_end.* += 1;
                    }
                }
            }
        }
    };

    var remaining = node_count;
    var next_right: isize = -1;
    var next_left: isize = 1;
    var random = JavaRandom.init(1);
    while (remaining > 0) {
        while (sink_read < sink_write) {
            const node = sinks[sink_read];
            sink_read += 1;
            if (mark[node] != 0) continue;
            mark[node] = next_right;
            next_right -= 1;
            Update.neighbors(edges, node, &mark, &indegree, &outdegree, &sources, &source_write, &sinks, &sink_write);
            remaining -= 1;
        }
        while (source_read < source_write) {
            const node = sources[source_read];
            source_read += 1;
            if (mark[node] != 0) continue;
            mark[node] = next_left;
            next_left += 1;
            Update.neighbors(edges, node, &mark, &indegree, &outdegree, &sources, &source_write, &sinks, &sink_write);
            remaining -= 1;
        }
        if (remaining == 0) break;

        var best: isize = std.math.minInt(isize);
        var candidates = [_]usize{0} ** node_limit;
        var candidate_count: usize = 0;
        for (0..node_count) |node| {
            if (mark[node] != 0) continue;
            const score = outdegree[node] - indegree[node];
            if (score > best) {
                best = score;
                candidate_count = 0;
            }
            if (score == best) {
                candidates[candidate_count] = node;
                candidate_count += 1;
            }
        }
        const node = candidates[random.nextInt(candidate_count)];
        mark[node] = next_left;
        next_left += 1;
        Update.neighbors(edges, node, &mark, &indegree, &outdegree, &sources, &source_write, &sinks, &sink_write);
        remaining -= 1;
    }

    const shift: isize = @intCast(node_count + 1);
    for (mark[0..node_count]) |*value| if (value.* < 0) {
        value.* += shift;
    };
    for (edges, 0..) |edge, edge_i| if (edge.from != edge.to and mark[edge.from] > mark[edge.to]) {
        reversed[edge_i] = true;
    };
    return random.state;
}

fn initialRanks(edges: anytype, node_count: usize, reversed: *const [edge_limit]bool, ranks: *[node_limit]usize) void {
    ranks.* = [_]usize{0} ** node_limit;
    var done = [_]bool{false} ** node_limit;
    for (0..node_count) |_| {
        var candidate: ?usize = null;
        for (0..node_count) |node| {
            if (done[node]) continue;
            var blocked = false;
            for (edges, 0..) |edge, edge_i| {
                if (edge.from == edge.to) continue;
                const ep = endpoints(edge, reversed[edge_i]);
                if (ep.to == node and !done[ep.from]) {
                    blocked = true;
                    break;
                }
            }
            if (!blocked) {
                candidate = node;
                break;
            }
        }
        const node = candidate orelse break;
        done[node] = true;
        for (edges, 0..) |edge, edge_i| {
            if (edge.from == edge.to) continue;
            const ep = endpoints(edge, reversed[edge_i]);
            if (ep.from == node) ranks[ep.to] = @max(ranks[ep.to], ranks[node] + minLength(edge));
        }
    }
}

// ELK's NETWORK_SIMPLEX layering minimizes total edge length under minimum-rank
// constraints. This equivalent cut-improvement form starts with longest-path
// ranks, closes each candidate set over tight outgoing arcs, and advances the
// best negative-cost cut to its next boundary.
fn compactRanks(edges: anytype, node_count: usize, reversed: *const [edge_limit]bool, ranks: *[node_limit]usize) void {
    const max_passes = node_limit * node_limit;
    for (0..max_passes) |_| {
        var best_delta: isize = 0;
        var best_square_delta: i128 = 0;
        var best_shift: usize = 0;
        var best_set = [_]bool{false} ** node_limit;

        for (0..node_count) |seed| {
            var set = [_]bool{false} ** node_limit;
            set[seed] = true;
            var expanded = true;
            while (expanded) {
                expanded = false;
                for (edges, 0..) |edge, edge_i| {
                    if (edge.from == edge.to) continue;
                    const ep = endpoints(edge, reversed[edge_i]);
                    const slack = ranks[ep.to] - ranks[ep.from] - minLength(edge);
                    if (set[ep.from] and !set[ep.to] and slack == 0) {
                        set[ep.to] = true;
                        expanded = true;
                    }
                }
            }

            var delta: isize = 0;
            var shift: usize = std.math.maxInt(usize);
            for (edges, 0..) |edge, edge_i| {
                if (edge.from == edge.to) continue;
                const ep = endpoints(edge, reversed[edge_i]);
                if (!set[ep.from] and set[ep.to]) delta += 1;
                if (set[ep.from] and !set[ep.to]) {
                    delta -= 1;
                    shift = @min(shift, ranks[ep.to] - ranks[ep.from] - minLength(edge));
                }
            }
            if (shift == std.math.maxInt(usize) or shift == 0) continue;
            // Several feasible layerings can have the same linear objective.
            // ELK's spanning-tree pivots settle those ties toward balanced
            // spans. Use the squared span only as a secondary objective so a
            // long return edge is shortened instead of leaving all sources in
            // rank zero.
            var square_delta: i128 = 0;
            for (edges, 0..) |edge, edge_i| {
                if (edge.from == edge.to) continue;
                const ep = endpoints(edge, reversed[edge_i]);
                if (set[ep.from] == set[ep.to]) continue;
                const before: i128 = @intCast(ranks[ep.to] - ranks[ep.from]);
                const signed_shift: i128 = if (!set[ep.from] and set[ep.to]) @intCast(shift) else -@as(i128, @intCast(shift));
                const after = before + signed_shift;
                square_delta += after * after - before * before;
            }
            if (delta < best_delta or (delta == best_delta and square_delta < best_square_delta)) {
                best_delta = delta;
                best_square_delta = square_delta;
                best_shift = shift;
                best_set = set;
            }
        }

        if (best_shift == 0 or (best_delta == 0 and best_square_delta >= 0)) break;
        for (0..node_count) |node| if (best_set[node]) {
            ranks[node] += best_shift;
        };
    }

    var minimum: usize = std.math.maxInt(usize);
    for (ranks[0..node_count]) |rank| minimum = @min(minimum, rank);
    if (minimum != std.math.maxInt(usize)) {
        for (ranks[0..node_count]) |*rank| rank.* -= minimum;
    }

    // Network simplex minimizes the sum of all edge spans, not merely the
    // height of the longest-path layering.  The cut pass above handles moves
    // of tight blocks; finish with the equivalent single-node pivots.  For a
    // node, the objective's slope is (incoming - outgoing): a source therefore
    // moves down to the rank immediately before its earliest successor, while
    // a sink moves up to the rank immediately after its latest predecessor.
    // This is the detail that keeps independent chains interleaved around long
    // reversed edges instead of pinning every source to rank zero.
    for (0..node_limit * node_limit) |pass| {
        var changed = false;
        const backwards = pass % 2 == 1;
        for (0..node_count) |step| {
            const node = if (backwards) node_count - 1 - step else step;
            var lower: usize = 0;
            var upper: usize = std.math.maxInt(usize);
            var incoming: usize = 0;
            var outgoing: usize = 0;
            for (edges, 0..) |edge, edge_i| {
                if (edge.from == edge.to) continue;
                const ep = endpoints(edge, reversed[edge_i]);
                if (ep.to == node) {
                    incoming += 1;
                    lower = @max(lower, ranks[ep.from] + minLength(edge));
                }
                if (ep.from == node) {
                    outgoing += 1;
                    upper = @min(upper, ranks[ep.to] -| minLength(edge));
                }
            }
            var desired = ranks[node];
            if (incoming > outgoing) {
                desired = lower;
            } else if (outgoing > incoming and upper != std.math.maxInt(usize)) {
                desired = upper;
            }
            desired = @max(desired, lower);
            if (upper != std.math.maxInt(usize)) desired = @min(desired, upper);
            if (desired != ranks[node]) {
                ranks[node] = desired;
                changed = true;
            }
        }
        if (!changed) break;
    }

    minimum = std.math.maxInt(usize);
    for (ranks[0..node_count]) |rank| minimum = @min(minimum, rank);
    if (minimum != std.math.maxInt(usize)) {
        for (ranks[0..node_count]) |*rank| rank.* -= minimum;
    }
}

// ELK balances equivalent minimum-cost layerings after network simplex. Edge
// labels are actual degree-1/degree-1 vertices at this point, so include them
// in both layer occupancy and the balancing pass instead of treating a label
// only as an edge with minimum length two.
fn balanceRanks(edges: anytype, node_count: usize, reversed: *const [edge_limit]bool, ranks: *[node_limit]usize) void {
    const virtual_node_limit = node_limit + edge_limit;
    const virtual_edge_limit = edge_limit * 2;
    const VEdge = struct { from: usize, to: usize };
    var vranks = [_]usize{0} ** virtual_node_limit;
    @memcpy(vranks[0..node_count], ranks[0..node_count]);
    var vedges: [virtual_edge_limit]VEdge = undefined;
    var virtual_nodes = node_count;
    var virtual_edges: usize = 0;
    for (edges, 0..) |edge, edge_i| {
        if (edge.from == edge.to) continue;
        const ep = endpoints(edge, reversed[edge_i]);
        const Link = @TypeOf(edge.link);
        const labelled = if (@hasField(Link, "label")) edge.link.label.len > 0 else false;
        if (labelled and virtual_nodes < virtual_node_limit and virtual_edges + 2 <= virtual_edge_limit) {
            const dummy = virtual_nodes;
            virtual_nodes += 1;
            vranks[dummy] = @min(vranks[ep.from] + 1, vranks[ep.to] -| 1);
            vedges[virtual_edges] = .{ .from = ep.from, .to = dummy };
            vedges[virtual_edges + 1] = .{ .from = dummy, .to = ep.to };
            virtual_edges += 2;
        } else if (virtual_edges < virtual_edge_limit) {
            vedges[virtual_edges] = .{ .from = ep.from, .to = ep.to };
            virtual_edges += 1;
        }
    }

    var highest: usize = 0;
    for (vranks[0..virtual_nodes]) |rank| highest = @max(highest, rank);
    var filling = [_]usize{0} ** 4096;
    if (highest >= filling.len) return;
    for (vranks[0..virtual_nodes]) |rank| filling[rank] += 1;

    for (0..virtual_nodes) |node| {
        var incoming: usize = 0;
        var outgoing: usize = 0;
        var min_in: usize = std.math.maxInt(usize);
        var min_out: usize = std.math.maxInt(usize);
        for (vedges[0..virtual_edges]) |edge| {
            const span = vranks[edge.to] - vranks[edge.from];
            if (edge.to == node) {
                incoming += 1;
                min_in = @min(min_in, span);
            }
            if (edge.from == node) {
                outgoing += 1;
                min_out = @min(min_out, span);
            }
        }
        if (incoming != outgoing or incoming == 0) continue;
        const in_span = if (min_in == std.math.maxInt(usize)) 0 else min_in;
        const out_span = if (min_out == std.math.maxInt(usize)) 0 else min_out;
        var new_rank = vranks[node];
        const first = vranks[node] -| in_span + 1;
        const last = vranks[node] + out_span;
        for (first..last) |candidate| if (filling[candidate] < filling[new_rank]) {
            new_rank = candidate;
        };
        if (filling[new_rank] < filling[vranks[node]]) {
            filling[vranks[node]] -= 1;
            filling[new_rank] += 1;
            vranks[node] = new_rank;
        }
    }
    @memcpy(ranks[0..node_count], vranks[0..node_count]);
}

pub const SimplexDetail = flow_simplex.Detail;

fn assignInternal(nodes: anytype, edges: anytype, detail: ?*SimplexDetail) [edge_limit]bool {
    var reversed = [_]bool{false} ** edge_limit;
    if (nodes.len == 0 or nodes.len > node_limit or edges.len > edge_limit) return reversed;
    const random_state = breakCycles(edges, nodes.len, &reversed);
    if (detail) |trace| trace.random_state = random_state;
    var ranks = [_]usize{0} ** node_limit;
    if (!flow_simplex.assign(nodes, edges, &reversed, ranks[0..nodes.len], detail)) {
        if (detail) |trace| trace.node_count = 0;
        initialRanks(edges, nodes.len, &reversed, &ranks);
        compactRanks(edges, nodes.len, &reversed, &ranks);
        balanceRanks(edges, nodes.len, &reversed, &ranks);
    }
    for (nodes, 0..) |*node, node_i| node.rank = ranks[node_i];
    return reversed;
}

pub fn assign(nodes: anytype, edges: anytype) [edge_limit]bool {
    return assignInternal(nodes, edges, null);
}

pub fn assignDetailed(nodes: anytype, edges: anytype, detail: *SimplexDetail) [edge_limit]bool {
    detail.* = .{};
    return assignInternal(nodes, edges, detail);
}

test "ELK greedy cycle breaking and simplex compaction preserve the readable workflow" {
    const Link = struct { length: usize = 1 };
    const Edge = struct { from: usize, to: usize, link: Link = .{} };
    const Node = struct { rank: usize = 0 };
    var nodes = [_]Node{.{}} ** 18;
    const edges = [_]Edge{
        .{ .from = 0, .to = 1 },   .{ .from = 1, .to = 2 },   .{ .from = 2, .to = 3 },
        .{ .from = 3, .to = 4 },   .{ .from = 4, .to = 5 },   .{ .from = 5, .to = 6 },
        .{ .from = 6, .to = 7 },   .{ .from = 7, .to = 8 },   .{ .from = 8, .to = 9 },
        .{ .from = 9, .to = 10 },  .{ .from = 10, .to = 8 },  .{ .from = 8, .to = 11 },
        .{ .from = 11, .to = 12 }, .{ .from = 12, .to = 13 }, .{ .from = 13, .to = 14 },
        .{ .from = 14, .to = 15 }, .{ .from = 15, .to = 3 },  .{ .from = 3, .to = 16 },
        .{ .from = 16, .to = 17 },
    };
    _ = assign(&nodes, &edges);
    const expected = [_]usize{ 5, 6, 7, 8, 9, 10, 11, 1, 2, 0, 1, 3, 4, 5, 6, 7, 9, 10 };
    for (nodes, expected) |node, rank| try std.testing.expectEqual(rank, node.rank);
}

test "ELK 0.9.3 greedy cycle breaking is deterministic for intersecting workflow cycles" {
    const Link = struct { length: usize = 1 };
    const Edge = struct { from: usize, to: usize, link: Link = .{} };
    const Node = struct { rank: usize = 0 };
    var nodes = [_]Node{.{}} ** 30;
    const edges = [_]Edge{
        .{ .from = 0, .to = 1 },   .{ .from = 1, .to = 2 },   .{ .from = 2, .to = 3 },
        .{ .from = 3, .to = 4 },   .{ .from = 3, .to = 5 },   .{ .from = 5, .to = 6 },
        .{ .from = 6, .to = 5 },   .{ .from = 5, .to = 7 },   .{ .from = 7, .to = 8 },
        .{ .from = 5, .to = 9 },   .{ .from = 9, .to = 10 },  .{ .from = 10, .to = 11 },
        .{ .from = 11, .to = 12 }, .{ .from = 12, .to = 13 }, .{ .from = 13, .to = 14 },
        .{ .from = 14, .to = 15 }, .{ .from = 15, .to = 16 }, .{ .from = 16, .to = 17 },
        .{ .from = 16, .to = 13 }, .{ .from = 14, .to = 18 }, .{ .from = 5, .to = 18 },
        .{ .from = 18, .to = 19 }, .{ .from = 19, .to = 20 }, .{ .from = 20, .to = 21 },
        .{ .from = 21, .to = 22 }, .{ .from = 22, .to = 23 }, .{ .from = 23, .to = 24 },
        .{ .from = 24, .to = 25 }, .{ .from = 24, .to = 26 }, .{ .from = 26, .to = 20 },
        .{ .from = 5, .to = 27 },  .{ .from = 27, .to = 5 },  .{ .from = 17, .to = 8 },
        .{ .from = 25, .to = 8 },  .{ .from = 8, .to = 28 },  .{ .from = 8, .to = 5 },
        .{ .from = 8, .to = 29 },
    };
    const reversed = assign(&nodes, &edges);
    const expected = [_]usize{ 6, 14, 23, 31, 35 };
    for (reversed, 0..) |is_reversed, edge_i| {
        try std.testing.expectEqual(std.mem.indexOfScalar(usize, &expected, edge_i) != null, is_reversed);
    }
}
