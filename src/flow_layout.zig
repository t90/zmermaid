// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/LayerSweepCrossingMinimizer.java
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/NodeRelativePortDistributor.java
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/LayerTotalPortDistributor.java
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/LongEdgeSplitter.java
// Upstream notice: Copyright (c) 2010, 2015 Kiel University and others.
// Upstream notice: Copyright (c) 2012, 2015 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
const paint = @import("flow_paint.zig");
const shapes = @import("flow_shapes.zig");
const std = @import("std");
pub const Size = struct { w: usize, h: usize };

pub const EndpointPorts = struct {
    counts: [512]usize = [_]usize{0} ** 512,
    source: [256]usize = [_]usize{0} ** 256,
    target: [256]usize = [_]usize{0} ** 256,
};

// Convert the winning proper-graph port order to original edge endpoints.
// Input ordinals are clockwise (opposite to increasing cross coordinates).
// Reversed edges exchange their first/last endpoints only, not their order.
pub fn endpointPorts(edges: anytype, reversed: []const bool, arcs: []const OrderedArc) !EndpointPorts {
    var result: EndpointPorts = .{};
    for (edges, 0..) |edge, i| {
        if (edge.from == edge.to) continue;
        result.counts[edge.from * 2 + @as(usize, if (reversed[i]) 0 else 1)] += 1;
        result.counts[edge.to * 2 + @as(usize, if (reversed[i]) 1 else 0)] += 1;
    }
    for (edges, 0..) |edge, i| {
        if (edge.from == edge.to) continue;
        var first: ?OrderedArc = null;
        var last: ?OrderedArc = null;
        for (arcs) |arc| {
            if (arc.edge != i) continue;
            if (first == null or arc.rank < first.?.rank) first = arc;
            if (last == null or arc.rank > last.?.rank) last = arc;
        }
        const low = first orelse return error.UnsupportedSyntax;
        const high = last orelse return error.UnsupportedSyntax;
        const source_count = result.counts[edge.from * 2 + @as(usize, if (reversed[i]) 0 else 1)];
        const target_count = result.counts[edge.to * 2 + @as(usize, if (reversed[i]) 1 else 0)];
        const input_count = if (reversed[i]) source_count else target_count;
        const output_count = if (reversed[i]) target_count else source_count;
        if (low.output >= output_count or high.input >= input_count) return error.UnsupportedSyntax;
        const input = input_count - 1 - high.input;
        result.source[i] = if (reversed[i]) input else low.output;
        result.target[i] = if (reversed[i]) low.output else input;
    }
    return result;
}

test "render endpoints inherit first and last proper arc ports including reversed edges" {
    const edges = [_]struct { from: usize, to: usize }{
        .{ .from = 0, .to = 2 }, .{ .from = 0, .to = 1 }, .{ .from = 2, .to = 1 },
    };
    const arcs = [_]OrderedArc{
        .{ .edge = 0, .rank = 0, .output = 1, .input = 0 },
        .{ .edge = 0, .rank = 2, .output = 0, .input = 1 },
        .{ .edge = 1, .rank = 0, .output = 0, .input = 0 },
        .{ .edge = 2, .rank = 1, .output = 0, .input = 0 },
    };
    const ports = try endpointPorts(&edges, &.{ false, false, true }, &arcs);
    try std.testing.expectEqual(@as(usize, 1), ports.source[0]);
    try std.testing.expectEqual(@as(usize, 0), ports.target[0]);
    try std.testing.expectEqual(@as(usize, 1), ports.source[2]);
    try std.testing.expectEqual(@as(usize, 0), ports.target[2]);
    try std.testing.expectEqual(@as(usize, 2), ports.counts[2 * 2]);
    try std.testing.expectError(error.UnsupportedSyntax, endpointPorts(&edges, &.{ false, false, true }, &.{}));
}

const ExpandedNode = struct {
    rank: usize,
    real: ?usize = null,
    edge: ?usize = null,
    label: bool = false,
    cross: usize = 0,
    along: usize = 0,
    external_order: ?usize = null,
    external_input: ?bool = null,
    inverted: bool = false,
};

const ExpandedArc = struct { low: usize, high: usize, edge: usize, source_east: bool = true, target_east: bool = false };
pub const EdgeSides = struct { source: ?bool = null, target: ?bool = null, source_y: ?f64 = null, target_y: ?f64 = null };

// ELK LabelDummySwitcher, default MEDIAN_LAYER strategy. Swap only the
// dummy's payload with the lower-median chain slot; layer order is frozen.
fn switchMedianLabels(nodes: []ExpandedNode) void {
    var done = [_]bool{false} ** 256;
    for (nodes, 0..) |node, label_index| {
        if (!node.label) continue;
        const edge = node.edge orelse continue;
        if (done[edge]) continue;
        done[edge] = true;
        var low = node.rank;
        var high = node.rank;
        for (nodes) |other| if (other.edge == edge) {
            low = @min(low, other.rank);
            high = @max(high, other.rank);
        };
        const median = low + (high - low) / 2;
        for (nodes, 0..) |other, target| {
            if (other.edge != edge or other.rank != median) continue;
            std.mem.swap(bool, &nodes[label_index].label, &nodes[target].label);
            std.mem.swap(usize, &nodes[label_index].cross, &nodes[target].cross);
            std.mem.swap(usize, &nodes[label_index].along, &nodes[target].along);
            break;
        }
    }
}

test "median label switching uses lower median without changing chain slots" {
    var nodes = [_]ExpandedNode{
        .{ .rank = 3, .edge = 0 },                                          .{ .rank = 4, .edge = 0 },
        .{ .rank = 5, .edge = 0, .label = true, .cross = 70, .along = 20 }, .{ .rank = 6, .edge = 0 },
    };
    switchMedianLabels(&nodes);
    try std.testing.expect(nodes[1].label);
    try std.testing.expect(!nodes[2].label);
    try std.testing.expectEqual(@as(usize, 70), nodes[1].cross);
    try std.testing.expectEqual(@as(usize, 0), nodes[2].cross);
    try std.testing.expectEqual(@as(usize, 4), nodes[1].rank);
}

