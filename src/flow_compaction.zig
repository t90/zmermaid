// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/bk/BKCompactor.java
// Upstream notice: Copyright (c) 2015 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// Port-aware BK block/class compaction and SimpleThresholdStrategy mechanics.
// Reference: ELK 0.10 BKCompactor, ThresholdStrategy and BKAlignedLayout.
const std = @import("std");
const bk = @import("flow_bk.zig");
const V = std.json.Value;
const Alignment = struct { root: []const usize, @"align": []const usize, inner_shift: []const f64, block_size: []const ?f64, only_dummies: []const bool };
const Case = struct { left: bool, up: bool, mode: []const u8, alignment: Alignment };
pub const Spacing = struct { before: usize, after: usize, value: f64 };
const Input = struct { schema: []const u8, graph: bk.Input, adjacent_spacing: []const Spacing, class_spacing: f64, cases: []const Case };
const ClassEdge = struct { target: usize, separation: f64 };
const Deferred = struct { free: usize, is_root: bool, edge: ?usize = null, has_edges: bool = false };

fn value(a: std.mem.Allocator, x: anytype) !V {
    return (try std.json.parseFromSlice(V, a, try std.json.Stringify.valueAlloc(a, x, .{}), .{})).value;
}
fn number(x: ?f64) V {
    const n = x orelse return .null;
    return if (std.math.isInf(n)) .{ .string = if (n > 0) "+Infinity" else "-Infinity" } else .{ .float = n };
}
fn numbers(a: std.mem.Allocator, xs: []const ?f64) !V {
    var out: std.ArrayList(V) = .empty;
    for (xs) |x| try out.append(a, number(x));
    return .{ .array = .{ .items = out.items, .capacity = out.capacity, .allocator = a } };
}
const Engine = struct {
    a: std.mem.Allocator,
    input: Input,
    case: Case,
    y: []?f64,
    sink: []usize,
    shift: []?f64,
    straight: []bool,
    finished: []bool,
    class_present: []bool,
    class_shift: []?f64,
    class_edges: []std.ArrayList(ClassEdge),
    queue: std.ArrayList(Deferred) = .empty,
    events: std.ArrayList(V) = .empty,
    capture: bool = true,
    fn invalid(s: *const Engine) f64 {
        return if (s.case.up) std.math.inf(f64) else -std.math.inf(f64);
    }
    fn neighbor(s: *const Engine, id: usize, below: bool) ?usize {
        const node = s.input.graph.nodes[id];
        if (!below and node.position == 0) return null;
        const position = if (below) node.position + 1 else node.position - 1;
        for (s.input.graph.nodes, 0..) |other, i| if (other.rank == node.rank and other.position == position) {
            return i;
        };
        return null;
    }
    fn spacing(s: *const Engine, x: usize, y: usize) !f64 {
        for (s.input.adjacent_spacing) |gap| if ((gap.before == x and gap.after == y) or (gap.before == y and gap.after == x)) {
            return gap.value;
        };
        return error.MissingSpacing;
    }
    fn snapshot(s: *Engine) !V {
        const pos = try s.a.alloc(?f64, s.y.len);
        for (s.y, 0..) |y, i| pos[i] = if (y) |n| n + s.case.alignment.inner_shift[i] else null;
        return value(s.a, .{ .block_y = try numbers(s.a, s.y), .node_y = try numbers(s.a, pos), .sink = s.sink, .shift = try numbers(s.a, s.shift), .straightened = s.straight });
    }
    fn classes(s: *Engine) !V {
        var out: std.ArrayList(V) = .empty;
        for (s.class_present, 0..) |present, id| {
            if (!present) continue;
            const edges = try s.a.dupe(ClassEdge, s.class_edges[id].items);
            const Less = struct {
                fn less(_: void, x: ClassEdge, y: ClassEdge) bool {
                    return x.target < y.target;
                }
            };
            std.mem.sort(ClassEdge, edges, {}, Less.less);
            try out.append(s.a, try value(s.a, .{ .sink = id, .shift = number(s.class_shift[id]), .outgoing = edges }));
        }
        return .{ .array = .{ .items = out.items, .capacity = out.capacity, .allocator = s.a } };
    }
    fn pick(s: *Engine, pp: Deferred) Deferred {
        var result = pp;
        result.has_edges = false;
        result.edge = null;
        const node = s.input.graph.nodes[pp.free];
        const incoming = if (pp.is_root) !s.case.left else s.case.left;
        const incident = if (incoming) node.incoming else node.outgoing;
        for (incident) |id| {
            const e = s.input.graph.arcs[id];
            const root = s.case.alignment.root[pp.free];
            if (!s.case.alignment.only_dummies[root] and s.input.graph.nodes[e.from].rank == s.input.graph.nodes[e.to].rank) continue;
            // Preserve the upstream free-block-only straightening guard.
            if (s.straight[root]) continue;
            result.has_edges = true;
            const other = if (e.from == pp.free) e.to else e.from;
            if (s.finished[s.case.alignment.root[other]]) {
                result.edge = id;
                return result;
            }
        }
        return result;
    }
    fn bound(s: *Engine, id: usize, is_root: bool) !f64 {
        const pp = s.pick(.{ .free = id, .is_root = is_root });
        if (pp.edge == null and pp.has_edges) {
            try s.queue.append(s.a, pp);
            return s.invalid();
        }
        const edge = s.input.graph.arcs[pp.edge orelse return s.invalid()];
        const root_is_target = if (is_root) !s.case.left else s.case.left;
        const free = if (root_is_target) edge.to else edge.from;
        const other = if (root_is_target) edge.from else edge.to;
        const free_port = if (root_is_target) edge.target_y else edge.source_y;
        const other_port = if (root_is_target) edge.source_y else edge.target_y;
        const limit = s.y[s.case.alignment.root[other]].? + s.case.alignment.inner_shift[other] + other_port - s.case.alignment.inner_shift[free] - free_port;
        s.straight[s.case.alignment.root[edge.from]] = true;
        s.straight[s.case.alignment.root[edge.to]] = true;
        return limit;
    }
    fn threshold(s: *Engine, old: f64, root: usize, current: usize) !f64 {
        var t = s.invalid();
        if (std.mem.eql(u8, s.case.mode, "IMPROVE_STRAIGHTNESS")) {
            t = old;
            if (root == current) t = try s.bound(current, true);
            if (std.math.isInf(t) and s.case.alignment.@"align"[current] == root) t = try s.bound(current, false);
        }
        if (s.capture) try s.events.append(s.a, try value(s.a, .{ .kind = "threshold", .root = root, .current = current, .old = number(old), .value = number(t) }));
        return t;
    }
    fn place(s: *Engine, root: usize, depth: usize) anyerror!void {
        if (depth > s.y.len) return error.InvalidBlocks;
        if (s.y[root] != null) return;
        s.y[root] = 0;
        var initial = true;
        var current = root;
        var t = s.invalid();
        while (true) {
            if (s.neighbor(current, s.case.up)) |adjacent| {
                const nr = s.case.alignment.root[adjacent];
                try s.place(nr, depth + 1);
                t = try s.threshold(t, root, current);
                if (s.sink[root] == root) s.sink[root] = s.sink[nr];
                const nodes = s.input.graph.nodes;
                const inside = s.case.alignment.inner_shift;
                if (s.sink[root] == s.sink[nr]) {
                    const gap = try s.spacing(current, adjacent);
                    const pos = if (s.case.up)
                        s.y[nr].? + inside[adjacent] - nodes[adjacent].top - gap - nodes[current].bottom - nodes[current].extent - inside[current]
                    else
                        s.y[nr].? + inside[adjacent] + nodes[adjacent].extent + nodes[adjacent].bottom + gap + nodes[current].top - inside[current];
                    const bounded = if (s.case.up) @min(pos, t) else @max(pos, t);
                    s.y[root] = if (initial) bounded else if (s.case.up) @min(s.y[root].?, bounded) else @max(s.y[root].?, bounded);
                    initial = false;
                } else {
                    const from = s.sink[root];
                    const to = s.sink[nr];
                    s.class_present[from] = true;
                    s.class_present[to] = true;
                    const separation = if (s.case.up)
                        s.y[root].? + inside[current] + nodes[current].extent + nodes[current].bottom + s.input.class_spacing - (s.y[nr].? + inside[adjacent] - nodes[adjacent].top)
                    else
                        s.y[root].? + inside[current] - nodes[current].top - s.y[nr].? - inside[adjacent] - nodes[adjacent].extent - nodes[adjacent].bottom - s.input.class_spacing;
                    try s.class_edges[from].append(s.a, .{ .target = to, .separation = separation });
                }
            } else t = try s.threshold(t, root, current);
            current = s.case.alignment.@"align"[current];
            if (current == root) break;
        }
        s.finished[root] = true;
        if (s.capture) try s.events.append(s.a, try value(s.a, .{ .kind = "block_finished", .root = root, .state = try s.snapshot() }));
    }
    fn moveDeferred(s: *Engine, pp: Deferred) !bool {
        const edge = s.input.graph.arcs[pp.edge orelse return false];
        const free = pp.free;
        const other = if (edge.from == free) edge.to else edge.from;
        const free_port = if (edge.from == free) edge.source_y else edge.target_y;
        const other_port = if (edge.from == free) edge.target_y else edge.source_y;
        const roots = s.case.alignment.root;
        const inside = s.case.alignment.inner_shift;
        const delta = s.y[free].? + inside[free] + free_port - s.y[other].? - inside[other] - other_port;
        if (delta == 0 or @abs(delta) >= std.math.floatMax(f64)) return false;
        const above = delta > 0;
        var available = @abs(delta);
        var current = free;
        while (true) {
            current = s.case.alignment.@"align"[current];
            if (s.neighbor(current, !above)) |adjacent| {
                const node = s.input.graph.nodes[current];
                const adj = s.input.graph.nodes[adjacent];
                const gap = try s.spacing(current, adjacent);
                const space = if (above)
                    s.y[roots[current]].? + inside[current] - node.top - (s.y[roots[adjacent]].? + inside[adjacent] + adj.extent + adj.bottom + gap)
                else
                    s.y[roots[adjacent]].? + inside[adjacent] - adj.top - (s.y[roots[current]].? + inside[current] + node.extent + node.bottom + gap);
                available = @min(available, space);
            }
            if (current == free) break;
        }
        current = free;
        while (true) {
            s.y[current] = s.y[current].? + if (above) -available else available;
            current = s.case.alignment.@"align"[current];
            if (current == free) break;
        }
        return available > 0;
    }
    fn run(s: *Engine) !void {
        const nodes = s.input.graph.nodes;
        var highest: usize = 0;
        for (nodes) |node| highest = @max(highest, node.rank);
        for (0..highest + 1) |step| {
            const rank = if (s.case.left) highest - step else step;
            if (s.case.up) {
                var id = nodes.len;
                while (id > 0) {
                    id -= 1;
                    if (nodes[id].rank == rank and s.case.alignment.root[id] == id) try s.place(id, 0);
                }
            } else {
                for (nodes, 0..) |node, id| {
                    if (node.rank == rank and s.case.alignment.root[id] == id) try s.place(id, 0);
                }
            }
        }
        const degree = try s.a.alloc(usize, nodes.len);
        @memset(degree, 0);
        for (s.class_edges) |edges| for (edges.items) |edge| {
            degree[edge.target] += 1;
        };
        var sinks: std.ArrayList(usize) = .empty;
        for (s.class_present, 0..) |present, id| if (present and degree[id] == 0) {
            try sinks.append(s.a, id);
        };
        var at: usize = 0;
        while (at < sinks.items.len) : (at += 1) {
            const id = sinks.items[at];
            if (s.class_shift[id] == null) s.class_shift[id] = 0;
            for (s.class_edges[id].items) |edge| {
                const proposed = s.class_shift[id].? + edge.separation;
                s.class_shift[edge.target] = if (s.class_shift[edge.target]) |old| (if (s.case.up) @max(old, proposed) else @min(old, proposed)) else proposed;
                degree[edge.target] -= 1;
                if (degree[edge.target] == 0) try sinks.append(s.a, edge.target);
            }
        }
        for (s.class_present, 0..) |present, id| if (present) {
            s.shift[id] = s.class_shift[id] orelse return error.InvalidClasses;
        };
        for (0..highest + 1) |step| {
            const rank = if (s.case.left) highest - step else step;
            for (nodes, 0..) |node, id| {
                if (node.rank != rank) continue;
                const root = s.case.alignment.root[id];
                s.y[id] = s.y[root];
                if (root == id and std.math.isFinite(s.shift[s.sink[id]].?)) s.y[id] = s.y[id].? + s.shift[s.sink[id]].?;
            }
        }
        if (s.capture) try s.events.append(s.a, try value(s.a, .{ .kind = "before_straightening", .state = try s.snapshot(), .classes = try s.classes() }));
        if (std.mem.eql(u8, s.case.mode, "IMPROVE_STRAIGHTNESS")) {
            var stack: std.ArrayList(Deferred) = .empty;
            for (s.queue.items) |pp| {
                const picked = s.pick(pp);
                if (picked.edge != null and !(try s.moveDeferred(picked))) try stack.append(s.a, picked);
            }
            while (stack.pop()) |pp| {
                _ = try s.moveDeferred(pp);
            }
        }
        if (s.capture) try s.events.append(s.a, try value(s.a, .{ .kind = "after_straightening", .state = try s.snapshot() }));
    }
};

