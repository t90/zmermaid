const std = @import("std");
pub const Marker = enum { none, arrow, circle, cross, inheritance, composition, aggregation, open, lollipop, exactly_one, zero_one, one_many, zero_many, contains, md_parent };
pub const Stroke = enum { normal, dotted, thick, invisible };
pub const Curve = enum { smooth, linear, linearClosed, natural, basis, basisOpen, basisClosed, bundle, cardinal, cardinalOpen, cardinalClosed, catmullRom, catmullRomOpen, catmullRomClosed, monotoneX, monotoneY, bumpX, bumpY, step, stepBefore, stepAfter, rounded };
pub const Point = struct { x: f64, y: f64 };
pub fn point(x: usize, y: usize) Point {
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}
test "short and coincident routes keep bounded finite terminals" {
    for ([_]Curve{ .smooth, .linear, .basisOpen, .cardinalClosed, .stepBefore }) |curve| {
        for ([_]bool{ false, true }) |horizontal| {
            var out: @import("svg.zig").Svg = .{ .allocator = std.testing.allocator, .theme = .light };
            defer out.deinit();
            try route(&out, curve, 2, 2, 0, 0, horizontal);
            try std.testing.expect(std.mem.endsWith(u8, out.bytes.items, " L 0 0\"/>"));
            try std.testing.expect(std.mem.indexOf(u8, out.bytes.items, "nan") == null);
            out.bytes.clearRetainingCapacity();
            try route(&out, curve, 0, 0, 0, 0, horizontal);
            try std.testing.expect(std.mem.startsWith(u8, out.bytes.items, "d=\"M 0 0 L 0 0"));
            try std.testing.expect(std.mem.indexOf(u8, out.bytes.items, "nan") == null);
        }
    }
}
fn towards(p: Point, q: Point, distance: f64) Point {
    const dx = q.x - p.x;
    const dy = q.y - p.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 0.00001) return p;
    const scale = @min(distance / length, 1);
    return .{ .x = p.x + dx * scale, .y = p.y + dy * scale };
}
// Shared terminal treatment for diagram-specific cubic/self-loop routes.
// Only writes the d attribute so callers retain their own markers and styles.
pub fn terminalCubic(out: *@import("svg.zig").Svg, p: Point, c1: Point, c2: Point, q: Point) !void {
    const a = towards(p, c1, 24);
    const b = towards(q, c2, 24);
    try out.fmt("d=\"M {d} {d} L {d} {d} C {d} {d} {d} {d} {d} {d} L {d} {d}\"", .{ p.x, p.y, a.x, a.y, c1.x, c1.y, c2.x, c2.y, b.x, b.y, q.x, q.y });
}
// Cardinality glyphs occupy a straight terminal section; a curve that bends
// immediately at its endpoint leaves the rigid marker floating off the line.
pub fn relationshipRoute(out: *@import("svg.zig").Svg, x1: usize, y1: usize, x2: usize, y2: usize, horizontal: bool) !void {
    try out.add("data-terminal-length=\"20\" ");
    try terminalRoute(out, .smooth, x1, y1, x2, y2, horizontal, 20);
}
fn mix(a: Point, b: Point, wa: f64, wb: f64) Point {
    return .{ .x = a.x * wa + b.x * wb, .y = a.y * wa + b.y * wb };
}
fn cubic(out: *@import("svg.zig").Svg, c1: Point, c2: Point, end: Point) !void {
    try out.fmt(" C {d} {d} {d} {d} {d} {d}", .{ c1.x, c1.y, c2.x, c2.y, end.x, end.y });
}
fn chord(a: Point, b: Point) f64 {
    return @sqrt(@sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)));
}
// Cubic controls from centripetal Catmull-Rom tangents; coincident points
// have zero tangent, avoiding divisions by zero without a geometry runtime.
fn catmull(out: *@import("svg.zig").Svg, p0: Point, p1: Point, p2: Point, p3: Point) !void {
    const d01 = chord(p0, p1);
    const d12 = chord(p1, p2);
    const d23 = chord(p2, p3);
    var c1 = p1;
    var c2 = p2;
    if (d01 > 1e-9 and d12 > 1e-9) {
        const tangent = mix(mix(p1, p0, 1 / d01, -1 / d01), mix(p2, p0, 1 / (d01 + d12), -1 / (d01 + d12)), 1, -1);
        c1 = mix(p1, mix(tangent, mix(p2, p1, 1 / d12, -1 / d12), 1, 1), 1, d12 / 3);
    }
    if (d23 > 1e-9 and d12 > 1e-9) {
        const tangent = mix(mix(p2, p1, 1 / d12, -1 / d12), mix(p3, p1, 1 / (d12 + d23), -1 / (d12 + d23)), 1, -1);
        c2 = mix(p2, mix(tangent, mix(p3, p2, 1 / d23, -1 / d23), 1, 1), 1, -d12 / 3);
    }
    try cubic(out, c1, c2, p2);
}
fn slope(a: Point, b: Point, c: Point) f64 {
    const dx1 = b.x - a.x;
    const dx2 = c.x - b.x;
    if (@abs(dx1) < 1e-9 or @abs(dx2) < 1e-9 or @abs(dx1 + dx2) < 1e-9) return 0;
    const s1 = (b.y - a.y) / dx1;
    const s2 = (c.y - b.y) / dx2;
    if (s1 * s2 <= 0) return 0;
    const average = (s1 * dx2 + s2 * dx1) / (dx1 + dx2);
    return (if (s1 < 0) @as(f64, -2) else 2) * @min(@min(@abs(s1), @abs(s2)), @abs(average) / 2);
}
// Route interpolation is local arithmetic over four routing points, not a layout dependency.
pub fn route(out: *@import("svg.zig").Svg, curve: Curve, x1: usize, y1: usize, x2: usize, y2: usize, horizontal: bool) !void {
    try terminalRoute(out, curve, x1, y1, x2, y2, horizontal, 24);
}
pub fn roundedPolyline(out: *@import("svg.zig").Svg, points: []const Point) !void {
    if (points.len == 0) return out.add("d=\"\"/>");
    try out.fmt("d=\"M {d} {d}", .{ points[0].x, points[0].y });
    if (points.len == 1) return out.add("\"/>");
    for (1..points.len - 1) |i| {
        const before = points[i - 1];
        const corner = points[i];
        const after = points[i + 1];
        const incoming = mix(corner, before, 1, -1);
        const outgoing = mix(after, corner, 1, -1);
        const length1 = @sqrt(incoming.x * incoming.x + incoming.y * incoming.y);
        const length2 = @sqrt(outgoing.x * outgoing.x + outgoing.y * outgoing.y);
        if (length1 < 1e-9 or length2 < 1e-9 or @abs(incoming.x * outgoing.y - incoming.y * outgoing.x) < 1e-9) {
            try out.fmt(" L {d} {d}", .{ corner.x, corner.y });
            continue;
        }
        var radius = @min(7, @min(length1 / 2, length2 / 2));
        // Corner rounding must not consume the marker's straight terminal.
        if (i == 1) radius = @min(radius, @max(@as(f64, 0), length1 - 14));
        if (i == points.len - 2) radius = @min(radius, @max(@as(f64, 0), length2 - 14));
        const enter = mix(corner, incoming, 1, -radius / length1);
        const leave = mix(corner, outgoing, 1, radius / length2);
        try out.fmt(" L {d} {d} Q {d} {d} {d} {d}", .{ enter.x, enter.y, corner.x, corner.y, leave.x, leave.y });
    }
    const last = points[points.len - 1];
    try out.fmt(" L {d} {d}\"/>", .{ last.x, last.y });
}
fn terminalRoute(out: *@import("svg.zig").Svg, curve: Curve, x1: usize, y1: usize, x2: usize, y2: usize, horizontal: bool, requested: usize) !void {
    const delta = if (horizontal) @max(x1, x2) - @min(x1, x2) else @max(y1, y2) - @min(y1, y2);
    const length = @min(requested, delta / 2);
    const reverse = if (horizontal) x2 < x1 else y2 < y1;
    const ax = if (!horizontal) x1 else if (reverse) x1 - length else x1 + length;
    const ay = if (horizontal) y1 else if (reverse) y1 - length else y1 + length;
    const bx = if (!horizontal) x2 else if (reverse) x2 + length else x2 - length;
    const by = if (horizontal) y2 else if (reverse) y2 + length else y2 - length;
    var inner: @import("svg.zig").Svg = .{ .allocator = out.allocator, .theme = out.theme };
    defer inner.deinit();
    try interpolate(&inner, curve, ax, ay, bx, by, horizontal);
    const value = inner.bytes.items;
    const first_space = std.mem.indexOfScalarPos(u8, value, 5, ' ') orelse unreachable;
    const second_space = std.mem.indexOfScalarPos(u8, value, first_space + 1, ' ') orelse unreachable;
    const first = value[5..second_space];
    const closed = std.mem.endsWith(u8, value, " Z\"/>");
    const open = curve == .basisOpen or curve == .cardinalOpen or curve == .catmullRomOpen;
    try out.fmt("d=\"M {d} {d} L {d} {d}", .{ x1, y1, ax, ay });
    if (open or closed) {
        try out.add(" L ");
        try out.add(first);
    }
    try out.add(value[second_space .. value.len - (if (closed) @as(usize, 5) else 3)]);
    if (closed) {
        // Close only the middle interpolation, never back through the endpoint.
        try out.add(" L ");
        try out.add(first);
    }
    if (open or closed) try out.fmt(" L {d} {d}", .{ bx, by });
    try out.fmt(" L {d} {d}\"/>", .{ x2, y2 });
}
fn interpolate(out: *@import("svg.zig").Svg, curve: Curve, x1: usize, y1: usize, x2: usize, y2: usize, horizontal: bool) !void {
    const p: Point = .{ .x = @floatFromInt(x1), .y = @floatFromInt(y1) };
    const q: Point = .{ .x = @floatFromInt(x2), .y = @floatFromInt(y2) };
    const h = if (curve == .bumpX) true else if (curve == .bumpY) false else horizontal;
    var a: Point = if (h) .{ .x = (p.x + q.x) / 2, .y = p.y } else .{ .x = p.x, .y = (p.y + q.y) / 2 };
    var b: Point = if (h) .{ .x = a.x, .y = q.y } else .{ .x = q.x, .y = a.y };
    if (curve == .bundle) {
        a = mix(a, mix(p, q, 2.0 / 3.0, 1.0 / 3.0), 0.85, 0.15);
        b = mix(b, mix(p, q, 1.0 / 3.0, 2.0 / 3.0), 0.85, 0.15);
    }
    const points4 = [_]Point{ p, a, b, q };
    if (curve == .basisOpen or curve == .basisClosed) {
        const start = mix(mix(p, a, 1.0 / 6.0, 4.0 / 6.0), b, 1, 1.0 / 6.0);
        try out.fmt("d=\"M {d} {d}", .{ start.x, start.y });
        for (0..if (curve == .basisOpen) @as(usize, 1) else 4) |i| {
            const u = points4[(i + 1) % 4];
            const v = points4[(i + 2) % 4];
            const w = points4[(i + 3) % 4];
            try cubic(out, mix(u, v, 2.0 / 3.0, 1.0 / 3.0), mix(u, v, 1.0 / 3.0, 2.0 / 3.0), mix(mix(u, v, 1.0 / 6.0, 4.0 / 6.0), w, 1, 1.0 / 6.0));
        }
        if (curve == .basisClosed) try out.add(" Z");
        try out.add("\"/>");
        return;
    }
    const open = curve == .cardinalOpen or curve == .catmullRomOpen;
    const closed = curve == .cardinalClosed or curve == .catmullRomClosed;
    const cat = curve == .catmullRom or curve == .catmullRomOpen or curve == .catmullRomClosed;
    if (cat or open or closed or curve == .cardinal) {
        const first = if (open) a else p;
        try out.fmt("d=\"M {d} {d}", .{ first.x, first.y });
        for (if (open) @as(usize, 1) else 0..if (open) @as(usize, 2) else if (closed) 4 else 3) |i| {
            const p0 = points4[if (i == 0) (if (closed) @as(usize, 3) else 0) else i - 1];
            const p1 = points4[i];
            const p2 = points4[(i + 1) % 4];
            const p3 = points4[if (closed) (i + 2) % 4 else @min(i + 2, 3)];
            if (cat) try catmull(out, p0, p1, p2, p3) else try cubic(out, if (!closed and !open and i == 0) p1 else mix(p1, mix(p2, p0, 1, -1), 1, 1.0 / 6.0), if (!closed and !open and i == 2) p2 else mix(p2, mix(p3, p1, 1, -1), 1, -1.0 / 6.0), p2);
        }
        if (closed) try out.add(" Z");
        try out.add("\"/>");
        return;
    }
    try out.fmt("d=\"M {d} {d}", .{ x1, y1 });
    switch (curve) {
        .rounded => {
            for (1..3) |i| {
                const before = points4[i - 1];
                const corner = points4[i];
                const after = points4[i + 1];
                const incoming = mix(corner, before, 1, -1);
                const outgoing = mix(after, corner, 1, -1);
                const length1 = @sqrt(incoming.x * incoming.x + incoming.y * incoming.y);
                const length2 = @sqrt(outgoing.x * outgoing.x + outgoing.y * outgoing.y);
                if (length1 < 1e-9 or length2 < 1e-9 or @abs(incoming.x * outgoing.y - incoming.y * outgoing.x) < 1e-9) {
                    try out.fmt(" L {d} {d}", .{ corner.x, corner.y });
                    continue;
                }
                const radius = @min(7, @min(length1 / 2, length2 / 2));
                const enter = mix(corner, incoming, 1, -radius / length1);
                const leave = mix(corner, outgoing, 1, radius / length2);
                try out.fmt(" L {d} {d} Q {d} {d} {d} {d}", .{ enter.x, enter.y, corner.x, corner.y, leave.x, leave.y });
            }
            try out.fmt(" L {d} {d}", .{ q.x, q.y });
        },
        .linear => try out.fmt(" L {d} {d} L {d} {d} L {d} {d}", .{ a.x, a.y, b.x, b.y, x2, y2 }),
        .linearClosed => try out.fmt(" L {d} {d} L {d} {d} L {d} {d} Z", .{ a.x, a.y, b.x, b.y, x2, y2 }),
        .monotoneX, .monotoneY => {
            var ps = points4;
            const swap = curve == .monotoneY;
            if (swap) for (&ps) |*pt| {
                pt.* = .{ .x = pt.y, .y = pt.x };
            };
            var tangents: [4]f64 = undefined;
            tangents[1] = slope(ps[0], ps[1], ps[2]);
            tangents[2] = slope(ps[1], ps[2], ps[3]);
            tangents[0] = if (@abs(ps[1].x - ps[0].x) < 1e-9) tangents[1] else (3 * (ps[1].y - ps[0].y) / (ps[1].x - ps[0].x) - tangents[1]) / 2;
            tangents[3] = if (@abs(ps[3].x - ps[2].x) < 1e-9) tangents[2] else (3 * (ps[3].y - ps[2].y) / (ps[3].x - ps[2].x) - tangents[2]) / 2;
            for (0..3) |i| {
                const dx = (ps[i + 1].x - ps[i].x) / 3;
                const c1: Point = .{ .x = ps[i].x + dx, .y = ps[i].y + dx * tangents[i] };
                const c2: Point = .{ .x = ps[i + 1].x - dx, .y = ps[i + 1].y - dx * tangents[i + 1] };
                try cubic(out, if (swap) .{ .x = c1.y, .y = c1.x } else c1, if (swap) .{ .x = c2.y, .y = c2.x } else c2, points4[i + 1]);
            }
        },
        .step => try out.fmt(" L {d} {d} L {d} {d} L {d} {d}", .{ a.x, a.y, b.x, b.y, x2, y2 }),
        .stepBefore => try out.fmt(" V {d} H {d}", .{ y2, x2 }),
        .stepAfter => try out.fmt(" H {d} V {d}", .{ x2, y2 }),
        .natural => {
            const points = [_]Point{ p, a, b, q };
            var first: [3]Point = undefined;
            var second: [3]Point = undefined;
            // Natural cubic spline: solve the tridiagonal system for first controls.
            var rhs = [_]Point{ mix(p, a, 1, 2), mix(a, b, 4, 2), mix(b, q, 4, 0.5) };
            const diagonal = [_]f64{ 2, 3.5, 3.5 - 1.0 / 3.5 };
            rhs[1] = mix(rhs[1], rhs[0], 1, -0.5);
            rhs[2] = mix(rhs[2], rhs[1], 1, -1.0 / 3.5);
            first[2] = mix(rhs[2], rhs[2], 1 / diagonal[2], 0);
            first[1] = mix(rhs[1], first[2], 1 / diagonal[1], -1 / diagonal[1]);
            first[0] = mix(rhs[0], first[1], 0.5, -0.5);
            second[0] = mix(a, first[1], 2, -1);
            second[1] = mix(b, first[2], 2, -1);
            second[2] = mix(q, first[2], 0.5, 0.5);
            for (0..3) |i| try out.fmt(" C {d} {d} {d} {d} {d} {d}", .{ first[i].x, first[i].y, second[i].x, second[i].y, points[i + 1].x, points[i + 1].y });
        },
        .basis, .bundle => {
            const points = [_]Point{ p, p, a, b, q, q };
            const start = mix(p, a, 5.0 / 6.0, 1.0 / 6.0);
            try out.fmt(" L {d} {d}", .{ start.x, start.y });
            for (1..4) |i| {
                const c1 = mix(points[i], points[i + 1], 2.0 / 3.0, 1.0 / 3.0);
                const c2 = mix(points[i], points[i + 1], 1.0 / 3.0, 2.0 / 3.0);
                const end = mix(mix(points[i], points[i + 1], 1.0 / 6.0, 4.0 / 6.0), points[i + 2], 1, 1.0 / 6.0);
                try out.fmt(" C {d} {d} {d} {d} {d} {d}", .{ c1.x, c1.y, c2.x, c2.y, end.x, end.y });
            }
            try out.fmt(" L {d} {d}", .{ q.x, q.y });
        },
        else => try out.fmt(" C {d} {d} {d} {d} {d} {d}", .{ a.x, a.y, b.x, b.y, q.x, q.y }),
    }
    try out.add("\"/>");
}
test "all curve variants handle coincident and reversed route coordinates" {
    const Svg = @import("svg.zig").Svg;
    inline for (std.meta.tags(Curve)) |curve| {
        for ([_][4]usize{ .{ 0, 0, 0, 0 }, .{ 20, 30, 300, 400 }, .{ 300, 400, 20, 30 }, .{ 20, 30, 20, 400 }, .{ 20, 30, 300, 30 } }) |coords| {
            for ([_]bool{ false, true }) |horizontal| {
                var out: Svg = .{ .allocator = std.testing.allocator, .theme = .light };
                defer out.deinit();
                try route(&out, curve, coords[0], coords[1], coords[2], coords[3], horizontal);
                try std.testing.expect(std.mem.indexOf(u8, out.bytes.items, "nan") == null);
                try std.testing.expect(std.mem.indexOf(u8, out.bytes.items, "inf") == null);
                try std.testing.expect(std.mem.startsWith(u8, out.bytes.items, "d=\"M "));
                try std.testing.expect(std.mem.endsWith(u8, out.bytes.items, "\"/>"));
            }
        }
    }
}
pub const Link = struct { start: Marker = .none, end: Marker = .none, stroke: Stroke = .normal, length: usize = 1, label: []const u8 = "", markdown: bool = false };
const Error = error{ UnsupportedSyntax, InvalidSyntax, LimitExceeded };
fn marker(ch: u8) Marker {
    return switch (ch) {
        '>', '<' => .arrow,
        'o' => .circle,
        'x' => .cross,
        else => .none,
    };
}
fn skip(source: []const u8, pos: *usize) void {
    while (pos.* < source.len and (source[pos.*] == ' ' or source[pos.*] == '\t')) pos.* += 1;
}