// Clockwise port ordinals are persistent sweep state. Inputs run in the
// opposite geometric direction to outputs; dummies have fixed port order.
const SweepPorts = struct {
    node_relative: bool = true,
    allocator: std.mem.Allocator,
    output: []usize,
    input: []usize,
    output_ranks: []f32,
    input_ranks: []f32,

    fn init(allocator: std.mem.Allocator, arcs: []const ExpandedArc, positions: []const usize) !SweepPorts {
        const output = try allocator.alloc(usize, arcs.len);
        errdefer allocator.free(output);
        const input = try allocator.alloc(usize, arcs.len);
        errdefer allocator.free(input);
        const output_ranks = try allocator.alloc(f32, arcs.len);
        errdefer allocator.free(output_ranks);
        const input_ranks = try allocator.alloc(f32, arcs.len);
        for (arcs, 0..) |arc, i| {
            output[i] = 0;
            input[i] = 0;
            for (arcs) |other| {
                if (other.low == arc.low and other.edge < arc.edge) output[i] += 1;
                if (other.high == arc.high and (positions[other.low] > positions[arc.low] or
                    (positions[other.low] == positions[arc.low] and other.edge < arc.edge))) input[i] += 1;
            }
        }
        @memset(output_ranks, 0);
        @memset(input_ranks, 0);
        return .{ .allocator = allocator, .output = output, .input = input, .output_ranks = output_ranks, .input_ranks = input_ranks };
    }

    fn deinit(self: *SweepPorts, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        allocator.free(self.input);
        allocator.free(self.output_ranks);
        allocator.free(self.input_ranks);
    }

    fn calculate(self: *SweepPorts, nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize, rank: usize, outputs: bool) void {
        for (nodes, 0..) |node, entry| {
            if (node.rank != rank) continue;
            var count: usize = 0;
            for (arcs) |arc| if ((if (outputs) arc.low else arc.high) == entry) {
                count += 1;
            };
            if (count == 0) continue;
            const increment: f32 = if (self.node_relative) 1.0 / @as(f32, @floatFromInt(count + 1)) else 1.0;
            var value: f32 = @floatFromInt(positions[entry]);
            if (!self.node_relative) {
                value = 0;
                for (arcs) |arc| {
                    const endpoint = if (outputs) arc.low else arc.high;
                    if (nodes[endpoint].rank == rank and positions[endpoint] < positions[entry]) value += 1;
                }
            }
            value = if (outputs) value + increment else if (self.node_relative) value + 1.0 - increment else value + @as(f32, @floatFromInt(count));
            // Increment in f32 just as NodeRelativePortDistributor does, not
            // a separately rounded multiplication for each port.
            for (0..count) |ordinal| {
                for (arcs, 0..) |arc, i| {
                    if ((if (outputs) arc.low else arc.high) != entry) continue;
                    if ((if (outputs) self.output[i] else self.input[i]) == ordinal) {
                        if (outputs) self.output_ranks[i] = value else self.input_ranks[i] = value;
                    }
                }
                value += if (outputs) increment else -increment;
            }
        }
    }

    fn distribute(self: *SweepPorts, nodes: []const ExpandedNode, arcs: []const ExpandedArc, rank: usize, outputs: bool) void {
        var members: [4096]usize = undefined;
        for (nodes, 0..) |node, entry| {
            if (node.rank != rank or node.real == null) continue;
            var count: usize = 0;
            for (arcs, 0..) |arc, i| if ((if (outputs) arc.low else arc.high) == entry) {
                if (count == members.len) return;
                members[count] = i;
                count += 1;
            };
            // Stable ties preserve the currently established port order.
            const Context = struct {
                ports: *const SweepPorts,
                outputs: bool,
                fn less(context: @This(), a: usize, b: usize) bool {
                    return (if (context.outputs) context.ports.output[a] else context.ports.input[a]) <
                        (if (context.outputs) context.ports.output[b] else context.ports.input[b]);
                }
            };
            std.mem.sort(usize, members[0..count], Context{ .ports = self, .outputs = outputs }, Context.less);
            var i: usize = 1;
            while (i < count) : (i += 1) {
                const value = members[i];
                const key = if (outputs) self.input_ranks[value] else -self.output_ranks[value];
                var j = i;
                while (j > 0) : (j -= 1) {
                    const previous = members[j - 1];
                    const other = if (outputs) self.input_ranks[previous] else -self.output_ranks[previous];
                    if (key >= other) break;
                    members[j] = previous;
                }
                members[j] = value;
            }
            for (members[0..count], 0..) |arc, ordinal| {
                if (outputs) self.output[arc] = ordinal else self.input[arc] = ordinal;
            }
        }
    }

    fn sweepLayer(self: *SweepPorts, nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize, rank: usize, forward: bool, highest: usize) void {
        const first = if (forward) rank == 0 else rank == highest;
        if (first) {
            self.distribute(nodes, arcs, rank, !forward);
            return;
        }
        const fixed = if (forward) rank - 1 else rank + 1;
        self.calculate(nodes, arcs, positions, fixed, forward);
        self.distribute(nodes, arcs, rank, !forward);
        self.calculate(nodes, arcs, positions, rank, !forward);
        self.distribute(nodes, arcs, fixed, forward);
    }

    fn crossings(self: *const SweepPorts, nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize) usize {
        var count: usize = 0;
        var has_inlayer = false;
        for (arcs, 0..) |a, i| {
            if (nodes[a.low].rank == nodes[a.high].rank) { has_inlayer = true; continue; }
            for (arcs[i + 1 ..], i + 1..) |b, j| {
                if (nodes[b.low].rank == nodes[b.high].rank) continue;
                if (nodes[a.low].rank != nodes[b.low].rank) continue;
                // A proper graph arc joins exactly one adjacent layer pair.
                // Ranks are checked by the caller's immutable node graph.
                const source_less = if (a.low == b.low) self.output[i] < self.output[j] else positions[a.low] < positions[b.low];
                const target_less = if (a.high == b.high) self.input[i] > self.input[j] else positions[a.high] < positions[b.high];
                if (source_less != target_less) count += 1;
            }
        }
        if (has_inlayer) {
            const counter = @import("flow_inlayer_crossings.zig");
            var arena = std.heap.ArenaAllocator.init(self.allocator); defer arena.deinit();
            const a = arena.allocator();
            const ns = a.alloc(counter.Node, nodes.len) catch return std.math.maxInt(usize);
            const ps = a.alloc(counter.Port, arcs.len * 2) catch return std.math.maxInt(usize);
            const es = a.alloc(counter.Edge, arcs.len) catch return std.math.maxInt(usize);
            for (nodes, 0..) |n, id| ns[id] = .{ .rank = n.rank, .position = positions[id] };
            for (arcs, 0..) |arc, id| {
                ps[id * 2] = .{ .node = arc.low, .side = if (arc.source_east) .EAST else .WEST, .ordinal = if (arc.source_east) self.output[id] else arcs.len - self.output[id] };
                ps[id * 2 + 1] = .{ .node = arc.high, .side = if (arc.target_east) .EAST else .WEST, .ordinal = arcs.len + (if (arc.target_east) arcs.len - self.input[id] else self.input[id]) };
                es[id] = .{ .source = id * 2, .target = id * 2 + 1 };
            }
            const counts = counter.compute(a, .{ .nodes = ns, .ports = ps, .edges = es }) catch return std.math.maxInt(usize);
            for (counts) |c| count += c.west + c.east;
        }
        return count;
    }
};

test "port redistribution separates sibling edges using target order" {
    const nodes = [_]ExpandedNode{
        .{ .rank = 0, .real = 0 },
        .{ .rank = 1, .real = 1 },
        .{ .rank = 1, .real = 2 },
    };
    const arcs = [_]ExpandedArc{
        .{ .low = 0, .high = 2, .edge = 0 },
        .{ .low = 0, .high = 1, .edge = 1 },
    };
    const positions = [_]usize{ 0, 0, 1 };
    var ports = try SweepPorts.init(std.testing.allocator, &arcs, &positions);
    defer ports.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ports.crossings(&nodes, &arcs, &positions));
    ports.calculate(&nodes, &arcs, &positions, 1, false);
    ports.distribute(&nodes, &arcs, 0, true);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, ports.output);
    try std.testing.expectEqual(@as(usize, 0), ports.crossings(&nodes, &arcs, &positions));
    ports.calculate(&nodes, &arcs, &positions, 0, true);
    try std.testing.expect(ports.output_ranks[1] < ports.output_ranks[0]);
}

test "crossing counter ignores unrelated layer pairs" {
    const nodes = [_]ExpandedNode{
        .{ .rank = 0, .real = 0 }, .{ .rank = 1, .real = 1 },
        .{ .rank = 2, .real = 2 }, .{ .rank = 3, .real = 3 },
    };
    const arcs = [_]ExpandedArc{
        .{ .low = 0, .high = 1, .edge = 0 },
        .{ .low = 2, .high = 3, .edge = 1 },
    };
    const positions = [_]usize{ 0, 1, 1, 0 };
    var ports = try SweepPorts.init(std.testing.allocator, &arcs, &positions);
    defer ports.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ports.crossings(&nodes, &arcs, &positions));
}

test "single-node outer-layer randomization consumes its draw" {
    const nodes = [_]ExpandedNode{.{ .rank = 0, .real = 0 }};
    var sequence = [_]usize{0};
    var actual = JavaRandom.init(42);
    var expected = JavaRandom.init(42);
    _ = expected.nextDouble();
    randomizeOuterRank(&nodes, &sequence, true, &actual);
    try std.testing.expectEqual(expected.state, actual.state);
}

test "preordered barycenterless node stays between its neighbors" {
    const nodes = [_]ExpandedNode{
        .{ .rank = 0, .real = 0 },
        .{ .rank = 1, .real = 1 },
        .{ .rank = 1, .real = 2 },
        .{ .rank = 1, .real = 3 },
    };
    const arcs = [_]ExpandedArc{
        .{ .low = 0, .high = 1, .edge = 0 }, .{ .low = 0, .high = 3, .edge = 1 },
    };
    var sequence = [_]usize{ 0, 1, 2, 3 };
    var positions = [_]usize{ 0, 0, 1, 2 };
    var ports = try SweepPorts.init(std.testing.allocator, &arcs, &positions);
    defer ports.deinit(std.testing.allocator);
    ports.calculate(&nodes, &arcs, &positions, 0, true);
    sortExpandedRankPorts(&nodes, &arcs, &sequence, 1, true, &positions, null, &ports, true);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, &sequence);
}

pub const OrderedEntry = struct {
    rank: usize = 0,
    position: usize = 0,
    real: ?usize = null,
    edge: ?usize = null,
    label: bool = false,
};

pub const OrderedArc = struct {
    edge: usize = 0,
    rank: usize = 0,
    output: usize = 0,
    input: usize = 0,
    from: ?usize = null,
    to: ?usize = null,
    source_east: bool = true,
    target_east: bool = false,
};

pub const PositionedEntry = struct {
    rank: usize,
    position: usize,
    real: ?usize,
    edge: ?usize,
    label: bool,
    cross: usize,
    along: usize = 0,
    cross_size: usize,
    along_size: usize,
    inverted: bool = false,
};

pub const Guide = struct {
    routing_random_state: u64 = 0,
    sweep_random_count: usize = 0,
    sweep_random_states: []u64 = &.{},
    sweep_random_bits: []u6 = &.{},
    arc_count: usize = 0,
    arcs: []OrderedArc = &.{},
    // Preserve the whole proper graph, not just first/last dummy summaries.
    positioned: []PositionedEntry = &.{},
    initial_order_count: usize = 0,
    initial_order: [768]OrderedEntry = [_]OrderedEntry{.{}} ** 768,
    model_order_count: usize = 0,
    model_order: [768]OrderedEntry = [_]OrderedEntry{.{}} ** 768,
    order_count: usize = 0,
    order: [768]OrderedEntry = [_]OrderedEntry{.{}} ** 768,
    offsets: [256]usize = [_]usize{0} ** 256,
    breadths: [4096]usize = [_]usize{0} ** 4096,
    depths: [4096]usize = [_]usize{0} ** 4096,
    centers: [4096]usize = [_]usize{0} ** 4096,
    near_low_cross: [256]usize = [_]usize{0} ** 256,
    near_low_rank: [256]usize = [_]usize{0} ** 256,
    near_low_valid: [256]bool = [_]bool{false} ** 256,
    near_high_cross: [256]usize = [_]usize{0} ** 256,
    near_high_rank: [256]usize = [_]usize{0} ** 256,
    near_high_valid: [256]bool = [_]bool{false} ** 256,
    label_cross: [256]usize = [_]usize{0} ** 256,
    label_rank: [256]usize = [_]usize{0} ** 256,
    label_valid: [256]bool = [_]bool{false} ** 256,
};

