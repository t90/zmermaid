// SPDX-License-Identifier: EPL-2.0
// Mermaid 11.16.1 implementation/behavior references:
// https://github.com/mermaid-js/mermaid/blob/7ecca0cd7f1658ef74f4e7e91f925724ef403bbf/packages/mermaid/src/rendering-util/rendering-elements/shapes/
// Upstream copyright: (c) 2014 - 2022 Knut Sveidqvist.
// Upstream MIT notice: LICENSES/Mermaid-MIT.txt; project license: LICENSE.
const std = @import("std");
const svg = @import("svg.zig");
pub const Shape = enum { box, round, circle, diamond, stadium, subroutine, cylinder, asymmetric, hexagon, lean_right, lean_left, trapezoid, inverse_trapezoid, double_circle, datastore, text, card, lined_process, small_circle, framed_circle, fork, hourglass, brace_left, brace_right, braces, bolt, document, delay, horizontal_cylinder, lined_cylinder, display, divided_process, triangle, window, junction, lined_document, loop_limit, flipped_triangle, manual_input, documents, processes, paper_tape, stored_data, crossed_circle, tagged_document, tagged_process };
pub fn named(name: []const u8) ?Shape {
    const aliases = [_]struct { shape: Shape, names: []const u8 }{
        .{ .shape = .box, .names = "rect|proc|process|rectangle" },
        .{ .shape = .round, .names = "rounded|event" },
        .{ .shape = .stadium, .names = "stadium|terminal|pill" },
        .{ .shape = .subroutine, .names = "fr-rect|subprocess|subproc|framed-rectangle|subroutine" },
        .{ .shape = .cylinder, .names = "cyl|db|database|cylinder" },
        .{ .shape = .circle, .names = "circle|circ" },
        .{ .shape = .diamond, .names = "diam|decision|diamond|question" },
        .{ .shape = .hexagon, .names = "hex|hexagon|prepare" },
        .{ .shape = .lean_right, .names = "lean-r|lean-right|in-out" },
        .{ .shape = .lean_left, .names = "lean-l|lean-left|out-in" },
        .{ .shape = .trapezoid, .names = "trap-b|priority|trapezoid-bottom|trapezoid" },
        .{ .shape = .inverse_trapezoid, .names = "trap-t|manual|trapezoid-top|inv-trapezoid" },
        .{ .shape = .double_circle, .names = "dbl-circ|double-circle" },
        .{ .shape = .asymmetric, .names = "odd" },
        .{ .shape = .datastore, .names = "datastore|data-store" },
        .{ .shape = .text, .names = "text" },
        .{ .shape = .card, .names = "notch-rect|card|notched-rectangle" },
        .{ .shape = .lined_process, .names = "lin-rect|lined-rectangle|lined-process|lin-proc|shaded-process" },
        .{ .shape = .small_circle, .names = "sm-circ|start|small-circle" },
        .{ .shape = .framed_circle, .names = "fr-circ|stop|framed-circle" },
        .{ .shape = .fork, .names = "fork|join" },
        .{ .shape = .hourglass, .names = "hourglass|collate" },
        .{ .shape = .brace_left, .names = "brace|comment|brace-l" },
        .{ .shape = .brace_right, .names = "brace-r" },
        .{ .shape = .braces, .names = "braces" },
        .{ .shape = .bolt, .names = "bolt|com-link|lightning-bolt" },
        .{ .shape = .document, .names = "doc|document" },
        .{ .shape = .delay, .names = "delay|half-rounded-rectangle" },
        .{ .shape = .horizontal_cylinder, .names = "h-cyl|das|horizontal-cylinder" },
        .{ .shape = .lined_cylinder, .names = "lin-cyl|disk|lined-cylinder" },
        .{ .shape = .display, .names = "curv-trap|curved-trapezoid|display" },
        .{ .shape = .divided_process, .names = "div-rect|div-proc|divided-rectangle|divided-process" },
        .{ .shape = .triangle, .names = "tri|extract|triangle" },
        .{ .shape = .window, .names = "win-pane|internal-storage|window-pane" },
        .{ .shape = .junction, .names = "f-circ|junction|filled-circle" },
        .{ .shape = .lined_document, .names = "lin-doc|lined-document" },
        .{ .shape = .loop_limit, .names = "notch-pent|loop-limit|notched-pentagon" },
        .{ .shape = .flipped_triangle, .names = "flip-tri|manual-file|flipped-triangle" },
        .{ .shape = .manual_input, .names = "sl-rect|manual-input|sloped-rectangle" },
        .{ .shape = .documents, .names = "docs|documents|st-doc|stacked-document" },
        .{ .shape = .processes, .names = "st-rect|procs|processes|stacked-rectangle" },
        .{ .shape = .paper_tape, .names = "flag|paper-tape" },
        .{ .shape = .stored_data, .names = "bow-rect|stored-data|bow-tie-rectangle" },
        .{ .shape = .crossed_circle, .names = "cross-circ|summary|crossed-circle" },
        .{ .shape = .tagged_document, .names = "tag-doc|tagged-document" },
        .{ .shape = .tagged_process, .names = "tag-rect|tagged-rectangle|tag-proc|tagged-process" },
    };
    for (aliases) |entry| {
        var parts = std.mem.splitScalar(u8, entry.names, '|');
        while (parts.next()) |part| if (std.mem.eql(u8, part, name)) return entry.shape;
    }
    return null;
}
pub fn circular(shape: Shape) bool {
    return shape == .circle or shape == .double_circle or shape == .crossed_circle;
}
pub fn externalLabel(shape: Shape) bool {
    return shape == .small_circle or shape == .framed_circle or shape == .junction or shape == .fork or shape == .bolt or shape == .hourglass;
}
pub const Point = struct { x: usize, y: usize };
pub const Side = enum { left, right, top, bottom };

