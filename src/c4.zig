const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const wrap = @import("text_wrap.zig");
const svg = @import("svg.zig");
const data = @import("chart_data.zig");
const assets = @import("assets.zig");
const eq = std.mem.eql;
const Arg = struct { key: []const u8 = "", value: []const u8, used: bool = false };
const Args = struct {
    values: [24]Arg = undefined,
    len: usize = 0,
    fn parse(a: std.mem.Allocator, raw: []const u8) d.Error!Args {
        var self: Args = .{};
        var start: usize = 0;
        var quote = false;
        var escaped = false;
        for (0..raw.len + 1) |i| {
            const c: u8 = if (i == raw.len) ',' else raw[i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quote and c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') quote = !quote;
            if (c != ',' or quote) continue;
            if (self.len == 24) return error.LimitExceeded;
            var value = d.trim(raw[start..i]);
            var key: []const u8 = "";
            if (txt.starts(value, "$")) {
                const at = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidSyntax;
                key = d.trim(value[1..at]);
                value = d.trim(value[at + 1 ..]);
                for (self.values[0..self.len]) |arg| if (eq(u8, arg.key, key)) return error.InvalidSyntax;
            }
            if (txt.starts(value, "\"")) {
                if (value.len < 2 or value[value.len - 1] != '"') return error.InvalidSyntax;
                value = value[1 .. value.len - 1];
                var decoded: std.ArrayList(u8) = .empty;
                var j: usize = 0;
                while (j < value.len) : (j += 1) {
                    if (value[j] == '\\') {
                        j += 1;
                        if (j == value.len) return error.InvalidSyntax;
                        try decoded.append(a, switch (value[j]) {
                            'n' => 10,
                            't' => 9,
                            '"' => '"',
                            '\\' => '\\',
                            else => return error.UnsupportedSyntax,
                        });
                    } else try decoded.append(a, value[j]);
                }
                value = try decoded.toOwnedSlice(a);
            } else if (std.mem.indexOfScalar(u8, value, '"') != null) return error.InvalidSyntax;
            self.values[self.len] = .{ .key = key, .value = value };
            self.len += 1;
            start = i + 1;
        }
        if (quote or escaped) return error.InvalidSyntax;
        return self;
    }
    fn get(self: *Args, position: usize, name: []const u8) d.Error![]const u8 {
        var result: ?[]const u8 = null;
        if (position < self.len and self.values[position].key.len == 0) {
            self.values[position].used = true;
            result = self.values[position].value;
        }
        for (self.values[0..self.len]) |*arg| if (arg.key.len > 0 and eq(u8, arg.key, name)) {
            if (result != null and result.?.len > 0) return error.InvalidSyntax;
            result = arg.value;
            arg.used = true;
        };
        return result orelse "";
    }
    fn finish(self: *Args) d.Error!void {
        for (self.values[0..self.len]) |arg| if (!arg.used and (arg.value.len > 0 or arg.key.len > 0)) return error.UnsupportedSyntax;
    }
};
const Kind = enum { person, system, container, component, boundary, deployment };
const Shape = enum { box, database, queue, person };
const Node = struct { id: []const u8, label: []const u8 = "", techn: []const u8 = "", descr: []const u8 = "", tags: []const u8 = "", link: []const u8 = "", sprite: []const u8 = "", kind: Kind = .boundary, shape: Shape = .box, parent: usize = 0, group: bool = false, external: bool = false, shadow: bool = false, fill: []const u8 = "", fg: []const u8 = "", stroke: []const u8 = "", x: f64 = 0, y: f64 = 0, w: f64 = 320, h: f64 = 100, header: f64 = 0 };
const Edge = struct { from: []const u8, to: []const u8, label: []const u8, tags: []const u8 = "", link: []const u8 = "", sprite: []const u8 = "", reverse: bool = false, both: bool = false, direction: u8 = 0, color: []const u8, text_color: []const u8, dx: f64 = 0, dy: f64 = 0, lx: f64 = 0, ly: f64 = 0 };
const Point = struct { x: f64, y: f64 };
fn lookup(nodes: []Node, id: []const u8) d.Error!usize {
    for (nodes, 0..) |n, i| if (eq(u8, n.id, id)) return i;
    return error.InvalidSyntax;
}
fn number(value: []const u8, default: f64, min: f64, max: f64) d.Error!f64 {
    if (value.len == 0) return default;
    const n = try d.number(value);
    if (n < min or n > max) return error.InvalidSyntax;
    return n;
}
fn styled(value: []const u8, default: []const u8) d.Error![]const u8 {
    return if (value.len == 0) default else try d.color(value);
}
fn text(a: std.mem.Allocator, value: []const u8, width: usize) d.Error![]const u8 {
    if (value.len > 512) return error.LimitExceeded;
    var safe: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '#') {
            var end = i + 1;
            while (end < value.len and std.ascii.isAlphanumeric(value[end])) : (end += 1) {}
            if (end > i + 1 and end < value.len and value[end] == ';') {
                try safe.appendSlice(a, value[i .. end + 1]);
                i = end;
            } else try safe.appendSlice(a, "#35;");
        } else if (value[i] == ';') try safe.appendSlice(a, "#59;") else try safe.append(a, value[i]);
    }
    return wrap.wrap(a, try txt.parse(a, safe.items), width);
}
fn href(value: []const u8) d.Error![]const u8 {
    if (value.len == 0) return value;
    if (txt.starts(value, "https://") or txt.starts(value, "http://") or txt.starts(value, "#")) return value;
    return error.UnsupportedSyntax;
}
fn anchor(out: *svg.Svg, link: []const u8) !void {
    if (link.len > 0) {
        try out.add("<a href=\"");
        try out.escape(link);
        try out.add("\">");
    }
}
fn measure(nodes: []Node, parent: usize, shape_cols: usize, group_cols: usize) void {
    var y = nodes[parent].header + 32;
    var width: f64 = nodes[parent].w;
    for ([_]bool{ false, true }) |groups| {
        var x: f64 = 32;
        var row_height: f64 = 0;
        var col: usize = 0;
        for (nodes, 0..) |*n, i| if (i != 0 and n.parent == parent and n.group == groups) {
            if (n.group) measure(nodes, i, shape_cols, group_cols);
            if (col == (if (groups) group_cols else shape_cols)) {
                y += row_height + 100;
                x = 32;
                row_height = 0;
                col = 0;
            }
            n.x = x;
            n.y = y;
            x += n.w + 100;
            row_height = @max(row_height, n.h);
            col += 1;
            width = @max(width, x - 100 + 32);
        };
        if (col > 0) y += row_height + 100;
    }
    nodes[parent].w = width;
    nodes[parent].h = @max(nodes[parent].header + 70, y - 100 + 32);
}
fn place(nodes: []Node, parent: usize) void {
    for (nodes, 0..) |*n, i| if (i != 0 and n.parent == parent) {
        n.x += nodes[parent].x;
        n.y += nodes[parent].y;
        if (n.group) place(nodes, i);
    };
}
fn center(n: Node) Point {
    return .{ .x = n.x + n.w / 2, .y = n.y + n.h / 2 };
}
fn boundary(n: Node, target: Point) Point {
    const c = center(n);
    const dx = target.x - c.x;
    const dy = target.y - c.y;
    if (@abs(dx) + @abs(dy) < 0.001) return .{ .x = c.x + n.w / 2, .y = c.y };
    const t = 1 / @max(@abs(dx) / (n.w / 2), @abs(dy) / (n.h / 2));
    return .{ .x = c.x + dx * t, .y = c.y + dy * t };
}
fn port(n: Node, dir: u8) Point {
    const c = center(n);
    return switch (dir) {
        'U' => .{ .x = c.x, .y = n.y },
        'D' => .{ .x = c.x, .y = n.y + n.h },
        'L' => .{ .x = n.x, .y = c.y },
        else => .{ .x = n.x + n.w, .y = c.y },
    };
}
fn writeText(out: *svg.Svg, x: f64, y: f64, value: []const u8, color: []const u8, bold: bool) !void {
    if (value.len == 0) return;
    var lines = std.mem.splitScalar(u8, value, '\n');
    var py = y;
    while (lines.next()) |line| {
        try out.fmt("<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" fill=\"{s}\" stroke=\"none\" font-family=\"Consolas,monospace\" font-size=\"14\" font-weight=\"{s}\">", .{ x, py, color, if (bold) "bold" else "normal" });
        try out.escape(line);
        try out.add("</text>");
        py += 20;
    }
}
fn drawSprite(out: *svg.Svg, registry: *const assets.Registry, name: []const u8, x: f64, y: f64, size: usize) d.Error!void {
    try out.add("<g data-c4-sprite=\"");
    try out.escape(name);
    try out.fmt("\" transform=\"translate({d} {d})\">", .{ x, y });
    try assets.draw(out, try registry.get(name), 0, 0, size, size);
    try out.add("</g>");
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var nodes: std.ArrayList(Node) = .empty;
    var edges: std.ArrayList(Edge) = .empty;
    try nodes.append(temp, .{ .id = "", .group = true });
    var stack: [17]usize = @splat(0);
    var depth: usize = 0;
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const bg = if (doc.theme == .dark) "#0d1117" else "#ffffff";
    var shape_cols: usize = @intFromFloat(try doc.num("config.c4.c4ShapeInRow", 3, 1, 32));
    var group_cols: usize = @intFromFloat(try doc.num("config.c4.c4BoundaryInRow", 2, 1, 32));
    const dynamic = txt.starts(doc.source, "C4Dynamic");
    var source = doc.source[std.mem.indexOfScalar(u8, doc.source, '\n') orelse doc.source.len ..];
    while (d.trim(source).len > 0) {
        source = d.trim(source);
        if (txt.starts(source, "%%")) {
            source = source[std.mem.indexOfScalar(u8, source, '\n') orelse source.len ..];
            continue;
        }
        if (source[0] == '}') {
            if (depth == 0) return error.InvalidSyntax;
            depth -= 1;
            source = source[1..];
            continue;
        }
        if (txt.starts(source, "title ") or txt.starts(source, "accTitle:") or txt.starts(source, "accDescr:")) {
            const end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
            const line = source[0..end];
            if (txt.starts(line, "title ")) doc.title = try txt.parse(doc.a, d.trim(line[6..])) else if (txt.starts(line, "accTitle:")) doc.acc_title = d.trim(line[9..]) else doc.acc_description = d.trim(line[9..]);
            source = source[end..];
            continue;
        }
        const open = std.mem.indexOfScalar(u8, source, '(') orelse return error.UnsupportedSyntax;
        const name = d.trim(source[0..open]);
        var end = open + 1;
        var quoted = false;
        var escaped = false;
        while (end < source.len) : (end += 1) {
            const c = source[end];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quoted and c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') quoted = !quoted;
            if (!quoted and c == ')') break;
        }
        if (end == source.len) return error.InvalidSyntax;
        var args = try Args.parse(temp, source[open + 1 .. end]);
        source = d.trim(source[end + 1 ..]);
        if (eq(u8, name, "UpdateLayoutConfig")) {
            shape_cols = @intFromFloat(try number(try args.get(0, "c4ShapeInRow"), @floatFromInt(shape_cols), 1, 32));
            group_cols = @intFromFloat(try number(try args.get(1, "c4BoundaryInRow"), @floatFromInt(group_cols), 1, 32));
        } else if (eq(u8, name, "UpdateElementStyle")) {
            const id = try lookup(nodes.items, try args.get(0, "elementName"));
            const n = &nodes.items[id];
            n.fill = try styled(try args.get(1, "bgColor"), n.fill);
            n.fg = try styled(try args.get(2, "fontColor"), n.fg);
            n.stroke = try styled(try args.get(3, "borderColor"), n.stroke);
            const shadow = try args.get(4, "shadowing");
            if (shadow.len > 0) {
                if (!eq(u8, shadow, "true") and !eq(u8, shadow, "false")) return error.InvalidSyntax;
                n.shadow = eq(u8, shadow, "true");
            }
            const shape = try args.get(5, "shape");
            if (shape.len > 0) {
                if (n.group) return error.UnsupportedSyntax;
                if (eq(u8, shape, "box") or eq(u8, shape, "rectangle")) n.shape = .box else if (eq(u8, shape, "cylinder")) n.shape = .database else if (eq(u8, shape, "queue")) n.shape = .queue else if (eq(u8, shape, "person")) n.shape = .person else return error.UnsupportedSyntax;
            }
            const sprite = try args.get(6, "sprite");
            if (sprite.len > 0) n.sprite = sprite;
            const techn = try args.get(7, "techn");
            if (techn.len > 0) n.techn = techn;
        } else if (eq(u8, name, "UpdateRelStyle")) {
            const from = try args.get(0, "from");
            const to = try args.get(1, "to");
            var found = false;
            for (edges.items) |*e| if (eq(u8, e.from, from) and eq(u8, e.to, to)) {
                e.text_color = try styled(try args.get(2, "textColor"), e.text_color);
                e.color = try styled(try args.get(3, "lineColor"), e.color);
                e.dx = try number(try args.get(4, "offsetX"), e.dx, -10000, 10000);
                e.dy = try number(try args.get(5, "offsetY"), e.dy, -10000, 10000);
                found = true;
                break;
            };
            if (!found) return error.InvalidSyntax;
        } else if (eq(u8, name, "Rel") or eq(u8, name, "RelIndex") or eq(u8, name, "BiRel") or txt.starts(name, "Rel_")) {
            var shift: usize = 0;
            if (eq(u8, name, "RelIndex")) {
                _ = try args.get(0, "index");
                shift = 1;
            }
            var e: Edge = .{ .from = try args.get(shift, "from"), .to = try args.get(1 + shift, "to"), .label = try args.get(2 + shift, "label"), .color = fg, .text_color = fg };
            e.reverse = eq(u8, name, "Rel_Back");
            e.both = eq(u8, name, "BiRel");
            if (txt.starts(name, "Rel_") and !e.reverse) {
                const suffix = name[4..];
                if (eq(u8, suffix, "U") or eq(u8, suffix, "Up")) e.direction = 'U' else if (eq(u8, suffix, "D") or eq(u8, suffix, "Down")) e.direction = 'D' else if (eq(u8, suffix, "L") or eq(u8, suffix, "Left")) e.direction = 'L' else if (eq(u8, suffix, "R") or eq(u8, suffix, "Right")) e.direction = 'R' else return error.UnsupportedSyntax;
            }
            const techn = try args.get(3 + shift, "techn");
            const descr = try args.get(4 + shift, "descr");
            e.sprite = try args.get(5 + shift, "sprite");
            e.tags = try args.get(6 + shift, "tags");
            e.link = try href(try args.get(7 + shift, "link"));
            if (dynamic) e.label = try std.fmt.allocPrint(temp, "{d}: {s}", .{ edges.items.len + 1, e.label });
            if (techn.len > 0) e.label = try std.fmt.allocPrint(temp, "{s}<br>[{s}]", .{ e.label, techn });
            if (descr.len > 0) e.label = try std.fmt.allocPrint(temp, "{s}<br>{s}", .{ e.label, descr });
            e.label = try text(temp, e.label, 252);
            if (e.from.len == 0 or e.to.len == 0) return error.InvalidSyntax;
            if (edges.items.len == 512) return error.LimitExceeded;
            try edges.append(temp, e);
        } else {
            var n: Node = .{ .id = try args.get(0, "alias"), .label = try args.get(1, "label"), .parent = stack[depth], .fill = "#1168bd", .fg = "#ffffff", .stroke = "#0b4884" };
            const deployment = eq(u8, name, "Deployment_Node") or eq(u8, name, "Node") or eq(u8, name, "Node_L") or eq(u8, name, "Node_R");
            const bound = eq(u8, name, "Boundary") or eq(u8, name, "Enterprise_Boundary") or eq(u8, name, "System_Boundary") or eq(u8, name, "Container_Boundary");
            n.group = bound or deployment;
            if (n.group) {
                n.kind = if (deployment) .deployment else .boundary;
                n.fill = if (doc.theme == .dark) "#161b22" else "#f6f8fa";
                n.fg = fg;
                n.stroke = fg;
                n.techn = try args.get(2, "type");
                if (n.techn.len == 0) n.techn = if (deployment) "Deployment node" else if (eq(u8, name, "Enterprise_Boundary")) "Enterprise" else if (eq(u8, name, "System_Boundary")) "Software system" else if (eq(u8, name, "Container_Boundary")) "Container" else "Boundary";
                n.descr = if (deployment) try args.get(3, "descr") else "";
                if (deployment) n.sprite = try args.get(4, "sprite");
                n.tags = try args.get(if (deployment) 5 else 3, "tags");
                n.link = try href(try args.get(if (deployment) 6 else 4, "link"));
            } else {
                var core = name;
                n.external = std.mem.endsWith(u8, core, "_Ext");
                if (n.external) core = core[0 .. core.len - 4];
                if (std.mem.endsWith(u8, core, "Db")) {
                    n.shape = .database;
                    core = core[0 .. core.len - 2];
                } else if (std.mem.endsWith(u8, core, "Queue")) {
                    n.shape = .queue;
                    core = core[0 .. core.len - 5];
                }
                if (eq(u8, core, "Person")) {
                    n.kind = .person;
                    n.shape = .person;
                } else if (eq(u8, core, "System")) n.kind = .system else if (eq(u8, core, "Container")) n.kind = .container else if (eq(u8, core, "Component")) n.kind = .component else return error.UnsupportedSyntax;
                const tech = n.kind == .container or n.kind == .component;
                n.techn = if (tech) try args.get(2, "techn") else "";
                n.descr = try args.get(if (tech) 3 else 2, "descr");
                n.sprite = try args.get(if (tech) 4 else 3, "sprite");
                n.tags = try args.get(if (tech) 5 else 4, "tags");
                n.link = try href(try args.get(if (tech) 6 else 5, "link"));
                if (n.external) {
                    n.fill = if (doc.theme == .dark) "#454b53" else "#737b84";
                    n.stroke = "#525961";
                } else switch (n.kind) {
                    .person => {
                        n.fill = "#08427b";
                        n.stroke = "#052e56";
                    },
                    .container => {
                        n.fill = "#438dd5";
                        n.stroke = "#2868a6";
                    },
                    .component => {
                        n.fill = "#85bbf0";
                        n.stroke = "#397fc1";
                        n.fg = "#142e45";
                    },
                    else => {},
                }
            }
            if (n.id.len == 0) return error.InvalidSyntax;
            if (n.label.len == 0) n.label = n.id;
            for (nodes.items) |old| if (eq(u8, old.id, n.id)) return error.InvalidSyntax;
            if (nodes.items.len == 257) return error.LimitExceeded;
            try nodes.append(temp, n);
            if (n.group) {
                if (depth == 16) return error.LimitExceeded;
                depth += 1;
                stack[depth] = nodes.items.len - 1;
                if (source.len == 0 or source[0] != '{') return error.InvalidSyntax;
                source = source[1..];
            }
        }
        try args.finish();
    }
    if (depth != 0) return error.InvalidSyntax;
    for (nodes.items[1..]) |*n| {
        if (n.sprite.len > 0) _ = try doc.assets.get(n.sprite);
        n.label = try text(temp, n.label, 270);
        n.techn = try text(temp, n.techn, 270);
        n.descr = try text(temp, n.descr, 270);
        n.header = @as(f64, @floatFromInt(txt.height(n.label) + txt.height(n.techn))) + 32;
        if (n.sprite.len > 0) n.header += 72;
        if (n.group) n.header += @as(f64, @floatFromInt(txt.height(n.descr))) else n.h = n.header + @as(f64, @floatFromInt(txt.height(n.descr))) + 48 + (if (n.shape == .person) @as(f64, 56) else 0);
    }
    measure(nodes.items, 0, shape_cols, group_cols);
    nodes.items[0].x = 30;
    nodes.items[0].y = 30;
    place(nodes.items, 0);
    var minx: f64 = 0;
    var miny: f64 = 0;
    var maxx = nodes.items[0].w + 60;
    var maxy = nodes.items[0].h + 60;
    for (edges.items) |*e| {
        if (e.sprite.len > 0) _ = try doc.assets.get(e.sprite);
        const from = nodes.items[try lookup(nodes.items, e.from)];
        const to = nodes.items[try lookup(nodes.items, e.to)];
        const p = center(from);
        const q = center(to);
        e.lx = (p.x + q.x) / 2 + e.dx;
        e.ly = (p.y + q.y) / 2 + e.dy - 10;
        if (eq(u8, e.from, e.to)) {
            e.lx = from.x + from.w + 70 + e.dx;
            e.ly = from.y - 30 + e.dy;
            maxx = @max(maxx, from.x + from.w + 90);
        }
        const tw: f64 = @floatFromInt(@max(txt.width(e.label), if (e.sprite.len > 0) @as(usize, 24) else 0));
        const th: f64 = @floatFromInt(txt.height(e.label) + if (e.sprite.len > 0) @as(usize, 32) else 0);
        minx = @min(minx, e.lx - tw / 2 - 20);
        maxx = @max(maxx, e.lx + tw / 2 + 20);
        miny = @min(miny, e.ly - 30);
        maxy = @max(maxy, e.ly + th + 20);
    }
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(data.coord(maxx - minx), data.coord(maxy - miny), "c4", prefix);
    try out.fmt("<defs><filter id=\"zm-{d}-c4-shadow\" x=\"-20%\" y=\"-20%\" width=\"150%\" height=\"150%\"><feDropShadow dx=\"3\" dy=\"4\" stdDeviation=\"2\" flood-opacity=\"0.3\"/></filter></defs><g transform=\"translate({d} {d})\">", .{ prefix, -minx, -miny });
    // Group backgrounds precede relations; solid nodes cover crossing line segments.
    for ([_]bool{ true, false }) |groups| {
        if (!groups) for (edges.items, 0..) |e, i| {
            const from = nodes.items[try lookup(nodes.items, e.from)];
            const to = nodes.items[try lookup(nodes.items, e.to)];
            var p = boundary(from, center(to));
            var q = boundary(to, center(from));
            if (e.direction != 0) {
                p = port(from, e.direction);
                q = port(to, switch (e.direction) {
                    'U' => 'D',
                    'D' => 'U',
                    'L' => 'R',
                    else => 'L',
                });
            }
            try out.fmt("<defs><marker id=\"zm-{d}-c4-rel-{d}\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"10\" markerHeight=\"10\" markerUnits=\"userSpaceOnUse\" orient=\"auto-start-reverse\"><path d=\"M 1 1 L 9 5 L 1 9 Z\" fill=\"{s}\" stroke=\"none\"/></marker></defs><path data-c4-rel=\"{d}\"", .{ prefix, i, e.color, i });
            if (eq(u8, e.from, e.to)) {
                try out.add(" ");
                try @import("flow_links.zig").terminalCubic(&out, .{ .x = from.x + from.w, .y = from.y + from.h / 3 }, .{ .x = from.x + from.w + 90, .y = from.y + from.h / 3 }, .{ .x = from.x + from.w + 90, .y = from.y + from.h * 2 / 3 }, .{ .x = from.x + from.w, .y = from.y + from.h * 2 / 3 });
            } else try out.fmt(" d=\"M {d} {d} L {d} {d}\"", .{ p.x, p.y, q.x, q.y });
            try out.fmt(" fill=\"none\" stroke=\"{s}\" stroke-dasharray=\"5 4\"", .{e.color});
            if (!e.reverse or e.both) try out.fmt(" marker-end=\"url(#zm-{d}-c4-rel-{d})\"", .{ prefix, i });
            if (e.reverse or e.both) try out.fmt(" marker-start=\"url(#zm-{d}-c4-rel-{d})\"", .{ prefix, i });
            try out.add("/>");
        };
        for (nodes.items[1..], 1..) |n, i| if (n.group == groups) {
            try anchor(&out, n.link);
            try out.fmt("<g data-c4-node=\"{d}\" data-parent=\"{d}\" data-kind=\"{s}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\" data-tags=\"", .{ i, n.parent, @tagName(n.kind), n.x, n.y, n.w, n.h });
            try out.escape(n.tags);
            try out.add("\"");
            if (n.shadow) try out.fmt(" filter=\"url(#zm-{d}-c4-shadow)\"", .{prefix});
            try out.add(">");
            try out.fmt("<g fill=\"{s}\" stroke=\"{s}\">", .{ n.fill, n.stroke });
            var texty = n.y + 28;
            if (n.group) {
                try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" stroke-dasharray=\"8 5\"/>", .{ n.x, n.y, n.w, n.h });
            } else if (n.shape == .database) {
                try out.fmt("<path d=\"M {d} {d} A {d} 16 0 0 1 {d} {d} V {d} A {d} 16 0 0 1 {d} {d} Z\"/><ellipse cx=\"{d}\" cy=\"{d}\" rx=\"{d}\" ry=\"16\"/>", .{ n.x, n.y + 16, n.w / 2, n.x + n.w, n.y + 16, n.y + n.h - 16, n.w / 2, n.x, n.y + n.h - 16, n.x + n.w / 2, n.y + 16, n.w / 2 });
                texty += 24;
            } else if (n.shape == .queue) {
                try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"22\"/><path d=\"M {d} {d} V {d} M {d} {d} V {d}\"/>", .{ n.x, n.y, n.w, n.h, n.x + 18, n.y + 10, n.y + n.h - 10, n.x + n.w - 18, n.y + 10, n.y + n.h - 10 });
            } else if (n.shape == .person) {
                try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"24\"/><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"28\"/>", .{ n.x + n.w / 2, n.y + 24, n.x, n.y + 52, n.w, n.h - 52 });
                texty += 58;
            } else try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"5\"/>", .{ n.x, n.y, n.w, n.h });
            try out.add("</g>");
            if (n.sprite.len > 0) {
                try drawSprite(&out, &doc.assets, n.sprite, n.x + n.w / 2 - 32, texty - 16, 64);
                texty += 72;
            }
            try writeText(&out, n.x + n.w / 2, texty, n.label, n.fg, true);
            texty += @as(f64, @floatFromInt(txt.height(n.label))) + 4;
            if (!n.group) {
                const stereotype = try std.fmt.allocPrint(temp, "[{s}{s}]", .{ if (n.external) "External " else "", @tagName(n.kind) });
                try writeText(&out, n.x + n.w / 2, texty, stereotype, n.fg, false);
                texty += 24;
            }
            try writeText(&out, n.x + n.w / 2, texty, n.techn, n.fg, false);
            if (n.techn.len > 0) texty += @as(f64, @floatFromInt(txt.height(n.techn))) + 8;
            try writeText(&out, n.x + n.w / 2, texty, n.descr, n.fg, false);
            try out.add("</g>");
            if (n.link.len > 0) try out.add("</a>");
        };
    }
    for (edges.items, 0..) |e, i| if (e.label.len > 0 or e.sprite.len > 0) {
        try anchor(&out, e.link);
        const label_width = @max(txt.width(e.label), if (e.sprite.len > 0) @as(usize, 24) else 0);
        const sprite_height: usize = if (e.sprite.len > 0) 32 else 0;
        try out.fmt("<g data-c4-rel-label=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" stroke=\"none\" opacity=\"0.94\"/>", .{ i, e.lx - @as(f64, @floatFromInt(label_width)) / 2 - 5, e.ly - 16, label_width + 10, txt.height(e.label) + sprite_height + 8, bg });
        if (e.sprite.len > 0) try drawSprite(&out, &doc.assets, e.sprite, e.lx - 12, e.ly - 16, 24);
        try writeText(&out, e.lx, e.ly + @as(f64, @floatFromInt(sprite_height)), e.label, e.text_color, false);
        try out.add("</g>");
        if (e.link.len > 0) try out.add("</a>");
    };
    try out.add("</g>");
    return out.finish();
}