pub const JavaRandom = struct {
    state: u64,
    draw_count: usize = 0,
    draw_states: ?[]u64 = null,
    draw_bits: ?[]u6 = null,
    pub fn init(seed: u64) JavaRandom {
        return .{ .state = (seed ^ 0x5deece66d) & ((@as(u64, 1) << 48) - 1) };
    }
    pub fn fromState(state: u64) JavaRandom {
        return .{ .state = state };
    }
    fn next(self: *JavaRandom, bits: u6) u32 {
        self.state = (self.state *% 0x5deece66d +% 0xb) & ((@as(u64, 1) << 48) - 1);
        if (self.draw_states) |states| {
            if (self.draw_count < states.len) states[self.draw_count] = self.state;
            self.draw_count += 1;
        }
        if (self.draw_bits) |bits_trace| if (self.draw_count > 0 and self.draw_count <= bits_trace.len) {
            bits_trace[self.draw_count - 1] = bits;
        };
        return @intCast(self.state >> @intCast(48 - bits));
    }
    pub fn nextInt(self: *JavaRandom, bound: usize) usize {
        if (bound == 0) return 0;
        if ((bound & (bound - 1)) == 0) return @intCast((@as(u64, bound) * self.next(31)) >> 31);
        while (true) {
            const bits: u32 = self.next(31);
            const value: u32 = bits % @as(u32, @intCast(bound));
            if (@as(u64, bits) - value + (bound - 1) < (@as(u64, 1) << 31)) return value;
        }
    }
    fn nextBoolean(self: *JavaRandom) bool {
        return self.next(1) != 0;
    }
    pub fn nextFloat(self: *JavaRandom) f64 {
        return @as(f64, @floatFromInt(self.next(24))) / 16777216.0;
    }
    fn nextDouble(self: *JavaRandom) f64 {
        const high = @as(u64, self.next(26));
        const low = @as(u64, self.next(27));
        return @as(f64, @floatFromInt((high << 27) | low)) / 9007199254740992.0;
    }
    fn nextLong(self: *JavaRandom) u64 {
        // java.util.Random uses signed int operands here:
        // ((long) next(32) << 32) + next(32).  The second value is sign-
        // extended before addition; unsigned concatenation produces a
        // different seed whenever its top bit is set.
        const high: i32 = @bitCast(self.next(32));
        const low: i32 = @bitCast(self.next(32));
        const value: i64 = (@as(i64, high) << 32) + @as(i64, low);
        return @bitCast(value);
    }
};

// ELK's layered layout orders each layer from the positions of its neighbours
// before Brandes-Koepf assigns coordinates.  Keep the same important property
// here: normalize feedback edges to the forward direction, then make alternating
// barycentric sweeps.  Stable ties preserve the model order selected by earlier
// sweeps instead of making disconnected branches jump around.
pub fn order(allocator: std.mem.Allocator, nodes: anytype, edges: anytype, ids: []usize, horizontal: bool, node_gap: usize, label_rank_hints: []const ?usize, cycle_random_state: u64, simplex_detail: *const @import("flow_simplex.zig").Detail, trace_random: bool) !Guide {
    return orderConfigured(allocator, nodes, edges, ids, horizontal, node_gap, label_rank_hints, cycle_random_state, simplex_detail, trace_random, true, null);
}

