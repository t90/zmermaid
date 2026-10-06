const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const data = @import("chart_data.zig");
const names = [_][]const u8{ "complex", "complicated", "clear", "chaotic", "confusion" };
const titles = [_][]const u8{ "Complex", "Complicated", "Clear", "Chaotic", "Confusion" };
const Transition = struct { from: usize, to: usize, label: []const u8 };
fn wobble(seed: *u32, amplitude: f64) f64 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return (@as(f64, @floatFromInt(seed.* >> 8)) / 16777215 * 2 - 1) * amplitude;
}
fn domain(s: []const u8) d.Error!usize {
    for (names, 0..) |v, i| if (std.mem.eql(u8, v, d.trim(s))) return i;
    return error.InvalidSyntax;
}
fn quoted(a: std.mem.Allocator, raw: []const u8) d.Error![]const u8 {
    const s = d.trim(raw);
    if (s.len < 2 or (s[0] != '"' and s[0] != '\'') or s[s.len - 1] != s[0]) return error.InvalidSyntax;
    return txt.parse(a, s[1 .. s.len - 1]);
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var items = [_]std.ArrayList([]const u8){.empty} ** 5;
    var transitions: std.ArrayList(Transition) = .empty;
    var active: ?usize = null;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (txt.starts(line, "title ")) {
            doc.title = try txt.parse(doc.a, d.unquote(line[6..]));
            continue;
        }
        if (txt.starts(line, "accTitle:")) {
            doc.acc_title = d.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "accDescr:")) {
            doc.acc_description = d.trim(line[9..]);
            continue;
        }
        if (line[0] == '"' or line[0] == '\'') {
            const id = active orelse return error.InvalidSyntax;
            if (items[id].items.len == 256) return error.LimitExceeded;
            try items[id].append(temp, try quoted(temp, line));
            continue;
        }
        if (std.mem.indexOf(u8, line, "-->")) |at| {
            const from = try domain(line[0..at]);
            const tail = d.trim(line[at + 3 ..]);
            const colon = std.mem.indexOfScalar(u8, tail, ':') orelse tail.len;
            const to = try domain(tail[0..colon]);
            const label = if (colon < tail.len) try quoted(temp, tail[colon + 1 ..]) else "";
            if (from != to) {
                if (transitions.items.len == 128) return error.LimitExceeded;
                try transitions.append(temp, .{ .from = from, .to = to, .label = label });
            }
            active = null;
            continue;
        }
        active = try domain(line);
        items[active.?].clearRetainingCapacity();
    }
    const descriptions = try doc.flag("config.cynefin.showDomainDescriptions", true);
    const amplitude = try doc.num("config.cynefin.boundaryAmplitude", 8, 0, 50);
    const requested_seed = try doc.num("config.cynefin.seed", 0, 0, 4294967295);
    if (@floor(requested_seed) != requested_seed) return error.InvalidSyntax;
    var seed: u32 = if (requested_seed == 0) prefix else @intFromFloat(requested_seed);
    var qw: usize = 360;
    var qh: usize = 210;
    var center_w: usize = 260;
    var center_h: usize = 100;
    for (items, 0..) |list, i| {
        var height: usize = 0;
        for (list.items) |label| {
            if (i == 4) center_w = @max(center_w, txt.width(label) * 3 / 2 + 80) else qw = @max(qw, txt.width(label) + 60);
            height += txt.height(label) + 10;
        }
        if (i == 4) center_h = @max(center_h, height * 2 + 130) else qh = @max(qh, height + if (descriptions) @as(usize, 135) else 70);
    }
    const width = @max(@max(qw * 2, center_w + 120), data.coord(try doc.num("config.cynefin.width", 800, 200, 10000)));
    const height = @max(qh * 2 + center_h, data.coord(try doc.num("config.cynefin.height", 700, 200, 10000)));
    if (center_w > width - 80) return error.LimitExceeded;
    const padding = data.coord(try doc.num("config.cynefin.padding", 30, 4, 200));
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const boundary_color = if (doc.get("config.themeVariables.cynefin.boundaryColor")) |v| try d.color(v) else fg;
    const bg = if (doc.theme == .dark) "#0d1117" else "#ffffff";
    var colors: [5][]const u8 = undefined;
    for (names, 0..) |name, i| colors[i] = if (doc.get(try std.fmt.allocPrint(temp, "config.themeVariables.cynefin.{s}Bg", .{name}))) |v| try d.color(v) else try doc.palette(i);
    var legend_width: usize = 0;
    var legend_height: usize = 0;
    for (transitions.items, 0..) |tr, i| {
        const label = try std.fmt.allocPrint(temp, "{d}. {s} → {s}{s}{s}", .{ i + 1, titles[tr.from], titles[tr.to], if (tr.label.len > 0) ": " else "", tr.label });
        legend_width = @max(legend_width, txt.width(label));
        legend_height += txt.height(label) + 12;
    }
    const total_width = @max(width + padding * 2, legend_width + 40);
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(total_width, height + padding * 2 + legend_height, "cynefin", prefix);
    const cx = padding + width / 2;
    const cy = padding + height / 2;
    const xs = [_]usize{ padding + width / 4, padding + width * 3 / 4, padding + width * 3 / 4, padding + width / 4, cx };
    const ys = [_]usize{ padding + qh / 2, padding + qh / 2, padding + height - qh / 2, padding + height - qh / 2, cy };
    for (0..4) |i| {
        const x = padding + if (i == 1 or i == 2) width / 2 else @as(usize, 0);
        const y = padding + if (i == 2 or i == 3) height / 2 else @as(usize, 0);
        try out.fmt("<rect data-domain=\"{s}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" fill-opacity=\"0.35\" stroke=\"none\"/>", .{ names[i], x, y, width / 2, height / 2, colors[i] });
    }
    const x: f64 = @floatFromInt(cx);
    const dx = [_]f64{ x + wobble(&seed, amplitude), x + wobble(&seed, amplitude), x + wobble(&seed, amplitude) };
    const dy = @as(f64, @floatFromInt(cy)) + wobble(&seed, amplitude);
    try out.fmt("<path data-boundary=\"true\" d=\"M {d} {d} C {d} {d} {d} {d} {d} {d} S {d} {d} {d} {d} M {d} {d} Q {d} {d} {d} {d}\" fill=\"none\" stroke=\"{s}\"/>", .{ cx, padding, dx[0], cy - height / 4, dx[1], cy - height / 8, cx, cy, dx[2], cy + height / 4, cx, padding + height, padding, cy, cx, dy, padding + width, cy, boundary_color });
    try out.fmt("<ellipse data-domain=\"confusion\" cx=\"{d}\" cy=\"{d}\" rx=\"{d}\" ry=\"{d}\" fill=\"{s}\" stroke=\"{s}\"/>", .{ cx, cy, center_w / 2, center_h / 2, colors[4], boundary_color });
    // Numbered connectors keep long transition descriptions out of domain text.
    for (transitions.items, 0..) |tr, i| {
        var x1 = xs[tr.from];
        var y1 = ys[tr.from];
        var x2 = xs[tr.to];
        var y2 = ys[tr.to];
        const pair = (@as(u8, 1) << @as(u3, @intCast(tr.from))) | (@as(u8, 1) << @as(u3, @intCast(tr.to)));
        if (pair == 3) {
            y1 = padding / 2;
            y2 = y1;
        } else if (pair == 6) {
            x1 = padding + width + padding / 2;
            x2 = x1;
        } else if (pair == 12) {
            y1 = padding + height + padding / 2;
            y2 = y1;
        } else if (pair == 9) {
            x1 = padding / 2;
            x2 = x1;
        }
        const mx = (x1 + x2) / 2;
        const my = (y1 + y2) / 2;
        try out.fmt("<path data-transition=\"{d}\" data-from=\"{s}\" data-to=\"{s}\" d=\"M {d} {d} Q {d} {d} {d} {d}\" fill=\"none\" stroke-dasharray=\"5 3\" marker-end=\"url(#zm-{d})\"/>", .{ i, names[tr.from], names[tr.to], x1, y1, mx, my, x2, y2, prefix });
        try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"12\" fill=\"{s}\"/>", .{ mx, my, bg });
        try out.text(mx, my, try std.fmt.allocPrint(temp, "{d}", .{i + 1}));
    }
    const models = [_][]const u8{ "Probe → Sense → Respond", "Sense → Analyse → Respond", "Sense → Categorise → Respond", "Act → Sense → Respond", "Disorder" };
    const practices = [_][]const u8{ "Emergent Practices", "Good Practices", "Best Practices", "Novel Practices", "" };
    for (0..5) |i| {
        var y = if (i == 4) cy - center_h / 2 + 20 else if (i < 2) padding + 24 else padding + height / 2 + center_h / 2 + 24;
        try out.add("<g font-weight=\"bold\">");
        try out.text(xs[i], y, titles[i]);
        try out.add("</g>");
        y += 26;
        if (descriptions) {
            try out.text(xs[i], y, models[i]);
            y += 24;
            if (i != 4) {
                try out.text(xs[i], y, practices[i]);
                y += 32;
            }
        }
        for (items[i].items) |label| {
            try txt.draw(&out, xs[i], y, label);
            y += txt.height(label) + 10;
        }
    }
    var y = height + padding * 2;
    for (transitions.items, 0..) |tr, i| {
        const label = try std.fmt.allocPrint(temp, "{d}. {s} → {s}{s}{s}", .{ i + 1, titles[tr.from], titles[tr.to], if (tr.label.len > 0) ": " else "", tr.label });
        try txt.draw(&out, total_width / 2, y, label);
        y += txt.height(label) + 12;
    }
    return out.finish();
}
