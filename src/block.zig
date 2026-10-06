const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const flow = @import("flowchart.zig");
const shapes = @import("flow_shapes.zig");
const paint = @import("flow_paint.zig");
const compound = @import("flow_compound.zig");
const getNode = @import("class.zig").getNode;
const Slot = struct { node: ?usize = null, span: usize = 1, row: usize = 0, col: usize = 0 };
const Scope = struct { node: ?usize = null, slots: std.ArrayList(Slot) = .empty, columns: usize = 0, used_columns: usize = 1, rows: usize = 0, cw: usize = 120, w: usize = 0, h: usize = 0, row_heights: [256]usize = .{0} ** 256 };
fn integer(s: []const u8) d.Error!usize {
    const n = std.fmt.parseInt(usize, d.trim(s), 10) catch return error.InvalidSyntax;
    if (n == 0 or n > 256) return error.LimitExceeded;
    return n;
}
fn identifier(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '.' or s[i] == '-' or s[i] >= 128)) : (i += 1) {}
    return s[0..i];
}
fn linkLine(s: []const u8) bool {
    var quote = false;
    var brackets: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '"') quote = !quote;
        if (quote) continue;
        if (c == '[' or c == '(' or c == '{') brackets += 1;
        if ((c == ']' or c == ')' or c == '}') and brackets > 0) brackets -= 1;
        if (brackets == 0 and i + 1 < s.len and (std.mem.startsWith(u8, s[i..], "--") or std.mem.startsWith(u8, s[i..], "==") or std.mem.startsWith(u8, s[i..], "-.") or std.mem.startsWith(u8, s[i..], "~~~"))) return true;
    }
    return false;
}
fn token(rest: *[]const u8) d.Error![]const u8 {
    rest.* = d.trim(rest.*);
    var i: usize = 0;
    var depth: usize = 0;
    var quote = false;
    while (i < rest.len) : (i += 1) {
        const c = rest.*[i];
        if (c == '"') quote = !quote;
        if (!quote) {
            if (depth == 0 and std.ascii.isWhitespace(c)) break;
            if (c == '[' or c == '(' or c == '{') depth += 1;
            if (c == '>' and depth == 0 and i > 0 and std.ascii.isAlphanumeric(rest.*[i - 1])) depth += 1;
            if (c == ']' or c == ')' or c == '}') {
                if (depth == 0) return error.InvalidSyntax;
                depth -= 1;
            }
        }
    }
    if (quote or depth > 0) return error.InvalidSyntax;
    const result = rest.*[0..i];
    rest.* = d.trim(rest.*[i..]);
    return result;
}
fn measure(scopes: []Scope, index: usize, nodes: []flow.Node, scope_for: []usize, arrows: []u4, depth: usize) d.Error!void {
    if (depth > 16) return error.LimitExceeded;
    var scope = &scopes[index];
    var span_sum: usize = 0;
    for (scope.slots.items) |slot| span_sum += slot.span;
    if (scope.columns == 0) scope.columns = @max(1, span_sum);
    if (scope.columns > 256) return error.LimitExceeded;
    var row: usize = 0;
    var col: usize = 0;
    scope.cw = 120;
    scope.used_columns = scope.columns;
    for (scope.slots.items) |*slot| {
        if (col > 0 and col + slot.span > scope.columns) {
            row += 1;
            col = 0;
        }
        if (row >= 256) return error.LimitExceeded;
        slot.row = row;
        slot.col = col;
        col += slot.span;
        scope.used_columns = @max(scope.used_columns, col);
        var w: usize = 100;
        var h: usize = 70;
        if (slot.node) |id| {
            var n = &nodes[id];
            if (n.container) {
                try measure(scopes, scope_for[id], nodes, scope_for, arrows, depth + 1);
                n.w = scopes[scope_for[id]].w;
                n.h = scopes[scope_for[id]].h;
            } else {
                n.w = @max(120, n.style.measure(paint.labelWidth(n.label, n.markdown)) + 48);
                n.h = @max(70, n.style.measure(paint.labelHeight(n.label)) + 40);
                if (n.shape == .diamond or n.shape == .hexagon or arrows[id] != 0) n.w = n.style.measure(paint.labelWidth(n.label, n.markdown)) * 2 + 80;
                if (shapes.circular(n.shape)) {
                    n.w = @max(n.w, n.h);
                    n.h = n.w;
                }
                if (arrows[id] != 0) n.h = @max(90, n.style.measure(paint.labelHeight(n.label)) * 2 + 50);
            }
            w = n.w;
            h = n.h;
        }
        scope.cw = @max(scope.cw, (w + slot.span - 1) / slot.span);
        scope.row_heights[row] = @max(scope.row_heights[row], h);
    }
    scope.rows = if (scope.slots.items.len == 0) 1 else row + 1;
    scope.w = 80 + scope.used_columns * scope.cw + (scope.used_columns - 1) * 32;
    scope.h = 80 + (scope.rows - 1) * 32;
    for (scope.row_heights[0..scope.rows]) |rh| scope.h += @max(rh, 70);
}
fn place(scopes: []Scope, index: usize, nodes: []flow.Node, scope_for: []usize, dx: usize, dy: usize, width: usize) void {
    const scope = scopes[index];
    const cw = (width - 80 - (scope.used_columns - 1) * 32) / scope.used_columns;
    for (scope.slots.items) |slot| if (slot.node) |id| {
        var n = &nodes[id];
        const span_width = slot.span * cw + (slot.span - 1) * 32;
        const x = dx + 40 + slot.col * (cw + 32);
        var y = dy + 40;
        for (0..slot.row) |r| y += @max(scope.row_heights[r], 70) + 32;
        n.x = x;
        n.y = y + (@max(scope.row_heights[slot.row], 70) - n.h) / 2;
        if (shapes.circular(n.shape)) n.x += (span_width - n.w) / 2 else n.w = span_width;
        if (n.container) place(scopes, scope_for[id], nodes, scope_for, n.x, n.y, n.w);
    };
}
fn arrow(out: *svg.Svg, n: flow.Node, mask: u4) !void {
    try paint.begin(out, n.style);
    try out.fmt("<g data-block-arrow=\"{d}\" transform=\"translate({d} {d}) scale({d:.5} {d:.5})\"><path vector-effect=\"non-scaling-stroke\" d=\"M 20 20 ", .{ mask, n.x, n.y, @as(f64, @floatFromInt(n.w)) / 100, @as(f64, @floatFromInt(n.h)) / 100 });
    try out.add(if (mask & 1 != 0) "L 40 20 L 40 12 L 28 12 L 50 0 L 72 12 L 60 12 L 60 20 " else "");
    try out.add("L 80 20 ");
    try out.add(if (mask & 2 != 0) "L 80 40 L 88 40 L 88 28 L 100 50 L 88 72 L 88 60 L 80 60 " else "");
    try out.add("L 80 80 ");
    try out.add(if (mask & 4 != 0) "L 60 80 L 60 88 L 72 88 L 50 100 L 28 88 L 40 88 L 40 80 " else "");
    try out.add("L 20 80 ");
    try out.add(if (mask & 8 != 0) "L 20 60 L 12 60 L 12 72 L 0 50 L 12 28 L 12 40 L 20 40 " else "");
    try out.add("Z\"/></g>");
    try paint.text(out, n.x + n.w / 2, n.y + (n.h - n.style.measure(paint.labelHeight(n.label))) / 2, n.label, n.style);
    try out.add("</g>");
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var graph: flow.Parser = .{ .allocator = temp, .kind = "block" };
    defer graph.deinit();
    var scopes: std.ArrayList(Scope) = .empty;
    try scopes.append(temp, .{});
    var scope_for = [_]usize{0} ** 256;
    var placed = [_]bool{false} ** 256;
    var arrows = [_]u4{0} ** 256;
    var stack: [17]usize = undefined;
    stack[0] = 0;
    var depth: usize = 0;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r;");
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        const current = stack[depth];
        if (std.mem.eql(u8, line, "end")) {
            if (depth == 0) return error.InvalidSyntax;
            depth -= 1;
            continue;
        }
        if (txt.starts(line, "columns ")) {
            const count = d.trim(line[8..]);
            scopes.items[current].columns = if (std.mem.eql(u8, count, "auto")) 0 else try integer(count);
            continue;
        }
        if (txt.starts(line, "style ") or txt.starts(line, "classDef ") or txt.starts(line, "class ") or linkLine(line)) {
            const previous = graph.nodes.items.len;
            try graph.statement(line);
            for (previous..graph.nodes.items.len) |id| {
                scope_for[id] = current;
                graph.nodes.items[id].parent = scopes.items[current].node;
            }
            continue;
        }
        if (std.mem.eql(u8, line, "block") or txt.starts(line, "block:") or txt.starts(line, "block ")) {
            if (depth == 16) return error.LimitExceeded;
            var rest = if (line.len > 5) line[6..] else "";
            const name = if (rest.len > 0) identifier(rest) else try std.fmt.allocPrint(temp, "block_{d}", .{scopes.items.len});
            if (name.len == 0) return error.InvalidSyntax;
            if (rest.len > 0) rest = rest[name.len..];
            const span = if (rest.len == 0) @as(usize, 1) else if (rest[0] == ':') try integer(rest[1..]) else return error.InvalidSyntax;
            const id = try getNode(&graph, name, scopes.items[current].node, false);
            if (placed[id]) return error.InvalidSyntax;
            placed[id] = true;
            graph.nodes.items[id].container = true;
            if (scopes.items[current].slots.items.len == 512) return error.LimitExceeded;
            try scopes.items[current].slots.append(temp, .{ .node = id, .span = span });
            scope_for[id] = scopes.items.len;
            try scopes.append(temp, .{ .node = id });
            depth += 1;
            stack[depth] = scopes.items.len - 1;
            continue;
        }
        var rest = line;
        while (rest.len > 0) {
            if (txt.starts(rest, "%%")) break;
            var item = try token(&rest);
            if (item.len == 0) return error.InvalidSyntax;
            const name = identifier(item);
            if (name.len == 0) return error.InvalidSyntax;
            for (graph.nodes.items, 0..) |node, ni| if (placed[ni] and std.mem.eql(u8, node.id, name) and node.parent != scopes.items[current].node) return error.InvalidSyntax;
            var span: usize = 1;
            // Span suffixes occur after the complete shape, outside quoted labels.
            if (std.mem.lastIndexOfScalar(u8, item, ':')) |colon| {
                const tail = item[colon + 1 ..];
                var numeric = tail.len > 0;
                for (tail) |c| if (!std.ascii.isDigit(c)) {
                    numeric = false;
                };
                if (numeric) {
                    span = try integer(tail);
                    item = item[0..colon];
                }
            }
            if (std.mem.eql(u8, name, "space")) {
                if (item.len != name.len) return error.InvalidSyntax;
                if (scopes.items[current].slots.items.len == 512) return error.LimitExceeded;
                try scopes.items[current].slots.append(temp, .{ .span = span });
                continue;
            }
            var id: usize = undefined;
            if (txt.starts(item[name.len..], "<[")) {
                const close = std.mem.indexOf(u8, item, "]>(") orelse return error.InvalidSyntax;
                if (!std.mem.endsWith(u8, item, ")")) return error.InvalidSyntax;
                id = try getNode(&graph, name, scopes.items[current].node, false);
                const raw_label = d.unquote(item[name.len + 2 .. close]);
                var decoded: std.ArrayList(u8) = .empty;
                var parts = std.mem.splitSequence(u8, raw_label, "&nbsp;");
                try decoded.appendSlice(temp, parts.next().?);
                while (parts.next()) |part| {
                    try decoded.appendSlice(temp, "#nbsp;");
                    try decoded.appendSlice(temp, part);
                }
                graph.nodes.items[id].label = try txt.parse(temp, decoded.items);
                var directions = std.mem.splitScalar(u8, item[close + 3 .. item.len - 1], ',');
                var mask: u4 = 0;
                while (directions.next()) |value| {
                    const v = d.trim(value);
                    mask |= if (std.mem.eql(u8, v, "up")) @as(u4, 1) else if (std.mem.eql(u8, v, "right")) 2 else if (std.mem.eql(u8, v, "down")) 4 else if (std.mem.eql(u8, v, "left")) 8 else if (std.mem.eql(u8, v, "x")) 10 else if (std.mem.eql(u8, v, "y")) 5 else return error.InvalidSyntax;
                }
                arrows[id] = mask;
            } else {
                try graph.statement(item);
                id = try getNode(&graph, name, scopes.items[current].node, false);
            }
            if (!placed[id]) {
                placed[id] = true;
                graph.nodes.items[id].parent = scopes.items[current].node;
                if (scopes.items[current].slots.items.len == 512) return error.LimitExceeded;
                try scopes.items[current].slots.append(temp, .{ .node = id, .span = span });
            } else if (span != 1) {
                for (scopes.items[current].slots.items) |*slot| if (slot.node == id) {
                    slot.span = span;
                };
            }
        }
    }
    if (depth != 0 or graph.nodes.items.len == 0) return error.InvalidSyntax;
    for (placed[0..graph.nodes.items.len], 0..) |v, id| if (!v) {
        const scope = &scopes.items[scope_for[id]];
        if (scope.slots.items.len == 512) return error.LimitExceeded;
        try scope.slots.append(temp, .{ .node = id });
    };
    try graph.resolveStyles();
    try doc.graphTheme(&graph);
    try measure(scopes.items, 0, graph.nodes.items, &scope_for, &arrows, 0);
    place(scopes.items, 0, graph.nodes.items, &scope_for, 0, 0, scopes.items[0].w);
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(scopes.items[0].w, scopes.items[0].h, "block", prefix);
    try out.flowMarkers(prefix);
    // Scope creation order is parent-before-child.
    for (scopes.items[1..]) |scope| {
        const n = graph.nodes.items[scope.node.?];
        try paint.begin(&out, n.style);
        try out.fmt("<rect data-block-group=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" fill=\"{s}\"/>", .{ scope.node.?, n.x, n.y, n.w, n.h, n.style.fill orelse if (doc.theme == .dark) "#1b2638" else "#f4f6f9" });
        try out.add("</g>");
    }
    try compound.drawEdges(&out, &graph, prefix);
    for (graph.nodes.items, 0..) |n, i| if (!n.container) {
        try out.fmt("<g data-block-node=\"{d}\" data-parent=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\">", .{ i, n.parent orelse 256, n.x, n.y, n.w, n.h });
        if (arrows[i] != 0) try arrow(&out, n, arrows[i]) else try paint.node(&out, n, n.w, n.h);
        try out.add("</g>");
    };
    return out.finish();
}