pub fn orderConfigured(allocator: std.mem.Allocator, nodes: anytype, edges: anytype, ids: []usize, horizontal: bool, node_gap: usize, label_rank_hints: []const ?usize, cycle_random_state: u64, simplex_detail: *const @import("flow_simplex.zig").Detail, trace_random: bool, model_order: bool, parent_state: ?u64) !Guide {
    return orderWithSides(allocator, nodes, edges, ids, horizontal, node_gap, label_rank_hints, cycle_random_state, simplex_detail, trace_random, model_order, parent_state, null);
}
pub fn orderWithSides(allocator: std.mem.Allocator, nodes: anytype, edges: anytype, ids: []usize, horizontal: bool, node_gap: usize, label_rank_hints: []const ?usize, cycle_random_state: u64, simplex_detail: *const @import("flow_simplex.zig").Detail, trace_random: bool, model_order: bool, parent_state: ?u64, sides: ?[]const EdgeSides) !Guide {
    var guide: Guide = .{};
    if (trace_random) {
        guide.sweep_random_states = try allocator.alloc(u64, 4096);
        errdefer allocator.free(guide.sweep_random_states);
        guide.sweep_random_bits = try allocator.alloc(u6, 4096);
    }
    errdefer allocator.free(guide.sweep_random_states);
    errdefer allocator.free(guide.sweep_random_bits);
    var expanded: std.ArrayList(ExpandedNode) = .empty;
    defer expanded.deinit(allocator);
    var arcs: std.ArrayList(ExpandedArc) = .empty;
    defer arcs.deinit(allocator);
    var sequence: std.ArrayList(usize) = .empty;
    defer sequence.deinit(allocator);
    const real_entry = try allocator.alloc(usize, nodes.len);
    defer allocator.free(real_entry);

    // Allocate real nodes and one LONG_EDGE dummy in every crossed layer. The
    // simplex traversal below establishes their initial ordering. Those
    // dummies, rather than a distant real endpoint, participate in the layer
    // sweeps and later become the edge's orthogonal corridor.
    for (ids) |id| {
        real_entry[id] = expanded.items.len;
        try expanded.append(allocator, .{
            .rank = nodes[id].rank,
            .real = id,
            .cross = if (horizontal) nodes[id].h else nodes[id].w,
            .along = if (horizontal) nodes[id].w else nodes[id].h,
            .external_order = if (@hasField(@TypeOf(nodes[id]), "external_order")) nodes[id].external_order else null,
            .external_input = if (@hasField(@TypeOf(nodes[id]), "external_input")) nodes[id].external_input else null,
        });
    }
    for (edges, 0..) |edge, edge_i| {
        if (edge.from == edge.to) continue;
        const from_rank = nodes[edge.from].rank;
        const to_rank = nodes[edge.to].rank;
        if (from_rank == to_rank) continue;
        const low_node = if (from_rank < to_rank) edge.from else edge.to;
        const high_node = if (from_rank < to_rank) edge.to else edge.from;
        const low_rank = nodes[low_node].rank;
        const high_rank = nodes[high_node].rank;
        const label_rank = if (edge_i < label_rank_hints.len)
            label_rank_hints[edge_i] orelse low_rank + (high_rank - low_rank) / 2
        else
            low_rank + (high_rank - low_rank) / 2;
        const label_cross = if (edge.link.label.len == 0) 0 else edge.style.measure(if (horizontal) paint.labelHeight(edge.link.label) else paint.labelWidth(edge.link.label, edge.link.markdown));
        const label_along = if (edge.link.label.len == 0) 0 else edge.style.measure(if (horizontal) paint.labelWidth(edge.link.label, edge.link.markdown) else paint.labelHeight(edge.link.label));
        var previous = real_entry[low_node];
        var rank = low_rank + 1;
        while (rank < high_rank) : (rank += 1) {
            const dummy = expanded.items.len;
            try expanded.append(allocator, .{
                .rank = rank,
                .edge = edge_i,
                .label = rank == label_rank and edge.link.label.len > 0,
                .cross = if (rank == label_rank) label_cross else 0,
                .along = if (rank == label_rank) label_along else 0,
            });
            try arcs.append(allocator, .{ .low = previous, .high = dummy, .edge = edge_i });
            previous = dummy;
        }
        try arcs.append(allocator, .{ .low = previous, .high = real_entry[high_node], .edge = edge_i });
    }
    if (sides) |pins| {
        for (arcs.items) |*arc| {
            const edge = edges[arc.edge];
            if (expanded.items[arc.low].real) |r| arc.source_east = (if (r == edge.from) pins[arc.edge].source else pins[arc.edge].target) orelse true;
            if (expanded.items[arc.high].real) |r| arc.target_east = (if (r == edge.to) pins[arc.edge].target else pins[arc.edge].source) orelse false;
        }
        var last: usize = 0; for (expanded.items) |node| last = @max(last, node.rank);
        const original_nodes = expanded.items.len;
        for (0..last + 1) |rank| for (0..original_nodes) |node| {
            if (expanded.items[node].rank != rank or expanded.items[node].real == null) continue;
            for ([_]bool{ true, false }) |east| {
                const end = arcs.items.len;
                var incident: std.ArrayList(usize) = .empty;
                defer incident.deinit(allocator);
                for (0..end) |id| {
                    const arc = arcs.items[id];
                    if ((east and arc.high == node and arc.target_east) or (!east and arc.low == node and !arc.source_east)) try incident.append(allocator, id);
                }
                const PortOrder = struct {
                    arcs: []const ExpandedArc, pins: []const EdgeSides, real: usize, east: bool, original_edges: @TypeOf(edges),
                    fn y(c: @This(), id: usize) f64 {
                        const e = c.arcs[id].edge;
                        return (if (c.original_edges[e].from == c.real) c.pins[e].source_y else c.pins[e].target_y) orelse 0;
                    }
                    fn less(c: @This(), x: usize, y_id: usize) bool {
                        const x_y = c.y(x); const y_y = c.y(y_id);
                        if (x_y != y_y) return if (c.east) x_y < y_y else x_y > y_y;
                        return if (c.east) c.arcs[x].edge < c.arcs[y_id].edge else c.arcs[x].edge > c.arcs[y_id].edge;
                    }
                };
                std.mem.sort(usize, incident.items, PortOrder{ .arcs = arcs.items, .pins = pins, .real = expanded.items[node].real.?, .east = east, .original_edges = edges }, PortOrder.less);
                for (incident.items) |id| {
                    const arc = arcs.items[id];
                    if ((east and (arc.high != node or !arc.target_east)) or (!east and (arc.low != node or arc.source_east))) continue;
                    if (arc.low == arc.high) continue;
                    const dummy = expanded.items.len;
                    try expanded.append(allocator, .{ .rank = rank, .edge = arc.edge, .inverted = true });
                    arcs.items[id].high = dummy; arcs.items[id].target_east = false;
                    try arcs.append(allocator, .{ .low = dummy, .high = arc.high, .edge = arc.edge, .target_east = arc.target_east });
                }
            }
        };
    }
    try sequence.ensureTotalCapacity(allocator, expanded.items.len);
    // NetworkSimplexLayerer inserts nodes into layers in its final NGraph
    // traversal order. LongEdgeSplitter then appends dummies one layer at a
    // time, scanning each predecessor's outgoing ports in model order.
    const inserted = try allocator.alloc(bool, expanded.items.len);
    defer allocator.free(inserted);
    @memset(inserted, false);
    for (simplex_detail.order[0..simplex_detail.order_count]) |simplex_node| {
        for (expanded.items, 0..) |item, entry| {
            const matches = if (simplex_node < simplex_detail.real_node_count)
                item.real == simplex_node
            else
                // Non-label simplex constraints are not imported LNodes.
                // LongEdgeSplitter creates their proper dummies later, in
                // predecessor traversal order rather than simplex order.
                simplex_detail.label_dummy[simplex_node] and item.real == null and
                    item.edge == simplex_detail.source_edge[simplex_node] and item.rank == simplex_detail.ranks[simplex_node];
            if (matches and !inserted[entry]) {
                sequence.appendAssumeCapacity(entry);
                inserted[entry] = true;
                break;
            }
        }
    }
    if (simplex_detail.order_count == 0) {
        for (expanded.items, 0..) |item, entry| if (item.real != null or item.label) {
            sequence.appendAssumeCapacity(entry);
            inserted[entry] = true;
        };
    }
    var split_rank: usize = 0;
    var max_rank: usize = 0;
    for (expanded.items) |item| max_rank = @max(max_rank, item.rank);
    while (split_rank < max_rank) : (split_rank += 1) {
        const layer_end = sequence.items.len;
        for (0..layer_end) |i| {
            const predecessor = sequence.items[i];
            if (expanded.items[predecessor].rank != split_rank) continue;
            for (arcs.items) |arc| if (arc.low == predecessor and !inserted[arc.high]) {
                sequence.appendAssumeCapacity(arc.high);
                inserted[arc.high] = true;
            };
        }
    }
    for (inserted, 0..) |present, entry| if (!present) sequence.appendAssumeCapacity(entry);
    stableRankSort(expanded.items, sequence.items);
    const constrained_output = constrainExternalOrder(expanded.items, sequence.items, false);
    const constrained_input = constrainExternalOrder(expanded.items, sequence.items, true);
    var initial_rank: ?usize = null;
    var initial_position: usize = 0;
    for (sequence.items) |entry| {
        const item = expanded.items[entry];
        if (initial_rank == null or initial_rank.? != item.rank) {
            initial_rank = item.rank;
            initial_position = 0;
        }
        guide.initial_order[guide.initial_order_count] = .{ .rank = item.rank, .position = initial_position, .real = item.real, .edge = item.edge, .label = item.label };
        guide.initial_order_count += 1;
        initial_position += 1;
    }

    const positions = try allocator.alloc(usize, expanded.items.len);
    defer allocator.free(positions);
    // SortByInputModelProcessor establishes a stable port-aware order before
    // phase 3. For a proper graph, a forward port-rank sweep is the equivalent
    // ordering: predecessor node order first, then the predecessor's model-
    // ordered outgoing ports.
    setLayerPositions(expanded.items, sequence.items, positions);
    var highest_rank: usize = 0;
    for (expanded.items) |item| highest_rank = @max(highest_rank, item.rank);
    if (model_order) for (0..highest_rank + 1) |rank| {
        try sortModelOrderRank(allocator, expanded.items, arcs.items, sequence.items, rank, positions);
    };
    var model_rank: ?usize = null;
    var model_position: usize = 0;
    for (sequence.items) |entry| {
        const item = expanded.items[entry];
        if (model_rank == null or model_rank.? != item.rank) {
            model_rank = item.rank;
            model_position = 0;
        }
        guide.model_order[guide.model_order_count] = .{
            .rank = item.rank,
            .position = model_position,
            .real = item.real,
            .edge = item.edge,
            .label = item.label,
        };
        guide.model_order_count += 1;
        model_position += 1;
    }

    var ports = try SweepPorts.init(allocator, arcs.items, positions);
    defer ports.deinit(allocator);
    const best_output = try allocator.dupe(usize, ports.output);
    defer allocator.free(best_output);
    const best_input = try allocator.dupe(usize, ports.input);
    defer allocator.free(best_input);
    const best_sequence = try allocator.dupe(usize, sequence.items);
    defer allocator.free(best_sequence);
    var best_crossings: usize = std.math.maxInt(usize);
    var global_random = JavaRandom.fromState(cycle_random_state);
    var parent_random = JavaRandom.fromState(parent_state orelse cycle_random_state);
    const random_seed = if (parent_state != null) parent_random.nextLong() else global_random.nextLong();
    ports.node_relative = global_random.nextBoolean();
    guide.routing_random_state = global_random.state;
    // ELK uses the root RNG for sweep direction and the child graph's own
    // RNG for barycenter perturbations. Only the root is reset to sweepSeed.
    var random = if (parent_state != null) global_random else JavaRandom.init(random_seed);
    var direction_random = JavaRandom.init(random_seed);
    if (trace_random) {
        random.draw_states = guide.sweep_random_states;
        random.draw_bits = guide.sweep_random_bits;
    }
    // ELK 0.10's FIRST/SECOND_TRY properties share the same identifier. The
    // first sweep clears both flags, so only trial zero preserves model order.
    // Later trials
    // randomize only the first fixed layer. It selects strictly by crossings,
    // without zmermaid's former arc-length tie-break or greedy-switch pass.
    for (0..7) |attempt| {
        var forward = if (parent_state != null) direction_random.nextBoolean() else random.nextBoolean();
        if (attempt == 0 and model_order) forward = true;
        if (attempt == 0 and constrained_output) forward = false else if (attempt == 0 and constrained_input) forward = true;
        if (attempt == 0 and model_order and ports.crossings(expanded.items, arcs.items, positions) == 0) {
            @memcpy(best_sequence, sequence.items);
            best_crossings = 0;
            break;
        }
        if (attempt > 0 or !model_order) {
            if (!(if (forward) constrained_input else constrained_output)) randomizeOuterRank(expanded.items, sequence.items, forward, &random);
        }
        var previous_crossings: usize = std.math.maxInt(usize);
        var first_sweep = true;
        while (true) {
            setLayerPositions(expanded.items, sequence.items, positions);
            ports.sweepLayer(expanded.items, arcs.items, positions, if (forward) 0 else highest_rank, forward, highest_rank);
            if (forward) {
                for (1..highest_rank + 1) |rank| {
                    ports.calculate(expanded.items, arcs.items, positions, rank - 1, true);
                    sortExpandedRankPorts(expanded.items, arcs.items, sequence.items, rank, true, positions, &random, &ports, !first_sweep or (attempt == 0 and model_order));
                    ports.sweepLayer(expanded.items, arcs.items, positions, rank, true, highest_rank);
                }
            } else {
                var rank = highest_rank;
                while (rank > 0) {
                    rank -= 1;
                    ports.calculate(expanded.items, arcs.items, positions, rank + 1, false);
                    sortExpandedRankPorts(expanded.items, arcs.items, sequence.items, rank, false, positions, &random, &ports, !first_sweep or (attempt == 0 and model_order));
                    ports.sweepLayer(expanded.items, arcs.items, positions, rank, false, highest_rank);
                }
            }
            setLayerPositions(expanded.items, sequence.items, positions);
            const crossings = ports.crossings(expanded.items, arcs.items, positions);
            if (crossings < best_crossings) {
                best_crossings = crossings;
                @memcpy(best_sequence, sequence.items);
                @memcpy(best_output, ports.output);
                @memcpy(best_input, ports.input);
            }
            if (crossings == 0 or crossings >= previous_crossings) break;
            previous_crossings = crossings;
            forward = !forward;
            first_sweep = false;
        }
        if (best_crossings == 0) break;
    }
    @memcpy(sequence.items, best_sequence);
    const proper_ids = try allocator.alloc(usize, expanded.items.len);
    defer allocator.free(proper_ids);
    for (sequence.items, 0..) |entry, id| proper_ids[entry] = id;
    if (parent_state != null) guide.routing_random_state = random.state;
    guide.sweep_random_count = @min(random.draw_count, guide.sweep_random_states.len);
    guide.arcs = try allocator.alloc(OrderedArc, arcs.items.len);
    errdefer allocator.free(guide.arcs);
    for (arcs.items, 0..) |arc, index| {
        if (guide.arc_count == guide.arcs.len) return error.UnsupportedSyntax;
        guide.arcs[guide.arc_count] = .{ .edge = arc.edge, .rank = expanded.items[arc.low].rank, .output = best_output[index], .input = best_input[index], .from = if (sides != null) proper_ids[arc.low] else null, .to = if (sides != null) proper_ids[arc.high] else null, .source_east = arc.source_east, .target_east = arc.target_east };
        guide.arc_count += 1;
    }

    // Keep the proper graph's occupied slots for coordinate assignment.  A
    // long-edge or label dummy must continue to reserve its place after the
    // crossing sweep; dropping it here was the main architectural divergence
    // from ELK and forced routing to rediscover corridors heuristically.
    // The P3 trace precedes label switching. Preserve it before the P4
    // preparation processors change which chain slot carries the label.
    setLayerPositions(expanded.items, sequence.items, positions);
    for (sequence.items) |entry| {
        const item = expanded.items[entry];
        if (guide.order_count < guide.order.len) {
            guide.order[guide.order_count] = .{ .rank = item.rank, .position = positions[entry], .real = item.real, .edge = item.edge, .label = item.label };
            guide.order_count += 1;
        }
    }
    switchMedianLabels(expanded.items);
    guide.positioned = try allocator.alloc(PositionedEntry, sequence.items.len);
    var current_rank: ?usize = null;
    var cursor: usize = 0;
    var entries: usize = 0;
    var previous_real = false;
    for (sequence.items, 0..) |entry, index| {
        const item = expanded.items[entry];
        if (current_rank == null or current_rank.? != item.rank) {
            current_rank = item.rank;
            cursor = 0;
            entries = 0;
            previous_real = false;
        }
        // ELK does not treat a zero-width LONG_EDGE dummy as a full node.
        // Adjacent real boxes use node spacing; corridors and label dummies
        // use the much tighter edge-edge clearance used by the layered router.
        if (entries > 0) cursor += if (previous_real and item.real != null) node_gap else 12;
        guide.positioned[index] = .{ .rank = item.rank, .position = entries, .real = item.real, .edge = item.edge, .label = item.label, .cross = cursor, .cross_size = item.cross, .along_size = item.along, .inverted = item.inverted };
        if (item.real) |id| guide.offsets[id] = cursor;
        if (item.edge) |edge_i| {
            const center = cursor + item.cross / 2;
            if (!guide.near_low_valid[edge_i] or item.rank < guide.near_low_rank[edge_i]) {
                guide.near_low_cross[edge_i] = center;
                guide.near_low_rank[edge_i] = item.rank;
                guide.near_low_valid[edge_i] = true;
            }
            if (!guide.near_high_valid[edge_i] or item.rank > guide.near_high_rank[edge_i]) {
                guide.near_high_cross[edge_i] = center;
                guide.near_high_rank[edge_i] = item.rank;
                guide.near_high_valid[edge_i] = true;
            }
            if (item.label) {
                guide.label_cross[edge_i] = center;
                guide.label_rank[edge_i] = item.rank;
                guide.label_valid[edge_i] = true;
            }
        }
        cursor += item.cross;
        entries += 1;
        previous_real = item.real != null;
        guide.breadths[item.rank] = cursor;
        guide.depths[item.rank] = @max(guide.depths[item.rank], item.along);
    }

    var out: usize = 0;
    for (sequence.items) |entry| if (expanded.items[entry].real) |id| {
        ids[out] = id;
        out += 1;
    };
    return guide;
}

