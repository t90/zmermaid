const std = @import("std");
const d = @import("document.zig");
pub const day: i64 = 86400000;
pub const Date = struct { year: i64 = 1970, month: i64 = 1, date: i64 = 1, hour: i64 = 0, minute: i64 = 0, second: i64 = 0, millis: i64 = 0 };
pub fn leap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}
pub fn monthDays(y: i64, m: i64) i64 {
    return if (m == 2) (if (leap(y)) @as(i64, 29) else 28) else if (m == 4 or m == 6 or m == 9 or m == 11) 30 else 31;
}
fn years(y: i64) i64 {
    const n = y - 1;
    return n * 365 + @divFloor(n, 4) - @divFloor(n, 100) + @divFloor(n, 400);
}
pub fn timestamp(v: Date) d.Error!i64 {
    if (v.year < 1 or v.year > 9999 or v.month < 1 or v.month > 12 or v.date < 1 or v.date > monthDays(v.year, v.month) or v.hour < 0 or v.hour > 23 or v.minute < 0 or v.minute > 59 or v.second < 0 or v.second > 59 or v.millis < 0 or v.millis > 999) return error.InvalidSyntax;
    var days = years(v.year) - years(1970) + v.date - 1;
    var m: i64 = 1;
    while (m < v.month) : (m += 1) days += monthDays(v.year, m);
    return days * day + v.hour * 3600000 + v.minute * 60000 + v.second * 1000 + v.millis;
}
pub fn date(t: i64) Date {
    var days = @divFloor(t, day) + years(1970);
    var y: i64 = @max(1, @min(9999, @divFloor(days, 365) + 1));
    while (years(y) > days) y -= 1;
    while (years(y + 1) <= days) y += 1;
    days -= years(y);
    var m: i64 = 1;
    while (days >= monthDays(y, m) and m < 12) : (m += 1) days -= monthDays(y, m);
    const time = @mod(t, day);
    return .{ .year = y, .month = m, .date = days + 1, .hour = @divFloor(time, 3600000), .minute = @mod(@divFloor(time, 60000), 60), .second = @mod(@divFloor(time, 1000), 60), .millis = @mod(time, 1000) };
}
pub fn parse(raw: []const u8, format: []const u8) d.Error!i64 {
    const s = d.trim(raw);
    if (std.mem.eql(u8, format, "X") or std.mem.eql(u8, format, "x")) {
        const value = std.fmt.parseFloat(f64, s) catch return error.InvalidSyntax;
        if (!std.math.isFinite(value)) return error.InvalidSyntax;
        const ms = value * (if (format[0] == 'X') @as(f64, 1000) else 1);
        if (ms < -62135596800000 or ms > 253402300799999) return error.LimitExceeded;
        return @intFromFloat(@round(ms));
    }
    var v: Date = .{};
    var fi: usize = 0;
    var si: usize = 0;
    while (fi < format.len) {
        const token = format[fi];
        if (std.mem.indexOfScalar(u8, "YMDHmsS", token) != null) {
            var end = fi + 1;
            while (end < format.len and format[end] == token) : (end += 1) {}
            const length = end - fi;
            if ((token == 'Y' and length != 4 and length != 2) or (token == 'S' and length != 3) or (token != 'Y' and token != 'S' and length > 2)) return error.UnsupportedSyntax;
            var se = si;
            const max_len = if (length == 1) @as(usize, 2) else length;
            while (se < s.len and se - si < max_len and std.ascii.isDigit(s[se])) : (se += 1) {}
            // Delimited numeric fields may omit leading zeros. Keep adjacent
            // fields fixed-width, YY's century pivot explicit, and SSS exact.
            const isolated = (fi == 0 or !std.ascii.isAlphabetic(format[fi - 1])) and (end == format.len or !std.ascii.isAlphabetic(format[end]));
            const unpadded = isolated and token != 'S' and !(token == 'Y' and length == 2);
            if (se == si or (length > 1 and se - si != length and !unpadded)) return error.InvalidSyntax;
            const value = std.fmt.parseInt(i64, s[si..se], 10) catch return error.InvalidSyntax;
            switch (token) {
                'Y' => v.year = if (length == 2) value + (if (value > 68) @as(i64, 1900) else 2000) else value,
                'M' => v.month = value,
                'D' => v.date = value,
                'H' => v.hour = value,
                'm' => v.minute = value,
                's' => v.second = value,
                'S' => v.millis = value,
                else => unreachable,
            }
            fi = end;
            si = se;
        } else {
            if (std.ascii.isAlphabetic(token)) return error.UnsupportedSyntax;
            if (si >= s.len or s[si] != token) return error.InvalidSyntax;
            si += 1;
            fi += 1;
        }
    }
    if (si != s.len) return error.InvalidSyntax;
    return timestamp(v);
}
pub fn duration(start: i64, raw: []const u8) d.Error!?i64 {
    const s = d.trim(raw);
    if (s.len < 2) return null;
    const ms = std.mem.endsWith(u8, s, "ms");
    const unit = s[s.len - 1];
    if (!ms and std.mem.indexOfScalar(u8, "yMwdhms", unit) == null) return null;
    const value = d.number(s[0 .. s.len - (if (ms) @as(usize, 2) else 1)]) catch return null;
    if (value < 0) return error.InvalidSyntax;
    if (!ms and (unit == 'y' or unit == 'M')) {
        if (value != @floor(value) or value > 120000) return error.InvalidSyntax;
        var v = date(start);
        const months = (v.year - 1) * 12 + v.month - 1 + @as(i64, @intFromFloat(value)) * (if (unit == 'y') @as(i64, 12) else 1);
        v.year = @divFloor(months, 12) + 1;
        v.month = @mod(months, 12) + 1;
        v.date = @min(v.date, monthDays(v.year, v.month));
        return try timestamp(v);
    }
    const multiplier: f64 = if (ms) 1 else switch (unit) {
        'w' => 7 * day,
        'd' => day,
        'h' => 3600000,
        'm' => 60000,
        's' => 1000,
        else => unreachable,
    };
    const delta = value * multiplier;
    if (delta > 315576000000000) return error.LimitExceeded;
    const result = start + @as(i64, @intFromFloat(@round(delta)));
    if (result > 253402300799999) return error.LimitExceeded;
    return result;
}
pub fn weekday(t: i64) usize {
    return @intCast(@mod(@divFloor(t, day) + 4, 7));
}
pub const weekdays = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
pub fn formatAxis(a: std.mem.Allocator, t: i64, format: []const u8) d.Error![]const u8 {
    const v = date(t);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var at: usize = 0;
    while (at < format.len) : (at += 1) {
        if (format[at] != '%') {
            try out.append(a, format[at]);
            continue;
        }
        at += 1;
        if (at == format.len) return error.InvalidSyntax;
        const part = switch (format[at]) {
            'Y' => try std.fmt.allocPrint(a, "{d:0>4}", .{@as(u32, @intCast(v.year))}),
            'y' => try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u32, @intCast(@mod(v.year, 100)))}),
            'm' => try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u32, @intCast(v.month))}),
            'd' => try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u32, @intCast(v.date))}),
            'e' => try std.fmt.allocPrint(a, "{d}", .{v.date}),
            'H' => try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u32, @intCast(v.hour))}),
            'M' => try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u32, @intCast(v.minute))}),
            'S' => try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u32, @intCast(v.second))}),
            'L' => try std.fmt.allocPrint(a, "{d:0>3}", .{@as(u32, @intCast(v.millis))}),
            's' => try std.fmt.allocPrint(a, "{d}", .{@divFloor(t, 1000)}),
            'Q' => try std.fmt.allocPrint(a, "{d}", .{t}),
            'a' => weekdays[weekday(t)][0..3],
            'A' => weekdays[weekday(t)],
            'b' => ([_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" })[@intCast(v.month - 1)],
            '%' => "%",
            else => return error.UnsupportedSyntax,
        };
        defer if (std.mem.indexOfScalar(u8, "YymdeHMSLsQ", format[at]) != null) a.free(part);
        try out.appendSlice(a, part);
    }
    return out.toOwnedSlice(a);
}
test "calendar dates durations leap days and pre-epoch values" {
    for ([_][]const u8{ "0001-01-01", "1900-02-28", "1969-12-31", "1970-01-01", "2000-02-29", "2024-12-31", "9999-12-31" }) |s| {
        const t = try parse(s, "YYYY-MM-DD");
        try std.testing.expectEqual(t, try timestamp(date(t)));
    }
    try std.testing.expectEqual(@as(i64, 0), try parse("1970-01-01", "YYYY-MM-DD"));
    try std.testing.expectError(error.InvalidSyntax, parse("2023-02-29", "YYYY-MM-DD"));
    try std.testing.expectEqual(try parse("2024-02-29", "YYYY-MM-DD"), (try duration(try parse("2024-01-31", "YYYY-MM-DD"), "1M")).?);
    try std.testing.expectEqual(@as(i64, 1500), (try duration(0, "1.5s")).?);
}

