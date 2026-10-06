const std = @import("std");
const svg = @import("svg.zig");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const Task = struct { label: []const u8, section: usize, score: u8, actors: std.ArrayList(usize) = .empty };
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var tasks: std.ArrayList(Task) = .empty;
    var sections: std.ArrayList([]const u8) = .empty;
    try sections.append(temp, "");
    var actors: std.ArrayList([]const u8) = .empty;
    var section: usize = 0;
    var title: []const u8 = "";
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
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
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
        var fields = std.mem.splitScalar(u8, line[colon + 1 ..], ':');
        const score = std.fmt.parseInt(u8, d.trim(fields.next().?), 10) catch return error.InvalidSyntax;
        if (score > 5) return error.InvalidSyntax;
        var task: Task = .{ .label = try txt.parse(temp, d.trim(line[0..colon])), .score = score, .section = section };
        if (fields.next()) |names| {
            var parts = std.mem.splitScalar(u8, names, ',');
            while (parts.next()) |part| {
                const name = try txt.parse(temp, d.trim(part));
                if (name.len == 0) continue;
                var id: ?usize = null;
                for (actors.items, 0..) |existing, i| if (std.mem.eql(u8, name, existing)) {
                    id = i;
                };
                if (id == null) {
                    if (actors.items.len == 32) return error.LimitExceeded;
                    id = actors.items.len;
                    try actors.append(temp, name);
                }
                try task.actors.append(temp, id.?);
            }
        }
        if (fields.next() != null) return error.InvalidSyntax;
        if (tasks.items.len == 256) return error.LimitExceeded;
        try tasks.append(temp, task);
    }
    if (tasks.items.len == 0) {
        var width: usize = @max(240, txt.width(title) + 40);
        var height: usize = if (title.len > 0) txt.height(title) + 40 else 20;
        for (sections.items[1..]) |label| {
            width = @max(width, txt.width(label) + 64);
            height += txt.height(label) + 40;
        }
        var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
        defer out.deinit();
        try out.start(width, height + 20, "journey", prefix);
        if (title.len > 0) try txt.draw(&out, width / 2, 12, title);
        var y: usize = if (title.len > 0) txt.height(title) + 40 else 20;
        for (sections.items[1..], 0..) |label, i| {
            try out.fmt("<rect data-empty-section=\"{d}\" x=\"20\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\"/>", .{ i, y, width - 40, txt.height(label) + 24, try doc.palette(i) });
            try txt.draw(&out, width / 2, y + 12, label);
            y += txt.height(label) + 40;
        }
        return out.finish();
    }
    var cell: usize = 180;
    var task_height: usize = 48;
    var section_height: usize = 44;
    var legend_width: usize = 0;
    var legend_height: usize = 0;
    for (actors.items) |name| {
        legend_width = @max(legend_width, txt.width(name) + 100);
        legend_height += txt.height(name) + 14;
    }
    for (tasks.items) |task| {
        cell = @max(cell, @max(txt.width(task.label) + 40, task.actors.items.len * 20 + 40));
        task_height = @max(task_height, txt.height(task.label) + 28);
    }
    for (sections.items) |s| {
        cell = @max(cell, txt.width(s) + 40);
        section_height = @max(section_height, txt.height(s) + 24);
    }
    const top = if (title.len > 0) txt.height(title) + 40 else 30;
    const task_y = top + section_height + 16;
    const score_bottom = task_y + task_height + 280;
    const width = @max(@max(tasks.items.len * (cell + 24) + 100, txt.width(title) + 40), legend_width);
    const height = score_bottom + 100 + legend_height;
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "journey", prefix);
    if (title.len > 0) try txt.draw(&out, width / 2, 15, title);
    for (tasks.items, 0..) |task, i| {
        const x = 50 + i * (cell + 24);
        const cx = x + cell / 2;
        const cy: usize = score_bottom - @as(usize, task.score) * 42;
        const fill = try doc.palette(task.section);
        try out.fmt("<g data-task=\"{d}\" data-score=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\"/>", .{ i, task.score, x, top, cell, section_height, fill });
        try txt.draw(&out, cx, top + 12, sections.items[task.section]);
        try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"5\" fill=\"{s}\"/>", .{ x, task_y, cell, task_height, fill });
        try txt.draw(&out, cx, task_y + 14, task.label);
        try out.fmt("<path d=\"M {d} {d} V {d}\" fill=\"none\" stroke-dasharray=\"4 4\"/><circle cx=\"{d}\" cy=\"{d}\" r=\"22\" fill=\"{s}\"/><circle cx=\"{d}\" cy=\"{d}\" r=\"2\"/><circle cx=\"{d}\" cy=\"{d}\" r=\"2\"/>", .{ cx, task_y + task_height, cy, cx, cy, fill, cx - 7, cy - 6, cx + 7, cy - 6 });
        if (task.score == 3) try out.fmt("<path d=\"M {d} {d} h 18\" fill=\"none\"/>", .{ cx - 9, cy + 8 }) else try out.fmt("<path d=\"M {d} {d} Q {d} {d} {d} {d}\" fill=\"none\"/>", .{ cx - 10, cy + 8, cx, if (task.score > 3) cy + 21 else cy - 3, cx + 10, cy + 8 });
        for (task.actors.items, 0..) |actor, j| {
            try out.fmt("<circle data-actor=\"{d}\" cx=\"{d}\" cy=\"{d}\" r=\"7\" fill=\"{s}\"/>", .{ actor, cx + j * 20 - (task.actors.items.len - 1) * 10, cy + 40, try doc.palette(actor) });
        }
        try out.add("</g>");
    }
    var legend_y = score_bottom + 70;
    for (actors.items, 0..) |name, i| {
        try out.fmt("<circle cx=\"50\" cy=\"{d}\" r=\"7\" fill=\"{s}\"/>", .{ legend_y + 10, try doc.palette(i) });
        try txt.draw(&out, 70 + txt.width(name) / 2, legend_y, name);
        legend_y += txt.height(name) + 14;
    }
    return out.finish();
}