fn stableRankSort(nodes: []const ExpandedNode, sequence: []usize) void {
    var i: usize = 1;
    while (i < sequence.len) : (i += 1) {
        const value = sequence[i];
        var j = i;
        while (j > 0 and nodes[value].rank < nodes[sequence[j - 1]].rank) : (j -= 1) sequence[j] = sequence[j - 1];
        sequence[j] = value;
    }
}

// Hierarchical sweeps fix the entering boundary layer to its parent's
// clockwise port order. Ordinary nodes and long-edge corridors are untouched.
fn constrainExternalOrder(nodes: []const ExpandedNode, sequence: []usize, input: bool) bool {
    var count: usize = 0;
    for (sequence) |id| if (nodes[id].external_order != null and nodes[id].external_input == input) { count += 1; };
    if (count < 2) return false;
    for (sequence, 0..) |id, i| {
        if (nodes[id].external_order == null or nodes[id].external_input != input) continue;
        var j = i;
        while (j > 0) {
            const previous = sequence[j - 1];
            if (nodes[previous].rank != nodes[id].rank or nodes[previous].external_order == null or nodes[previous].external_input != input or nodes[previous].external_order.? <= nodes[id].external_order.?) break;
            sequence[j] = previous; j -= 1;
        }
        sequence[j] = id;
    }
    return true;
}

test "parent port order constrains only the entering external boundary layer" {
    const nodes = [_]ExpandedNode{
        .{ .rank = 0, .real = 0 },
        .{ .rank = 1, .edge = 0 },
        .{ .rank = 2, .real = 1, .external_input = false, .external_order = 1 },
        .{ .rank = 2, .real = 2, .external_input = false, .external_order = 0 },
    };
    var sequence = [_]usize{ 0, 1, 2, 3 };
    try std.testing.expect(!constrainExternalOrder(&nodes, &sequence, true));
    try std.testing.expect(constrainExternalOrder(&nodes, &sequence, false));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3, 2 }, &sequence);
}

fn setLayerPositions(nodes: []const ExpandedNode, sequence: []const usize, positions: []usize) void {
    var rank: ?usize = null;
    var position: usize = 0;
    for (sequence) |entry| {
        if (rank == null or rank.? != nodes[entry].rank) {
            rank = nodes[entry].rank;
            position = 0;
        }
        positions[entry] = position;
        position += 1;
    }
}

fn shuffleOuterRank(nodes: []const ExpandedNode, sequence: []usize, forward: bool, random: *JavaRandom) void {
    if (sequence.len < 2) return;
    const rank = nodes[sequence[if (forward) 0 else sequence.len - 1]].rank;
    var first: usize = sequence.len;
    var end: usize = 0;
    for (sequence, 0..) |entry, i| if (nodes[entry].rank == rank) {
        first = @min(first, i);
        end = i + 1;
    };
    if (end <= first + 1) return;
    var i = end - first;
    while (i > 1) {
        i -= 1;
        const j = random.nextInt(i + 1);
        const tmp = sequence[first + i];
        sequence[first + i] = sequence[first + j];
        sequence[first + j] = tmp;
    }
}

fn randomizeOuterRank(nodes: []const ExpandedNode, sequence: []usize, forward: bool, random: *JavaRandom) void {
    if (sequence.len == 0) return;
    const rank = nodes[sequence[if (forward) 0 else sequence.len - 1]].rank;
    var first: usize = sequence.len;
    var end: usize = 0;
    for (sequence, 0..) |entry, i| if (nodes[entry].rank == rank) {
        first = @min(first, i);
        end = i + 1;
    };
    if (end <= first) return;
    var keys = [_]f64{0} ** 768;
    for (sequence[first..end]) |entry| keys[entry] = random.nextDouble();
    var i = first + 1;
    while (i < end) : (i += 1) {
        const value = sequence[i];
        var j = i;
        while (j > first and keys[value] < keys[sequence[j - 1]]) : (j -= 1) sequence[j] = sequence[j - 1];
        sequence[j] = value;
    }
}

fn modelSourceArc(arcs: []const ExpandedArc, positions: []const usize, entry: usize, before_ports: bool) ?usize {
    var result: ?usize = null;
    for (arcs, 0..) |arc, arc_i| {
        if (arc.high != entry) continue;
        if (result == null) {
            result = arc_i;
            continue;
        }
        const current = arcs[result.?];
        // ModelOrderPortComparator sorts incoming ports in reverse order of
        // their predecessor nodes. ModelOrderNodeComparator then observes the
        // last such port, i.e. the earliest predecessor. Equal predecessors
        // retain edge model order, so the largest edge is last.
        if ((before_ports and arc.edge > current.edge) or (!before_ports and (positions[arc.low] < positions[current.low] or
            (positions[arc.low] == positions[current.low] and arc.edge > current.edge)))) result = arc_i;
    }
    return result;
}

fn modelLess(nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize, left: usize, right: usize) bool {
    return modelLessWithPorts(nodes, arcs, positions, left, right, false);
}

fn modelLessWithPorts(nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize, left: usize, right: usize, before_ports: bool) bool {
    if (nodes[left].real != null and nodes[right].real != null)
        return nodes[left].real.? < nodes[right].real.?;

    const left_source = modelSourceArc(arcs, positions, left, before_ports);
    const right_source = modelSourceArc(arcs, positions, right, before_ports);
    if (left_source != null and right_source != null) {
        const a = arcs[left_source.?];
        const b = arcs[right_source.?];
        if (a.low != b.low) return positions[a.low] < positions[b.low];
        if (a.edge != b.edge) return a.edge < b.edge;
    }

    // At least one node is a dummy here. ELK falls back to the model order of
    // the first incoming edge; normal nodes use their first input port too.
    if (left_source == null and right_source == null) return true;
    const left_key = modelFirstInput(arcs, positions, left, before_ports);
    const right_key = modelFirstInput(arcs, positions, right, before_ports);
    return left_key <= right_key;
}

fn modelFirstInput(arcs: []const ExpandedArc, positions: []const usize, entry: usize, before_ports: bool) usize {
    var first: ?usize = null;
    for (arcs, 0..) |arc, index| {
        if (arc.high != entry) continue;
        if (first == null) {
            first = index;
            continue;
        }
        const current = arcs[first.?];
        if ((before_ports and arc.edge < current.edge) or
            (!before_ports and (positions[arc.low] > positions[current.low] or
                (positions[arc.low] == positions[current.low] and arc.edge < current.edge)))) first = index;
    }
    return if (first) |index| arcs[index].edge else std.math.maxInt(usize);
}

