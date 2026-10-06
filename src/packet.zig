const std = @import("std");
const svg = @import("svg.zig");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const Field = struct { start: usize, end: usize, label: []const u8 };
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var fields: std.ArrayList(Field) = .empty;
    var title: []const u8 = "";
    var next: usize = 0;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (txt.starts(line, "title ")) {
            title = try txt.parse(temp, d.unquote(line[6..]));
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
        const range = d.trim(line[0..colon]);
        if (range.len == 0) return error.InvalidSyntax;
        var start = next;
        var end = next;
        if (range[0] == '+') {
            const count = std.fmt.parseInt(usize, range[1..], 10) catch return error.InvalidSyntax;
            if (count == 0 or count > 65536) return error.InvalidSyntax;
            end = start + count - 1;
        } else {
            var parts = std.mem.splitScalar(u8, range, '-');
            start = std.fmt.parseInt(usize, d.trim(parts.next().?), 10) catch return error.InvalidSyntax;
            end = if (parts.next()) |part| std.fmt.parseInt(usize, d.trim(part), 10) catch return error.InvalidSyntax else start;
            if (parts.next() != null) return error.InvalidSyntax;
        }
        if (start != next or end < start) return error.InvalidSyntax;
        if (end > 65535 or fields.items.len == 512) return error.LimitExceeded;
        const rawlabel = d.trim(line[colon + 1 ..]);
        if (rawlabel.len < 2 or rawlabel[0] != '"' or rawlabel[rawlabel.len - 1] != '"') return error.InvalidSyntax;
        try fields.append(temp, .{ .start = start, .end = end, .label = try txt.parse(temp, d.unquote(rawlabel)) });
        next = end + 1;
    }
    if (fields.items.len == 0) return error.InvalidSyntax;
    const bitsf = try doc.num("config.packet.bitsPerRow", 32, 1, 64);
    if (@floor(bitsf) != bitsf) return error.InvalidSyntax;
    const bits: usize = @intFromFloat(bitsf);
    const show = try doc.flag("config.packet.showBits", true);
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const start_color = if (doc.get("config.themeVariables.packet.startByteColor")) |c| try d.color(c) else fg;
    const end_color = if (doc.get("config.themeVariables.packet.endByteColor")) |c| try d.color(c) else fg;
    const fill = if (doc.get("config.themeVariables.packet.blockFillColor")) |c| try d.color(c) else if (doc.theme == .dark) "#16213e" else "#eef4ff";
    var unit: usize = 28;
    var row: usize = 80;
    for (fields.items) |field| {
        row = @max(row, txt.height(field.label) + 48);
        var at = field.start;
        while (at <= field.end) {
            const end = @min(field.end, (at / bits + 1) * bits - 1);
            const count = end - at + 1;
            unit = @max(unit, (txt.width(field.label) + 16 + count - 1) / count);
            if (show) {
                const digits = try std.fmt.allocPrint(temp, "{d}", .{end});
                unit = @max(unit, (txt.width(digits) * (if (count > 1) @as(usize, 2) else 1) + 24 + count - 1) / count);
            }
            at = end + 1;
        }
    }
    const rows = (next + bits - 1) / bits;
    if (rows > 2048) return error.LimitExceeded;
    const top = if (title.len > 0) txt.height(title) + 50 else 40;
    const width = @max(bits * unit + 80, txt.width(title) + 40);
    const height = top + rows * row + 40;
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "packet", prefix);
    if (title.len > 0) try txt.draw(&out, width / 2, 12, title);
    for (fields.items, 0..) |field, index| {
        var at = field.start;
        while (at <= field.end) {
            const end = @min(field.end, (at / bits + 1) * bits - 1);
            const x = 40 + (at % bits) * unit;
            const y = top + (at / bits) * row;
            const w = (end - at + 1) * unit;
            try out.fmt("<rect data-field=\"{d}\" data-start=\"{d}\" data-end=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\"/>", .{ index, at, end, x, y, w, row, fill });
            if (show) {
                const first = try std.fmt.allocPrint(temp, "{d}", .{at});
                try out.textColor(x + 8 + txt.width(first) / 2, y + 12, first, start_color);
                if (end != at) {
                    const last = try std.fmt.allocPrint(temp, "{d}", .{end});
                    try out.textColor(x + w - 8 - txt.width(last) / 2, y + 12, last, end_color);
                }
            }
            try txt.draw(&out, x + w / 2, y + 30, field.label);
            at = end + 1;
        }
    }
    return out.finish();
}
