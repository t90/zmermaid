// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/bk/BKNodePlacer.java
// Upstream notice: Copyright (c) 2012, 2015 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// ELK 0.10 BKNodePlacer candidate feasibility, balancing, and stable selection.
// Coordinates remain in the internal layered axis; no normalization is added.
const std = @import("std");
const bk = @import("flow_bk.zig");

pub const Candidate = struct {
    left: bool,
    up: bool,
    mode: []const u8,
    alignment: struct { root: []const usize, inner_shift: []const f64, block_size: []const ?f64 },
    final: struct { block_y: []const f64 },
};
pub const Validation = struct { valid: bool, size: f64 };
pub const Fixed = enum { NONE, LEFTUP, RIGHTUP, LEFTDOWN, RIGHTDOWN, BALANCED };
pub const Choice = union(enum) { candidate: usize, balanced };
const Policy = struct { fixed: Fixed, favor_straight: bool, node_y: []const f64 };
pub const Result = struct {
    mode: []const u8,
    candidates: [4]Validation,
    balanced: struct { valid: bool, node_y: []const f64 },
    policies: [7]Policy,
};

fn validateNodes(nodes: []const bk.Node) !void {
    if (nodes.len == 0 or nodes.len > 4096) return error.UnsupportedGraph;
    for (nodes, 0..) |node, id| {
        if (node.rank > 4095 or node.position > 4095 or !std.math.isFinite(node.extent) or node.extent < 0 or
            !std.math.isFinite(node.top) or node.top < 0 or !std.math.isFinite(node.bottom) or node.bottom < 0) return error.InvalidGraph;
        var count: usize = 0;
        for (nodes[0..id]) |earlier| if (earlier.rank == node.rank) {
            count += 1;
        };
        if (node.position != count) return error.InvalidGraph;
    }
}

// Nodes must be in validated per-layer order; compute validates this contract.
pub fn validate(nodes: []const bk.Node, c: Candidate) !Validation {
    const b = c.alignment;
    const y = c.final.block_y;
    if (b.root.len != nodes.len or b.inner_shift.len != nodes.len or b.block_size.len != nodes.len or y.len != nodes.len) return error.InvalidCandidate;
    var min = std.math.inf(f64);
    var max = -std.math.inf(f64);
    for (nodes, 0..) |_, id| {
        const root = b.root[id];
        if (root >= nodes.len or b.root[root] != root or !std.math.isFinite(y[id]) or !std.math.isFinite(b.inner_shift[id])) return error.InvalidCandidate;
        const size = b.block_size[root] orelse return error.InvalidCandidate;
        if (!std.math.isFinite(size) or size < 0) return error.InvalidCandidate;
        min = @min(min, y[id]);
        max = @max(max, y[id] + size);
    }
    if (!std.math.isFinite(max - min)) return error.InvalidCandidate;
    var valid = true;
    for (nodes, 0..) |node, id| {
        if (node.position == 0) continue;
        var previous: ?usize = null;
        for (nodes[0..id], 0..) |other, other_id| if (other.rank == node.rank and other.position + 1 == node.position) {
            previous = other_id;
        };
        const p = previous orelse return error.InvalidGraph;
        const bottom_before = y[p] + b.inner_shift[p] + nodes[p].extent + nodes[p].bottom;
        const top = y[id] + b.inner_shift[id] - node.top;
        const bottom = y[id] + b.inner_shift[id] + node.extent + node.bottom;
        if (!(top > bottom_before and bottom > bottom_before)) valid = false;
    }
    return .{ .valid = valid, .size = max - min };
}

pub fn select(validations: [4]Validation, fixed: Fixed, favor_straight: bool, balanced_valid: bool) Choice {
    switch (fixed) {
        .RIGHTDOWN => return .{ .candidate = 0 },
        .RIGHTUP => return .{ .candidate = 1 },
        .LEFTDOWN => return .{ .candidate = 2 },
        .LEFTUP => return .{ .candidate = 3 },
        else => {},
    }
    if ((fixed == .BALANCED or !favor_straight) and balanced_valid) return .balanced;
    var best: ?usize = null;
    for (validations, 0..) |v, i| {
        if (v.valid and (best == null or validations[best.?].size > v.size)) best = i;
    }
    return .{ .candidate = best orelse 0 };
}

