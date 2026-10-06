// RoughJS 4.6.6 ellipse measurement reference: https://www.npmjs.com/package/roughjs/v/4.6.6
// Upstream copyright: (c) 2019 Preet Shihn. MIT notice: LICENSES/RoughJS-MIT.txt.
// SPDX-License-Identifier: EPL-2.0
// Mermaid 11.16.1 implementation/behavior references:
// https://github.com/mermaid-js/mermaid/blob/7ecca0cd7f1658ef74f4e7e91f925724ef403bbf/packages/mermaid/src/rendering-util/rendering-elements/shapes/
// Upstream copyright: (c) 2014 - 2022 Knut Sveidqvist.
// Upstream MIT notice: LICENSES/Mermaid-MIT.txt; project license: LICENSE.
// Mermaid 11.16.1 classic SVG shape sizing, with host-shaped text bounds.
// Browser/DirectWrite font shaping belongs to the host, not a glyph-count
// approximation. All geometry remains f64 until the final renderer boundary.
// See THIRD-PARTY-NOTICES.txt for Mermaid and RoughJS attribution.
const std = @import("std");
const Shape = @import("flow_shapes.zig").Shape;
pub const Size = struct { width: f64, height: f64 };
pub fn hasLabel(shape: Shape) bool {
    return switch (shape) {
        .small_circle, .framed_circle, .junction, .fork, .hourglass, .bolt, .crossed_circle => false,
        else => true,
    };
}
fn finite(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 1e7;
}
fn sineMaximum(cycles: f64) f64 {
    var maximum: f64 = 0;
    for (0..51) |i| maximum = @max(maximum, @sin(2 * std.math.pi * cycles * @as(f64, @floatFromInt(i)) / 50));
    return maximum;
}
fn arcMaximum(samples: f64) f64 {
    // Half-circle sampled with both endpoints; even counts miss its apex.
    return @cos(std.math.pi / (2 * (samples - 1)));
}
const Range = struct {
    low: f64 = std.math.inf(f64),
    high: f64 = -std.math.inf(f64),
    fn add(self: *Range, value: f64) void {
        self.low = @min(self.low, value);
        self.high = @max(self.high, value);
    }
    fn cubic(self: *Range, p0: f64, p1: f64, p2: f64, p3: f64) void {
        self.add(p0);
        self.add(p3);
        const a = -p0 + 3 * p1 - 3 * p2 + p3;
        const b = 2 * (p0 - 2 * p1 + p2);
        const c = p1 - p0;
        var roots: [2]f64 = .{ -1, -1 };
        if (@abs(a) < 1e-12) {
            if (@abs(b) > 1e-12) roots[0] = -c / b;
        } else {
            const discriminant = b * b - 4 * a * c;
            if (discriminant >= 0) roots = .{ (-b + @sqrt(discriminant)) / (2 * a), (-b - @sqrt(discriminant)) / (2 * a) };
        }
        for (roots) |t| if (t > 0 and t < 1) {
            const u = 1 - t;
            self.add(u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3);
        };
    }
};
// RoughJS 4.6.6 renderer.generateEllipseParams/_computeEllipsePoints/_curve,
// roughness=0, curveStepCount=9, curveTightness=0. Bounds include the cubic
// extrema rather than assuming the nominal diameter is the rendered box.
fn roughCircle(diameter: f64) Size {
    const radius = diameter / 2;
    const psq = @sqrt(2 * std.math.pi * radius);
    const steps = @ceil(@max(9, 9 / @sqrt(@as(f64, 200)) * psq));
    const increment = 2 * std.math.pi / steps / 4;
    var points: [256][2]f64 = undefined;
    points[0] = .{ radius * @cos(-increment), radius * @sin(-increment) };
    var count: usize = 1;
    var angle: f64 = 0;
    while (angle <= 2 * std.math.pi and count < points.len - 2) : (angle += increment) {
        points[count] = .{ radius * @cos(angle), radius * @sin(angle) };
        count += 1;
    }
    points[count] = .{ radius, 0 };
    points[count + 1] = .{ radius * @cos(increment), radius * @sin(increment) };
    count += 2;
    var x: Range = .{};
    var y: Range = .{};
    for (1..count - 2) |i| {
        inline for (0..2) |axis| {
            const p0 = points[i][axis];
            const p1 = p0 + (points[i + 1][axis] - points[i - 1][axis]) / 6;
            const p2 = points[i + 1][axis] + (points[i][axis] - points[i + 2][axis]) / 6;
            const p3 = points[i + 1][axis];
            (if (axis == 0) &x else &y).cubic(p0, p1, p2, p3);
        }
    }
    return .{ .width = x.high - x.low, .height = y.high - y.low };
}
pub fn nodeSize(shape: Shape, text: Size, padding: f64, horizontal: bool) !Size {
    if (!finite(text.width) or !finite(text.height) or !finite(padding)) return error.InvalidMeasurement;
    const w = text.width;
    const h = text.height;
    const p = padding;
    const result: Size = switch (shape) {
        .box, .datastore => .{ .width = w + 4 * p, .height = h + 2 * p },
        .round => .{ .width = w + 2 * p, .height = h + 2 * p },
        .text => .{ .width = w + p, .height = h + p },
        .diamond => .{ .width = w + h + 2 * p, .height = w + h + 2 * p },
        // ELK uses the whole node's bounds, including labels protruding beyond
        // a circle. The circle renderer itself chooses radius from width only.
        .circle => .{ .width = w + p, .height = @max(w + p, h) },
        .double_circle => .{ .width = w + 2 * p, .height = @max(w + 2 * p, h) },
        .stadium => blk: {
            const height = h + p;
            const width = w + p + height / 4;
            break :blk .{ .width = @max(width - height * (1 - arcMaximum(50)), height - width), .height = height };
        },
        .subroutine => .{ .width = w + p + 16, .height = h + p },
        .asymmetric => .{ .width = w + p + (h + p) / 4, .height = h + p },
        .hexagon => .{ .width = w + p + (h + p) / 2, .height = h + p },
        .lean_left, .lean_right, .trapezoid => .{ .width = w + p + h + p, .height = h + p },
        .inverse_trapezoid => .{ .width = w + 2 * p + h + 2 * p, .height = h + 2 * p },
        .card => .{ .width = w + p + 12, .height = h + p },
        .lined_process => .{ .width = w + 2 * p + 16, .height = h + 2 * p },
        .small_circle => .{ .width = 14, .height = 14 },
        .framed_circle, .junction => roughCircle(14),
        // Flowchart ELK does not pass dir/state config to forkJoin.
        .fork => .{ .width = 70, .height = 10 },
        .hourglass => .{ .width = 30, .height = 30 },
        .bolt => .{ .width = 35, .height = 70 },
        .crossed_circle => roughCircle(60),
        .triangle, .flipped_triangle => .{ .width = w + p + h, .height = w + p + h },
        .manual_input => .{ .width = w + 2 * p, .height = (h + 2 * p) * 1.5 },
        .window => .{ .width = w + 2 * p + 10, .height = h + 2 * p + 10 },
        .loop_limit => .{ .width = w + 2 * p, .height = h + 2 * p },
        .processes => .{ .width = w + 2 * p + 10, .height = h + 2 * p + 10 },
        .divided_process => .{ .width = w + p, .height = (h + p) * 1.2 },
        .tagged_process => .{ .width = w + 2 * p + (h + 2 * p) * 0.2, .height = h + 2 * p },
        .delay, .display => blk: {
            const height = if (shape == .delay) @max(10, h) + 2 * p else @max(5, h + 2 * p);
            const width = if (shape == .delay) @max(15, w) + 2 * p else @max(20, (w + 2 * p) * 1.25);
            break :blk .{ .width = @max(width, height / 2) - height / 2 * (1 - arcMaximum(50)), .height = height };
        },
        .cylinder, .lined_cylinder => blk: {
            const width = w + (if (shape == .cylinder) p else 2 * p);
            const ry = width / 2 / (2.5 + width / 50);
            break :blk .{ .width = width, .height = h + (if (shape == .cylinder) p else 2 * p) + 3 * ry };
        },
        .horizontal_cylinder => blk: {
            const height = h + p / 2;
            const rx = height / 2 / (2.5 + height / 50);
            break :blk .{ .width = w + p / 2 + 3 * rx, .height = height };
        },
        .document, .tagged_document, .lined_document => blk: {
            const height = h + 2 * p;
            break :blk .{ .width = @max(14, w + 2 * p) * (if (shape == .lined_document or shape == .tagged_document) @as(f64, 1.1) else 1), .height = height * (1 + (1 + sineMaximum(0.8)) / 8) };
        },
        .documents => .{ .width = w + 2 * p + 20, .height = (h + 3 * p) * (1 + (0.5 + sineMaximum(0.8)) / 8) + 20 },
        .paper_tape => .{ .width = w + 2 * p, .height = (h + p) * (1 + (2 + 2 * sineMaximum(1)) / 8) },
        .stored_data => .{ .width = w + 2 * p + (h + p) / 2 / (2.5 + (h + p) / 50) * arcMaximum(20), .height = h + p },
        .brace_left, .brace_right, .braces => blk: {
            const height = h + p;
            const radius = @max(5, height * 0.1);
            const width = w + p;
            const extra = switch (shape) {
                .brace_left => @max(width * 0.1, radius * 2),
                .brace_right => radius * 2,
                .braces => radius * 2.5,
                else => unreachable,
            };
            break :blk .{ .width = width + extra, .height = height + 2 * radius };
        },
    };
    _ = horizontal;
    if (!finite(result.width) or !finite(result.height)) return error.InvalidMeasurement;
    return result;
}
pub const Run = struct { content: []const u8, type: enum { normal, strong, em } };
fn validTextGeometry(x: f64, y: f64, runs: []const []const Run) bool {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or @abs(x) > 1e7 or @abs(y) > 1e7 or runs.len > 256) return false;
    for (runs) |row| {
        if (row.len > 4096) return false;
        for (row) |run| if (run.content.len > 4096) return false;
    }
    return true;
}
pub const Node = struct {
    id: []const u8,
    shape: Shape,
    label: []const u8,
    markdown: bool,
    text_width: f64,
    text_height: f64,
    text_x: f64 = 0,
    text_y: f64 = 0,
    font_size: f64,
    lines: []const []const u8,
    runs: []const []const Run = &.{},
    sections: []const Section = &.{},
    padding: ?f64 = null,
};
pub const Section = struct { label: []const u8, font_size: f64, text_width: f64, text_height: f64, text_x: f64 = 0, text_y: f64 = 0, lines: []const []const u8, runs: []const []const Run = &.{} };
pub const Edge = struct {
    index: usize,
    source: []const u8,
    target: []const u8,
    label: []const u8,
    markdown: bool,
    width: f64,
    height: f64,
    font_size: f64 = 16,
    text_width: f64 = 0,
    text_height: f64 = 0,
    text_x: f64 = 0,
    text_y: f64 = 0,
    lines: []const []const u8 = &.{},
    runs: []const []const Run = &.{},
};
pub const Family = enum { flowchart, state };
pub const Input = struct { schema: []const u8, nodes: []const Node, edges: []const Edge, font_family: []const u8, padding: f64, direction: []const u8, request_key: ?[]const u8 = null, diagram_family: Family = .flowchart };
pub fn measuredNodeSize(input: Input, node: Node) !Size {
    if (node.padding) |p| {
        if (input.diagram_family != .state or node.shape != .tagged_process or !finite(p)) return error.InvalidMeasurement;
        return .{ .width = node.text_width + 2 * p, .height = node.text_height + 2 * p };
    }
    if (node.sections.len == 0) return nodeSize(node.shape, .{ .width = node.text_width, .height = node.text_height }, input.padding, std.mem.eql(u8, input.direction, "LR"));
    if (input.diagram_family != .state or node.sections.len != 2 or node.shape != .round) return error.InvalidMeasurement;
    return .{ .width = @max(node.sections[0].text_width, node.sections[1].text_width) + input.padding,
        .height = node.sections[0].text_height + node.sections[1].text_height + input.padding * 1.5 + 5 };
}
pub fn trace(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len > 4 * 1024 * 1024) return error.InvalidMeasurement;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = (try std.json.parseFromSlice(Input, a, source, .{})).value;
    if (!std.mem.eql(u8, input.schema, "zmermaid-shaped-text-v1") or input.nodes.len == 0 or input.nodes.len > 256 or input.edges.len > 256 or input.font_family.len == 0 or !finite(input.padding)) return error.InvalidMeasurement;
    if (!std.mem.eql(u8, input.direction, "LR") and !std.mem.eql(u8, input.direction, "RL") and !std.mem.eql(u8, input.direction, "TB") and !std.mem.eql(u8, input.direction, "BT")) return error.InvalidMeasurement;
    const ResultNode = struct { id: []const u8, shape: Shape, label: []const u8, markdown: bool, width: f64, height: f64, text_width: f64, text_height: f64, text_x: f64, text_y: f64, font_size: f64, lines: []const []const u8, runs: []const []const Run };
    const nodes = try a.alloc(ResultNode, input.nodes.len);
    for (input.nodes, 0..) |node, i| {
        if (node.id.len == 0 or node.id.len > 512 or node.label.len > 4096 or node.lines.len > 256 or !finite(node.font_size) or node.font_size == 0 or node.font_size > 256) return error.InvalidMeasurement;
        for (node.lines) |line| if (line.len > 4096) return error.InvalidMeasurement;
        if (!validTextGeometry(node.text_x, node.text_y, node.runs)) return error.InvalidMeasurement;
        for (input.nodes[0..i]) |other| if (std.mem.eql(u8, node.id, other.id)) return error.InvalidMeasurement;
        for (node.sections) |section| {
            if (section.label.len > 4096 or !finite(section.font_size) or section.font_size == 0 or section.font_size > 256 or
                !finite(section.text_width) or !finite(section.text_height) or section.lines.len > 256 or
                !validTextGeometry(section.text_x, section.text_y, section.runs)) return error.InvalidMeasurement;
            for (section.lines) |line| if (line.len > 4096) return error.InvalidMeasurement;
        }
        const size = try measuredNodeSize(input, node);
        nodes[i] = .{ .id = node.id, .shape = node.shape, .label = node.label, .markdown = node.markdown, .width = size.width, .height = size.height, .text_width = node.text_width, .text_height = node.text_height, .text_x = node.text_x, .text_y = node.text_y, .font_size = node.font_size, .lines = node.lines, .runs = node.runs };
    }
    for (input.edges, 0..) |edge, i| {
        if (edge.index != i or !finite(edge.width) or !finite(edge.height)) return error.InvalidMeasurement;
        if (!finite(edge.font_size) or edge.font_size == 0 or edge.font_size > 256 or !finite(edge.text_width) or !finite(edge.text_height) or
            !validTextGeometry(edge.text_x, edge.text_y, edge.runs) or edge.lines.len > 256) return error.InvalidMeasurement;
        for (edge.lines) |line| if (line.len > 4096) return error.InvalidMeasurement;
        var found_source = false;
        var found_target = false;
        for (input.nodes) |node| {
            found_source = found_source or std.mem.eql(u8, edge.source, node.id);
            found_target = found_target or std.mem.eql(u8, edge.target, node.id);
        }
        if (!found_source or !found_target) return error.InvalidMeasurement;
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .schema = "zmermaid-measurement-trace-v1", .request_key = input.request_key, .nodes = nodes, .edges = input.edges, .font_family = input.font_family, .direction = input.direction, .padding = input.padding }, .{});
}