// A terminal stroke is either a whole link, or the closing half of a labelled link.
fn terminal(source: []const u8, pos: *usize) Error!?Link {
    var at = pos.*;
    if (at >= source.len) return null;
    var result: Link = .{};
    if (source[at] == '<' or source[at] == 'o' or source[at] == 'x') {
        result.start = marker(source[at]);
        at += 1;
    }
    if (at >= source.len) return null;
    const begin = at;
    if (source[at] == '-' and at + 1 < source.len and source[at + 1] == '.') at += 1;
    if (source[at] == '.') {
        result.stroke = .dotted;
        const dots = at;
        while (at < source.len and source[at] == '.') at += 1;
        result.length = at - dots;
        if (at == source.len or source[at] != '-') return null;
        at += 1;
        if (at < source.len and source[at] != '<' and marker(source[at]) != .none) {
            result.end = marker(source[at]);
            at += 1;
        }
    } else {
        const ch = source[at];
        if (ch != '-' and ch != '=' and ch != '~') return null;
        while (at < source.len and source[at] == ch) at += 1;
        const count = at - begin;
        if (ch != '~' and at < source.len and source[at] != '<' and marker(source[at]) != .none) {
            result.end = marker(source[at]);
            at += 1;
        }
        const minimum: usize = if (result.end == .none) 3 else 2;
        if (count < minimum) return null;
        result.length = count - minimum + 1;
        result.stroke = if (ch == '=') .thick else if (ch == '~') .invisible else .normal;
    }
    if (result.start != .none and result.start != result.end) return error.UnsupportedSyntax;
    if (result.stroke == .invisible and (result.start != .none or result.end != .none)) return error.UnsupportedSyntax;
    if (result.length > 16) return error.LimitExceeded;
    pos.* = at;
    return result;
}