const ModelRelations = struct {
    count: usize,
    before: []bool,
    before_ports: bool = false,

    fn compare(self: *ModelRelations, nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize, left: usize, right: usize, left_index: usize, right_index: usize) bool {
        if (self.before[left_index * self.count + right_index]) return true;
        if (self.before[right_index * self.count + left_index]) return false;
        const less = modelLessWithPorts(nodes, arcs, positions, left, right, self.before_ports);
        const small = if (less) left_index else right_index;
        const big = if (less) right_index else left_index;
        self.before[small * self.count + big] = true;
        // Keep the established comparisons transitive. Real/real model order
        // and dummy/predecessor order can otherwise contradict one another.
        for (0..self.count) |predecessor| {
            if (predecessor != small and !self.before[predecessor * self.count + small]) continue;
            for (0..self.count) |successor| {
                if (successor == big or self.before[big * self.count + successor])
                    self.before[predecessor * self.count + successor] = true;
            }
        }
        return less;
    }
};

test "model ordering preserves learned transitive comparisons across real and dummy nodes" {
    const nodes = [_]ExpandedNode{
        .{ .rank = 1, .real = 0 },
        .{ .rank = 1, .real = 1 },
        .{ .rank = 1, .edge = 1 },
        .{ .rank = 0, .real = 2 },
        .{ .rank = 0, .real = 3 },
    };
    const arcs = [_]ExpandedArc{
        .{ .low = 3, .high = 1, .edge = 0 },
        .{ .low = 4, .high = 2, .edge = 1 },
    };
    const positions = [_]usize{ 0, 1, 2, 0, 1 };
    var before = [_]bool{false} ** 9;
    var relations: ModelRelations = .{ .count = 3, .before = &before };
    try std.testing.expect(relations.compare(&nodes, &arcs, &positions, 0, 1, 0, 1));
    try std.testing.expect(relations.compare(&nodes, &arcs, &positions, 2, 0, 2, 0));
    // Raw predecessor order conflicts with the comparisons already learned.
    try std.testing.expect(modelLess(&nodes, &arcs, &positions, 1, 2));
    try std.testing.expect(!relations.compare(&nodes, &arcs, &positions, 1, 2, 1, 2));
}

test "model input ports distinguish first fallback from last predecessor" {
    const arcs = [_]ExpandedArc{
        .{ .low = 0, .high = 3, .edge = 8 },
        .{ .low = 1, .high = 3, .edge = 2 },
        .{ .low = 2, .high = 3, .edge = 5 },
    };
    const positions = [_]usize{ 0, 2, 1, 0 };
    try std.testing.expectEqual(@as(?usize, 0), modelSourceArc(&arcs, &positions, 3, true));
    try std.testing.expectEqual(@as(?usize, 0), modelSourceArc(&arcs, &positions, 3, false));
    try std.testing.expectEqual(@as(usize, 2), modelFirstInput(&arcs, &positions, 3, true));
    try std.testing.expectEqual(@as(usize, 2), modelFirstInput(&arcs, &positions, 3, false));
}

test "model ordering uses two insertion passes and source-less real nodes" {
    const nodes = [_]ExpandedNode{
        .{ .rank = 2, .real = 3 },
        .{ .rank = 2, .edge = 14, .label = true },
        .{ .rank = 2, .edge = 16, .label = true },
        .{ .rank = 2, .edge = 12 },
        .{ .rank = 3, .real = 0 },
        .{ .rank = 3, .edge = 9, .label = true },
        .{ .rank = 3, .edge = 11, .label = true },
        .{ .rank = 3, .real = 1 },
        .{ .rank = 3, .real = 2 },
        .{ .rank = 3, .edge = 8 },
        .{ .rank = 3, .edge = 12 },
    };
    const arcs = [_]ExpandedArc{
        .{ .low = 0, .high = 9, .edge = 8 },
        .{ .low = 0, .high = 5, .edge = 9 },
        .{ .low = 0, .high = 6, .edge = 11 },
        .{ .low = 3, .high = 10, .edge = 12 },
        .{ .low = 1, .high = 7, .edge = 14 },
        .{ .low = 2, .high = 8, .edge = 16 },
    };
    var sequence = [_]usize{ 3, 1, 2, 0, 4, 5, 6, 7, 8, 9, 10 };
    var positions: [nodes.len]usize = undefined;
    setLayerPositions(&nodes, &sequence, &positions);
    try sortModelOrderRank(std.testing.allocator, &nodes, &arcs, &sequence, 3, &positions);
    try std.testing.expectEqualSlices(usize, &.{ 3, 1, 2, 0, 10, 5, 6, 4, 7, 8, 9 }, &sequence);
}

fn sortModelOrderRank(allocator: std.mem.Allocator, nodes: []const ExpandedNode, arcs: []const ExpandedArc, sequence: []usize, rank: usize, positions: []usize) !void {
    var first = sequence.len;
    var end = sequence.len;
    for (sequence, 0..) |entry, i| if (nodes[entry].rank == rank) {
        first = @min(first, i);
        end = i + 1;
    };
    if (first == sequence.len or end - first < 2) return;
    const count = end - first;
    const before = try allocator.alloc(bool, count * count);
    defer allocator.free(before);
    @memset(before, false);
    const original = try allocator.dupe(usize, sequence[first..end]);
    defer allocator.free(original);
    const indices = try allocator.alloc(usize, nodes.len);
    defer allocator.free(indices);
    for (original, 0..) |entry, index| indices[entry] = index;
    var relations: ModelRelations = .{ .count = count, .before = before };
    // ELK 0.10 uses two explicit insertion sorts, before and after sorting
    // ports. It compares the predecessor against the inserted node (not the
    // other way around), and resets its learned relations between passes.
    for (0..2) |pass| {
        @memset(before, false);
        relations.before_ports = pass == 0;
        var i = first + 1;
        while (i < end) : (i += 1) {
            const value = sequence[i];
            var j = i;
            while (j > first and !relations.compare(nodes, arcs, positions, sequence[j - 1], value, indices[sequence[j - 1]], indices[value])) : (j -= 1)
                sequence[j] = sequence[j - 1];
            sequence[j] = value;
        }
    }
    setLayerPositions(nodes, sequence, positions);
}

fn portRank(arcs: []const ExpandedArc, positions: []const usize, arc_i: usize, forward: bool) f64 {
    const arc = arcs[arc_i];
    const fixed = if (forward) arc.low else arc.high;
    var count: usize = 0;
    var ordinal: usize = 0;
    for (arcs, 0..) |other, other_i| {
        const same_fixed = if (forward) other.low == fixed else other.high == fixed;
        if (!same_fixed) continue;
        count += 1;
        if (other.edge < arc.edge or (other.edge == arc.edge and other_i < arc_i)) ordinal += 1;
    }
    const increment = 1.0 / @as(f64, @floatFromInt(count + 1));
    const base: f64 = @floatFromInt(positions[fixed]);
    return if (forward)
        base + @as(f64, @floatFromInt(ordinal + 1)) * increment
    else
        base + 1.0 - @as(f64, @floatFromInt(ordinal + 1)) * increment;
}

fn sortExpandedRankPorts(nodes: []const ExpandedNode, arcs: []const ExpandedArc, sequence: []usize, rank: usize, predecessors: bool, positions: []usize, random: ?*JavaRandom, ports: *const SweepPorts, pre_ordered: bool) void {
    var first = sequence.len;
    var end = sequence.len;
    for (sequence, 0..) |entry, i| if (nodes[entry].rank == rank) {
        first = @min(first, i);
        end = i + 1;
    };
    if (first == sequence.len) return;
    var keys = [_]f64{0} ** 768;
    var known = [_]bool{false} ** 768;
    const center_stage = @import("flow_barycenter.zig");
    var ranks: [768]usize = undefined;
    var links: [4096]center_stage.Link = undefined;
    var states: [768]center_stage.State = undefined;
    if (nodes.len > ranks.len or arcs.len > links.len) return;
    for (nodes, 0..) |node, i| ranks[i] = node.rank;
    for (arcs, 0..) |arc, i| links[i] = .{ .owner = if (predecessors) arc.high else arc.low, .other = if (predecessors) arc.low else arc.high, .fixed_rank = if (predecessors) ports.output_ranks[i] else ports.input_ranks[i] };
    var deterministic = JavaRandom.init(1);
    const center_random = random orelse &deterministic;
    center_stage.calculate(ranks[0..nodes.len], links[0..arcs.len], sequence[first..end], center_random, states[0..nodes.len]);
    for (sequence[first..end]) |entry| if (states[entry].barycenter) |value| { keys[entry] = value; known[entry] = true; };
    if (pre_ordered) {
        var last: f64 = -1;
        for (sequence[first..end], first..) |entry, index| {
            if (!known[entry]) {
                var next = last + 1;
                for (sequence[index + 1 .. end]) |later| if (known[later]) {
                    next = keys[later];
                    break;
                };
                keys[entry] = (last + next) / 2;
                known[entry] = true;
            }
            last = keys[entry];
        }
    } else {
        var maximum: f64 = 0;
        for (sequence[first..end]) |entry| if (known[entry]) {
            maximum = @max(maximum, keys[entry]);
        };
        for (sequence[first..end]) |entry| if (!known[entry]) {
            keys[entry] = if (random) |rng| rng.nextFloat() * (maximum + 2) - 1 else 0;
            known[entry] = true;
        };
    }
    var i = first + 1;
    while (i < end) : (i += 1) {
        const value = sequence[i];
        var j = i;
        while (j > first) {
            const previous = sequence[j - 1];
            if (!known[value] or (known[previous] and keys[value] >= keys[previous])) break;
            sequence[j] = previous;
            j -= 1;
        }
        sequence[j] = value;
    }
    setLayerPositions(nodes, sequence, positions);
}