test "measurement shape rules preserve fractions without global minimum boxes" {
    const box = try nodeSize(.box, .{ .width = 10.125, .height = 24 }, 5.5, false);
    try std.testing.expectEqual(@as(f64, 32.125), box.width);
    try std.testing.expectEqual(@as(f64, 35), box.height);
    const diamond = try nodeSize(.diamond, .{ .width = 10.125, .height = 24 }, 5.5, false);
    try std.testing.expectEqual(@as(f64, 45.125), diamond.width);
    try std.testing.expectEqual(diamond.width, diamond.height);
    try std.testing.expectError(error.InvalidMeasurement, nodeSize(.box, .{ .width = -1, .height = 1 }, 15, false));
    try std.testing.expectError(error.InvalidMeasurement, nodeSize(.box, .{ .width = std.math.nan(f64), .height = 1 }, 15, false));
    inline for (std.meta.tags(Shape)) |shape| {
        const size = try nodeSize(shape, .{ .width = 100.125, .height = 47.75 }, 13.25, false);
        try std.testing.expect(finite(size.width) and finite(size.height));
    }
}

test "shaped measurements reject malformed references and release allocations" {
    const source = "{\"schema\":\"zmermaid-shaped-text-v1\",\"nodes\":[{\"id\":\"A\",\"shape\":\"box\",\"label\":\"Hi\",\"markdown\":false,\"text_width\":10.125,\"text_height\":17,\"font_size\":16,\"lines\":[\"Hi\"]}],\"edges\":[],\"font_family\":\"Arial\",\"padding\":15,\"direction\":\"LR\"}";
    const result = try trace(std.testing.allocator, source);
    defer std.testing.allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 70.125), parsed.value.object.get("nodes").?.array.items[0].object.get("width").?.float);
    const mutated = try std.mem.replaceOwned(u8, std.testing.allocator, source, "\"edges\":[]", "\"edges\":[{\"index\":0,\"source\":\"A\",\"target\":\"missing\",\"label\":\"\",\"markdown\":false,\"width\":0,\"height\":0}]");
    defer std.testing.allocator.free(mutated);
    try std.testing.expectError(error.InvalidMeasurement, trace(std.testing.allocator, mutated));
    const negative = try std.mem.replaceOwned(u8, std.testing.allocator, source, "10.125", "-1");
    defer std.testing.allocator.free(negative);
    try std.testing.expectError(error.InvalidMeasurement, trace(std.testing.allocator, negative));
}