/// Production compaction on the same verified engine, without allocating
/// diagnostic JSON snapshots at each block. Caller supplies an arena.
pub fn compact(a: std.mem.Allocator, graph: bk.Input, gaps: []const Spacing, class_spacing: f64, alignment: bk.Layout, straighten: bool) ![]f64 {
    const n = graph.nodes.len;
    if (n == 0 or !std.math.isFinite(class_spacing) or class_spacing < 0) return error.InvalidSpacing;
    const candidate: Case = .{ .left = alignment.left, .up = alignment.up, .mode = if (straighten) "IMPROVE_STRAIGHTNESS" else "NONE", .alignment = .{ .root = alignment.root, .@"align" = alignment.@"align", .inner_shift = alignment.inner_shift, .block_size = alignment.block_size, .only_dummies = alignment.only_dummies } };
    var engine: Engine = .{ .a = a, .input = .{ .schema = "zmermaid-bk-compaction-v1", .graph = graph, .adjacent_spacing = gaps, .class_spacing = class_spacing, .cases = &.{} }, .case = candidate, .capture = false, .y = try a.alloc(?f64, n), .sink = try a.alloc(usize, n), .shift = try a.alloc(?f64, n), .straight = try a.alloc(bool, n), .finished = try a.alloc(bool, n), .class_present = try a.alloc(bool, n), .class_shift = try a.alloc(?f64, n), .class_edges = try a.alloc(std.ArrayList(ClassEdge), n) };
    @memset(engine.y, null);
    @memset(engine.shift, if (candidate.up) -std.math.inf(f64) else std.math.inf(f64));
    @memset(engine.straight, false);
    @memset(engine.finished, false);
    @memset(engine.class_present, false);
    @memset(engine.class_shift, null);
    for (0..n) |id| {
        engine.sink[id] = id;
        engine.class_edges[id] = .empty;
    }
    try engine.run();
    const result = try a.alloc(f64, n);
    for (engine.y, 0..) |y, id| result[id] = y orelse return error.InvalidBlocks;
    return result;
}

