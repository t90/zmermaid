// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/LabelSideSelector.java
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/LabelAndNodeSizeProcessor.java
// Upstream notice: Copyright (c) 2012, 2017 Kiel University and others.
// Upstream notice: Copyright (c) 2010, 2020 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// ELK 0.10 LabelSideSelector center/end-label preparation on measured proper nodes.
// Measurement is an input contract, not an emulation of browser font metrics.
const std = @import("std");
pub const Side = enum { ABOVE, BELOW, INLINE, UNKNOWN };
pub const Mode = enum { ALWAYS_UP, ALWAYS_DOWN, DIRECTION_UP, DIRECTION_DOWN, SMART_UP, SMART_DOWN };
pub const Port = struct { order: usize, side: []const u8, x: f64, y: f64, anchor_x: f64, anchor_y: f64, width: f64, height: f64, connected: bool = false, end_labels: []const usize = &.{} };
pub const Node = struct { id: usize, rank: usize, position: usize, type: []const u8, width: f64, height: f64, top: f64, bottom: f64, left: f64, right: f64, label_side: ?Side, ports: []Port };
pub const Info = struct { id: usize, @"inline": bool, thickness: f64, source: ?usize = null, target: ?usize = null, rightward: bool };
pub const EndInfo = struct { id: usize, label_side: Side, rightward: bool };
pub const EndLabel = struct { id: usize, label_side: Side };
pub const Input = struct { schema: []const u8, nodes: []const Node, label_info: []const Info, mode: Mode, spacing: f64, end_labels_present: bool = false, end_labels: []const EndInfo = &.{} };
pub const Result = struct { schema: []const u8 = "zmermaid-placement-preparation-v1", nodes: []Node, labels: []EndLabel };

fn isLabel(n: Node) bool {
    return std.mem.eql(u8, n.type, "LABEL");
}
fn isDummy(n: Node) bool {
    return isLabel(n) or std.mem.eql(u8, n.type, "LONG_EDGE");
}
fn apply(nodes: []Node, infos: []const ?Info, id: usize, side: Side, spacing: f64) !void {
    const n = &nodes[id];
    if (!isLabel(n.*)) return;
    const info = infos[id] orelse return error.MissingLabelInfo;
    const effective: Side = if (info.@"inline") .INLINE else side;
    n.label_side = effective;
    if (effective == .BELOW) return;
    const port_y = if (effective == .ABOVE) n.height - @ceil(info.thickness / 2) else @ceil(n.height - spacing - info.thickness) / 2;
    if (effective == .INLINE) n.height -= spacing + info.thickness;
    if (!std.math.isFinite(port_y) or !std.math.isFinite(n.height) or n.height < 0) return error.InvalidLabelSize;
    for (n.ports) |*port| port.y = port_y;
}
fn sameEnds(x: Info, y: Info) bool {
    return x.source == y.source and x.target == y.target;
}
fn run(nodes: []Node, infos: []const ?Info, start: usize, end: usize, top: bool, bottom: bool, default: Side, spacing: f64) !void {
    var count: usize = 0;
    for (nodes[start..end]) |n| if (isLabel(n)) {
        count += 1;
    };
    if (top and (!bottom or end - start > 1) and count == 1 and isLabel(nodes[start])) {
        try apply(nodes, infos, start, .ABOVE, spacing);
    } else if (bottom and (!top or end - start > 1) and count == 1 and isLabel(nodes[end - 1])) {
        try apply(nodes, infos, end - 1, .BELOW, spacing);
    } else if (end - start == 2) {
        try apply(nodes, infos, start, .ABOVE, spacing);
        try apply(nodes, infos, start + 1, .BELOW, spacing);
    } else {
        var group = start;
        while (group < end) {
            var next = group + 1;
            while (next < end and sameEnds(infos[group].?, infos[next].?)) next += 1;
            if (next - group == 2) {
                try apply(nodes, infos, group, .ABOVE, spacing);
                try apply(nodes, infos, group + 1, .BELOW, spacing);
            } else for (group..next) |id| try apply(nodes, infos, id, default, spacing);
            group = next;
        }
    }
}

