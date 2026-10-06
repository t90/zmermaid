const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const styles = @import("chart_style.zig");
const data = @import("chart_data.zig");
const paint = @import("flow_paint.zig");
const Circle = struct { id: []const u8, x: f64 = 0, y: f64 = 0, r: f64 };
const Area = struct { mask: u8, label: []const u8, size: f64, style: styles.Style = .{}, synthetic: bool = false };
const Text = struct { mask: u8, id: []const u8, label: []const u8, style: styles.Style = .{} };
fn id(rest: *[]const u8) d.Error![]const u8 {
    rest.* = d.trim(rest.*);
    if (rest.len == 0) return error.InvalidSyntax;
    if (rest.*[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, rest.*, 1, '"') orelse return error.InvalidSyntax;
        const value = rest.*[1..end];
        rest.* = d.trim(rest.*[end + 1 ..]);
        return value;
    }
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest.*[end]) or rest.*[end] == '_' or rest.*[end] == '-')) : (end += 1) {}
    if (end == 0) return error.InvalidSyntax;
    const value = rest.*[0..end];
    rest.* = d.trim(rest.*[end..]);
    return value;
}
fn setId(circles: []Circle, name: []const u8) d.Error!usize {
    for (circles, 0..) |c, i| if (std.mem.eql(u8, c.id, name)) return i;
    return error.InvalidSyntax;
}
fn maskIds(circles: []Circle, rest: *[]const u8) d.Error!u8 {
    var mask: u8 = 0;
    while (true) {
        const i = try setId(circles, try id(rest));
        const bit = @as(u8, 1) << @as(u3, @intCast(i));
        if (mask & bit != 0) return error.InvalidSyntax;
        mask |= bit;
        if (!txt.starts(rest.*, ",")) break;
        rest.* = rest.*[1..];
    }
    return mask;
}
fn label(a: std.mem.Allocator, rest: *[]const u8, default: []const u8) d.Error![]const u8 {
    if (!txt.starts(rest.*, "[")) return default;
    var end: usize = 1;
    var quote = false;
    while (end < rest.len) : (end += 1) {
        if (rest.*[end] == '"') quote = !quote;
        if (rest.*[end] == ']' and !quote) break;
    }
    if (end == rest.len) return error.InvalidSyntax;
    const value = try txt.parse(a, d.unquote(rest.*[1..end]));
    rest.* = d.trim(rest.*[end + 1 ..]);
    return value;
}
fn distance(a: Circle, b: Circle) f64 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}
fn pairArea(a: f64, b: f64, dist: f64) f64 {
    if (dist >= a + b) return 0;
    if (dist <= @abs(a - b)) return std.math.pi * @min(a, b) * @min(a, b);
    const aa = std.math.acos(std.math.clamp((dist * dist + a * a - b * b) / (2 * dist * a), -1, 1));
    const bb = std.math.acos(std.math.clamp((dist * dist + b * b - a * a) / (2 * dist * b), -1, 1));
    return a * a * aa + b * b * bb - 0.5 * @sqrt(@max(0, (-dist + a + b) * (dist + a - b) * (dist - a + b) * (dist + a + b)));
}
fn intersection(circles: []Circle, mask: u8) f64 {
    var list: [8]Circle = undefined;
    var n: usize = 0;
    for (circles, 0..) |c, i| if (mask & (@as(u8, 1) << @as(u3, @intCast(i))) != 0) {
        list[n] = c;
        n += 1;
    };
    if (n == 1) return std.math.pi * list[0].r * list[0].r;
    if (n == 2) return pairArea(list[0].r, list[1].r, distance(list[0], list[1]));
    var bottom = list[0].y - list[0].r;
    var top = list[0].y + list[0].r;
    for (list[1..n]) |c| {
        bottom = @max(bottom, c.y - c.r);
        top = @min(top, c.y + c.r);
    }
    if (bottom >= top) return 0;
    // Midpoint quadrature is deterministic and has no dependency on polygon engines.
    const dy = (top - bottom) / 96;
    var area: f64 = 0;
    for (0..96) |i| {
        const y = bottom + (@as(f64, @floatFromInt(i)) + 0.5) * dy;
        var left: f64 = -1e100;
        var right: f64 = 1e100;
        for (list[0..n]) |c| {
            const extent = @sqrt(@max(0, c.r * c.r - (y - c.y) * (y - c.y)));
            left = @max(left, c.x - extent);
            right = @min(right, c.x + extent);
        }
        area += @max(0, right - left) * dy;
    }
    return area;
}
fn loss(circles: []Circle, areas: []Area) f64 {
    var total: f64 = 0;
    for (areas) |area| if (@popCount(area.mask) > 1) {
        const diff = intersection(circles, area.mask) - area.size;
        total += diff * diff * if (area.synthetic) @as(f64, 0.001) else 1;
    };
    return total;
}
fn layout(circles: []Circle, areas: *std.ArrayList(Area), a: std.mem.Allocator) d.Error!void {
    const declared = areas.items.len;
    // A declared higher-order overlap implies pair overlaps at least as large.
    for (0..circles.len) |i| for (i + 1..circles.len) |j| {
        const mask = (@as(u8, 1) << @as(u3, @intCast(i))) | (@as(u8, 1) << @as(u3, @intCast(j)));
        var exists = false;
        for (areas.items) |area| if (area.mask == mask) {
            exists = true;
            break;
        };
        if (exists) continue;
        var size: f64 = 0;
        for (areas.items[0..declared]) |area| if (area.mask & mask == mask) {
            size = @max(size, area.size * 1.6);
        };
        size = @min(size, @min(circles[i].r * circles[i].r, circles[j].r * circles[j].r) * std.math.pi);
        try areas.append(a, .{ .mask = mask, .label = "", .size = size, .synthetic = size > 0 });
    };
    if (circles.len < 2) return;
    var max_r: f64 = 0;
    for (circles) |c| max_r = @max(max_r, c.r);
    // Exact separation for two circles; larger systems minimize overlap-area error.
    if (circles.len == 2) {
        var target: f64 = 0;
        for (areas.items) |area| if (area.mask == 3) {
            target = area.size;
        };
        var low = @abs(circles[0].r - circles[1].r);
        var high = circles[0].r + circles[1].r;
        for (0..64) |_| {
            const mid = (low + high) / 2;
            if (pairArea(circles[0].r, circles[1].r, mid) > target) low = mid else high = mid;
        }
        circles[1].x = (low + high) / 2;
        return;
    }
    var best_layout: [8]Circle = undefined;
    var best_loss: f64 = 1e100;
    for (0..2) |attempt| {
        for (circles, 0..) |*c, i| {
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(circles.len));
            c.x = if (attempt == 0) max_r * 0.6 * @cos(angle) else @as(f64, @floatFromInt(i)) * max_r * 1.4;
            c.y = if (attempt == 0) max_r * 0.6 * @sin(angle) else 0;
        }
        var step = max_r * 0.5;
        var best = loss(circles, areas.items);
        for (0..100) |_| {
            var improved = false;
            for (circles, 0..) |*c, i| {
                if (i == 0) continue;
                for (0..2) |axis| {
                    const coordinate = if (axis == 0) &c.x else &c.y;
                    const old = coordinate.*;
                    var selected = old;
                    for ([_]f64{ -1, 1 }) |sign| {
                        coordinate.* = old + step * sign;
                        const candidate = loss(circles, areas.items);
                        if (candidate < best) {
                            best = candidate;
                            selected = coordinate.*;
                            improved = true;
                        }
                    }
                    coordinate.* = selected;
                }
            }
            if (!improved) step *= 0.55;
            if (step < max_r * 0.00001) break;
        }
        if (best < best_loss) {
            best_loss = best;
            @memcpy(best_layout[0..circles.len], circles);
        }
    }
    @memcpy(circles, best_layout[0..circles.len]);
    areas.shrinkRetainingCapacity(declared);
}
const Position = struct { x: f64, y: f64, margin: f64 };
fn clearance(circles: []Circle, mask: u8, x: f64, y: f64) f64 {
    var result: f64 = 1e100;
    for (circles, 0..) |c, i| {
        const dist = @sqrt((x - c.x) * (x - c.x) + (y - c.y) * (y - c.y));
        const inside = mask & (@as(u8, 1) << @as(u3, @intCast(i))) != 0;
        result = @min(result, if (inside) c.r - dist else dist - c.r);
    }
    return result;
}
fn position(circles: []Circle, mask: u8) Position {
    var first: usize = 0;
    while (mask & (@as(u8, 1) << @as(u3, @intCast(first))) == 0) first += 1;
    const c = circles[first];
    var result: Position = .{ .x = c.x, .y = c.y, .margin = -1e100 };
    for (0..41) |ix| for (0..41) |iy| {
        const x = c.x - c.r + 2 * c.r * @as(f64, @floatFromInt(ix)) / 40;
        const y = c.y - c.r + 2 * c.r * @as(f64, @floatFromInt(iy)) / 40;
        const margin = clearance(circles, mask, x, y);
        if (margin > result.margin) result = .{ .x = x, .y = y, .margin = margin };
    };
    return result;
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var circles: std.ArrayList(Circle) = .empty;
    var areas: std.ArrayList(Area) = .empty;
    var texts: std.ArrayList(Text) = .empty;
    var current: u8 = 0;
    var indent_mode = false;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        const indent = raw.len - std.mem.trimStart(u8, raw, " \t").len;
        if (indent == 0) indent_mode = false;
        if (txt.starts(line, "title ")) {
            doc.title = try txt.parse(doc.a, d.unquote(line[6..]));
            continue;
        }
        var rest = line;
        const cmd = try id(&rest);
        if (std.mem.eql(u8, cmd, "set") or std.mem.eql(u8, cmd, "union")) {
            const single = std.mem.eql(u8, cmd, "set");
            var mask: u8 = 0;
            var default: []const u8 = "";
            if (single) {
                default = try id(&rest);
                for (circles.items) |c| if (std.mem.eql(u8, c.id, default)) return error.InvalidSyntax;
                if (circles.items.len == 8) return error.LimitExceeded;
                mask = @as(u8, 1) << @as(u3, @intCast(circles.items.len));
            } else {
                mask = try maskIds(circles.items, &rest);
                if (@popCount(mask) < 2) return error.InvalidSyntax;
            }
            const text = try label(temp, &rest, default);
            var size: f64 = 10 / @as(f64, @floatFromInt(@popCount(mask) * @popCount(mask)));
            if (rest.len > 0) {
                if (rest[0] != ':') return error.InvalidSyntax;
                size = try d.number(rest[1..]);
            }
            if (size < 0 or size > 1e9 or (single and size == 0)) return error.InvalidSyntax;
            if (single) try circles.append(temp, .{ .id = default, .r = @sqrt(size / std.math.pi) });
            for (areas.items) |area| if (area.mask == mask) return error.InvalidSyntax;
            if (areas.items.len == 64) return error.LimitExceeded;
            try areas.append(temp, .{ .mask = mask, .label = text, .size = size });
            current = mask;
            indent_mode = true;
        } else if (std.mem.eql(u8, cmd, "text")) {
            const mask = if (indent > 0 and indent_mode and current != 0) current else try maskIds(circles.items, &rest);
            const name = try id(&rest);
            const text = try label(temp, &rest, name);
            if (rest.len > 0) return error.InvalidSyntax;
            if (texts.items.len == 512) return error.LimitExceeded;
            try texts.append(temp, .{ .mask = mask, .id = name, .label = text });
        } else if (std.mem.eql(u8, cmd, "style")) {
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse return error.InvalidSyntax;
            const target = rest[0..end];
            const style = try styles.parse(rest[end..], false);
            if (style.dash != null or style.radius != null) return error.UnsupportedSyntax;
            var found = false;
            for (texts.items) |*t| if (std.mem.eql(u8, t.id, target)) {
                if (style.fill != null or style.stroke != null or style.width != null) return error.UnsupportedSyntax;
                t.style.merge(style);
                found = true;
            };
            if (!found) {
                var target_rest = target;
                const mask = try maskIds(circles.items, &target_rest);
                if (target_rest.len > 0) return error.InvalidSyntax;
                for (areas.items) |*area| if (area.mask == mask) {
                    if (@popCount(mask) > 1 and (style.stroke != null or style.width != null)) return error.UnsupportedSyntax;
                    area.style.merge(style);
                    found = true;
                };
            }
            if (!found) return error.InvalidSyntax;
        } else return error.UnsupportedSyntax;
    }
    if (circles.items.len == 0) return error.InvalidSyntax;
    for (texts.items) |t| {
        var found = false;
        for (areas.items) |area| if (area.mask == t.mask) {
            found = true;
            break;
        };
        if (!found) return error.UnsupportedSyntax;
    }
    for (areas.items) |area| for (circles.items, 0..) |c, i| if (area.mask & (@as(u8, 1) << @as(u3, @intCast(i))) != 0 and area.size > std.math.pi * c.r * c.r + 0.000001) return error.InvalidSyntax;
    const declared = areas.items.len;
    try layout(circles.items, &areas, temp);
    areas.shrinkRetainingCapacity(declared);
    var minx: f64 = 1e100;
    var miny: f64 = 1e100;
    var maxx: f64 = -1e100;
    var maxy: f64 = -1e100;
    for (circles.items) |c| {
        minx = @min(minx, c.x - c.r);
        miny = @min(miny, c.y - c.r);
        maxx = @max(maxx, c.x + c.r);
        maxy = @max(maxy, c.y + c.r);
    }
    const width = try doc.num("config.venn.width", 900, 200, 10000);
    const height = try doc.num("config.venn.height", 600, 200, 10000);
    const padding = try doc.num("config.venn.padding", 30, 0, 200);
    if (width <= padding * 2 + 20 or height <= padding * 2 + 20) return error.InvalidSyntax;
    const scale = @min((width - padding * 2) / (maxx - minx), (height - padding * 2) / (maxy - miny));
    for (circles.items) |*c| {
        c.x = (c.x - minx) * scale + (width - (maxx - minx) * scale) / 2;
        c.y = (c.y - miny) * scale + (height - (maxy - miny) * scale) / 2;
        c.r *= scale;
    }
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(data.coord(width), data.coord(height), "venn", prefix);
    try out.add("<defs>");
    for (circles.items, 0..) |c, i| try out.fmt("<clipPath id=\"zm-{d}-set-{d}\"><circle cx=\"{d:.3}\" cy=\"{d:.3}\" r=\"{d:.3}\"/></clipPath>", .{ prefix, i, c.x, c.y, c.r });
    try out.add("</defs>");
    for (areas.items) |area| {
        var first: usize = 0;
        while (area.mask & (@as(u8, 1) << @as(u3, @intCast(first))) == 0) first += 1;
        const fill = area.style.fill orelse if (doc.get(try std.fmt.allocPrint(temp, "config.themeVariables.venn{d}", .{first + 1}))) |v| try d.color(v) else try doc.palette(first);
        try out.fmt("<g data-area=\"{d}\" data-value=\"{d}\" data-actual-area=\"{d:.4}\">", .{ area.mask, area.size, intersection(circles.items, area.mask) / (scale * scale) });
        if (@popCount(area.mask) == 1) {
            const c = circles.items[first];
            try out.fmt("<circle data-set=\"{d}\" cx=\"{d:.3}\" cy=\"{d:.3}\" r=\"{d:.3}\" fill=\"{s}\" fill-opacity=\"0.22\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ first, c.x, c.y, c.r, fill, area.style.stroke orelse fill, area.style.width orelse 2 });
        } else if (area.style.fill != null) {
            for (circles.items, 0..) |_, i| if (area.mask & (@as(u8, 1) << @as(u3, @intCast(i))) != 0) {
                try out.fmt("<g clip-path=\"url(#zm-{d}-set-{d})\">", .{ prefix, i });
            };
            try out.fmt("<rect width=\"100%\" height=\"100%\" fill=\"{s}\" fill-opacity=\"0.3\" stroke=\"none\"/>", .{fill});
            for (0..@popCount(area.mask)) |_| try out.add("</g>");
        }
        try out.add("</g>");
    }
    for (areas.items) |area| {
        var content_h = if (area.label.len > 0) txt.height(area.label) + 10 else @as(usize, 0);
        var content_w = txt.width(area.label);
        for (texts.items) |t| if (t.mask == area.mask) {
            content_h += txt.height(t.label) + 8;
            content_w = @max(content_w, txt.width(t.label));
        };
        if (content_h == 0 or area.size == 0) continue;
        const p = position(circles.items, area.mask);
        if (p.margin <= 0) return error.UnsupportedSyntax;
        const fit = @min(1, @min(p.margin * 1.4 / @as(f64, @floatFromInt(@max(1, content_w))), p.margin * 1.4 / @as(f64, @floatFromInt(content_h))));
        try out.fmt("<g data-region-label=\"{d}\" transform=\"translate({d:.3} {d:.3}) scale({d:.4})\">", .{ area.mask, p.x - @as(f64, @floatFromInt(content_w)) * fit / 2, p.y - @as(f64, @floatFromInt(content_h)) * fit / 2, fit });
        var y: usize = 0;
        if (area.label.len > 0) {
            try paint.text(&out, content_w / 2, y, area.label, area.style);
            y += txt.height(area.label) + 10;
        }
        for (texts.items) |t| if (t.mask == area.mask) {
            try paint.text(&out, content_w / 2, y, t.label, t.style);
            y += txt.height(t.label) + 8;
        };
        try out.add("</g>");
    }
    return out.finish();
}