pub fn trace(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = (try std.json.parseFromSlice(Input, a, source, .{})).value;
    if (!std.mem.eql(u8, input.schema, "zmermaid-bk-compaction-v1")) return error.InvalidSchema;
    if (!std.math.isFinite(input.class_spacing) or input.class_spacing < 0 or input.cases.len > 8) return error.InvalidSpacing;
    // Validate graph topology with the independently verified BK preparation.
    _ = try bk.compute(a, input.graph);
    const n = input.graph.nodes.len;
    var candidates: std.ArrayList(V) = .empty;
    for (input.adjacent_spacing, 0..) |gap, index| {
        if (gap.before >= n or gap.after >= n or !std.math.isFinite(gap.value) or gap.value < 0) return error.InvalidSpacing;
        const before = input.graph.nodes[gap.before];
        const after = input.graph.nodes[gap.after];
        if (before.rank != after.rank or before.position + 1 != after.position) return error.InvalidSpacing;
        for (input.adjacent_spacing[0..index]) |other| if (other.before == gap.before and other.after == gap.after) {
            return error.InvalidSpacing;
        };
    }
    for (input.cases) |candidate| {
        if (!std.mem.eql(u8, candidate.mode, "NONE") and !std.mem.eql(u8, candidate.mode, "IMPROVE_STRAIGHTNESS")) return error.InvalidMode;
        const b = candidate.alignment;
        if (b.root.len != n or b.@"align".len != n or b.inner_shift.len != n or b.block_size.len != n or b.only_dummies.len != n) return error.InvalidBlocks;
        for (b.root, b.@"align") |root, next| if (root >= n or next >= n) {
            return error.InvalidBlocks;
        };
        for (0..n) |id| {
            const root = b.root[id];
            if (b.root[root] != root or !std.math.isFinite(b.inner_shift[id]) or b.block_size[root] == null or
                !std.math.isFinite(b.block_size[root].?) or b.block_size[root].? < 0) return error.InvalidBlocks;
            var current = id;
            var steps: usize = 0;
            var contains_root = false;
            while (true) {
                if (b.root[current] != root) return error.InvalidBlocks;
                contains_root = contains_root or current == root;
                current = b.@"align"[current];
                steps += 1;
                if (steps > n) return error.InvalidBlocks;
                if (current == id) break;
            }
            if (!contains_root) return error.InvalidBlocks;
        }
        var engine: Engine = .{ .a = a, .input = input, .case = candidate, .y = try a.alloc(?f64, n), .sink = try a.alloc(usize, n), .shift = try a.alloc(?f64, n), .straight = try a.alloc(bool, n), .finished = try a.alloc(bool, n), .class_present = try a.alloc(bool, n), .class_shift = try a.alloc(?f64, n), .class_edges = try a.alloc(std.ArrayList(ClassEdge), n) };
        @memset(engine.y, null);
        @memset(engine.shift, if (candidate.up) -std.math.inf(f64) else std.math.inf(f64));
        @memset(engine.straight, false);
        @memset(engine.finished, false);
        @memset(engine.class_present, false);
        @memset(engine.class_shift, null);
        for (0..n) |id| {
            engine.sink[id] = id;
            engine.class_edges[id] = .empty;
        }
        try engine.run();
        try candidates.append(a, try value(a, .{ .left = candidate.left, .up = candidate.up, .mode = candidate.mode, .alignment = b, .events = engine.events.items, .final = try engine.snapshot(), .classes = try engine.classes() }));
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .schema = input.schema, .adjacent_spacing = input.adjacent_spacing, .class_spacing = input.class_spacing, .cases = candidates.items }, .{});
}

