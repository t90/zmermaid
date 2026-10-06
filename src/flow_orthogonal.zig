// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p5edges/orthogonal/OrthogonalRoutingGenerator.java
// Upstream notice: Copyright (c) 2010, 2020 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// ELK's single-edge orthogonal segment dependencies and topological slots.
// Critical cycles need segment splitting; never silently reverse those.
const std = @import("std");
const measured = @import("flow_measured_layout.zig");
const Random = @import("flow_layout.zig").JavaRandom;
const Segment = struct { arc: usize, source: f64, target: f64, slot: usize = 0, source_east: bool = true, target_east: bool = false };
const Dep = struct { from: usize, to: usize, weight: i32, critical: bool, active: bool = true };
pub const Result = struct { along: []f64, lane: []f64, slots: []usize, width: f64 };
fn inside(y: f64, s: Segment) i32 {
    return @intFromBool(y >= @min(s.source, s.target) and y <= @max(s.source, s.target));
}
fn coordinate(s: Segment, endpoint: usize) f64 { return if (endpoint == 0) s.source else s.target; }
fn eastern(s: Segment, endpoint: usize) bool { return if (endpoint == 0) s.source_east else s.target_east; }
fn conflicts(s: Segment, t: Segment, critical: f64) i32 {
    var count: i32 = 0;
    for (0..2) |i| if (!eastern(s, i)) for (0..2) |j| {
        if (!eastern(t, j)) continue;
        const distance = @abs(coordinate(s, i) - coordinate(t, j));
        if (distance < critical) return -1;
        if (distance < 10) count += 1;
    };
    return count;
}
fn crossingCost(s: Segment, t: Segment) i32 {
    var count: i32 = 0;
    for (0..2) |i| {
        if (!eastern(s, i)) count += inside(coordinate(s, i), t);
        if (eastern(t, i)) count += inside(coordinate(t, i), s);
    }
    return count;
}
fn arcSide(graph: measured.Result, id: usize, source: bool) bool {
    if (graph.connections.len == graph.graph.arcs.len) {
        const c = graph.connections[id];
        return std.mem.eql(u8, graph.nodes[if (source) c.from else c.to].ports[if (source) c.source_port else c.target_port].side, "EAST");
    }
    return source;
}
fn update(a: std.mem.Allocator, id: usize, deps: []const Dep, marks: []const i32, ins: []i32, outs: []i32, cin: []i32, cout: []i32, sources: *std.ArrayList(usize), sinks: *std.ArrayList(usize)) !void {
    for (deps) |d| if (d.active and d.weight > 0 and d.from == id and marks[d.to] < 0) {
        ins[d.to] -= d.weight;
        if (d.critical) cin[d.to] -= d.weight;
        if (ins[d.to] <= 0 and outs[d.to] > 0) try sources.append(a, d.to);
    };
    for (deps) |d| if (d.active and d.weight > 0 and d.to == id and marks[d.from] < 0) {
        outs[d.from] -= d.weight;
        if (d.critical) cout[d.from] -= d.weight;
        if (outs[d.from] <= 0 and ins[d.from] > 0) try sinks.append(a, d.from);
    };
}
fn breakCycles(a: std.mem.Allocator, n: usize, deps: []Dep, random: *Random) !void {
    const marks = try a.alloc(i32, n);
    const ins = try a.alloc(i32, n);
    const outs = try a.alloc(i32, n);
    const cin = try a.alloc(i32, n);
    const cout = try a.alloc(i32, n);
    @memset(ins, 0);
    @memset(outs, 0);
    @memset(cin, 0);
    @memset(cout, 0);
    for (deps) |d| {
        ins[d.to] += d.weight;
        outs[d.from] += d.weight;
        if (d.critical) {
            cin[d.to] += d.weight;
            cout[d.from] += d.weight;
        }
    }
    var sources: std.ArrayList(usize) = .empty;
    var sinks: std.ArrayList(usize) = .empty;
    for (0..n) |id| {
        marks[id] = -@as(i32, @intCast(id)) - 1;
        if (outs[id] == 0) try sinks.append(a, id) else if (ins[id] == 0) try sources.append(a, id);
    }
    var sa: usize = 0;
    var ta: usize = 0;
    var remaining = n;
    var sink_mark = @as(i32, @intCast(n)) - 1;
    var source_mark = @as(i32, @intCast(n)) + 1;
    while (remaining > 0) {
        while (ta < sinks.items.len) : (ta += 1) {
            const id = sinks.items[ta];
            if (marks[id] >= 0) continue;
            marks[id] = sink_mark;
            sink_mark -= 1;
            remaining -= 1;
            try update(a, id, deps, marks, ins, outs, cin, cout, &sources, &sinks);
        }
        while (sa < sources.items.len) : (sa += 1) {
            const id = sources.items[sa];
            if (marks[id] >= 0) continue;
            marks[id] = source_mark;
            source_mark += 1;
            remaining -= 1;
            try update(a, id, deps, marks, ins, outs, cin, cout, &sources, &sinks);
        }
        var choices: std.ArrayList(usize) = .empty;
        var maximum: i32 = std.math.minInt(i32);
        var scan = n;
        while (scan > 0) {
            scan -= 1;
            if (marks[scan] >= 0) continue;
            if (cout[scan] > 0 and cin[scan] <= 0) {
                choices.clearRetainingCapacity();
                try choices.append(a, scan);
                break;
            }
            const flow = outs[scan] - ins[scan];
            if (flow >= maximum) {
                if (flow > maximum) {
                    maximum = flow;
                    choices.clearRetainingCapacity();
                }
                try choices.append(a, scan);
            }
        }
        if (choices.items.len > 0) {
            const id = choices.items[random.nextInt(choices.items.len)];
            marks[id] = source_mark;
            source_mark += 1;
            remaining -= 1;
            try update(a, id, deps, marks, ins, outs, cin, cout, &sources, &sinks);
        }
    }
    for (marks) |*m| if (m.* < @as(i32, @intCast(n))) {
        m.* += @as(i32, @intCast(n)) + 1;
    };
    for (deps) |*d| if (marks[d.from] > marks[d.to]) {
        if (d.critical) return error.CriticalSegmentSplitRequired;
        if (d.weight == 0) d.active = false else {
            const from = d.from;
            d.from = d.to;
            d.to = from;
        }
    };
}
pub fn compute(a: std.mem.Allocator, graph: measured.Result, random_state: u64) !Result {
    return computeSpacing(a, graph, random_state, 40, 20);
}
pub fn computeSpacing(a: std.mem.Allocator, graph: measured.Result, random_state: u64, node_spacing: f64, edge_spacing: f64) !Result {
    // Prepared port graphs may now retain inverted-port in-layer arcs. This
    // router still handles inter-layer channels only: fail explicitly rather
    // than treating a same-layer arc as if it crossed the next layer gap.
    for (graph.graph.arcs) |arc| {
        if (arc.from >= graph.graph.nodes.len or arc.to >= graph.graph.nodes.len) return error.InvalidProperGraph;
        if (graph.graph.nodes[arc.to].rank != graph.graph.nodes[arc.from].rank + 1 and graph.connections.len == 0) return error.InLayerRoutingRequired;
    }
    const along = try a.alloc(f64, graph.nodes.len);
    const lanes = try a.alloc(f64, graph.graph.arcs.len);
    @memset(lanes, 0);
    var last: usize = 0;
    for (graph.nodes) |n| last = @max(last, n.rank);
    const depths = try a.alloc(f64, last + 1);
    @memset(depths, 0);
    const offsets = try a.alloc(f64, last + 1);
    @memset(offsets, 0);
    const slots = try a.alloc(usize, last + 2);
    @memset(slots, 0);
    for (graph.nodes) |n| depths[n.rank] = @max(depths[n.rank], n.width + n.left + n.right);
    var random = Random.fromState(random_state);
    var xpos: f64 = 0;
    for (0..last + 2) |gap| {
        if (gap > 0) { offsets[gap - 1] = xpos; xpos += depths[gap - 1]; }
        var segments: std.ArrayList(Segment) = .empty;
        // EAST output ports of the left layer, then WEST outputs of the
        // right layer. The latter include the in-layer return connectors.
        for ([_]bool{ true, false }) |east| for (graph.graph.nodes, 0..) |n, id| {
            if ((east and (gap == 0 or n.rank + 1 != gap)) or (!east and n.rank != gap)) continue;
            for (n.outgoing) |arc| {
                if (arcSide(graph, arc, true) != east) continue;
                const target_east = arcSide(graph, arc, false);
                const target_rank = graph.graph.nodes[graph.graph.arcs[arc].to].rank;
                if ((target_east and (gap == 0 or target_rank + 1 != gap)) or (!target_east and target_rank != gap)) return error.InvalidRoutingChannel;
                try segments.append(a, .{ .arc = arc, .source = graph.cross[id] + graph.graph.arcs[arc].source_y, .target = graph.cross[graph.graph.arcs[arc].to] + graph.graph.arcs[arc].target_y, .source_east = east, .target_east = target_east });
            }
        };
        var minimum = std.math.floatMax(f64);
        for (segments.items, 0..) |s, i| for (segments.items[i + 1 ..]) |t| {
            for (0..2) |u| for (0..2) |v| if (eastern(s, u) == eastern(t, v) and coordinate(s, u) != coordinate(t, v)) {
                minimum = @min(minimum, @abs(coordinate(s, u) - coordinate(t, v)));
            };
        };
        const critical = minimum * 0.2;
        var deps: std.ArrayList(Dep) = .empty;
        for (segments.items, 0..) |s, i| for (segments.items[i + 1 ..], i + 1..) |t, j| {
            if (@abs(s.source - s.target) < 1e-3 or @abs(t.source - t.target) < 1e-3) continue;
            const conflicts1 = conflicts(s, t, critical);
            const conflicts2 = conflicts(t, s, critical);
            const c1 = conflicts1 < 0;
            const c2 = conflicts2 < 0;
            if (c1 or c2) {
                if (c1) try deps.append(a, .{ .from = j, .to = i, .weight = 1, .critical = true });
                if (c2) try deps.append(a, .{ .from = i, .to = j, .weight = 1, .critical = true });
            } else {
                const cost1 = conflicts1 + 16 * crossingCost(s, t);
                const cost2 = conflicts2 + 16 * crossingCost(t, s);
                if (cost1 < cost2) try deps.append(a, .{ .from = i, .to = j, .weight = cost2 - cost1, .critical = false }) else if (cost2 < cost1) try deps.append(a, .{ .from = j, .to = i, .weight = cost1 - cost2, .critical = false }) else if (cost1 > 0) {
                    try deps.append(a, .{ .from = i, .to = j, .weight = 0, .critical = false });
                    try deps.append(a, .{ .from = j, .to = i, .weight = 0, .critical = false });
                }
            }
        };
        try breakCycles(a, segments.items.len, deps.items, &random);
        const incoming = try a.alloc(usize, segments.items.len);
        @memset(incoming, 0);
        for (deps.items) |d| if (d.active) {
            incoming[d.to] += 1;
        };
        var queue: std.ArrayList(usize) = .empty;
        for (incoming, 0..) |count, id| if (count == 0) {
            try queue.append(a, id);
        };
        var at: usize = 0;
        while (at < queue.items.len) : (at += 1) {
            const id = queue.items[at];
            for (deps.items) |d| if (d.active and d.from == id) {
                segments.items[d.to].slot = @max(segments.items[d.to].slot, segments.items[id].slot + 1);
                incoming[d.to] -= 1;
                if (incoming[d.to] == 0) try queue.append(a, d.to);
            };
        }
        if (at != segments.items.len) return error.InvalidDependencies;
        var max_slot: usize = 0;
        for (segments.items) |s| max_slot = @max(max_slot, s.slot);
        const outs = try a.alloc(usize, segments.items.len); @memset(outs, 0);
        for (deps.items) |d| if (d.active) { outs[d.from] += 1; };
        queue.clearRetainingCapacity();
        for (segments.items, 0..) |*s, id| if (!s.source_east and !s.target_east and outs[id] == 0) { s.slot = max_slot; try queue.append(a, id); };
        at = 0;
        while (at < queue.items.len) : (at += 1) {
            const id = queue.items[at];
            for (deps.items) |d| if (d.active and d.to == id and !segments.items[d.from].source_east and !segments.items[d.from].target_east) {
                segments.items[d.from].slot = @min(segments.items[d.from].slot, segments.items[id].slot -| 1);
                outs[d.from] -= 1;
                if (outs[d.from] == 0) try queue.append(a, d.from);
            };
        }
        for (segments.items) |s| if (@abs(s.source - s.target) >= 1e-3) { slots[gap] = @max(slots[gap], s.slot + 1); };
        for (segments.items) |s| lanes[s.arc] = xpos + (if (gap > 0) edge_spacing else @as(f64, 0)) + @as(f64, @floatFromInt(s.slot)) * edge_spacing;
        const outer = gap == 0 or gap == last + 1;
        var left_external = true; var right_external = true;
        for (graph.nodes) |node| {
            if (gap > 0 and node.rank + 1 == gap and !std.mem.eql(u8, node.type, "EXTERNAL_PORT")) left_external = false;
            if (node.rank == gap and !std.mem.eql(u8, node.type, "EXTERNAL_PORT")) right_external = false;
        }
        const routing_width = if (slots[gap] > 0) @as(f64, @floatFromInt(slots[gap] - 1)) * edge_spacing + (if (outer) edge_spacing else 2 * edge_spacing) else @as(f64, 0);
        xpos += if (outer or left_external or right_external) routing_width else @max(node_spacing, routing_width);
        xpos = @as(f32, @floatCast(xpos));
    }
    for (graph.nodes, 0..) |n, id| {
        const ins = graph.graph.nodes[id].incoming.len;
        const outs = graph.graph.nodes[id].outgoing.len;
        const ratio = if (ins + outs == 0) @as(f64, 0.5) else @as(f64, @floatFromInt(outs)) / @as(f64, @floatFromInt(ins + outs));
        // LGraphUtil.placeNodesHorizontally aligns peers against the layer's
        // largest margins, then clamps to each node's own margins.
        var max_left: f64 = 0; var max_right: f64 = 0;
        for (graph.nodes) |peer| if (peer.rank == n.rank) { max_left = @max(max_left, peer.left); max_right = @max(max_right, peer.right); };
        var x = (depths[n.rank] - n.width) * ratio;
        if (ratio > 0.5) x -= max_right * 2 * (ratio - 0.5) else if (ratio < 0.5) x += max_left * 2 * (0.5 - ratio);
        x = @max(x, n.left);
        x = @min(x, depths[n.rank] - n.right - n.width);
        along[id] = offsets[n.rank] + x;
    }
    return .{ .along = along, .lane = lanes, .slots = slots, .width = xpos };
}