// Caller owns an arena, including cloned output nodes and ordered ports.
pub fn compute(a: std.mem.Allocator, input: Input) !Result {
    if (!std.mem.eql(u8, input.schema, "zmermaid-preparation-input-v1")) return error.InvalidSchema;
    if (input.end_labels_present and input.end_labels.len == 0) return error.MissingEndLabelMetadata;
    if (input.nodes.len == 0 or input.nodes.len > 4096 or !std.math.isFinite(input.spacing) or input.spacing < 0) return error.InvalidInput;
    const nodes = try a.dupe(Node, input.nodes);
    const labels = try a.alloc(EndLabel, input.end_labels.len);
    for (input.end_labels, 0..) |info, id| {
        if (info.id != id) return error.InvalidLabelInfo;
        labels[id] = .{ .id = id, .label_side = info.label_side };
    }
    const infos = try a.alloc(?Info, nodes.len);
    @memset(infos, null);
    for (input.label_info) |info| {
        if (info.id >= nodes.len or infos[info.id] != null or !std.math.isFinite(info.thickness) or info.thickness < 0) return error.InvalidLabelInfo;
        if ((info.source != null and info.source.? >= nodes.len) or (info.target != null and info.target.? >= nodes.len)) return error.InvalidLabelInfo;
        infos[info.id] = info;
    }
    for (nodes, 0..) |*n, id| {
        if (n.id != id or n.rank > 4095 or n.position > 4095) return error.InvalidNode;
        var position: usize = 0;
        for (nodes[0..id]) |other| if (other.rank == n.rank) {
            position += 1;
        };
        if (n.position != position or (id > 0 and nodes[id - 1].rank > n.rank)) return error.InvalidNode;
        for ([_]f64{ n.width, n.height, n.top, n.bottom, n.left, n.right }) |v| if (!std.math.isFinite(v) or v < 0) return error.InvalidNode;
        if (isDummy(n.*) and infos[id] == null) return error.MissingLabelInfo;
        n.ports = try a.dupe(Port, n.ports);
        for (n.ports, 0..) |p, index| {
            if (p.order != index) return error.InvalidPort;
            for ([_]f64{ p.x, p.y, p.anchor_x, p.anchor_y, p.width, p.height }) |v| if (!std.math.isFinite(v)) return error.InvalidPort;
            if (p.width < 0 or p.height < 0) return error.InvalidPort;
            if (!p.connected and p.end_labels.len > 0) return error.InvalidPort;
            for (p.end_labels) |label| if (label >= labels.len) return error.InvalidLabelInfo;
        }
    }
    const default: Side = switch (input.mode) {
        .ALWAYS_DOWN, .DIRECTION_DOWN, .SMART_DOWN => .BELOW,
        else => .ABOVE,
    };
    switch (input.mode) {
        .SMART_UP, .SMART_DOWN => {
            for (nodes) |node| {
                if (!std.mem.eql(u8, node.type, "NORMAL")) continue;
                var start: usize = 0;
                while (start < node.ports.len) {
                    var end = start + 1;
                    while (end < node.ports.len and std.mem.eql(u8, node.ports[start].side, node.ports[end].side)) end += 1;
                    var count: usize = 0;
                    for (node.ports[start..end]) |port| if (port.connected) {
                        count += 1;
                    };
                    var index: usize = 0;
                    const forward = std.mem.eql(u8, node.ports[start].side, "NORTH") or std.mem.eql(u8, node.ports[start].side, "EAST");
                    for (node.ports[start..end]) |port| {
                        if (!port.connected) continue;
                        const side: Side = if (count == 2) (if ((index == 0) == forward) .ABOVE else .BELOW) else default;
                        for (port.end_labels) |label| labels[label].label_side = side;
                        index += 1;
                    }
                    start = end;
                }
            }
        },
        else => {
            const directional = input.mode == .DIRECTION_UP or input.mode == .DIRECTION_DOWN;
            for (input.end_labels, 0..) |info, id| labels[id].label_side = if (directional and !info.rightward) (if (default == .ABOVE) .BELOW else .ABOVE) else default;
        },
    }
    switch (input.mode) {
        .ALWAYS_UP, .ALWAYS_DOWN, .DIRECTION_UP, .DIRECTION_DOWN => {
            for (nodes, 0..) |n, id| {
                if (!isLabel(n)) continue;
                const directional = input.mode == .DIRECTION_UP or input.mode == .DIRECTION_DOWN;
                const side: Side = if (directional and !infos[id].?.rightward) (if (default == .ABOVE) .BELOW else .ABOVE) else default;
                try apply(nodes, infos, id, side, input.spacing);
            }
        },
        .SMART_UP, .SMART_DOWN => {
            var layer_start: usize = 0;
            while (layer_start < nodes.len) {
                var layer_end = layer_start + 1;
                while (layer_end < nodes.len and nodes[layer_end].rank == nodes[layer_start].rank) layer_end += 1;
                var start = layer_start;
                while (start < layer_end) {
                    if (!isDummy(nodes[start])) {
                        start += 1;
                        continue;
                    }
                    var end = start + 1;
                    while (end < layer_end and isDummy(nodes[end])) end += 1;
                    try run(nodes, infos, start, end, start == layer_start, end == layer_end, default, input.spacing);
                    start = end;
                }
                layer_start = layer_end;
            }
        },
    }
    return .{ .nodes = nodes, .labels = labels };
}