test "calendar axis padding does not introduce signed plus prefixes" {
    const a = std.testing.allocator;
    const formatted = try formatAxis(a, try timestamp(.{ .year = 2024, .month = 2, .date = 3, .hour = 4, .minute = 5, .second = 6, .millis = 7 }), "%Y-%m-%d %H:%M:%S.%L");
    defer a.free(formatted);
    try std.testing.expectEqualStrings("2024-02-03 04:05:06.007", formatted);
}

test "delimited unpadded calendar fields retain literal values" {
    try std.testing.expectEqual(try timestamp(.{ .year = 202, .month = 12, .date = 1 }), try parse("202-12-1", "YYYY-MM-DD"));
    try std.testing.expectEqual(@as(i64, 0), try parse("0", "ss"));
    try std.testing.expectEqual(@as(i64, 20000), try parse("20", "ss"));
    try std.testing.expectEqual(try timestamp(.{ .year = 2024, .month = 2, .date = 3, .hour = 4, .minute = 5, .second = 6 }), try parse("2024-2-3 4:5:6", "YYYY-MM-DD HH:mm:ss"));
    for ([_][]const u8{ "2024121", "20241301", "20240230" }) |raw| try std.testing.expectError(error.InvalidSyntax, parse(raw, "YYYYMMDD"));
    try std.testing.expectError(error.InvalidSyntax, parse("1", "YY"));
    try std.testing.expectError(error.InvalidSyntax, parse("7", "SSS"));
    try std.testing.expectError(error.InvalidSyntax, parse("60", "ss"));
    try std.testing.expectError(error.InvalidSyntax, parse("0000-1-1", "YYYY-MM-DD"));
}
