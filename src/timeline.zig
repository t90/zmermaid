const std = @import("std");
const svg = @import("svg.zig");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const Period = struct { label: []const u8, section: usize, events: std.ArrayList([]const u8) = .empty };
fn label(out: *svg.Svg, x: usize, y: usize, value: []const u8, fg: []const u8) !void {
    var lines = std.mem.splitScalar(u8, value, '\n');
    var top = y + 10;
    while (lines.next()) |line| {
        try out.textColor(x, top, line, fg);
        top += 20;
    }
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var periods: std.ArrayList(Period) = .empty;
    var sections: std.ArrayList([]const u8) = .empty;
    try sections.append(temp, "");
    var section: usize = 0;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    const header = d.trim(lines.next().?);
    var words = std.mem.tokenizeAny(u8, header, " \t\r");
    _ = words.next();
    const direction = words.next() orelse "LR";
    if (words.next() != null or (!std.mem.eql(u8, direction, "LR") and !std.mem.eql(u8, direction, "TD"))) return error.InvalidSyntax;
    const vertical = std.mem.eql(u8, direction, "TD");
    var title: []const u8 = "";
    var total: usize = 0;
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (txt.starts(line, "title ")) {
            title = try txt.parse(temp, d.unquote(line[6..]));
            continue;
        }
        if (txt.starts(line, "section ")) {
            if (sections.items.len == 128) return error.LimitExceeded;
            try sections.append(temp, try txt.parse(temp, d.trim(line[8..])));
            section = sections.items.len - 1;
            continue;
        }
        var split: usize = 0;
        while (split < line.len and line[split] != ':') split += 1;
        const period = d.trim(line[0..split]);
        if (period.len > 0) {
            if (periods.items.len == 256) return error.LimitExceeded;
            try periods.append(temp, .{ .label = try txt.parse(temp, period), .section = section });
        }
        if (split < line.len) {
            if (periods.items.len == 0) return error.InvalidSyntax;
            var rest = line[split + 1 ..];
            while (true) {
                const next = std.mem.indexOf(u8, rest, ": ");
                const value = d.trim(rest[0 .. next orelse rest.len]);
                if (value.len == 0) return error.InvalidSyntax;
                if (total == 1024) return error.LimitExceeded;
                total += 1;
                try periods.items[periods.items.len - 1].events.append(temp, try txt.parse(temp, value));
                if (next) |n| {
                    rest = rest[n + 2 ..];
                } else break;
            }
        }
    }
    if (periods.items.len == 0) return error.InvalidSyntax;
    const single = try doc.flag("config.timeline.disableMulticolor", false);
    var box_width: usize = 180;
    var row_height: usize = 100;
    var max_events_height: usize = 0;
    var section_height: usize = 0;
    var period_height: usize = 0;
    for (sections.items) |s| {
        box_width = @max(box_width, txt.width(s) + 40);
        if (s.len > 0) section_height = @max(section_height, txt.height(s) + 24);
    }
    for (periods.items) |period| {
        period_height = @max(period_height, txt.height(period.label) + 24);
        box_width = @max(box_width, txt.width(period.label) + 40);
        var event_height: usize = 0;
        for (period.events.items) |event| {
            box_width = @max(box_width, txt.width(event) + 40);
            event_height += txt.height(event) + 32;
        }
        max_events_height = @max(max_events_height, event_height);
        row_height = @max(row_height, @max(txt.height(period.label) + 32, event_height) + section_height + 32);
    }
    const title_height: usize = if (title.len > 0) txt.height(title) + 40 else 24;
    const width = if (vertical) 2 * box_width + 160 else periods.items.len * (box_width + 32) + 80;
    const height = title_height + if (vertical) periods.items.len * row_height + 40 else section_height + period_height + max_events_height + 84;
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(@max(width, txt.width(title) + 40), height, "timeline", prefix);
    if (title.len > 0) try txt.draw(&out, @max(width, txt.width(title) + 40) / 2, 12, title);
    const default_fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    for (periods.items, 0..) |period, i| {
        const color_index = if (single) @as(usize, 0) else if (sections.items.len > 1) period.section - @as(usize, if (period.section > 0) 1 else 0) else i;
        const fill = try doc.palette(color_index);
        var buf: [80]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "config.themeVariables.cScaleLabel{d}", .{color_index}) catch return error.LimitExceeded;
        const fg = if (doc.get(key)) |c| try d.color(c) else default_fg;
        const x: usize = if (vertical) 40 else 40 + i * (box_width + 32);
        const y = title_height + if (vertical) i * row_height else 0;
        try out.fmt("<g data-period=\"{d}\" data-section=\"{d}\">", .{ i, period.section });
        if (sections.items[period.section].len > 0) {
            try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\"/>", .{ x, y, if (vertical) 2 * box_width + 80 else box_width, section_height, fill });
            try label(&out, x + (if (vertical) 2 * box_width + 80 else box_width) / 2, y + 12, sections.items[period.section], fg);
        }
        const py = y + section_height + 20;
        const ph = txt.height(period.label) + 24;
        try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"6\" fill=\"{s}\"/>", .{ x, py, box_width, ph, fill });
        try label(&out, x + box_width / 2, py + 12, period.label, fg);
        var ey = if (vertical) py else py + ph + 24;
        const ex = if (vertical) x + box_width + 80 else x;
        // Paint all connectors below the event cards, not across earlier labels.
        for (period.events.items) |event| {
            const eh = txt.height(event) + 24;
            try out.fmt("<path d=\"M {d} {d} L {d} {d}\" fill=\"none\"/>", .{ if (vertical) x + box_width else x + box_width / 2, if (vertical) py + ph / 2 else py + ph, if (vertical) ex else ex + box_width / 2, ey + if (vertical) eh / 2 else 0 });
            ey += eh + 8;
        }
        ey = if (vertical) py else py + ph + 24;
        for (period.events.items, 0..) |event, j| {
            const eh = txt.height(event) + 24;
            try out.fmt("<rect data-event=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" fill=\"{s}\"/>", .{ j, ex, ey, box_width, eh, fill });
            try label(&out, ex + box_width / 2, ey + 12, event, fg);
            ey += eh + 8;
        }
        try out.add("</g>");
    }
    return out.finish();
}