pub fn trace(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const input = (try std.json.parseFromSlice(Input, arena.allocator(), source, .{})).value;
    return std.json.Stringify.valueAlloc(allocator, try compute(arena.allocator(), input), .{});
}

test "preparation preserves measured geometry, adjusts inline size and ports, and frees trace scratch" {
    var ports = [_]Port{.{ .order = 0, .side = "WEST", .x = 0, .y = 1, .anchor_x = 0, .anchor_y = 0, .width = 0, .height = 0 }};
    const node: Node = .{ .id = 0, .rank = 0, .position = 0, .type = "LABEL", .width = 45, .height = 29.5, .top = 2, .bottom = 3, .left = 0, .right = 0, .label_side = null, .ports = &ports };
    const info: Info = .{ .id = 0, .@"inline" = true, .thickness = 3, .source = null, .target = null, .rightward = true };
    const input: Input = .{ .schema = "zmermaid-preparation-input-v1", .nodes = &.{node}, .label_info = &.{info}, .mode = .SMART_UP, .spacing = 5 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try compute(arena.allocator(), input);
    try std.testing.expectEqual(@as(f64, 21.5), result.nodes[0].height);
    try std.testing.expectEqual(@as(f64, 11), result.nodes[0].ports[0].y);
    try std.testing.expectEqual(@as(f64, 2), result.nodes[0].top);
    try std.testing.expectEqual(@as(f64, 29.5), input.nodes[0].height);
    try std.testing.expectEqual(@as(f64, 1), input.nodes[0].ports[0].y);
    const source = try std.json.Stringify.valueAlloc(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(source);
    const output = try trace(std.testing.allocator, source);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "INLINE") != null);
}

test "preparation groups dummy runs by endpoints and honors reversed direction" {
    var ports = [_]Port{.{ .order = 0, .side = "WEST", .x = 0, .y = 0, .anchor_x = 0, .anchor_y = 0, .width = 0, .height = 0 }};
    var nodes: [3]Node = undefined;
    var infos: [3]Info = undefined;
    for (&nodes, &infos, 0..) |*node, *info, id| {
        node.* = .{ .id = id, .rank = 0, .position = id, .type = "LABEL", .width = 45, .height = 29.5, .top = 2, .bottom = 3, .left = 0, .right = 0, .label_side = .UNKNOWN, .ports = &ports };
        info.* = .{ .id = id, .@"inline" = false, .thickness = 1, .source = if (id < 2) 0 else 1, .target = 2, .rightward = id != 1 };
    }
    var input: Input = .{ .schema = "zmermaid-preparation-input-v1", .nodes = &nodes, .label_info = &infos, .mode = .SMART_UP, .spacing = 5 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const smart = try compute(arena.allocator(), input);
    try std.testing.expectEqual(Side.ABOVE, smart.nodes[0].label_side.?);
    try std.testing.expectEqual(Side.BELOW, smart.nodes[1].label_side.?);
    try std.testing.expectEqual(Side.ABOVE, smart.nodes[2].label_side.?);
    input.mode = .DIRECTION_DOWN;
    const directional = try compute(arena.allocator(), input);
    try std.testing.expectEqual(Side.BELOW, directional.nodes[0].label_side.?);
    try std.testing.expectEqual(Side.ABOVE, directional.nodes[1].label_side.?);
    input.end_labels_present = true;
    try std.testing.expectError(error.MissingEndLabelMetadata, compute(arena.allocator(), input));
    input.end_labels_present = false;
    input.label_info = &.{};
    try std.testing.expectError(error.MissingLabelInfo, compute(arena.allocator(), input));
    input.label_info = &infos;
    nodes[0].width = std.math.inf(f64);
    try std.testing.expectError(error.InvalidNode, compute(arena.allocator(), input));
}
