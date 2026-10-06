const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const cal = @import("calendar.zig");
const data = @import("chart_data.zig");
const Task = struct { id: []const u8, label: []const u8, section: usize, start_spec: []const u8 = "", end_spec: []const u8, start: ?i64 = null, end: ?i64 = null, display_end: ?i64 = null, done: bool = false, active: bool = false, critical: bool = false, milestone: bool = false, vertical: bool = false, row: usize = 0, action: @import("interaction.zig").Action = .{} };
const Exclusions = struct {
    days: [7]bool = .{false} ** 7,
    dates: std.ArrayList(i64) = .empty,
    includes: std.ArrayList(i64) = .empty,
    fn excluded(self: *const Exclusions, t: i64) bool {
        const date = @divFloor(t, cal.day);
        for (self.includes.items) |v| if (date == v) return false;
        if (self.days[cal.weekday(t)]) return true;
        for (self.dates.items) |v| if (date == v) return true;
        return false;
    }
};
fn refs(tasks: []Task, raw: []const u8, start: bool) d.Error!?i64 {
    var names = std.mem.tokenizeAny(u8, raw, " \t");
    var result: ?i64 = null;
    var pending = false;
    while (names.next()) |name| {
        var found = false;
        var reverse = tasks.len;
        while (reverse > 0) {
            reverse -= 1;
            const t = tasks[reverse];
            if (!std.mem.eql(u8, t.id, name)) continue;
            found = true;
            const value = if (start) t.start else t.end;
            if (value) |v| {
                result = if (result) |r| (if (start) @min(r, v) else @max(r, v)) else v;
            } else pending = true;
            break;
        }
        if (!found) return error.InvalidSyntax;
    }
    if (pending) return null;
    return result orelse return error.InvalidSyntax;
}
fn xcoord(t: i64, low: i64, high: i64, left: usize, width: usize) usize {
    return left + data.coord(@as(f64, @floatFromInt(t - low)) / @as(f64, @floatFromInt(high - low)) * @as(f64, @floatFromInt(width)));
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var tasks: std.ArrayList(Task) = .empty;
    var clicks: std.ArrayList([]const u8) = .empty;
    var sections: std.ArrayList([]const u8) = .empty;
    try sections.append(temp, "");
    var section: usize = 0;
    var automatic_ids: usize = 0;
    var date_format: []const u8 = "YYYY-MM-DD";
    var axis_format: []const u8 = "%Y-%m-%d";
    var excludes: []const u8 = "";
    var includes: []const u8 = "";
    var weekend: usize = 6;
    var tick: []const u8 = "";
    var week_start: usize = 0;
    var inclusive = false;
    var today_enabled = true;
    var today_explicit = false;
    var today_style: @import("chart_style.zig").Style = .{};
    var today_opacity: f64 = 1;
    const compact_raw = doc.get("displayMode") orelse doc.get("config.gantt.displayMode") orelse "";
    if (compact_raw.len > 0 and !std.mem.eql(u8, compact_raw, "compact")) return error.UnsupportedSyntax;
    const compact = std.mem.eql(u8, compact_raw, "compact");
    const plot_width = data.coord(try doc.num("config.gantt.useWidth", 1000, 200, 10000));
    const bar_height = data.coord(try doc.num("config.gantt.barHeight", 24, 8, 200));
    const gap = data.coord(try doc.num("config.gantt.barGap", 12, 0, 100));
    const top_axis = try doc.flag("config.gantt.topAxis", false);
    const right = data.coord(try doc.num("config.gantt.rightPadding", 30, 0, 2000));
    const section_styles = data.coord(try doc.num("config.gantt.numberSectionStyles", 8, 1, 128));
    const custom_css = doc.get("config.themeCSS") orelse "";
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        var line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (std.mem.indexOf(u8, line, "%%")) |comment| line = d.trim(line[0..comment]);
        if (txt.starts(line, "title ")) {
            doc.title = try txt.parse(doc.a, d.trim(line[6..]));
            continue;
        }
        if (txt.starts(line, "dateFormat ")) {
            date_format = d.trim(line[11..]);
            continue;
        }
        if (txt.starts(line, "axisFormat ")) {
            axis_format = d.trim(line[11..]);
            continue;
        }
        if (txt.starts(line, "excludes ")) {
            excludes = d.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "includes ")) {
            includes = d.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "tickInterval ")) {
            tick = d.trim(line[13..]);
            continue;
        }
        if (std.mem.eql(u8, line, "inclusiveEndDates")) {
            inclusive = true;
            continue;
        }
        if (txt.starts(line, "todayMarker ")) {
            const value = d.trim(line[12..]);
            today_enabled = !std.mem.eql(u8, value, "off");
            today_explicit = today_enabled;
            if (today_enabled) {
                today_style = .{};
                today_opacity = 1;
                var parts: @import("chart_style.zig").CssParts = .{ .rest = value };
                while (try parts.next()) |part| {
                    const colon = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidSyntax;
                    if (std.mem.eql(u8, d.trim(part[0..colon]), "opacity")) {
                        today_opacity = try d.number(part[colon + 1 ..]);
                        if (today_opacity < 0 or today_opacity > 1) return error.InvalidSyntax;
                    } else today_style.merge(try @import("chart_style.zig").parse(part, false));
                }
                if (today_style.fill != null or today_style.text != null or today_style.radius != null or today_style.italic != null or today_style.bold != null or today_style.animation != null) return error.UnsupportedSyntax;
            }
            continue;
        }
        if (txt.starts(line, "weekday ") or txt.starts(line, "weekend ")) {
            const is_weekend = txt.starts(line, "weekend ");
            const value = d.trim(line[8..]);
            var found = false;
            for (cal.weekdays, 0..) |v, i| if (std.ascii.eqlIgnoreCase(value, v)) {
                if (is_weekend) weekend = i else week_start = i;
                found = true;
                break;
            };
            if (!found) return error.InvalidSyntax;
            continue;
        }
        if (txt.starts(line, "section ")) {
            if (sections.items.len == 128) return error.LimitExceeded;
            try sections.append(temp, try txt.parse(temp, d.trim(line[8..])));
            section = sections.items.len - 1;
            continue;
        }
        if (txt.starts(line, "click ")) {
            if (clicks.items.len == 512) return error.LimitExceeded;
            try clicks.append(temp, line);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.UnsupportedSyntax;
        var task: Task = .{ .id = "", .label = try txt.parse(temp, d.trim(line[0..colon])), .section = section, .end_spec = "" };
        var parts = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
        var values: [3][]const u8 = undefined;
        var count: usize = 0;
        while (parts.next()) |part| {
            const v = d.trim(part);
            if (v.len == 0) {
                if (task.vertical and count > 0 and count < 3 and parts.next() == null) {
                    values[count] = "0s";
                    count += 1;
                    break;
                }
                return error.InvalidSyntax;
            }
            if (count == 0 and std.mem.eql(u8, v, "done")) task.done = true else if (count == 0 and std.mem.eql(u8, v, "active")) task.active = true else if (count == 0 and std.mem.eql(u8, v, "crit")) task.critical = true else if (count == 0 and std.mem.eql(u8, v, "milestone")) task.milestone = true else if (count == 0 and std.mem.eql(u8, v, "vert")) task.vertical = true else {
                if (count == 3) return error.InvalidSyntax;
                values[count] = v;
                count += 1;
            }
        }
        if (count == 0) return error.InvalidSyntax;
        task.end_spec = values[count - 1];
        if (count >= 2) task.start_spec = values[count - 2];
        if (count == 3) task.id = values[0] else {
            automatic_ids += 1;
            task.id = try std.fmt.allocPrint(temp, "task{d}", .{automatic_ids});
        }
        if (tasks.items.len == 512) return error.LimitExceeded;
        try tasks.append(temp, task);
    }
    var actions = struct { allocator: std.mem.Allocator, nodes: std.ArrayList(Task), labels: std.ArrayList([]const u8) = .empty }{ .allocator = temp, .nodes = tasks };
    for (clicks.items) |click| try @import("interaction.zig").parseGantt(&actions, click);
    if (tasks.items.len == 0) {
        const left = data.coord(try doc.num("config.gantt.leftPadding", 60, 40, 10000));
        var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
        defer out.deinit();
        try out.start(left + plot_width + right, 120, "gantt", prefix);
        if (custom_css.len > 0) try @import("scoped_css.zig").emit(&out, custom_css);
        try out.fmt("<path data-empty-gantt=\"true\" d=\"M {d} 80 H {d}\" fill=\"none\"/>", .{ left, left + plot_width });
        return out.finish();
    }
    var excluded: Exclusions = .{};
    for ([_][]const u8{ excludes, includes }, 0..) |list, li| {
        var parts = std.mem.tokenizeAny(u8, list, ", \t");
        while (parts.next()) |part| {
            // Legacy examples include this token, but upstream only gives
            // special meaning to "weekends" and explicit weekday names.
            if (std.mem.eql(u8, part, "weekdays")) continue;
            if (li == 0 and std.mem.eql(u8, part, "weekends")) {
                excluded.days[weekend] = true;
                excluded.days[(weekend + 1) % 7] = true;
                continue;
            }
            var found = false;
            for (cal.weekdays, 0..) |v, i| if (std.ascii.eqlIgnoreCase(v, part)) {
                if (li == 1) return error.UnsupportedSyntax;
                excluded.days[i] = true;
                found = true;
                break;
            };
            if (found) continue;
            const time = try cal.parse(part, "YYYY-MM-DD");
            if (li == 0) try excluded.dates.append(temp, @divFloor(time, cal.day)) else try excluded.includes.append(temp, @divFloor(time, cal.day));
        }
    }
    var unresolved = tasks.items.len;
    while (unresolved > 0) {
        var progress = false;
        for (tasks.items, 0..) |*t, i| {
            if (t.end != null) continue;
            if (t.start == null) {
                if (t.start_spec.len == 0) {
                    if (i == 0) return error.UnsupportedSyntax;
                    t.start = tasks.items[i - 1].end;
                } else if (txt.starts(t.start_spec, "after ")) t.start = try refs(tasks.items, t.start_spec[6..], false) else t.start = try cal.parse(t.start_spec, date_format);
                if (t.start != null) progress = true;
            }
            if (t.start) |start| {
                var end: ?i64 = null;
                var duration = false;
                if (txt.starts(t.end_spec, "until ")) end = try refs(tasks.items, t.end_spec[6..], true) else {
                    end = if (t.milestone and std.mem.eql(u8, t.end_spec, "0")) start else try cal.duration(start, t.end_spec);
                    duration = end != null;
                    if (end == null) {
                        end = try cal.parse(t.end_spec, date_format);
                        if (inclusive) end.? += cal.day;
                    }
                }
                if (end) |original| {
                    if (original < start) return error.InvalidSyntax;
                    var adjusted = original;
                    var display = original;
                    if (duration and excludes.len > 0) {
                        var at = start + cal.day;
                        var n: usize = 0;
                        var invalid = false;
                        while (at <= adjusted) : (at += cal.day) {
                            if (n == 10000) return error.LimitExceeded;
                            n += 1;
                            if (!invalid) display = adjusted;
                            invalid = excluded.excluded(at);
                            if (invalid) adjusted += cal.day;
                        }
                    }
                    if (adjusted > 253402300799999) return error.LimitExceeded;
                    t.end = adjusted;
                    t.display_end = display;
                    unresolved -= 1;
                    progress = true;
                }
            }
        }
        if (!progress) return error.InvalidSyntax;
    }
    var low = tasks.items[0].start.?;
    var high = low;
    var label_width: usize = 60;
    for (tasks.items) |t| {
        low = @min(low, t.start.?);
        high = @max(high, t.end.?);
        label_width = @max(label_width, txt.width(t.label) + 28);
    }
    for (sections.items) |s| label_width = @max(label_width, txt.width(s) + 28);
    if (low == high) high += if (std.mem.eql(u8, date_format, "HH:mm")) @as(i64, 60000) else cal.day;
    const left = @max(label_width, data.coord(try doc.num("config.gantt.leftPadding", @floatFromInt(label_width), 40, 10000)));
    var rows: usize = 0;
    var row_ends: [512]i64 = undefined;
    var row_sections: [512]usize = undefined;
    for (tasks.items) |*t| {
        if (t.vertical) continue;
        var row = rows;
        if (compact) for (0..rows) |r| if (row_sections[r] == t.section and row_ends[r] <= t.start.?) {
            row = r;
            break;
        };
        if (row == rows) rows += 1;
        t.row = row;
        const text_time = @as(i64, @intFromFloat(@ceil(@as(f64, @floatFromInt(txt.width(t.label) + 24)) / @as(f64, @floatFromInt(plot_width)) * @as(f64, @floatFromInt(high - low)))));
        row_ends[row] = t.end.? + if (compact and t.end.? - t.start.? < text_time) text_time else @as(i64, 0);
        row_sections[row] = t.section;
    }
    var row_height = @max(bar_height + gap, 40);
    for (tasks.items) |t| row_height = @max(row_height, txt.height(t.label) + 16);
    const top: usize = 60;
    var row_y: [512]usize = undefined;
    var section_y = [_]?usize{null} ** 128;
    var bottom = top;
    for (0..rows) |r| {
        const s = row_sections[r];
        if (section_y[s] == null and sections.items[s].len > 0) {
            section_y[s] = bottom;
            bottom += txt.height(sections.items[s]) + 16;
        }
        row_y[r] = bottom;
        bottom += row_height;
    }
    const width = left + plot_width + @max(right, if (compact) label_width + 20 else @as(usize, 60));
    const height = bottom + 80;
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "gantt", prefix);
    if (custom_css.len > 0) try @import("scoped_css.zig").emit(&out, custom_css);
    for (0..rows) |row| {
        const fill = try doc.palette(row_sections[row] % section_styles);
        try out.fmt("<rect x=\"0\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" opacity=\"0.08\" stroke=\"none\"/>", .{ row_y[row], width, row_height, fill });
    }
    // Like the reference, omit day shading when the whole-year span exceeds 5.
    const shade_days = cal.date(low).year > 9993 or high < (try cal.duration(low, "6y")).?;
    if (excludes.len > 0 and !shade_days) try out.add("<desc data-excludes-omitted=\"long-range\">Excluded-day shading omitted for a range of six years or more.</desc>");
    var day_start = @divFloor(low, cal.day) * cal.day;
    if (excludes.len > 0 and shade_days) while (day_start < high) : (day_start += cal.day) {
        if (!excluded.excluded(day_start)) continue;
        const x = xcoord(@max(low, day_start), low, high, left, plot_width);
        const end = xcoord(@min(high, day_start + cal.day), low, high, left, plot_width);
        try out.fmt("<rect data-excluded-day=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" opacity=\"0.07\" stroke=\"none\"/>", .{ day_start, x, top, end - x, bottom - top, fg });
    };
    var ticks: std.ArrayList(i64) = .empty;
    var custom_ticks = false;
    if (tick.len > 0) custom: {
        var digits: usize = 0;
        while (digits < tick.len and std.ascii.isDigit(tick[digits])) : (digits += 1) {}
        if (digits == 0 or digits == tick.len or tick[0] == '0') break :custom;
        const n = std.fmt.parseInt(i64, tick[0..digits], 10) catch break :custom;
        if (n < 1 or n > 10000) break :custom;
        const unit = tick[digits..];
        if (std.mem.eql(u8, unit, "month")) {
            var date = cal.date(low);
            date.date = 1;
            date.hour = 0;
            date.minute = 0;
            date.second = 0;
            date.millis = 0;
            while (date.year <= 9999) {
                const t = try cal.timestamp(date);
                if (t > high) break;
                if (t >= low and @mod(date.month - 1, n) == 0) try ticks.append(temp, t);
                if (ticks.items.len > 1024) {
                    ticks.clearRetainingCapacity();
                    break :custom;
                }
                date.month += 1;
                if (date.month > 12) {
                    date.month = 1;
                    date.year += 1;
                }
            }
            custom_ticks = true;
            break :custom;
        }
        const scale: i64 = if (std.mem.eql(u8, unit, "millisecond")) 1 else if (std.mem.eql(u8, unit, "second")) 1000 else if (std.mem.eql(u8, unit, "minute")) 60000 else if (std.mem.eql(u8, unit, "hour")) 3600000 else if (std.mem.eql(u8, unit, "day")) cal.day else if (std.mem.eql(u8, unit, "week")) 7 * cal.day else break :custom;
        const stride = n * scale;
        if (@divFloor(high - low, stride) > 1023) break :custom;
        var t = @divFloor(low, stride) * stride;
        if (std.mem.eql(u8, unit, "week")) {
            t = @divFloor(low, cal.day) * cal.day;
            t -= @as(i64, @intCast((cal.weekday(t) + 7 - week_start) % 7)) * cal.day;
        }
        if (t < low) t += stride;
        while (t <= high) : (t += stride) {
            if (ticks.items.len == 1024) return error.LimitExceeded;
            try ticks.append(temp, t);
        }
        custom_ticks = true;
    }
    if (!custom_ticks) {
        if (tick.len > 0) {
            try out.add("<desc data-tick-fallback=\"auto\">Ignored tickInterval: ");
            try out.escape(tick);
            try out.add("</desc>");
        }
        for (0..6) |i| try ticks.append(temp, low + @divFloor((high - low) * @as(i64, @intCast(i)), 5));
    }
    for (ticks.items) |t| {
        const x = xcoord(t, low, high, left, plot_width);
        try out.fmt("<path d=\"M {d} {d} V {d}\" stroke=\"{s}\" opacity=\"0.2\"/>", .{ x, top, bottom, fg });
        try out.text(x, if (top_axis) top - 24 else bottom + 30, try cal.formatAxis(temp, t, axis_format));
    }
    for (tasks.items, 0..) |t, i| {
        const start = xcoord(t.start.?, low, high, left, plot_width);
        const end = xcoord(t.display_end.?, low, high, left, plot_width);
        const y = (if (t.vertical) top else row_y[t.row]) + (row_height - bar_height) / 2;
        const fill = if (t.done) (if (doc.theme == .dark) "#505965" else "#b9c1ca") else if (t.active) (if (doc.theme == .dark) "#247ba5" else "#74bada") else if (t.critical) (if (doc.theme == .dark) "#a83a46" else "#e57b83") else try doc.palette(t.section % section_styles);
        try @import("interaction.zig").begin(&out, t.action, t.id, "");
        try out.fmt("<g data-gantt-task=\"{d}\" data-start=\"{d}\" data-end=\"{d}\" data-row=\"{d}\"><title>", .{ i, t.start.?, t.end.?, t.row });
        try out.escape(t.id);
        try out.add("</title>");
        if (t.vertical) {
            try out.fmt("<path d=\"M {d} {d} V {d}\" stroke=\"{s}\" stroke-width=\"2\"/>", .{ start, top, bottom, fill });
            try out.text(start, 30, t.label);
        } else {
            if (t.milestone) {
                const x = (start + end) / 2;
                const center = y + bar_height / 2;
                const radius = bar_height / 2;
                try out.fmt("<path data-milestone=\"true\" d=\"M {d} {d} L {d} {d} L {d} {d} L {d} {d} Z\" fill=\"{s}\"/>", .{ x, center - radius, x + radius, center, x, center + radius, x - radius, center, fill });
            } else {
                try out.add("<rect data-source-id=\"");
                try out.escape(t.id);
                try out.fmt("\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"3\" fill=\"{s}\"{s}/>", .{ start, y, @max(1, end - start), bar_height, fill, if (t.critical) " stroke-width=\"3\" stroke=\"#d63242\"" else "" });
            }
            const label_x = if (!compact) left / 2 else if (end - start > txt.width(t.label) + 12) (start + end) / 2 else end + txt.width(t.label) / 2 + 8;
            const label_id = try std.fmt.allocPrint(temp, "{s}-text", .{t.id});
            var label_lines = std.mem.splitScalar(u8, t.label, '\n');
            var label_y = y + bar_height / 2 - txt.height(t.label) / 2 + 10;
            while (label_lines.next()) |line| {
                try out.textSource(label_x, label_y, line, fg, label_id);
                label_y += 20;
            }
        }
        try out.add("</g>");
        try @import("interaction.zig").end(&out, t.action);
    }
    if (today_enabled) {
        if (doc.now_ms) |now| {
            // Paint above task bars, without stretching the chart for an out-of-range date.
            if (now >= low and now <= high) {
                const x = xcoord(now, low, high, left, plot_width);
                try out.fmt("<path data-today-marker=\"{d}\" d=\"M {d} {d} V {d}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d}\"", .{ now, x, top, bottom, today_style.stroke orelse "#db5757", today_style.width orelse 2 });
                if (today_style.dash) |dash| {
                    try out.add(" stroke-dasharray=\"");
                    for (dash) |c| if (c != '\\') try out.bytes.append(a, c);
                    try out.add("\"");
                }
                if (today_style.offset) |offset| try out.fmt(" stroke-dashoffset=\"{d}\"", .{offset});
                try out.fmt(" opacity=\"{d}\"/>", .{today_opacity});
            }
        } else if (today_explicit) return error.MissingContext;
    }
    // Section headings remain visible above each run of task rows.
    for (sections.items, 0..) |name, s| if (name.len > 0) {
        if (section_y[s]) |sy| {
            try out.add("<g font-weight=\"bold\">");
            try txt.draw(&out, left / 2, sy + 8, name);
            try out.add("</g>");
        }
    };
    return out.finish();
}