fn totalCrossings(nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize) usize {
    var last: usize = 0;
    for (nodes) |node| last = @max(last, node.rank);
    var result: usize = 0;
    for (0..last) |rank| result += gapCrossings(nodes, arcs, positions, rank);
    return result;
}

fn totalArcLength(arcs: []const ExpandedArc, positions: []const usize) usize {
    var result: usize = 0;
    for (arcs) |arc| result += if (positions[arc.low] > positions[arc.high]) positions[arc.low] - positions[arc.high] else positions[arc.high] - positions[arc.low];
    return result;
}

fn adjacentLength(nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize, rank: usize) usize {
    var result: usize = 0;
    for (arcs) |arc| {
        if (!((nodes[arc.low].rank == rank and nodes[arc.high].rank == rank + 1) or
            (rank > 0 and nodes[arc.low].rank == rank - 1 and nodes[arc.high].rank == rank))) continue;
        result += if (positions[arc.low] > positions[arc.high]) positions[arc.low] - positions[arc.high] else positions[arc.high] - positions[arc.low];
    }
    return result;
}

fn expandedBarycenter(nodes: []const ExpandedNode, arcs: []const ExpandedArc, entry: usize, predecessors: bool, positions: []const usize) Barycenter {
    var result: Barycenter = .{};
    for (arcs) |arc| {
        const neighbour = if (predecessors and arc.high == entry)
            arc.low
        else if (!predecessors and arc.low == entry)
            arc.high
        else
            continue;
        if ((predecessors and nodes[neighbour].rank + 1 != nodes[entry].rank) or (!predecessors and nodes[entry].rank + 1 != nodes[neighbour].rank)) continue;
        result.sum += positions[neighbour];
        result.count += 1;
    }
    return result;
}

fn sortExpandedRank(nodes: []const ExpandedNode, arcs: []const ExpandedArc, sequence: []usize, rank: usize, predecessors: bool, positions: []usize) void {
    var first = sequence.len;
    var end = sequence.len;
    for (sequence, 0..) |entry, i| if (nodes[entry].rank == rank) {
        first = @min(first, i);
        end = i + 1;
    };
    if (first == sequence.len or end - first < 2) return;
    var i = first + 1;
    while (i < end) : (i += 1) {
        const value = sequence[i];
        const key = expandedBarycenter(nodes, arcs, value, predecessors, positions);
        var j = i;
        while (j > first) {
            const previous = expandedBarycenter(nodes, arcs, sequence[j - 1], predecessors, positions);
            if (!baryLess(key, previous)) break;
            sequence[j] = sequence[j - 1];
            j -= 1;
        }
        sequence[j] = value;
    }
    setLayerPositions(nodes, sequence, positions);
}

fn gapCrossings(nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize, low_rank: usize) usize {
    var result: usize = 0;
    for (arcs, 0..) |a, i| {
        if (nodes[a.low].rank != low_rank or nodes[a.high].rank != low_rank + 1) continue;
        for (arcs[i + 1 ..]) |b| {
            if (nodes[b.low].rank != low_rank or nodes[b.high].rank != low_rank + 1) continue;
            const source_order = if (a.low == b.low) a.edge < b.edge else positions[a.low] < positions[b.low];
            const target_order = if (a.high == b.high) a.edge > b.edge else positions[a.high] < positions[b.high];
            if (source_order != target_order) result += 1;
        }
    }
    return result;
}

fn adjacentCrossings(nodes: []const ExpandedNode, arcs: []const ExpandedArc, positions: []const usize, rank: usize) usize {
    var result: usize = 0;
    if (rank > 0) result += gapCrossings(nodes, arcs, positions, rank - 1);
    result += gapCrossings(nodes, arcs, positions, rank);
    return result;
}

fn greedySwitchExpanded(nodes: []const ExpandedNode, arcs: []const ExpandedArc, sequence: []usize, positions: []usize) void {
    for (0..32) |pass| {
        var improved = false;
        if (pass % 2 == 0) {
            var i: usize = 1;
            while (i < sequence.len) : (i += 1) {
                const a = sequence[i - 1];
                const b = sequence[i];
                if (nodes[a].rank != nodes[b].rank) continue;
                const before = adjacentCrossings(nodes, arcs, positions, nodes[a].rank);
                const before_length = adjacentLength(nodes, arcs, positions, nodes[a].rank);
                sequence[i - 1] = b;
                sequence[i] = a;
                setLayerPositions(nodes, sequence, positions);
                const after = adjacentCrossings(nodes, arcs, positions, nodes[a].rank);
                const after_length = adjacentLength(nodes, arcs, positions, nodes[a].rank);
                if (after < before or (after == before and after_length < before_length)) improved = true else {
                    sequence[i - 1] = a;
                    sequence[i] = b;
                    setLayerPositions(nodes, sequence, positions);
                }
            }
        } else {
            var i = sequence.len;
            while (i > 1) {
                i -= 1;
                const a = sequence[i - 1];
                const b = sequence[i];
                if (nodes[a].rank != nodes[b].rank) continue;
                const before = adjacentCrossings(nodes, arcs, positions, nodes[a].rank);
                const before_length = adjacentLength(nodes, arcs, positions, nodes[a].rank);
                sequence[i - 1] = b;
                sequence[i] = a;
                setLayerPositions(nodes, sequence, positions);
                const after = adjacentCrossings(nodes, arcs, positions, nodes[a].rank);
                const after_length = adjacentLength(nodes, arcs, positions, nodes[a].rank);
                if (after < before or (after == before and after_length < before_length)) improved = true else {
                    sequence[i - 1] = a;
                    sequence[i] = b;
                    setLayerPositions(nodes, sequence, positions);
                }
            }
        }
        if (!improved) break;
    }
}

// Compact ordered layers into vertical (or horizontal) blocks. This is the
// coordinate-assignment half of a layered layout: alternating median sweeps
// align chains while the adjacent-node bounds preserve the chosen order.
pub fn compact(nodes: anytype, edges: anytype, ids: []const usize, horizontal: bool, node_gap: usize, size: Size) void {
    if (ids.len < 2) return;
    var last: usize = 0;
    for (ids) |id| last = @max(last, nodes[id].rank);
    for (0..2) |_| {
        for (1..last + 1) |rank| alignRank(nodes, edges, ids, rank, true, horizontal, node_gap, size);
        var rank = last;
        while (rank > 0) : (rank -= 1) alignRank(nodes, edges, ids, rank - 1, false, horizontal, node_gap, size);
    }
    // The alternating sweeps discover useful alignment blocks, but ending on
    // the reverse sweep makes successors win every tie. In a top-down fan-in
    // that can move the join away from its incoming spine and braid otherwise
    // ordered connectors. Finish in the graph direction so predecessor chains
    // retain the alignment used by ELK's layered coordinate assignment.
    for (1..last + 1) |rank| alignRank(nodes, edges, ids, rank, true, horizontal, node_gap, size);

    // A long edge is represented by an aligned chain of dummy nodes in ELK.
    // When its source occupies a layer by itself, preserve that straight
    // virtual chain by aligning the source with the distant target. Without
    // this, the later router is forced into an exterior detour even though the
    // intervening layers have a viable internal channel.
    var rank_counts = [_]usize{0} ** 4096;
    for (ids) |id| rank_counts[nodes[id].rank] += 1;
    for (edges) |edge| {
        if (nodes[edge.from].rank <= nodes[edge.to].rank or nodes[edge.from].rank - nodes[edge.to].rank <= 1) continue;
        if (rank_counts[nodes[edge.from].rank] != 1) continue;
        const extent = if (horizontal) nodes[edge.from].h else nodes[edge.from].w;
        const target_center = crossCenter(nodes[edge.to], horizontal);
        const canvas = if (horizontal) size.h else size.w;
        const center = @min(@max(target_center, extent / 2), canvas -| ((extent + 1) / 2));
        if (horizontal) nodes[edge.from].y = center -| extent / 2 else nodes[edge.from].x = center -| extent / 2;
    }
}

