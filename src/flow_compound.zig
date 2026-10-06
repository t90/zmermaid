const std = @import("std");
const svg = @import("svg.zig");
const shapes = @import("flow_shapes.zig");
const txt = @import("sequence_text.zig");
const paint = @import("flow_paint.zig");
const Error = txt.Error;
pub fn validDirection(dir: []const u8) bool {
    for ([_][]const u8{ "LR", "RL", "TD", "TB", "BT" }) |d| if (std.mem.eql(u8, d, dir)) return true;
    return false;
}
fn belongs(nodes: anytype, id: usize, parent: usize) bool {
    var at: ?usize = id;
    var depth: usize = 0;
    while (at) |i| : (depth += 1) {
        if (depth > 16) return false;
        if (i == parent) return true;
        at = nodes[i].parent;
    }
    return false;
}
fn representative(nodes: anytype, id: usize, parent: ?usize) ?usize {
    if (nodes[id].note_for != null) return null;
    var at = id;
    var depth: usize = 0;
    while (nodes[at].parent != parent) : (depth += 1) {
        if (depth > 16) return null;
        at = nodes[at].parent orelse return null;
    }
    return at;
}
const Size = struct { w: usize, h: usize };
fn layout(parser: anytype, parent: ?usize, inherited: []const u8, depth: usize) Error!Size {
    if (depth > 16) return error.LimitExceeded;
    var direction = inherited;
    if (parent) |p| {
        direction = parser.nodes.items[p].direction orelse if (!parser.inherit_direction and std.mem.eql(u8, parser.kind, "flowchart")) "TB" else inherited;
        // Mermaid ignores a local direction when an external edge touches a member.
        for (parser.edges.items) |edge| {
            if (std.mem.eql(u8, parser.kind, "state")) break;
            const inside_from = edge.from != p and belongs(parser.nodes.items, edge.from, p);
            const inside_to = edge.to != p and belongs(parser.nodes.items, edge.to, p);
            if (inside_from != inside_to and edge.from != p and edge.to != p) {
                direction = inherited;
                break;
            }
        }
    }
    const horizontal = std.mem.eql(u8, direction, "LR") or std.mem.eql(u8, direction, "RL");
    const reverse = std.mem.eql(u8, direction, "RL") or std.mem.eql(u8, direction, "BT");
    var ids: [256]usize = undefined;
    var count: usize = 0;
    var cell_w: usize = 144;
    var cell_h: usize = 80;
    for (parser.edges.items) |edge| if (paint.hasMedia(edge.link.label)) {
        cell_w = @max(cell_w, edge.style.measure(paint.labelWidth(edge.link.label, edge.link.markdown)) + 48);
        cell_h = @max(cell_h, edge.style.measure(paint.labelHeight(edge.link.label)) + 40);
    };
    for (0..parser.nodes.items.len) |i| {
        if (parser.nodes.items[i].parent != parent) continue;
        if (parser.nodes.items[i].note_for != null) {
            parser.nodes.items[i].w = @max(160, parser.nodes.items[i].style.measure(txt.width(parser.nodes.items[i].label)) + 40);
            parser.nodes.items[i].h = parser.nodes.items[i].style.measure(paint.labelHeight(parser.nodes.items[i].label)) + 40;
            continue;
        }
        ids[count] = i;
        count += 1;
        var size: Size = undefined;
        if (parser.nodes.items[i].container) {
            size = try layout(parser, i, direction, depth + 1);
        } else {
            const node = parser.nodes.items[i];
            const measured = @import("flow_layout.zig").nodeSize(node);
            size = .{ .w = measured.w, .h = measured.h };
            if (node.asset != null) {
                size.w = @max(size.w, node.asset_width + 64);
                size.h = @max(size.h, node.asset_height + node.style.measure(paint.labelHeight(node.label)) + 64);
            }
            if (node.table) {
                size.w = @max(80, node.style.measure(paint.labelWidth(node.label, node.markdown)) + 32);
                size.w = @max(size.w, node.style.measure(txt.width(node.annotation)) + 40);
                size.h = node.style.measure(paint.labelHeight(node.label)) + 28 + (if (node.annotation.len > 0) node.style.measure(paint.labelHeight(node.annotation)) + 8 else @as(usize, 0));
                for (node.members.items) |member| {
                    size.w = @max(size.w, node.style.measure(paint.labelWidth(member.text, member.markdown or node.markdown)) + 32);
                    size.h += node.style.measure(paint.labelHeight(member.text)) + 12;
                }
                if (node.members.items.len == 0 and !node.hide_empty) size.h += 40;
                size.h += if (node.entity and node.members.items.len == 0) @as(usize, 0) else 16;
                if (node.entity and node.members.items.len > 0) {
                    var columns = [_]usize{ 0, 0, 0, 0 };
                    for (node.members.items) |member| for (member.cells, 0..) |cell, c| {
                        if (cell.len > 0) columns[c] = @max(columns[c], node.style.measure(txt.width(cell)) + 24);
                    };
                    var sum: usize = 0;
                    for (columns) |cw| sum += cw;
                    size.w = @max(size.w, sum);
                    columns[1] += size.w - sum;
                    parser.nodes.items[i].columns = columns;
                }
            }
            if (shapes.circular(node.shape)) {
                size.w = @max(size.w, size.h);
                size.h = size.w;
            }
        }
        parser.nodes.items[i].w = size.w;
        parser.nodes.items[i].h = size.h;
        parser.nodes.items[i].rank = 0;
        cell_w = @max(cell_w, size.w);
        cell_h = @max(cell_h, size.h + if (shapes.externalLabel(parser.nodes.items[i].shape)) parser.nodes.items[i].style.measure(paint.labelHeight(parser.nodes.items[i].label)) + 8 else @as(usize, 0));
        var note_stack: usize = 0;
        for (parser.nodes.items) |note| if (note.note_for == i) {
            cell_w = @max(cell_w, size.w + 2 * (@max(160, note.style.measure(txt.width(note.label)) + 40) + 40));
            note_stack += note.style.measure(paint.labelHeight(note.label)) + 52;
        };
        cell_h = @max(cell_h, note_stack);
    }
    const title_height = if (parent) |p| (if (parser.nodes.items[p].region) @as(usize, 0) else parser.nodes.items[p].style.measure(paint.labelHeight(parser.nodes.items[p].label)) + 20 + parser.title_margin_top + parser.title_margin_bottom) else @as(usize, 0);
    if (count == 0) return .{ .w = if (parent) |p| @max(180, parser.nodes.items[p].style.measure(paint.labelWidth(parser.nodes.items[p].label, parser.nodes.items[p].markdown)) + 80) else 180, .h = title_height + 80 };
    var done = [_]bool{false} ** 256;
    for (0..count) |_| {
        var candidate: ?usize = null;
        for (ids[0..count]) |id| {
            if (done[id]) continue;
            var incoming = false;
            for (parser.edges.items) |edge| {
                const from = representative(parser.nodes.items, edge.from, parent) orelse continue;
                const to = representative(parser.nodes.items, edge.to, parent) orelse continue;
                if (to == id and from != to and !done[from]) incoming = true;
            }
            if (!incoming) {
                candidate = id;
                break;
            }
        }
        if (candidate == null) for (ids[0..count]) |id| {
            if (!done[id]) {
                candidate = id;
                break;
            }
        };
        const id = candidate.?;
        done[id] = true;
        for (parser.edges.items) |edge| {
            const from = representative(parser.nodes.items, edge.from, parent) orelse continue;
            const to = representative(parser.nodes.items, edge.to, parent) orelse continue;
            if (from == id and from != to and !done[to]) parser.nodes.items[to].rank = @max(parser.nodes.items[to].rank, parser.nodes.items[from].rank + edge.link.length);
        }
    }
    var lanes = [_]usize{0} ** 4096;
    var max_rank: usize = 0;
    var max_lanes: usize = 1;
    for (ids[0..count]) |id| {
        const rank = parser.nodes.items[id].rank;
        max_rank = @max(max_rank, rank);
        lanes[rank] += 1;
        max_lanes = @max(max_lanes, lanes[rank]);
    }
    const padding = if (parent == null) parser.diagram_padding else 24;
    var width: usize = 0;
    var height: usize = 0;
    var has_notes = false;
    for (parser.nodes.items) |node| if (node.parent == parent and node.note_for != null) {
        has_notes = true;
    };
    if (!has_notes) {
        var rank_gap = parser.rank_spacing;
        for (parser.edges.items) |edge| {
            const from = representative(parser.nodes.items, edge.from, parent) orelse continue;
            const to = representative(parser.nodes.items, edge.to, parent) orelse continue;
            if (from == to or edge.link.label.len == 0) continue;
            const extent = if (horizontal) paint.labelWidth(edge.link.label, edge.link.markdown) else paint.labelHeight(edge.link.label);
            rank_gap = @max(rank_gap, edge.style.measure(extent) + 24);
        }
        const placement = @import("flow_layout.zig").place(parser.nodes.items, ids[0..count], horizontal, reverse, parser.node_spacing, rank_gap, null, null);
        width = placement.w + padding * 2;
        height = placement.h + padding * 2 + title_height;
        for (ids[0..count]) |id| {
            parser.nodes.items[id].x += padding;
            parser.nodes.items[id].y += padding + title_height;
        }
    } else {
        // Notes retain dedicated slots so packing cannot overlap their target's peers.
        lanes = @splat(0);
        width = 2 * padding + (if (horizontal) (max_rank + 1) * (cell_w + parser.rank_spacing) else max_lanes * (cell_w + parser.node_spacing));
        height = 2 * padding + title_height + (if (horizontal) max_lanes * (cell_h + parser.node_spacing) else (max_rank + 1) * (cell_h + parser.rank_spacing));
        for (ids[0..count]) |id| {
            const node = &parser.nodes.items[id];
            const rank = if (reverse) max_rank - node.rank else node.rank;
            const lane = lanes[node.rank];
            lanes[node.rank] += 1;
            node.x = padding + (if (horizontal) rank * (cell_w + parser.rank_spacing) else lane * (cell_w + parser.node_spacing)) + (cell_w - node.w) / 2;
            node.y = padding + title_height + (if (horizontal) lane * (cell_h + parser.node_spacing) else rank * (cell_h + parser.rank_spacing)) + (cell_h - node.h) / 2;
        }
    }
    for (parser.edges.items) |edge| if (edge.from == edge.to and parser.nodes.items[edge.from].parent == parent) {
        const node = parser.nodes.items[edge.from];
        width = @max(width, node.x + node.w + @max(72, edge.style.measure(paint.labelWidth(edge.link.label, edge.link.markdown)) + 32));
        height = @max(height, node.y + node.h + @max(72, edge.style.measure(paint.labelHeight(edge.link.label)) + 24));
    };
    var left_space: usize = 0;
    for (parser.nodes.items) |node| if (node.parent == parent and node.note_for != null and node.note_left) {
        left_space = @max(left_space, node.w + 40);
    };
    for (ids[0..count]) |id| parser.nodes.items[id].x += left_space;
    width += left_space;
    for (parser.nodes.items, 0..) |*note, i| {
        if (note.parent != parent) continue;
        const target = note.note_for orelse continue;
        const node = parser.nodes.items[target];
        note.x = if (note.note_left) node.x - note.w - 32 else node.x + node.w + 32;
        note.y = node.y;
        for (parser.nodes.items[0..i]) |previous| if (previous.note_for == target and previous.note_left == note.note_left) {
            note.y = @max(note.y, previous.y + previous.h + 12);
        };
        width = @max(width, note.x + note.w + padding);
        height = @max(height, note.y + note.h + padding);
    }
    return .{ .w = if (parent) |p| @max(width, parser.nodes.items[p].style.measure(paint.labelWidth(parser.nodes.items[p].label, parser.nodes.items[p].markdown)) + 80) else width, .h = height };
}
fn absolute(nodes: anytype, parent: ?usize, dx: usize, dy: usize, depth: usize) Error!void {
    if (depth > 16) return error.LimitExceeded;
    for (0..nodes.len) |i| if (nodes[i].parent == parent) {
        nodes[i].x += dx;
        nodes[i].y += dy;
        if (nodes[i].container) try absolute(nodes, i, nodes[i].x, nodes[i].y, depth + 1);
    };
}
pub fn drawEdges(out: *svg.Svg, parser: anytype, prefix: u32) Error!void {
    for (parser.edges.items, 0..) |edge, i| {
        if (edge.link.stroke == .invisible) continue;
        try paint.begin(out, edge.style);
        const from = parser.nodes.items[edge.from];
        const to = parser.nodes.items[edge.to];
        const dx = @as(i64, @intCast(to.x + to.w / 2)) - @as(i64, @intCast(from.x + from.w / 2));
        const dy = @as(i64, @intCast(to.y + to.h / 2)) - @as(i64, @intCast(from.y + from.h / 2));
        const entity = std.mem.eql(u8, parser.kind, "entity");
        var horizontal = @abs(dx) > @abs(dy);
        if (entity) {
            // With variable-width boxes, center distances can select a side
            // that points into an overlapping box. Prefer the actual clear gap.
            const gap_x = @as(i64, @intCast(@max(from.x, to.x))) - @as(i64, @intCast(@min(from.x + from.w, to.x + to.w)));
            const gap_y = @as(i64, @intCast(@max(from.y, to.y))) - @as(i64, @intCast(@min(from.y + from.h, to.y + to.h)));
            horizontal = gap_x > gap_y;
            if (from.rank != to.rank) horizontal = parser.entity_horizontal;
        }
        const side: shapes.Side = if (horizontal) (if (dx >= 0) .right else .left) else (if (dy >= 0) .bottom else .top);
        const opposite: shapes.Side = switch (side) {
            .left => .right,
            .right => .left,
            .top => .bottom,
            .bottom => .top,
        };
        const p = shapes.anchor(from.shape, from.x, from.y, from.w, from.h, side);
        const q = shapes.anchor(to.shape, to.x, to.y, to.w, to.h, opposite);
        try out.fmt("<path data-edge=\"{d}\" fill=\"none\"", .{i});
        try @import("interaction.zig").classAttribute(out, edge.classes);
        if (edge.id.len > 0) try out.fmt(" id=\"zm-{d}-edge-{s}\" data-edge-id=\"{s}\"", .{ prefix, edge.id, edge.id });
        if (edge.link.start != .none) try out.fmt(" marker-start=\"url(#zm-{d}-{s})\"", .{ prefix, @tagName(edge.link.start) });
        if (edge.link.end != .none) try out.fmt(" marker-end=\"url(#zm-{d}-{s})\"", .{ prefix, @tagName(edge.link.end) });
        if (edge.link.stroke == .dotted and edge.style.dash == null) try out.add(" stroke-dasharray=\"5 4\"");
        if (edge.link.stroke == .thick and edge.style.width == null) try out.add(" stroke-width=\"3\"");
        if (entity and edge.from == edge.to) {
            try out.fmt(" data-terminal-length=\"20\" d=\"M {d} {d} L {d} {d} C {d} {d} {d} {d} {d} {d} L {d} {d}\"/>", .{ from.x + from.w, from.y + from.h / 2, from.x + from.w + 20, from.y + from.h / 2, from.x + from.w + 65, from.y + from.h / 2, from.x + from.w / 2, from.y + from.h + 65, from.x + from.w / 2, from.y + from.h + 20, from.x + from.w / 2, from.y + from.h });
        } else if (edge.from == edge.to) {
            const links = @import("flow_links.zig");
            try out.add(" ");
            try links.terminalCubic(out, links.point(from.x + from.w, from.y + from.h / 2), links.point(from.x + from.w + 65, from.y + from.h / 2), links.point(from.x + from.w / 2, from.y + from.h + 65), links.point(from.x + from.w / 2, from.y + from.h));
            try out.add("/>");
        } else {
            try out.add(" ");
            if (entity) try @import("flow_links.zig").relationshipRoute(out, p.x, p.y, q.x, q.y, horizontal) else try @import("flow_links.zig").route(out, edge.curve, p.x, p.y, q.x, q.y, horizontal);
        }
        if (!entity and edge.link.label.len > 0) {
            const lw = edge.style.measure(paint.labelWidth(edge.link.label, edge.link.markdown));
            const lh = edge.style.measure(paint.labelHeight(edge.link.label));
            try paint.textAssets(out, if (edge.from == edge.to) from.x + from.w + 16 + lw / 2 else (p.x + q.x) / 2, if (edge.from == edge.to) from.y + from.h + 12 else (p.y + q.y) / 2 -| lh / 2, edge.link.label, edge.style, edge.link.markdown, parser.assets);
        }
        if (edge.left_label.len > 0) try txt.draw(out, p.x + 20, p.y - 20, edge.left_label);
        if (edge.right_label.len > 0) try txt.draw(out, q.x + 20, q.y + 8, edge.right_label);
        try out.add("</g>");
    }
}
pub fn render(a: std.mem.Allocator, parser: anytype, theme: svg.Theme, prefix: u32, direction: []const u8) Error![]u8 {
    parser.entity_horizontal = std.mem.eql(u8, direction, "LR") or std.mem.eql(u8, direction, "RL");
    const size = try layout(parser, null, direction, 0);
    try absolute(parser.nodes.items, null, 0, 0, 0);
    var out: svg.Svg = .{ .allocator = a, .theme = theme };
    defer out.deinit();
    const image_padding = paint.imageEdgePadding(parser.edges.items);
    const entity = std.mem.eql(u8, parser.kind, "entity");
    const labels = if (entity) @import("er_labels.zig").plan(parser, size.w + image_padding.w, size.h + image_padding.h) else @import("er_labels.zig").Plan{ .w = size.w + image_padding.w, .h = size.h + image_padding.h };
    try out.start(labels.w, labels.h, parser.kind, prefix);
    if (entity) try out.fmt("<style>#zm-{d}-css text{{font-family:Segoe UI,Arial,sans-serif}}</style>", .{prefix});
    try out.flowMarkers(prefix);
    // Parent frames are painted before their children, independent of declaration order.
    for (0..16) |depth| for (parser.nodes.items, 0..) |node, i| {
        if (!node.container) continue;
        var actual: usize = 0;
        var parent = node.parent;
        while (parent) |p| {
            actual += 1;
            parent = parser.nodes.items[p].parent;
        }
        if (actual != depth) continue;
        try @import("interaction.zig").begin(&out, node.action, node.id, node.classes);
        try paint.begin(&out, node.style);
        try out.fmt("<g data-subgraph=\"{d}\" data-parent=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"6\" fill=\"{s}\" fill-opacity=\"0.65\"{s}/>", .{ i, node.parent orelse 256, node.x, node.y, node.w, node.h, node.style.fill orelse if (theme == .dark) "#283349" else if (std.mem.eql(u8, parser.kind, "state")) "#eef4ff" else "#f4f0dc", if (node.region) " stroke-dasharray=\"6 5\"" else "" });
        if (!node.region) try paint.textAssets(&out, node.x + node.w / 2, node.y + 12 + parser.title_margin_top, node.label, node.style, node.markdown, node.assets);
        try out.add("</g></g>");
        try @import("interaction.zig").end(&out, node.action);
    };
    try drawEdges(&out, parser, prefix);
    for (parser.nodes.items, 0..) |node, i| if (!node.container) {
        try out.fmt("<g data-node=\"{d}\" data-parent=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\">", .{ i, node.parent orelse 256, node.x, node.y, node.w, node.h });
        try paint.node(&out, node, node.w, node.h);
        try out.add("</g>");
    };
    if (entity) try @import("er_labels.zig").draw(&out, parser, &labels);
    return out.finish();
}
