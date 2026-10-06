const std = @import("std");
const d = @import("document.zig");
const flow = @import("flowchart.zig");
const compound = @import("flow_compound.zig");
const paint = @import("flow_paint.zig");
const shapes = @import("flow_shapes.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const Lane = struct { id: ?usize, label: []const u8, offset: usize = 0, span: usize = 0, slots: usize = 1 };
fn area(a: flow.Node, b: flow.Node, c: flow.Node) i64 {
    const ax: i64 = @intCast(a.parent orelse 256);
    const bx: i64 = @intCast(b.parent orelse 256);
    const cx: i64 = @intCast(c.parent orelse 256);
    const ay: i64 = @intCast(a.rank);
    const by: i64 = @intCast(b.rank);
    const cy: i64 = @intCast(c.rank);
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
}
fn crossingCost(p: *flow.Parser, node: usize) usize {
    var score: usize = 0;
    for (p.edges.items) |e| {
        if (e.from != node and e.to != node) continue;
        if (e.link.stroke == .invisible) continue;
        for (p.edges.items) |f| {
            if (f.link.stroke == .invisible or e.from == f.from or e.from == f.to or e.to == f.from or e.to == f.to) continue;
            const a = p.nodes.items[e.from];
            const b = p.nodes.items[e.to];
            const c = p.nodes.items[f.from];
            const z = p.nodes.items[f.to];
            const ab_c = area(a, b, c);
            const ab_z = area(a, b, z);
            const cz_a = area(c, z, a);
            const cz_b = area(c, z, b);
            if (ab_c != 0 and ab_z != 0 and cz_a != 0 and cz_b != 0 and (ab_c < 0) != (ab_z < 0) and (cz_a < 0) != (cz_b < 0)) score += 1;
        }
    }
    return score;
}
fn optimizeRanks(p: *flow.Parser, ignore_cross: bool) void {
    var initial: [256]usize = @splat(0);
    var max_rank: usize = 0;
    for (p.nodes.items, 0..) |n, i| {
        initial[i] = n.rank;
        max_rank = @max(max_rank, n.rank);
    }
    // Two bounded coordinate-descent passes. Only strictly fewer crossings
    // justify movement; preserve all forward dependency constraints.
    for (0..2) |_| for (p.nodes.items, 0..) |*n, id| {
        if (n.container) continue;
        var best = n.rank;
        var score = crossingCost(p, id);
        if (score == 0) continue;
        const candidates = [_]usize{ best -| 1, @min(best + 1, max_rank) };
        for (candidates) |candidate| {
            var valid = true;
            for (p.edges.items) |e| {
                if (initial[e.to] <= initial[e.from]) continue;
                if (ignore_cross and p.nodes.items[e.from].parent != p.nodes.items[e.to].parent) continue;
                if (e.from == id and candidate + e.link.length > p.nodes.items[e.to].rank) valid = false;
                if (e.to == id and candidate < p.nodes.items[e.from].rank + e.link.length) valid = false;
            }
            if (!valid) continue;
            n.rank = candidate;
            const cost = crossingCost(p, id);
            if (cost < score) {
                best = candidate;
                score = cost;
            }
        }
        n.rank = best;
    };
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var p: flow.Parser = .{ .allocator = a, .kind = "swimlane", .assets = &doc.assets };
    defer p.deinit();
    const header_end = std.mem.indexOfAny(u8, doc.source, ";\n") orelse doc.source.len;
    var words = std.mem.tokenizeAny(u8, doc.source[0..header_end], " \t\r");
    _ = words.next();
    var direction = words.next() orelse "TB";
    if (words.next() != null) return error.UnsupportedSyntax;
    if (!compound.validDirection(direction)) return error.InvalidSyntax;
    try flow.parseBody(&p, doc.source[@min(header_end + 1, doc.source.len)..], doc);
    direction = p.direction_override orelse direction;
    const horizontal = std.mem.eql(u8, direction, "LR") or std.mem.eql(u8, direction, "RL");
    const reverse = std.mem.eql(u8, direction, "RL") or std.mem.eql(u8, direction, "BT");
    const ignore_cross = try doc.flag("config.swimlane.ignoreCrossLaneEdges", true);
    const optimize = try doc.flag("config.swimlane.optimizeRanksByCrossings", true);
    try doc.graphTheme(&p);
    var lanes: std.ArrayList(Lane) = .empty;
    defer lanes.deinit(a);
    var ungrouped = false;
    var cw: usize = 160;
    var ch: usize = 80;
    var external: usize = 0;
    var header: usize = if (horizontal) 100 else 60;
    for (p.nodes.items, 0..) |n, i| {
        if (n.container) {
            if (n.parent != null) return error.UnsupportedSyntax;
            if (n.direction) |dir| if (!std.mem.eql(u8, dir, direction)) return error.UnsupportedSyntax;
            try lanes.append(a, .{ .id = i, .label = n.label });
            header = @max(header, if (horizontal) n.style.measure(paint.labelWidth(n.label, n.markdown)) + 48 else n.style.measure(paint.labelHeight(n.label)) + 32);
        } else {
            if (n.parent == null) ungrouped = true;
            cw = @max(cw, n.style.measure(paint.labelWidth(n.label, n.markdown)) * 2 + 48);
            ch = @max(ch, n.style.measure(paint.labelHeight(n.label)) * 2 + 40);
            if (n.asset != null) {
                cw = @max(cw, n.asset_width + 64);
                ch = @max(ch, n.asset_height + n.style.measure(paint.labelHeight(n.label)) + 64);
            }
            if (shapes.externalLabel(n.shape)) external = @max(external, n.style.measure(paint.labelHeight(n.label)) + 8);
        }
    }
    for (p.nodes.items) |n| if (shapes.circular(n.shape)) {
        cw = @max(cw, ch);
        ch = cw;
    };
    if (!horizontal) header += p.title_margin_top + p.title_margin_bottom;
    if (ungrouped) try lanes.append(a, .{ .id = null, .label = "Ungrouped" });
    for (p.edges.items) |e| if (p.nodes.items[e.from].container or p.nodes.items[e.to].container) return error.UnsupportedSyntax;
    var done: [256]bool = @splat(false);
    var count: usize = 0;
    for (p.nodes.items, 0..) |n, i| {
        done[i] = n.container;
        if (!n.container) count += 1;
    }
    for (0..count) |_| {
        var selected: ?usize = null;
        for (p.nodes.items, 0..) |_, i| {
            if (done[i]) continue;
            var incoming = false;
            for (p.edges.items) |e| if (e.to == i and e.from != i and !done[e.from]) {
                if (ignore_cross and p.nodes.items[e.from].parent != p.nodes.items[e.to].parent) continue;
                incoming = true;
                break;
            };
            if (!incoming) {
                selected = i;
                break;
            }
        }
        if (selected == null) for (done[0..p.nodes.items.len], 0..) |v, i| {
            if (!v) {
                selected = i;
                break;
            }
        };
        const id = selected.?;
        done[id] = true;
        for (p.edges.items) |e| if (e.from == id and !done[e.to]) {
            if (ignore_cross and p.nodes.items[e.from].parent != p.nodes.items[e.to].parent) continue;
            p.nodes.items[e.to].rank = @max(p.nodes.items[e.to].rank, p.nodes.items[id].rank + e.link.length);
        };
    }
    if (optimize) optimizeRanks(&p, ignore_cross);
    var maxrank: usize = 0;
    var assigned: [256]usize = @splat(0);
    var slot: [256]usize = @splat(0);
    for (p.nodes.items, 0..) |n, i| if (!n.container) {
        maxrank = @max(maxrank, n.rank);
        for (lanes.items, 0..) |lane, l| if (n.parent == lane.id) {
            assigned[i] = l;
            break;
        };
        var offset: usize = 0;
        for (p.nodes.items[0..i], 0..) |other, j| if (!other.container and assigned[j] == assigned[i] and other.rank == n.rank) {
            offset += 1;
        };
        slot[i] = offset;
        lanes.items[assigned[i]].slots = @max(lanes.items[assigned[i]].slots, offset + 1);
    };
    var span: usize = 0;
    for (lanes.items) |*lane| {
        lane.offset = span;
        lane.span = lane.slots * (if (horizontal) ch + external + 80 else cw + 80) + 40;
        const style = if (lane.id) |id| p.nodes.items[id].style else @import("chart_style.zig").Style{};
        if (!horizontal) lane.span = @max(lane.span, style.measure(txt.width(lane.label)) + 48);
        if (horizontal) lane.span = @max(lane.span, style.measure(paint.labelHeight(lane.label)) + 32 + p.title_margin_top + p.title_margin_bottom);
        span += lane.span;
    }
    const step = if (horizontal) cw + 180 else ch + external + 140;
    const length = header + (maxrank + 1) * step + 40;
    const width = if (horizontal) length + 80 else span + 80;
    const height = if (horizontal) span + 80 else length + 80;
    for (p.nodes.items, 0..) |*n, i| if (!n.container) {
        const lane = lanes.items[assigned[i]];
        const rank = if (reverse) maxrank - n.rank else n.rank;
        n.w = cw;
        n.h = ch;
        n.x = if (horizontal) 40 + header + 60 + rank * step else 40 + lane.offset + 40 + slot[i] * (cw + 80);
        n.y = if (horizontal) 40 + lane.offset + 40 + slot[i] * (ch + external + 80) else 40 + header + 50 + rank * step;
    };
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "swimlane", prefix);
    try out.flowMarkers(prefix);
    for (lanes.items, 0..) |lane, i| {
        const x = if (horizontal) 40 else 40 + lane.offset;
        const y = if (horizontal) 40 + lane.offset else 40;
        const w = if (horizontal) length else lane.span;
        const h = if (horizontal) lane.span else length;
        const style = if (lane.id) |id| p.nodes.items[id].style else @import("chart_style.zig").Style{};
        if (lane.id) |id| {
            const n = p.nodes.items[id];
            try @import("interaction.zig").begin(&out, n.action, n.id, n.classes);
        }
        try paint.begin(&out, style);
        try out.fmt("<g data-swimlane=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\"/>", .{ i, x, y, w, h, x, y, w, h, style.fill orelse if (doc.theme == .dark) (if (i % 2 == 0) "#161b22" else "#1c2330") else (if (i % 2 == 0) "#f6f8fa" else "#edf2f8") });
        if (horizontal) try out.fmt("<path d=\"M {d} {d} V {d}\" fill=\"none\"/>", .{ x + header, y, y + h }) else try out.fmt("<path d=\"M {d} {d} H {d}\" fill=\"none\"/>", .{ x, y + header, x + w });
        try paint.textAssets(&out, if (horizontal) x + header / 2 else x + w / 2, y + p.title_margin_top + ((if (horizontal) h else header) - p.title_margin_top - p.title_margin_bottom - style.measure(paint.labelHeight(lane.label))) / 2, lane.label, style, if (lane.id) |id| p.nodes.items[id].markdown else false, &doc.assets);
        try out.add("</g></g>");
        if (lane.id) |id| try @import("interaction.zig").end(&out, p.nodes.items[id].action);
    }
    try compound.drawEdges(&out, &p, prefix);
    for (p.nodes.items, 0..) |n, i| if (!n.container) {
        try out.fmt("<g data-swimlane-node=\"{d}\" data-lane=\"{d}\" data-rank=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\">", .{ i, assigned[i], n.rank, n.x, n.y, n.w, n.h });
        try paint.node(&out, n, n.w, n.h);
        try out.add("</g>");
    };
    return out.finish();
}
