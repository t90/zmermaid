// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/BarycenterHeuristic.java
// Upstream notice: Copyright (c) 2010, 2015 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// ELK BarycenterHeuristic.calculateBarycenter: same-layer connections inherit
// recursively accumulated weights, not a port rank from their own layer.
const std = @import("std");
const Random = @import("flow_layout.zig").JavaRandom;
pub const Link = struct { owner: usize, other: usize, fixed_rank: f64 };
pub const State = struct { degree: usize = 0, summed_weight: f64 = 0, barycenter: ?f64 = null, visited: bool = false };
pub const Input = struct { ranks: []const usize, links: []const Link, order: []const usize, rank: usize, seed: u64, pre_ordered: bool };
pub const Result = struct { states: []const State, order: []const usize, random_state: u64 };
const Calculator = struct {
    ranks: []const usize, links: []const Link, states: []State, random: *Random,
    fn visit(self: *@This(), node: usize) void {
        if (self.states[node].visited) return;
        self.states[node] = .{ .visited = true };
        for (self.links) |link| {
            if (link.owner != node) continue;
            if (self.ranks[link.other] == self.ranks[node]) {
                if (link.other == node) continue;
                self.visit(link.other);
                self.states[node].degree += self.states[link.other].degree;
                self.states[node].summed_weight += self.states[link.other].summed_weight;
            } else {
                self.states[node].summed_weight += link.fixed_rank;
                self.states[node].degree += 1;
            }
        }
        if (self.states[node].degree > 0) {
            const perturbation: f32 = @as(f32, @floatCast(self.random.nextFloat())) * @as(f32, 0.07) - @as(f32, 0.07) / 2;
            self.states[node].summed_weight += perturbation;
            self.states[node].barycenter = self.states[node].summed_weight / @as(f64, @floatFromInt(self.states[node].degree));
        }
    }
};
pub fn calculate(ranks: []const usize, links: []const Link, order: []const usize, random: *Random, states: []State) void {
    @memset(states, .{});
    var calculator: Calculator = .{ .ranks = ranks, .links = links, .states = states, .random = random };
    for (order) |node| calculator.visit(node);
}
pub fn fillUnknown(order: []const usize, pre_ordered: bool, random: *Random, states: []State) void {
    if (pre_ordered) {
        var last: f64 = -1;
        for (order, 0..) |node, index| {
            if (states[node].barycenter == null) {
                var next = last + 1;
                for (order[index + 1 ..]) |later| if (states[later].barycenter) |value| { next = value; break; };
                const value = (last + next) / 2;
                states[node].barycenter = value; states[node].summed_weight = value; states[node].degree = 1;
            }
            last = states[node].barycenter.?;
        }
    } else {
        var maximum: f64 = 0;
        for (order) |node| if (states[node].barycenter) |value| { maximum = @max(maximum, value); };
        for (order) |node| if (states[node].barycenter == null) {
            const value = random.nextFloat() * (maximum + 2) - 1;
            states[node].barycenter = value; states[node].summed_weight = value; states[node].degree = 1;
        };
    }
}
pub fn compute(a: std.mem.Allocator, input: Input) !Result {
    if (input.ranks.len == 0 or input.ranks.len > 768 or input.links.len > 4096 or input.order.len == 0) return error.InvalidBarycenterGraph;
    for (input.links) |link| if (link.owner >= input.ranks.len or link.other >= input.ranks.len or !std.math.isFinite(link.fixed_rank)) return error.InvalidBarycenterGraph;
    const seen = try a.alloc(bool, input.ranks.len); @memset(seen, false);
    for (input.order) |node| {
        if (node >= input.ranks.len or input.ranks[node] != input.rank or seen[node]) return error.InvalidBarycenterGraph;
        seen[node] = true;
    }
    for (input.ranks, 0..) |rank, node| if (rank == input.rank and !seen[node]) return error.InvalidBarycenterGraph;
    const states = try a.alloc(State, input.ranks.len);
    var random = Random.init(input.seed);
    calculate(input.ranks, input.links, input.order, &random, states);
    fillUnknown(input.order, input.pre_ordered, &random, states);
    const order = try a.dupe(usize, input.order);
    // Stable ties preserve incoming order, as Java Collections.sort does.
    for (1..order.len) |i| {
        const node = order[i]; var j = i;
        while (j > 0 and states[node].barycenter.? < states[order[j - 1]].barycenter.?) : (j -= 1) order[j] = order[j - 1];
        order[j] = node;
    }
    return .{ .states = states, .order = order, .random_state = random.state };
}
pub fn trace(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const scratch = arena.allocator();
    const input = (try std.json.parseFromSlice(Input, scratch, source, .{})).value;
    return std.json.Stringify.valueAlloc(a, try compute(scratch, input), .{});
}

test "same-layer barycenters inherit degree and perturbation instead of stale port rank" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const result = try compute(arena.allocator(), .{ .ranks = &.{ 0, 1, 1 }, .order = &.{ 2, 1 }, .rank = 1, .seed = 1, .pre_ordered = true,
        .links = &.{ .{ .owner = 1, .other = 0, .fixed_rank = 0.25 }, .{ .owner = 2, .other = 1, .fixed_rank = 999 } } });
    try std.testing.expectEqual(@as(usize, 1), result.states[2].degree);
    try std.testing.expect(@abs(result.states[2].barycenter.? - 0.25) < 0.07);
    try std.testing.expectError(error.InvalidBarycenterGraph, compute(arena.allocator(), .{ .ranks = &.{0}, .order = &.{}, .rank = 1, .seed = 1, .pre_ordered = true, .links = &.{} }));
}
