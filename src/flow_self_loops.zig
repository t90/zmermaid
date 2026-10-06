// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/LabelAndNodeSizeProcessor.java
// Upstream notice: Copyright (c) 2010, 2020 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// ELK north-side free-port self loops. Slot/label clearances are reserved
// before BK compaction, not patched into the final SVG.
const std = @import("std");
const measurement = @import("flow_measurement.zig");
pub const Loop = struct { edge: usize, source: f64, target: f64, slot: f64, label_x: f64, label_y: f64, label_width: f64, label_height: f64 };
pub const Plan = struct { loops: []const Loop, top: f64, left: f64, right: f64 };
pub fn plan(a: std.mem.Allocator, input: measurement.Input, node: usize, along_width: f64) !Plan {
    const id = input.nodes[node].id;
    var count: usize = 0;
    for (input.edges) |edge| if (std.mem.eql(u8, edge.source, id) and std.mem.eql(u8, edge.target, id)) { count += 1; };
    const loops = try a.alloc(Loop, count);
    const vertical = std.mem.eql(u8, input.direction, "TB") or std.mem.eql(u8, input.direction, "BT");
    var ordinal: usize = 0;
    var distance: f64 = 20;
    var top: f64 = 0;
    var along_margin: f64 = 0;
    for (input.edges, 0..) |edge, index| {
        if (!std.mem.eql(u8, edge.source, id) or !std.mem.eql(u8, edge.target, id)) continue;
        const width = if (vertical) edge.height else edge.width;
        const height = if (vertical) edge.width else edge.height;
        along_margin = @max(along_margin, (width - along_width) / 2);
        const denominator: f64 = @floatFromInt(count * 2 + 1);
        const source = along_width * @as(f64, @floatFromInt(count - ordinal)) / denominator;
        const target = along_width * @as(f64, @floatFromInt(count + ordinal + 1)) / denominator;
        const label_y = -distance - if (height > 0) height + 4 else @as(f64, 0);
        loops[ordinal] = .{ .edge = index, .source = source, .target = target, .slot = -distance,
            .label_x = (along_width - width) / 2, .label_y = label_y, .label_width = width, .label_height = height };
        top = @max(top, -label_y);
        distance += 20 + if (height > 0) height + 4 else @as(f64, 0);
        ordinal += 1;
    }
    return .{ .loops = loops, .top = top, .left = along_margin, .right = along_margin };
}

test "loop slots reserve cross and along margins before placement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var input: measurement.Input = .{ .schema = "zmermaid-shaped-text-v1", .font_family = "Arial", .padding = 8, .direction = "TB",
        .nodes = &.{.{ .id = "A", .shape = .round, .label = "A", .markdown = false, .font_size = 16, .text_width = 12, .text_height = 17, .lines = &.{"A"} }},
        .edges = &.{
            .{ .index = 0, .source = "A", .target = "A", .label = "retry", .markdown = false, .width = 37, .height = 21 },
            .{ .index = 1, .source = "A", .target = "A", .label = "wait", .markdown = false, .width = 34.0078125, .height = 21 },
        } };
    const vertical = try plan(arena.allocator(), input, 0, 33);
    try std.testing.expectEqual(@as(f64, 119.0078125), vertical.top);
    try std.testing.expectEqual(@as(f64, -81), vertical.loops[1].slot);
    try std.testing.expectApproxEqAbs(@as(f64, 13.2), vertical.loops[0].source, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 26.4), vertical.loops[1].target, 1e-9);
    input.direction = "LR";
    const horizontal = try plan(arena.allocator(), input, 0, 28);
    try std.testing.expectEqual(@as(f64, 90), horizontal.top);
    try std.testing.expectEqual(@as(f64, 4.5), horizontal.left);
    try std.testing.expectEqual(horizontal.left, horizontal.right);
}