// Result slices and scratch storage use the caller's arena, like flow_bk.compute.
pub fn compute(a: std.mem.Allocator, nodes: []const bk.Node, candidates: [4]Candidate) !Result {
    try validateNodes(nodes);
    var validations: [4]Validation = undefined;
    var positions: [4][]f64 = undefined;
    var min: [4]f64 = undefined;
    var max: [4]f64 = undefined;
    var smallest: usize = 0;
    for (candidates, 0..) |c, i| {
        if (c.left != (i >= 2) or c.up != (i % 2 == 1) or !std.mem.eql(u8, c.mode, candidates[0].mode)) return error.InvalidCandidateOrder;
        validations[i] = try validate(nodes, c);
        if (validations[smallest].size > validations[i].size) smallest = i;
        positions[i] = try a.alloc(f64, nodes.len);
        min[i] = 2147483647;
        max[i] = -2147483648;
        for (nodes, 0..) |node, id| {
            positions[i][id] = c.final.block_y[id] + c.alignment.inner_shift[id];
            min[i] = @min(min[i], positions[i][id]);
            max[i] = @max(max[i], positions[i][id] + node.extent);
        }
    }
    const balanced = try a.alloc(f64, nodes.len);
    for (nodes, 0..) |_, id| {
        var ys: [4]f64 = undefined;
        for (candidates, 0..) |c, i| ys[i] = positions[i][id] + if (c.up) max[smallest] - max[i] else min[smallest] - min[i];
        std.mem.sort(f64, &ys, {}, std.sort.asc(f64));
        balanced[id] = (ys[1] + ys[2]) / 2;
        if (!std.math.isFinite(balanced[id])) return error.InvalidCandidate;
    }
    var balanced_valid = true;
    for (nodes, 0..) |node, id| {
        if (node.position == 0) continue;
        for (nodes[0..id], 0..) |previous, p| {
            if (previous.rank != node.rank or previous.position + 1 != node.position) continue;
            const bottom_before = balanced[p] + previous.extent + previous.bottom;
            if (!(balanced[id] - node.top > bottom_before and balanced[id] + node.extent + node.bottom > bottom_before)) balanced_valid = false;
        }
    }
    var policies: [7]Policy = undefined;
    const fixeds = [_]Fixed{ .NONE, .NONE, .LEFTUP, .RIGHTUP, .LEFTDOWN, .RIGHTDOWN, .BALANCED };
    for (fixeds, 0..) |fixed, i| {
        const favor = i != 1;
        const chosen = select(validations, fixed, favor, balanced_valid);
        policies[i] = .{ .fixed = fixed, .favor_straight = favor, .node_y = switch (chosen) {
            .balanced => balanced,
            .candidate => |index| positions[index],
        } };
    }
    return .{ .mode = candidates[0].mode, .candidates = validations, .balanced = .{ .valid = balanced_valid, .node_y = balanced }, .policies = policies };
}

pub fn trace(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Input = struct { schema: []const u8, nodes: []const bk.Node, cases: []const Candidate };
    const input = (try std.json.parseFromSlice(Input, a, source, .{ .ignore_unknown_fields = true })).value;
    if (!std.mem.eql(u8, input.schema, "zmermaid-bk-selection-v1")) return error.InvalidSchema;
    if (input.cases.len != 8) return error.InvalidCandidateCount;
    var result: [2]Result = undefined;
    for ([_][]const u8{ "NONE", "IMPROVE_STRAIGHTNESS" }, 0..) |mode, index| {
        var cases: [4]Candidate = undefined;
        var count: usize = 0;
        for (input.cases) |c| {
            if (!std.mem.eql(u8, c.mode, mode)) continue;
            if (count == 4) return error.InvalidCandidateCount;
            cases[count] = c;
            count += 1;
        }
        if (count != 4) return error.InvalidCandidateCount;
        result[index] = try compute(a, input.nodes, cases);
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .schema = input.schema, .selection = result }, .{});
}

test "selection keeps first ties, skips invalid, falls back and honors policies" {
    const v = [4]Validation{ .{ .valid = true, .size = 40 }, .{ .valid = true, .size = 20 }, .{ .valid = true, .size = 20 }, .{ .valid = false, .size = 1 } };
    try std.testing.expectEqual(@as(usize, 1), select(v, .NONE, true, true).candidate);
    try std.testing.expect(select(v, .NONE, false, true) == .balanced);
    try std.testing.expectEqual(@as(usize, 1), select(v, .BALANCED, true, false).candidate);
    try std.testing.expectEqual(@as(usize, 3), select(v, .LEFTUP, false, true).candidate);
    const bad = [_]Validation{.{ .valid = false, .size = 40 }} ** 4;
    try std.testing.expectEqual(@as(usize, 0), select(bad, .NONE, true, false).candidate);
}

