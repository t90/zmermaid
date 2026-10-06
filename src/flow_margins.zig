// SPDX-License-Identifier: EPL-2.0
// Upstream implementation references: Eclipse Layout Kernel 0.10.0.
// https://github.com/eclipse-elk/elk/blob/30035c605c0d45467f673f7b6b263d44dc2632da/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/InnermostNodeMarginCalculator.java
// Upstream notice: Copyright (c) 2010, 2019 Kiel University and others.
// Upstream license: LICENSES/ELK-EPL-2.0.txt; project license: LICENSE.
// Reconstructed/adapted mechanics; no Java runtime implementation is bundled.
// ELK InnermostNodeMarginCalculator: union node labels, ports and port labels.
// Self-loop, comment and edge-end-label margins are separate upstream stages.
const std = @import("std");
pub const Box = struct { x: f64, y: f64, width: f64, height: f64 };
pub const Port = struct { box: Box, labels: []const Box };
pub const Node = struct { box: Box, labels: []const Box, ports: []const Port };
pub const Margin = struct { top: f64, bottom: f64, left: f64, right: f64 };
fn valid(b: Box) bool {
    return std.math.isFinite(b.x) and std.math.isFinite(b.y) and std.math.isFinite(b.width) and std.math.isFinite(b.height) and b.width >= 0 and b.height >= 0;
}
const Bounds = struct {
    x: f64,
    y: f64,
    right: f64,
    bottom: f64,
    fn add(b: *Bounds, box: Box, x: f64, y: f64) !void {
        if (!valid(box)) return error.InvalidBox;
        const px = box.x + x;
        const py = box.y + y;
        if (!std.math.isFinite(px + box.width) or !std.math.isFinite(py + box.height)) return error.InvalidBox;
        b.x = @min(b.x, px);
        b.y = @min(b.y, py);
        b.right = @max(b.right, px + box.width);
        b.bottom = @max(b.bottom, py + box.height);
    }
};
pub fn compute(node: Node) !Margin {
    if (!valid(node.box)) return error.InvalidBox;
    var b: Bounds = .{ .x = node.box.x, .y = node.box.y, .right = node.box.x + node.box.width, .bottom = node.box.y + node.box.height };
    for (node.labels) |label| try b.add(label, node.box.x, node.box.y);
    for (node.ports) |port| {
        try b.add(port.box, node.box.x, node.box.y);
        for (port.labels) |label| try b.add(label, node.box.x + port.box.x, node.box.y + port.box.y);
    }
    const result: Margin = .{ .top = @max(0, node.box.y - b.y), .bottom = @max(0, b.bottom - node.box.y - node.box.height), .left = @max(0, node.box.x - b.x), .right = @max(0, b.right - node.box.x - node.box.width) };
    for ([_]f64{ result.top, result.bottom, result.left, result.right }) |v| if (!std.math.isFinite(v)) return error.InvalidBox;
    return result;
}
pub fn trace(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const Input = struct { schema: []const u8, nodes: []const Node };
    const input = (try std.json.parseFromSlice(Input, arena.allocator(), source, .{})).value;
    if (!std.mem.eql(u8, input.schema, "zmermaid-margins-v1") or input.nodes.len == 0 or input.nodes.len > 4096) return error.InvalidInput;
    const margins = try arena.allocator().alloc(Margin, input.nodes.len);
    for (input.nodes, 0..) |node, i| margins[i] = try compute(node);
    return std.json.Stringify.valueAlloc(allocator, .{ .schema = input.schema, .margins = margins }, .{});
}
test "margins union labels and port-relative labels independently of translation" {
    const labels = [_]Box{.{ .x = -5, .y = -4, .width = 10, .height = 8 }};
    const port_labels = [_]Box{.{ .x = -8, .y = 5, .width = 20, .height = 15 }};
    const ports = [_]Port{.{ .box = .{ .x = 78, .y = 38, .width = 6, .height = 4 }, .labels = &port_labels }};
    var node: Node = .{ .box = .{ .x = 0, .y = 0, .width = 80, .height = 40 }, .labels = &labels, .ports = &ports };
    const expected: Margin = .{ .top = 4, .bottom = 18, .left = 5, .right = 10 };
    try std.testing.expectEqual(expected, try compute(node));
    node.box.x = -100;
    node.box.y = 200;
    try std.testing.expectEqual(expected, try compute(node));
    node.box.width = -1;
    try std.testing.expectError(error.InvalidBox, compute(node));
}