pub fn anchor(shape: Shape, x: usize, y: usize, w: usize, h: usize, side: Side) Point {
    if (shape == .fork) return switch (side) {
        .left => .{ .x = x, .y = y + h / 2 },
        .right => .{ .x = x + w, .y = y + h / 2 },
        .top => .{ .x = x + w / 2, .y = y + h / 2 - 6 },
        .bottom => .{ .x = x + w / 2, .y = y + h / 2 + 6 },
    };
    if ((shape == .triangle or shape == .flipped_triangle) and (side == .left or side == .right)) return .{ .x = x + if (side == .left) w / 4 else w * 3 / 4, .y = y + h / 2 };
    if ((shape == .document or shape == .lined_document or shape == .tagged_document or shape == .paper_tape) and side == .bottom) return .{ .x = x + w / 2, .y = y + h * 85 / 100 };
    if (shape == .small_circle or shape == .framed_circle or shape == .junction) {
        const r: usize = if (shape == .framed_circle) 12 else 8;
        const cx = x + w / 2;
        const cy = y + h / 2;
        return switch (side) {
            .left => .{ .x = cx - r, .y = cy },
            .right => .{ .x = cx + r, .y = cy },
            .top => .{ .x = cx, .y = cy - r },
            .bottom => .{ .x = cx, .y = cy + r },
        };
    }
    const inset: usize = switch (shape) {
        .lean_right, .lean_left, .trapezoid, .inverse_trapezoid => 12,
        .asymmetric => if (side == .left) 24 else 0,
        else => 0,
    };
    return switch (side) {
        .left => .{ .x = x + inset, .y = y + h / 2 },
        .right => .{ .x = x + w - inset, .y = y + h / 2 },
        .top => .{ .x = x + w / 2, .y = y },
        .bottom => .{ .x = x + w / 2, .y = y + h },
    };
}