test "selection geometry includes margins, strict boundaries, shifts and root block sizes" {
    const nodes = [_]bk.Node{
        .{ .rank = 0, .position = 0, .extent = 10, .top = 2, .bottom = 3, .long_edge = false, .incoming = &.{}, .outgoing = &.{}, .connected = &.{} },
        .{ .rank = 0, .position = 1, .extent = 10, .top = 2, .bottom = 3, .long_edge = false, .incoming = &.{}, .outgoing = &.{}, .connected = &.{} },
    };
    var c: Candidate = .{ .left = false, .up = false, .mode = "NONE", .alignment = .{ .root = &.{ 0, 1 }, .inner_shift = &.{ 0, 0 }, .block_size = &.{ 15, 15 } }, .final = .{ .block_y = &.{ 0, 16 } } };
    try std.testing.expectEqual(Validation{ .valid = true, .size = 31 }, try validate(&nodes, c));
    c.final.block_y = &.{ 0, 15 };
    try std.testing.expect(!(try validate(&nodes, c)).valid);
    c.final.block_y = &.{ 0, 100 };
    c.alignment.inner_shift = &.{ 0, -86 };
    try std.testing.expect(!(try validate(&nodes, c)).valid);
    c.alignment.inner_shift = &.{ 0, 0 };
    c.alignment.root = &.{ 0, 0 };
    c.alignment.block_size = &.{ 80, null };
    c.final.block_y = &.{ 0, 30 };
    try std.testing.expectEqual(@as(f64, 110), (try validate(&nodes, c)).size);
    c.alignment.root = &.{ 0, 2 };
    try std.testing.expectError(error.InvalidCandidate, validate(&nodes, c));
}

test "selection balances four directions and frees trace scratch allocations" {
    const nodes = [_]bk.Node{
        .{ .rank = 0, .position = 0, .extent = 10, .top = 2, .bottom = 3, .long_edge = false, .incoming = &.{}, .outgoing = &.{}, .connected = &.{} },
        .{ .rank = 0, .position = 1, .extent = 10, .top = 2, .bottom = 3, .long_edge = false, .incoming = &.{}, .outgoing = &.{}, .connected = &.{} },
    };
    const ys = [4][2]f64{ .{ 0, 20 }, .{ 10, 40 }, .{ -10, 10 }, .{ 40, 60 } };
    var candidates: [8]Candidate = undefined;
    for (&candidates, 0..) |*c, i| c.* = .{ .left = i % 4 >= 2, .up = i % 2 == 1, .mode = if (i < 4) "NONE" else "IMPROVE_STRAIGHTNESS", .alignment = .{ .root = &.{ 0, 1 }, .inner_shift = &.{ 0, 0 }, .block_size = &.{ 15, 15 } }, .final = .{ .block_y = &ys[i % 4] } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try compute(arena.allocator(), &nodes, candidates[0..4].*);
    try std.testing.expectEqualSlices(f64, &.{ 0, 20 }, result.balanced.node_y);
    try std.testing.expect(result.balanced.valid);
    try std.testing.expectEqualSlices(f64, &.{ 0, 20 }, result.policies[1].node_y);
    const source = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .schema = "zmermaid-bk-selection-v1", .nodes = nodes, .cases = candidates }, .{});
    defer std.testing.allocator.free(source);
    const output = try trace(std.testing.allocator, source);
    defer std.testing.allocator.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("selection").?.array.items.len);
    candidates[0].left = true;
    try std.testing.expectError(error.InvalidCandidateOrder, compute(arena.allocator(), &nodes, candidates[0..4].*));
}

test "selection rejects malformed schema and incomplete candidate sets" {
    try std.testing.expectError(error.InvalidSchema, trace(std.testing.allocator, "{\"schema\":\"bad\",\"nodes\":[],\"cases\":[]}"));
    try std.testing.expectError(error.InvalidCandidateCount, trace(std.testing.allocator, "{\"schema\":\"zmermaid-bk-selection-v1\",\"nodes\":[],\"cases\":[]}"));
}