test "compaction trace preserves a straight block and releases diagnostic allocations" {
    const graph: bk.Input = .{ .nodes = &.{
        .{ .rank = 0, .position = 0, .extent = 20, .top = 0, .bottom = 0, .long_edge = false, .incoming = &.{}, .outgoing = &.{0}, .connected = &.{0} },
        .{ .rank = 1, .position = 0, .extent = 20, .top = 0, .bottom = 0, .long_edge = false, .incoming = &.{0}, .outgoing = &.{}, .connected = &.{0} },
    }, .arcs = &.{.{ .from = 0, .to = 1, .source_y = 10, .target_y = 10, .priority = 0 }} };
    const input: Input = .{ .schema = "zmermaid-bk-compaction-v1", .graph = graph, .adjacent_spacing = &.{}, .class_spacing = 40, .cases = &.{.{ .left = false, .up = false, .mode = "NONE", .alignment = .{ .root = &.{ 0, 0 }, .@"align" = &.{ 1, 0 }, .inner_shift = &.{ 0, 0 }, .block_size = &.{ 20, null }, .only_dummies = &.{ false, true } } }} };
    const source = try std.json.Stringify.valueAlloc(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(source);
    const output = try trace(std.testing.allocator, source);
    defer std.testing.allocator.free(output);
    const parsed = try std.json.parseFromSlice(V, std.testing.allocator, output, .{});
    defer parsed.deinit();
    const final = parsed.value.object.get("cases").?.array.items[0].object.get("final").?;
    for (final.object.get("node_y").?.array.items) |y| {
        const coordinate: f64 = switch (y) {
            .float => |x| x,
            .integer => |x| @floatFromInt(x),
            else => return error.InvalidCoordinate,
        };
        try std.testing.expectEqual(@as(f64, 0), coordinate);
    }
}

test "compaction rejects malformed schema" {
    try std.testing.expectError(error.InvalidSchema, trace(std.testing.allocator, "{\"schema\":\"bad\",\"graph\":{\"nodes\":[],\"arcs\":[]},\"adjacent_spacing\":[],\"class_spacing\":40,\"cases\":[]}"));
}