pub fn draw(out: *svg.Svg, shape: Shape, x: usize, y: usize, w: usize, h: usize) !void {
    return drawGeometry(out, shape, x, y, w, h);
}
pub fn drawFractional(out: *svg.Svg, shape: Shape, x: f64, y: f64, w: f64, h: f64) !void {
    return drawGeometry(out, shape, x, y, w, h);
}
fn drawGeometry(out: *svg.Svg, shape: Shape, x: anytype, y: @TypeOf(x), w: @TypeOf(x), h: @TypeOf(x)) !void {
    try out.fmt("<g data-shape=\"{s}\">", .{@tagName(shape)});
    switch (shape) {
        .diamond => try out.fmt("<polygon points=\"{d},{d} {d},{d} {d},{d} {d},{d}\"/>", .{ x + w / 2, y, x + w, y + h / 2, x + w / 2, y + h, x, y + h / 2 }),
        .circle, .double_circle, .crossed_circle => {
            try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"{d}\"/>", .{ x + w / 2, y + h / 2, w / 2 });
            if (shape == .double_circle) try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"{d}\" fill=\"none\"/>", .{ x + w / 2, y + h / 2, w / 2 - 6 });
            if (shape == .crossed_circle) try out.fmt("<path d=\"M {d} {d} H {d} M {d} {d} V {d}\" fill=\"none\"/>", .{ x, y + h / 2, x + w, x + w / 2, y, y + h });
        },
        .subroutine => {
            try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\"/><path d=\"M {d} {d} v {d} M {d} {d} v {d}\" fill=\"none\"/>", .{ x, y, w, h, x + 12, y, h, x + w - 12, y, h });
        },
        .cylinder => {
            try out.fmt("<path d=\"M {d} {d} A {d} 12 0 0 1 {d} {d} V {d} A {d} 12 0 0 1 {d} {d} Z\"/><ellipse cx=\"{d}\" cy=\"{d}\" rx=\"{d}\" ry=\"12\"/>", .{ x, y + 12, w / 2, x + w, y + 12, y + h - 12, w / 2, x, y + h - 12, x + w / 2, y + 12, w / 2 });
        },
        .hexagon => try out.fmt("<polygon points=\"{d},{d} {d},{d} {d},{d} {d},{d} {d},{d} {d},{d}\"/>", .{ x + 24, y, x + w - 24, y, x + w, y + h / 2, x + w - 24, y + h, x + 24, y + h, x, y + h / 2 }),
        .asymmetric => try out.fmt("<polygon points=\"{d},{d} {d},{d} {d},{d} {d},{d} {d},{d}\"/>", .{ x, y, x + w, y, x + w, y + h, x, y + h, x + 24, y + h / 2 }),
        .lean_right, .lean_left, .trapezoid, .inverse_trapezoid => {
            const tl = x + @as(@TypeOf(x), if (shape == .lean_right or shape == .trapezoid) 24 else 0);
            const tr = x + w - @as(@TypeOf(x), if (shape == .lean_left or shape == .trapezoid) 24 else 0);
            const bl = x + @as(@TypeOf(x), if (shape == .lean_left or shape == .inverse_trapezoid) 24 else 0);
            const br = x + w - @as(@TypeOf(x), if (shape == .lean_right or shape == .inverse_trapezoid) 24 else 0);
            try out.fmt("<polygon points=\"{d},{d} {d},{d} {d},{d} {d},{d}\"/>", .{ tl, y, tr, y, br, y + h, bl, y + h });
        },
        .box, .round, .stadium => try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"{d}\"/>", .{ x, y, w, h, if (shape == .stadium) h / 2 else @as(@TypeOf(x), 10) }),
        .text => {},
        .small_circle, .junction, .framed_circle => {
            const fg = if (out.theme == .dark) "#e0e0e0" else "#24292f";
            if (shape == .framed_circle) try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"12\"/>", .{ x + w / 2, y + h / 2 });
            try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"8\" fill=\"var(--zm-node-fill,{s})\"/>", .{ x + w / 2, y + h / 2, fg });
        },
        .fork => try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"12\" fill=\"var(--zm-node-fill,{s})\"/>", .{ x, y + h / 2 - 6, w, if (out.theme == .dark) "#e0e0e0" else "#24292f" }),
        else => try modern(out, shape, x, y, w, h),
    }
    try out.add("</g>");
}

/// Label-free symbols share the measured bounds used by connector clipping.
/// Legacy fixed-size symbols are left unchanged in drawGeometry.
pub fn drawMeasuredSymbol(out: *svg.Svg, shape: Shape, x: f64, y: f64, w: f64, h: f64) !bool {
    if (shape != .small_circle and shape != .framed_circle and shape != .fork) return false;
    const fg = if (out.theme == .dark) "#e0e0e0" else "#24292f";
    try out.fmt("<g data-shape=\"{s}\">", .{@tagName(shape)});
    if (shape == .fork) {
        try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"var(--zm-node-fill,{s})\"/>", .{ x, y, w, h, fg });
    } else {
        const radius = w / 2;
        if (shape == .framed_circle) try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"{d}\" stroke-width=\"2\"/>", .{ x + w / 2, y + h / 2, radius });
        try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"{d}\" fill=\"var(--zm-node-fill,{s})\"/>", .{ x + w / 2, y + h / 2, if (shape == .framed_circle) w * 5 / 28 else radius, fg });
    }
    try out.add("</g>");
    return true;
}