fn alignRank(nodes: anytype, edges: anytype, ids: []const usize, rank: usize, predecessors: bool, horizontal: bool, node_gap: usize, size: Size) void {
    for (ids, 0..) |id, at| {
        if (nodes[id].rank != rank) continue;
        if (!predecessors) {
            var original_in: usize = 0;
            var original_out: usize = 0;
            for (edges) |edge| {
                if (edge.to == id and edge.from != id) original_in += 1;
                if (edge.from == id and edge.to != id) original_out += 1;
            }
            // Keep broad fan-out hubs on their incoming spine. Moving such a
            // hub to the median child recreates rank-centering and breaks the
            // visual column established by the downward sweep.
            if (original_in == 1 and original_out >= 3) continue;
        }
        var neighbours = [_]usize{0} ** 256;
        var count: usize = 0;
        for (edges) |edge| {
            const a = edge.from;
            const b = edge.to;
            const rank_distance = if (nodes[a].rank > nodes[b].rank) nodes[a].rank - nodes[b].rank else nodes[b].rank - nodes[a].rank;
            // ELK expands long edges into dummy nodes, one per crossed layer.
            // Treating the distant real endpoint as an immediate neighbour
            // pulls nodes off their local spine and can force adjacent fan-in
            // connectors to braid. Only genuine neighbouring-layer endpoints
            // participate in this compacting pass; routing handles the long
            // edge's intermediate corridor separately.
            if (rank_distance != 1) continue;
            const low = if (nodes[a].rank < nodes[b].rank) a else b;
            const high = if (low == a) b else a;
            const neighbour = if (predecessors and high == id) low else if (!predecessors and low == id) high else continue;
            neighbours[count] = crossCenter(nodes[neighbour], horizontal);
            count += 1;
        }
        if (count == 0) continue;
        var i: usize = 1;
        while (i < count) : (i += 1) {
            const value = neighbours[i];
            var j = i;
            while (j > 0 and value < neighbours[j - 1]) : (j -= 1) neighbours[j] = neighbours[j - 1];
            neighbours[j] = value;
        }
        const desired = neighbours[(count - 1) / 2];
        const extent = if (horizontal) nodes[id].h else nodes[id].w;
        var low_bound = extent / 2;
        var high_bound = (if (horizontal) size.h else size.w) -| ((extent + 1) / 2);
        var before = at;
        while (before > 0) {
            before -= 1;
            const other = ids[before];
            if (nodes[other].rank == rank) {
                low_bound = @max(low_bound, crossCenter(nodes[other], horizontal) + ((if (horizontal) nodes[other].h else nodes[other].w) + 1) / 2 + node_gap + extent / 2);
                break;
            }
            if (nodes[other].rank < rank) break;
        }
        var after = at + 1;
        while (after < ids.len) : (after += 1) {
            const other = ids[after];
            if (nodes[other].rank == rank) {
                high_bound = @min(high_bound, crossCenter(nodes[other], horizontal) -| ((if (horizontal) nodes[other].h else nodes[other].w) / 2 + node_gap + (extent + 1) / 2));
                break;
            }
            if (nodes[other].rank > rank) break;
        }
        const center = @min(@max(desired, low_bound), high_bound);
        if (horizontal) nodes[id].y = center -| extent / 2 else nodes[id].x = center -| extent / 2;
    }
}

fn crossCenter(node: anytype, horizontal: bool) usize {
    return if (horizontal) node.y + node.h / 2 else node.x + node.w / 2;
}

fn sortRank(nodes: anytype, edges: anytype, ids: []usize, rank: usize, predecessors: bool, positions: *[256]usize) void {
    var first: usize = ids.len;
    var end: usize = ids.len;
    for (ids, 0..) |id, i| if (nodes[id].rank == rank) {
        first = @min(first, i);
        end = i + 1;
    };
    if (first == ids.len or end - first < 2) return;

    var i = first + 1;
    while (i < end) : (i += 1) {
        const value = ids[i];
        const key = barycenter(nodes, edges, value, predecessors, positions);
        var j = i;
        while (j > first) {
            const previous = barycenter(nodes, edges, ids[j - 1], predecessors, positions);
            if (!baryLess(key, previous)) break;
            ids[j] = ids[j - 1];
            j -= 1;
        }
        ids[j] = value;
    }
    for (ids, 0..) |id, position| positions[id] = position;
}

const Barycenter = struct { sum: usize = 0, count: usize = 0, root: bool = false };

fn barycenter(nodes: anytype, edges: anytype, id: usize, predecessors: bool, positions: *const [256]usize) Barycenter {
    var result: Barycenter = .{};
    var original_incoming = false;
    for (edges) |edge| {
        if (edge.to == id and edge.from != id) original_incoming = true;
        const a = edge.from;
        const b = edge.to;
        const rank_distance = if (nodes[a].rank > nodes[b].rank) nodes[a].rank - nodes[b].rank else nodes[b].rank - nodes[a].rank;
        // ELK's long-edge dummy nodes influence one layer at a time. Voting
        // with the distant real endpoint reverses otherwise parallel chains
        // and creates a crossing that routing cannot remove afterward.
        if (rank_distance != 1) continue;
        const low = if (nodes[a].rank < nodes[b].rank) a else b;
        const high = if (low == a) b else a;
        const neighbour = if (predecessors and high == id) low else if (!predecessors and low == id) high else continue;
        result.sum += positions[neighbour];
        result.count += 1;
    }
    result.root = predecessors and result.count == 0 and !original_incoming;
    return result;
}

fn baryLess(a: Barycenter, b: Barycenter) bool {
    if (a.root != b.root) return a.root;
    if (a.count == 0) return false;
    if (b.count == 0) return true;
    return a.sum * b.count < b.sum * a.count;
}

// Measure each shape independently: one large label must not resize its peers.
pub fn nodeSize(node: anytype) Size {
    const text_w = node.style.measure(paint.labelWidth(node.label, node.markdown));
    const text_h = node.style.measure(paint.labelHeight(node.label));
    var size: Size = .{ .w = @max(64, text_w + 32), .h = @max(44, text_h + 24) };
    switch (node.shape) {
        .diamond, .triangle, .flipped_triangle => {
            size.w = @max(80, (text_w + 16) * 2);
            size.h = @max(64, (text_h + 12) * 2);
        },
        .box, .round, .text => {},
        else => {
            // Insets, folded corners and curved borders need extra clearance.
            size.w = @max(80, text_w + 48);
            size.h = @max(60, text_h + 40);
        },
    }
    if (shapes.circular(node.shape)) {
        // Fit the label's corners, not just its width, inside the circle.
        const fw: f64 = @floatFromInt(text_w + 24);
        const fh: f64 = @floatFromInt(text_h + 24);
        size.w = @max(64, @as(usize, @intFromFloat(@ceil(@sqrt(fw * fw + fh * fh)))));
        size.h = size.w;
    }
    if (node.asset != null) {
        size.w = @max(size.w, node.asset_width + 64);
        size.h = @max(size.h, node.asset_height + text_h + 64);
    }
    return size;
}

// Pack variable-size nodes within each rank, and use that rank's own depth.
// Empty ranks still retain a gap, preserving long-link syntax.
pub fn place(nodes: anytype, ids: []const usize, horizontal: bool, reverse: bool, node_gap: usize, rank_gap: usize, rank_gaps: ?[]const usize, guide: ?*Guide) Size {
    var depths = [_]usize{0} ** 4096;
    var breadths = [_]usize{0} ** 4096;
    var offsets = [_]usize{0} ** 4096;
    var counts = [_]usize{0} ** 4096;
    var last: usize = 0;
    for (ids) |id| {
        const n = nodes[id];
        last = @max(last, n.rank);
        const extra = if (shapes.externalLabel(n.shape)) n.style.measure(paint.labelHeight(n.label)) + 8 else @as(usize, 0);
        const w = n.w;
        const h = n.h + extra;
        depths[n.rank] = @max(depths[n.rank], if (horizontal) w else h);
        if (counts[n.rank] > 0) breadths[n.rank] += node_gap;
        breadths[n.rank] += if (horizontal) h else w;
        counts[n.rank] += 1;
    }
    if (guide) |g| for (0..last + 1) |rank| {
        depths[rank] = @max(depths[rank], g.depths[rank]);
        breadths[rank] = @max(breadths[rank], g.breadths[rank]);
    };
    var depth: usize = 0;
    var breadth: usize = 0;
    for (0..last + 1) |rank| {
        offsets[rank] = depth;
        depth += depths[rank];
        if (rank < last) depth += if (rank_gaps) |gaps| gaps[rank] else rank_gap;
        breadth = @max(breadth, breadths[rank]);
    }
    if (guide) |g| {
        for (g.positioned) |*entry| {
            entry.cross += (breadth - breadths[entry.rank]) / 2;
            const forward = offsets[entry.rank] + (depths[entry.rank] - entry.along_size) / 2;
            entry.along = if (reverse) depth - forward - entry.along_size else forward;
        }
        for (0..last + 1) |rank| {
            const forward = offsets[rank] + depths[rank] / 2;
            g.centers[rank] = if (reverse) depth - forward else forward;
        }
        for (0..g.near_low_cross.len) |edge_i| {
            if (g.near_low_valid[edge_i]) g.near_low_cross[edge_i] += (breadth - breadths[g.near_low_rank[edge_i]]) / 2;
            if (g.near_high_valid[edge_i]) g.near_high_cross[edge_i] += (breadth - breadths[g.near_high_rank[edge_i]]) / 2;
            if (g.label_valid[edge_i]) g.label_cross[edge_i] += (breadth - breadths[g.label_rank[edge_i]]) / 2;
        }
    }
    var used = [_]usize{0} ** 4096;
    for (ids) |id| {
        const n = &nodes[id];
        const extra = if (shapes.externalLabel(n.shape)) n.style.measure(paint.labelHeight(n.label)) + 8 else @as(usize, 0);
        const along = if (horizontal) n.w else n.h + extra;
        const across = if (horizontal) n.h + extra else n.w;
        const forward = offsets[n.rank] + (depths[n.rank] - along) / 2;
        const main = if (reverse) depth - forward - along else forward;
        const cross = (breadth - breadths[n.rank]) / 2 + if (guide) |g| g.offsets[id] else used[n.rank];
        n.x = if (horizontal) main else cross;
        n.y = if (horizontal) cross else main;
        used[n.rank] += across + node_gap;
    }
    return .{ .w = if (horizontal) depth else breadth, .h = if (horizontal) breadth else depth };
}