pub fn parse(source: []const u8, pos: *usize) Error!Link {
    skip(source, pos);
    var result: Link = undefined;
    if (try terminal(source, pos)) |complete| {
        result = complete;
    } else {
        var start_marker: Marker = .none;
        if (pos.* < source.len and (source[pos.*] == '<' or source[pos.*] == 'o' or source[pos.*] == 'x')) {
            start_marker = marker(source[pos.*]);
            pos.* += 1;
        }
        const rest = source[pos.*..];
        const stroke: Stroke = if (std.mem.startsWith(u8, rest, "--")) .normal else if (std.mem.startsWith(u8, rest, "==")) .thick else if (std.mem.startsWith(u8, rest, "-.")) .dotted else return error.UnsupportedSyntax;
        pos.* += 2;
        const label_start = pos.*;
        var quoted = false;
        var found = false;
        while (pos.* < source.len) : (pos.* += 1) {
            if (source[pos.*] == '"') quoted = !quoted;
            if (quoted) continue;
            // Letters in unspaced labels (e.g. --No-->) are text, not
            // start markers for the closing half of the link.
            if (source[pos.*] != '-' and source[pos.*] != '=' and source[pos.*] != '.') continue;
            var end = pos.*;
            if (try terminal(source, &end)) |closing| {
                if (closing.stroke != stroke or closing.start != .none or (start_marker != .none and start_marker != closing.end)) return error.UnsupportedSyntax;
                result = closing;
                result.start = start_marker;
                result.label = std.mem.trim(u8, source[label_start..pos.*], " \t");
                pos.* = end;
                found = true;
                break;
            }
        }
        if (!found) return error.UnsupportedSyntax;
    }
    skip(source, pos);
    if (pos.* < source.len and source[pos.*] == '|') {
        if (result.label.len != 0) return error.UnsupportedSyntax;
        pos.* += 1;
        const begin = pos.*;
        var quoted = false;
        while (pos.* < source.len) : (pos.* += 1) {
            if (source[pos.*] == '"') quoted = !quoted;
            if (!quoted and source[pos.*] == '|') break;
        }
        if (pos.* == source.len) return error.InvalidSyntax;
        result.label = std.mem.trim(u8, source[begin..pos.*], " \t");
        pos.* += 1;
    }
    if (result.label.len >= 2 and result.label[0] == '"' and result.label[result.label.len - 1] == '"') result.label = result.label[1 .. result.label.len - 1];
    if (result.label.len > 512) return error.LimitExceeded;
    if (result.stroke == .invisible and result.label.len > 0) return error.UnsupportedSyntax;
    return result;
}

