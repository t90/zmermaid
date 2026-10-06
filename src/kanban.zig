const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const rich = @import("rich_text.zig");
const wrapping = @import("text_wrap.zig");
const svg = @import("svg.zig");
const data = @import("chart_data.zig");
const Item = struct { id: []const u8, label: []const u8, column: usize, ticket: []const u8 = "", ticket_raw: []const u8 = "", assigned: []const u8 = "", priority: []const u8 = "", icon: []const u8 = "", h: usize = 0 };
const Column = struct { label: []const u8, height: usize = 0, metadata: Item };
fn metadata(item: *Item, source: []const u8) d.Error!void {
    var rest = d.trim(source);
    if (rest.len == 0) return;
    if (!txt.starts(rest, "@{") or !std.mem.endsWith(u8, rest, "}")) return error.UnsupportedSyntax;
    rest = rest[2 .. rest.len - 1];
    var seen: u8 = 0;
    while (d.trim(rest).len > 0) {
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.InvalidSyntax;
        const key = d.trim(rest[0..colon]);
        rest = d.trim(rest[colon + 1 ..]);
        if (rest.len == 0) return error.InvalidSyntax;
        var value: []const u8 = undefined;
        if (rest[0] == '\'' or rest[0] == '"') {
            const end = std.mem.indexOfScalarPos(u8, rest, 1, rest[0]) orelse return error.InvalidSyntax;
            value = rest[1..end];
            rest = d.trim(rest[end + 1 ..]);
        } else {
            const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
            value = d.trim(rest[0..end]);
            rest = d.trim(rest[end..]);
        }
        if (value.len > 512) return error.LimitExceeded;
        const bit: u8 = if (std.mem.eql(u8, key, "ticket")) 1 else if (std.mem.eql(u8, key, "assigned")) 2 else if (std.mem.eql(u8, key, "priority")) 4 else if (std.mem.eql(u8, key, "label")) 8 else if (std.mem.eql(u8, key, "icon")) 16 else return error.UnsupportedSyntax;
        if (seen & bit != 0) return error.InvalidSyntax;
        seen |= bit;
        switch (bit) {
            1 => item.ticket = value,
            2 => item.assigned = value,
            4 => item.priority = value,
            8 => item.label = value,
            else => item.icon = value,
        }
        if (rest.len > 0) {
            if (rest[0] != ',') return error.InvalidSyntax;
            rest = rest[1..];
        }
    }
}
fn ticketUrl(a: std.mem.Allocator, base: []const u8, ticket: []const u8) ![]const u8 {
    var encoded: std.ArrayList(u8) = .empty;
    for (ticket) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try encoded.append(a, c) else try encoded.appendSlice(a, &.{ '%', "0123456789ABCDEF"[c >> 4], "0123456789ABCDEF"[c & 15] });
    }
    var url: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitSequence(u8, base, "#TICKET#");
    try url.appendSlice(a, parts.next().?);
    while (parts.next()) |part| {
        try url.appendSlice(a, encoded.items);
        try url.appendSlice(a, part);
    }
    return url.toOwnedSlice(a);
}
fn lines(out: *svg.Svg, x: usize, y: usize, s: []const u8, fg: []const u8, markdown: bool) !void {
    var parts = std.mem.splitScalar(u8, s, '\n');
    var top = y + 10;
    while (parts.next()) |part| {
        if (markdown) try rich.draw(out, x, top, part, fg) else try out.textColor(x, top, part, fg);
        top += 20;
    }
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var columns: std.ArrayList(Column) = .empty;
    var items: std.ArrayList(Item) = .empty;
    const cw = data.coord(try doc.num("config.kanban.sectionWidth", 240, 120, 2000));
    const padding = data.coord(try doc.num("config.kanban.padding", 16, 4, 100));
    if (cw <= padding * 2 + 40) return error.InvalidSyntax;
    const ticket_base = doc.get("config.kanban.ticketBaseUrl") orelse "";
    if (ticket_base.len > 4096) return error.LimitExceeded;
    if (ticket_base.len > 0) {
        // SVG anchors are inert until clicked. The embedding host owns navigation policy.
        if (!txt.starts(ticket_base, "https://") and !txt.starts(ticket_base, "http://")) return error.UnsupportedSyntax;
        for (ticket_base) |c| if (c <= 32 or c == '\\' or c == '"' or c == '\'') return error.InvalidSyntax;
    }
    var source = std.mem.splitScalar(u8, doc.source, '\n');
    _ = source.next();
    var base_indent: ?usize = null;
    var task_indent: ?usize = null;
    while (source.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        const indent = raw.len - std.mem.trimStart(u8, raw, " ").len;
        if (indent < raw.len and raw[indent] == '\t') return error.UnsupportedSyntax;
        if (base_indent == null) base_indent = indent;
        if (indent < base_indent.?) return error.InvalidSyntax;
        const column = indent == base_indent.?;
        if (!column) {
            if (task_indent == null) task_indent = indent;
            if (indent != task_indent.?) return error.UnsupportedSyntax;
        } else task_indent = null;
        var id: []const u8 = undefined;
        var label: []const u8 = undefined;
        var props: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, '[')) |start| {
            var end = start + 1;
            const content_start = line.len - std.mem.trimStart(u8, line[start + 1 ..], " \t").len;
            var quote: u8 = 0;
            while (end < line.len) : (end += 1) {
                if (line[end] == '"' or line[end] == '\'') {
                    if (end == content_start) quote = line[end] else if (quote == line[end]) quote = 0;
                }
                if (line[end] == ']' and quote == 0) break;
            }
            if (end == line.len) return error.InvalidSyntax;
            id = d.trim(line[0..start]);
            label = d.unquote(line[start + 1 .. end]);
            props = d.trim(line[end + 1 ..]);
            if (id.len == 0) id = label;
        } else {
            if (std.mem.indexOfAny(u8, line, "@{}()") != null) return error.UnsupportedSyntax;
            id = line;
            label = d.unquote(line);
        }
        if (label.len == 0 or id.len == 0) return error.InvalidSyntax;
        var item: Item = .{ .id = id, .label = label, .column = if (column) columns.items.len else columns.items.len - 1 };
        try metadata(&item, props);
        item.label = try wrapping.wrap(temp, try rich.parse(temp, item.label), cw - padding * 2 - 24);
        item.ticket_raw = item.ticket;
        item.ticket = try wrapping.wrap(temp, item.ticket, cw - padding * 2 - 24);
        if (column) {
            if (columns.items.len == 64) return error.LimitExceeded;
            const ticket_height = if (item.ticket.len > 0) txt.height(item.ticket) + 6 else @as(usize, 0);
            try columns.append(temp, .{ .label = item.label, .height = txt.height(item.label) + padding * 2 + ticket_height, .metadata = item });
        } else {
            if (items.items.len == 512) return error.LimitExceeded;
            item.assigned = try wrapping.wrap(temp, item.assigned, cw - padding * 2 - 24);
            item.priority = try wrapping.wrap(temp, item.priority, cw - padding * 2 - 24);
            item.h = txt.height(item.label) + 24;
            if (item.icon.len > 0) {
                _ = try doc.assets.get(item.icon);
                item.h += 30;
            }
            for ([_][]const u8{ item.ticket, item.assigned, item.priority }) |v| if (v.len > 0) {
                item.h += txt.height(v) + 6;
            };
            columns.items[item.column].height += item.h + padding;
            try items.append(temp, item);
        }
    }
    if (columns.items.len == 0) return error.InvalidSyntax;
    var h: usize = 120;
    for (columns.items) |col| h = @max(h, col.height + padding + 40);
    const w = columns.items.len * (cw + 20) + 20;
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const board = if (doc.theme == .dark) "#1b2638" else "#f1f4f8";
    const card = if (doc.theme == .dark) "#243247" else "#ffffff";
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(w, h, "kanban", prefix);
    for (columns.items, 0..) |col, ci| {
        const x = 20 + ci * (cw + 20);
        const fill = try doc.palette(ci);
        try out.fmt("<g data-column=\"{d}\"><rect x=\"{d}\" y=\"20\" width=\"{d}\" height=\"{d}\" rx=\"8\" fill=\"{s}\" stroke=\"none\"/><path d=\"M {d} 24 H {d}\" stroke=\"{s}\" stroke-width=\"6\"/>", .{ ci, x, cw, h - 40, board, x + 8, x + cw - 8, fill });
        try lines(&out, x + cw / 2, 20 + padding, col.label, fg, true);
        var y = 20 + padding * 2 + txt.height(col.label);
        // Same-indent entries are columns even when they carry metadata.
        // Preserve nonvisual metadata rather than guessing a task hierarchy.
        try out.add("<g data-assigned=\"");
        try out.escape(col.metadata.assigned);
        try out.add("\" data-priority=\"");
        try out.escape(col.metadata.priority);
        try out.add("\"/>");
        if (col.metadata.ticket.len > 0) {
            if (ticket_base.len > 0) {
                try out.add("<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"");
                try out.escape(try ticketUrl(temp, ticket_base, col.metadata.ticket_raw));
                try out.add("\">");
            }
            try lines(&out, x + cw / 2, y, col.metadata.ticket, fg, false);
            y += txt.height(col.metadata.ticket) + 6;
            if (ticket_base.len > 0) try out.add("</a>");
        }
        for (items.items, 0..) |item, ii| if (item.column == ci) {
            try out.fmt("<g data-task=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"5\" fill=\"{s}\" stroke=\"{s}\" stroke-opacity=\"0.3\"/>", .{ ii, x + padding, y, cw - padding * 2, item.h, card, fg });
            var top = y + 12;
            if (item.icon.len > 0) {
                try @import("assets.zig").draw(&out, try doc.assets.get(item.icon), x + cw / 2 - 12, top, 24, 24);
                top += 30;
            }
            try lines(&out, x + cw / 2, top, item.label, fg, true);
            top += txt.height(item.label) + 6;
            if (item.ticket.len > 0) {
                if (ticket_base.len > 0) {
                    try out.add("<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"");
                    try out.escape(try ticketUrl(temp, ticket_base, item.ticket_raw));
                    try out.add("\">");
                }
                try lines(&out, x + cw / 2, top, item.ticket, fg, false);
                top += txt.height(item.ticket) + 6;
                if (ticket_base.len > 0) try out.add("</a>");
            }
            if (item.assigned.len > 0) {
                try lines(&out, x + cw / 2, top, item.assigned, fg, false);
                top += txt.height(item.assigned) + 6;
            }
            if (item.priority.len > 0) {
                const priority_color = if (std.ascii.eqlIgnoreCase(item.priority, "Very High") or std.ascii.eqlIgnoreCase(item.priority, "High")) (if (doc.theme == .dark) "#ff9292" else "#b42318") else fg;
                try lines(&out, x + cw / 2, top, item.priority, priority_color, false);
            }
            try out.add("</g>");
            y += item.h + padding;
        };
        try out.add("</g>");
    }
    return out.finish();
}
