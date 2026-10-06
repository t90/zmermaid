const std = @import("std");
const svg = @import("svg.zig");
const docmod = @import("document.zig");
const txt = @import("sequence_text.zig");
const Slice = struct { label: []const u8, value: f64 };
pub fn render(a: std.mem.Allocator, doc: *docmod.Document, prefix: u32) docmod.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var slices: std.ArrayList(Slice) = .empty;
    var title: []const u8 = "";
    var show = false;
    var total: f64 = 0;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    var header = docmod.trim(lines.next().?);
    if (!txt.starts(header, "pie")) return error.InvalidSyntax;
    header = docmod.trim(header[3..]);
    if (txt.starts(header, "showData")) {
        show = true;
        header = docmod.trim(header[8..]);
    }
    if (header.len > 0) {
        if (!txt.starts(header, "title ")) return error.UnsupportedSyntax;
        title = try txt.parse(temp, docmod.unquote(header[6..]));
    }
    while (lines.next()) |raw| {
        const line = docmod.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (txt.starts(line, "accTitle:")) {
            doc.acc_title = docmod.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "accDescr:")) {
            doc.acc_description = docmod.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "accDescr") and docmod.trim(line[8..]).len > 0 and docmod.trim(line[8..])[0] == '{') {
            var part = docmod.trim(line[8..])[1..];
            var description: std.ArrayList(u8) = .empty;
            while (true) {
                const close = std.mem.indexOfScalar(u8, part, '}');
                const content = docmod.trim(part[0 .. close orelse part.len]);
                if (description.items.len + content.len + 1 > 16384) return error.LimitExceeded;
                if (description.items.len > 0 and content.len > 0) try description.append(doc.a, '\n');
                try description.appendSlice(doc.a, content);
                if (close) |end| {
                    if (docmod.trim(part[end + 1 ..]).len > 0) return error.InvalidSyntax;
                    break;
                }
                part = lines.next() orelse return error.InvalidSyntax;
            }
            doc.acc_description = try description.toOwnedSlice(doc.a);
            continue;
        }
        if (txt.starts(line, "title ")) {
            title = try txt.parse(temp, docmod.unquote(line[6..]));
            continue;
        }
        if (line[0] != '"') return error.UnsupportedSyntax;
        const end = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse return error.InvalidSyntax;
        const rest = docmod.trim(line[end + 1 ..]);
        if (rest.len == 0 or rest[0] != ':') return error.InvalidSyntax;
        const n = try docmod.number(rest[1..]);
        if (n < 0) return error.InvalidSyntax;
        const label = try txt.parse(temp, line[1..end]);
        // Upstream keeps the first value when a label is repeated.
        var duplicate = false;
        for (slices.items) |slice| if (std.mem.eql(u8, slice.label, label)) {
            duplicate = true;
        };
        if (duplicate) continue;
        if (slices.items.len == 128) return error.LimitExceeded;
        total += n;
        try slices.append(temp, .{ .label = label, .value = n });
    }
    if (slices.items.len == 0 or total <= 0 or !std.math.isFinite(total)) return error.InvalidSyntax;
    const requested_hole = try doc.num("config.pie.donutHole", 0, -1e12, 1e12);
    // Upstream falls back to a solid pie for out-of-range donut settings.
    const hole = if (requested_hole > 0 and requested_hole <= 0.9) requested_hole else 0;
    const text_position = try doc.num("config.pie.textPosition", 0.75, 0, 1);
    const highlight = doc.get("config.pie.highlightSlice") orelse "";
    if (std.mem.eql(u8, highlight, "hover")) return error.UnsupportedSyntax;
    const position = doc.get("config.pie.legendPosition") orelse "right";
    var valid = false;
    for ([_][]const u8{ "left", "right", "top", "bottom", "center" }) |v| if (std.mem.eql(u8, position, v)) {
        valid = true;
    };
    if (!valid) return error.InvalidSyntax;
    var stroke_width: f64 = 1;
    if (doc.get("config.themeVariables.pieOuterStrokeWidth")) |raw| {
        const v = if (std.mem.endsWith(u8, raw, "px")) raw[0 .. raw.len - 2] else raw;
        stroke_width = try docmod.number(v);
        if (stroke_width < 0 or stroke_width > 30) return error.InvalidSyntax;
    }
    var legend_width: usize = 160;
    var legend_height: usize = 0;
    for (slices.items) |slice| {
        legend_width = @max(legend_width, txt.width(slice.label) + if (show) @as(usize, 180) else 50);
        legend_height += txt.height(slice.label) + 12;
    }
    const side = std.mem.eql(u8, position, "left") or std.mem.eql(u8, position, "right");
    const top = std.mem.eql(u8, position, "top");
    const centered = std.mem.eql(u8, position, "center");
    const title_height: usize = if (title.len > 0) txt.height(title) + 30 else 20;
    const width = @max(txt.width(title) + 40, if (side) 500 + legend_width else @max(@as(usize, 500), legend_width + 40));
    const height = title_height + if (side or centered) @max(@as(usize, 460), legend_height + 40) else 460 + legend_height + 20;
    const cx: f64 = @floatFromInt(if (std.mem.eql(u8, position, "left")) legend_width + 250 else if (side) @as(usize, 250) else width / 2);
    const cy: f64 = @floatFromInt(title_height + 230 + if (top) legend_height + 20 else @as(usize, 0));
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "pie", prefix);
    if (title.len > 0) try txt.draw(&out, width / 2, 12, title);
    var angle: f64 = -std.math.pi / 2.0;
    for (slices.items, 0..) |slice, i| {
        const sweep = slice.value / total * 2 * std.math.pi;
        const finish = angle + sweep;
        const mid = angle + sweep / 2;
        const offset: f64 = if (std.mem.eql(u8, highlight, slice.label)) 12 else 0;
        const x = cx + @cos(mid) * offset;
        const y = cy + @sin(mid) * offset;
        const radius: f64 = 190;
        const fill = try doc.palette(i);
        try out.fmt("<g data-slice=\"{d}\" data-value=\"{d}\" fill=\"{s}\">", .{ i, slice.value, fill });
        if (slice.value == total) {
            try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"190\"/>", .{ x, y });
        } else if (slice.value > 0) {
            try out.fmt("<path d=\"M {d} {d} L {d} {d} A 190 190 0 {d} 1 {d} {d} Z\"/>", .{ x, y, x + radius * @cos(angle), y + radius * @sin(angle), @as(u8, if (sweep > std.math.pi) 1 else 0), x + radius * @cos(finish), y + radius * @sin(finish) });
        }
        const percent = try std.fmt.allocPrint(temp, "{d:.1}%", .{slice.value / total * 100});
        if (slice.value > 0 and text_position >= hole) try out.text(@intFromFloat(x + radius * text_position * @cos(mid)), @intFromFloat(y + radius * text_position * @sin(mid)), percent);
        try out.add("</g>");
        angle = finish;
    }
    if (hole > 0) try out.fmt("<circle data-donut=\"true\" cx=\"{d}\" cy=\"{d}\" r=\"{d}\" fill=\"{s}\"/>", .{ cx, cy, 190 * hole, if (doc.theme == .dark) "#0d1117" else "#ffffff" });
    try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"190\" fill=\"none\" stroke-width=\"{d}\"/>", .{ cx, cy, stroke_width });
    const lx: usize = if (std.mem.eql(u8, position, "left")) 20 else if (side) 480 else if (centered) @as(usize, @intFromFloat(cx)) - legend_width / 2 else (width - legend_width) / 2;
    const ly: usize = if (side) title_height + 24 else if (top) title_height else if (centered) @as(usize, @intFromFloat(cy)) - @min(legend_height / 2, @as(usize, @intFromFloat(cy))) else title_height + 460;
    var legend_y = ly;
    for (slices.items, 0..) |slice, i| {
        try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"18\" height=\"18\" fill=\"{s}\"/>", .{ lx, legend_y, try doc.palette(i) });
        const label = if (show) try std.fmt.allocPrint(temp, "{s} [{d}]", .{ slice.label, slice.value }) else slice.label;
        try txt.draw(&out, lx + 28 + txt.width(label) / 2, legend_y, label);
        legend_y += txt.height(label) + 12;
    }
    return out.finish();
}