test "link grammar carries stroke endpoints labels and minimum rank length" {
    const cases = .{
        .{ "-->", Stroke.normal, Marker.none, Marker.arrow, @as(usize, 1), "" },
        .{ "<---->", Stroke.normal, Marker.arrow, Marker.arrow, @as(usize, 3), "" },
        .{ "o--o", Stroke.normal, Marker.circle, Marker.circle, @as(usize, 1), "" },
        .{ "x==x", Stroke.thick, Marker.cross, Marker.cross, @as(usize, 1), "" },
        .{ "-. text ...->", Stroke.dotted, Marker.none, Marker.arrow, @as(usize, 3), "text" },
        .{ "== heavy ===>", Stroke.thick, Marker.none, Marker.arrow, @as(usize, 2), "heavy" },
        .{ "-- open ----", Stroke.normal, Marker.none, Marker.none, @as(usize, 2), "open" },
        .{ "--No-->", Stroke.normal, Marker.none, Marker.arrow, @as(usize, 1), "No" },
        .{ "--Yes-->", Stroke.normal, Marker.none, Marker.arrow, @as(usize, 1), "Yes" },
        .{ "==box==>", Stroke.thick, Marker.none, Marker.arrow, @as(usize, 1), "box" },
        .{ "~~~", Stroke.invisible, Marker.none, Marker.none, @as(usize, 1), "" },
    };
    inline for (cases) |case| {
        var pos: usize = 0;
        const link = try parse(case[0], &pos);
        try std.testing.expectEqual(case[0].len, pos);
        try std.testing.expectEqual(case[1], link.stroke);
        try std.testing.expectEqual(case[2], link.start);
        try std.testing.expectEqual(case[3], link.end);
        try std.testing.expectEqual(case[4], link.length);
        try std.testing.expectEqualStrings(case[5], link.label);
    }
}