fn asFloat(value: anytype) f64 {
    return if (@typeInfo(@TypeOf(value)) == .int) @floatFromInt(value) else value;
}
fn modern(out: *svg.Svg, shape: Shape, x: anytype, y: @TypeOf(x), w: @TypeOf(x), h: @TypeOf(x)) !void {
    // Unit-square geometry scales to the measured label box, with constant stroke width.
    try out.fmt("<g transform=\"translate({d} {d}) scale({d:.4} {d:.4})\">", .{ x, y, asFloat(w) / 100, asFloat(h) / 100 });
    const path: []const u8 = switch (shape) {
        .datastore => "M 0 0 H 100 M 0 100 H 100",
        .card => "M 15 0 H 100 V 100 H 0 V 20 Z",
        .lined_process, .divided_process, .window, .tagged_process => "M 0 0 H 100 V 100 H 0 Z",
        .hourglass => "M 0 0 H 100 L 0 100 H 100 Z",
        .brace_left => "M 20 0 Q 8 0 8 15 V 35 Q 8 50 0 50 Q 8 50 8 65 V 85 Q 8 100 20 100",
        .brace_right => "M 80 0 Q 92 0 92 15 V 35 Q 92 50 100 50 Q 92 50 92 65 V 85 Q 92 100 80 100",
        .braces => "M 20 0 Q 8 0 8 15 V 35 Q 8 50 0 50 Q 8 50 8 65 V 85 Q 8 100 20 100 M 80 0 Q 92 0 92 15 V 35 Q 92 50 100 50 Q 92 50 92 65 V 85 Q 92 100 80 100",
        .bolt => "M 65 0 L 15 55 H 48 L 35 100 L 85 45 H 52 Z",
        .document, .lined_document, .tagged_document => "M 0 0 H 100 V 85 C 65 60 35 110 0 85 Z",
        .delay => "M 0 0 H 60 A 40 50 0 0 1 60 100 H 0 Z",
        .horizontal_cylinder => "M 12 0 H 88 A 12 50 0 0 1 88 100 H 12 A 12 50 0 0 1 12 0 Z",
        .lined_cylinder => "M 0 12 A 50 12 0 0 1 100 12 V 88 A 50 12 0 0 1 0 88 Z",
        .display => "M 20 0 H 80 Q 120 50 80 100 H 20 L 0 50 Z",
        .triangle => "M 50 0 L 100 100 H 0 Z",
        .loop_limit => "M 20 0 H 80 L 100 25 V 100 H 0 V 25 Z",
        .flipped_triangle => "M 0 0 H 100 L 50 100 Z",
        .manual_input => "M 0 25 L 100 0 V 100 H 0 Z",
        .documents => "M 16 0 H 100 V 75 H 84 V 8 H 16 Z M 8 8 H 92 V 83 H 76 V 16 H 8 Z M 0 16 H 84 V 85 C 55 65 29 110 0 85 Z",
        .processes => "M 16 0 H 100 V 84 H 92 V 8 H 16 Z M 8 8 H 92 V 92 H 84 V 16 H 8 Z M 0 16 H 84 V 100 H 0 Z",
        .paper_tape => "M 0 15 C 35 40 65 -10 100 15 V 85 C 65 60 35 110 0 85 Z",
        .stored_data => "M 15 0 H 100 Q 70 50 100 100 H 15 Q -15 50 15 0 Z",
        else => unreachable,
    };
    const open = shape == .datastore or shape == .brace_left or shape == .brace_right or shape == .braces;
    try out.fmt("<path vector-effect=\"non-scaling-stroke\" d=\"{s}\"{s}/>", .{ path, if (open) " fill=\"none\"" else "" });
    const detail: []const u8 = switch (shape) {
        .lined_process => "M 10 0 V 100",
        .divided_process => "M 0 22 H 100",
        .window => "M 0 20 H 100 M 15 0 V 100",
        .horizontal_cylinder => "M 88 0 A 12 50 0 1 0 88 100 A 12 50 0 1 0 88 0",
        .lined_cylinder => "M 0 12 A 50 12 0 0 0 100 12 M 0 24 A 50 12 0 0 0 100 24 M 0 36 A 50 12 0 0 0 100 36",
        .lined_document => "M 12 15 V 75",
        .tagged_document, .tagged_process => "M 80 0 V 20 H 100",
        else => "",
    };
    if (detail.len > 0) try out.fmt("<path vector-effect=\"non-scaling-stroke\" fill=\"none\" d=\"{s}\"/>", .{detail});
    try out.add("</g>");
}
