const std = @import("std");
const d = @import("document.zig");
const svg = @import("svg.zig");

fn identifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}
fn length(value: []const u8) d.Error!void {
    var v = d.trim(value);
    for ([_][]const u8{ "px", "rem", "em", "%", "deg" }) |unit| if (std.mem.endsWith(u8, v, unit)) {
        v = v[0 .. v.len - unit.len];
        break;
    };
    if (@abs(try d.number(v)) > 100000) return error.LimitExceeded;
}
fn declaration(key: []const u8, value: []const u8) d.Error!void {
    if (std.mem.eql(u8, key, "fill") or std.mem.eql(u8, key, "stroke") or std.mem.eql(u8, key, "color")) {
        _ = try d.color(value);
        return;
    }
    if (std.mem.eql(u8, key, "font-weight")) {
        if (!std.mem.eql(u8, value, "bold") and !std.mem.eql(u8, value, "normal")) return error.UnsupportedSyntax;
        return;
    }
    if (std.mem.eql(u8, key, "font-style")) {
        if (!std.mem.eql(u8, value, "italic") and !std.mem.eql(u8, value, "normal")) return error.UnsupportedSyntax;
        return;
    }
    if (std.mem.eql(u8, key, "transform")) {
        var rest = value;
        var count: usize = 0;
        while (rest.len > 0) {
            const open = std.mem.indexOfScalar(u8, rest, '(') orelse return error.InvalidSyntax;
            const close = std.mem.indexOfScalarPos(u8, rest, open + 1, ')') orelse return error.InvalidSyntax;
            const name = d.trim(rest[0..open]);
            var allowed = false;
            for ([_][]const u8{ "translate", "translateX", "translateY", "scale", "scaleX", "scaleY", "rotate", "matrix" }) |candidate| if (std.mem.eql(u8, name, candidate)) {
                allowed = true;
            };
            if (!allowed) return error.UnsupportedSyntax;
            var args = std.mem.tokenizeAny(u8, rest[open + 1 .. close], " ,\t");
            var n: usize = 0;
            while (args.next()) |arg| {
                try length(arg);
                n += 1;
            }
            if (n == 0 or n > 6) return error.InvalidSyntax;
            count += 1;
            if (count > 16) return error.LimitExceeded;
            rest = d.trim(rest[close + 1 ..]);
        }
        return;
    }
    if (std.mem.eql(u8, key, "opacity") or std.mem.eql(u8, key, "fill-opacity") or std.mem.eql(u8, key, "stroke-opacity")) {
        const n = try d.number(value);
        if (n < 0 or n > 1) return error.InvalidSyntax;
        return;
    }
    if (std.mem.eql(u8, key, "stroke-dasharray")) {
        if (std.mem.eql(u8, value, "none")) return;
        var parts = std.mem.tokenizeAny(u8, value, " ,\t");
        var count: usize = 0;
        while (parts.next()) |part| {
            try length(part);
            count += 1;
        }
        if (count == 0 or count > 16) return error.InvalidSyntax;
        return;
    }
    for ([_][]const u8{ "x", "y", "width", "height", "rx", "ry", "font-size", "stroke-width", "stroke-dashoffset" }) |candidate| if (std.mem.eql(u8, key, candidate)) {
        if (std.mem.startsWith(u8, value, "calc(") and std.mem.endsWith(u8, value, ")")) {
            var terms = std.mem.tokenizeAny(u8, value[5 .. value.len - 1], " \t");
            try length(terms.next() orelse return error.InvalidSyntax);
            const op = terms.next() orelse return error.InvalidSyntax;
            if (!std.mem.eql(u8, op, "+") and !std.mem.eql(u8, op, "-")) return error.UnsupportedSyntax;
            try length(terms.next() orelse return error.InvalidSyntax);
            if (terms.next() != null) return error.UnsupportedSyntax;
        } else try length(value);
        return;
    };
    return error.UnsupportedSyntax;
}
fn selector(out: *svg.Svg, raw: []const u8) d.Error!void {
    const value = d.trim(raw);
    if (value.len == 0) return error.InvalidSyntax;
    if (std.mem.indexOfScalar(u8, ">+~", value[0]) != null) return error.UnsupportedSyntax;
    try out.fmt("#zm-{d}-css ", .{out.id_prefix});
    var at: usize = 0;
    while (at < value.len) {
        const c = value[at];
        if (c == ' ' or c == '\t' or c == '>' or c == '+' or c == '~' or c == '*') {
            try out.add(value[at..][0..1]);
            at += 1;
            continue;
        }
        if (c == '[') {
            const end = std.mem.indexOfScalarPos(u8, value, at, ']') orelse return error.InvalidSyntax;
            const attribute = d.trim(value[at + 1 .. end]);
            const eq = std.mem.indexOfScalar(u8, attribute, '=') orelse return error.UnsupportedSyntax;
            const key = d.trim(attribute[0..eq]);
            const name = d.unquote(attribute[eq + 1 ..]);
            if (!identifier(name)) return error.UnsupportedSyntax;
            if (!std.mem.eql(u8, key, "id") and !std.mem.eql(u8, key, "id^") and !std.mem.eql(u8, key, "id$") and !std.mem.eql(u8, key, "id*")) return error.UnsupportedSyntax;
            try out.fmt("[data-source-id{s}=\"{s}\"]", .{ key[2..], name });
            at = end + 1;
            continue;
        }
        const marker = c == '#' or c == '.';
        if (marker) at += 1;
        const start = at;
        while (at < value.len and (std.ascii.isAlphanumeric(value[at]) or value[at] == '_' or value[at] == '-')) at += 1;
        const name = value[start..at];
        if (!identifier(name)) return error.UnsupportedSyntax;
        if (c == '#') try out.fmt("[data-source-id=\"{s}\"]", .{name}) else {
            if (c == '.') try out.add(".");
            try out.add(name);
        }
    }
}
pub fn emit(out: *svg.Svg, source: []const u8) d.Error!void {
    if (source.len > 65536) return error.LimitExceeded;
    // Strip only recognized comments, then validate every selector/property/value.
    // No raw CSS, imports, URLs, variables, selectors outside this SVG, or scripts.
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(out.allocator);
    var at: usize = 0;
    while (at < source.len) {
        if (std.mem.startsWith(u8, source[at..], "/*")) {
            at = (std.mem.indexOfPos(u8, source, at + 2, "*/") orelse return error.InvalidSyntax) + 2;
            try cleaned.append(out.allocator, ' ');
        } else if (std.mem.startsWith(u8, source[at..], "//") and (at == 0 or std.ascii.isWhitespace(source[at - 1]))) {
            at = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
        } else {
            try cleaned.append(out.allocator, source[at]);
            at += 1;
        }
    }
    try out.add("<style>");
    var rest = d.trim(cleaned.items);
    var count: usize = 0;
    while (rest.len > 0) {
        const open = std.mem.indexOfScalar(u8, rest, '{') orelse return error.InvalidSyntax;
        const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '}') orelse return error.InvalidSyntax;
        var selectors = std.mem.splitScalar(u8, rest[0..open], ',');
        var first = true;
        while (selectors.next()) |part| {
            if (!first) try out.add(",");
            try selector(out, part);
            first = false;
            count += 1;
            if (count > 128) return error.LimitExceeded;
        }
        try out.add("{");
        var declarations = std.mem.splitScalar(u8, rest[open + 1 .. close], ';');
        while (declarations.next()) |raw| {
            const part = d.trim(raw);
            if (part.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidSyntax;
            const key = d.trim(part[0..colon]);
            var value = d.trim(part[colon + 1 ..]);
            const important = std.mem.endsWith(u8, value, "!important");
            if (important) value = d.trim(value[0 .. value.len - 10]);
            try declaration(key, value);
            // Validation above permits no markup delimiters in emitted values.
            try out.fmt("{s}:{s}{s};", .{ key, value, if (important) " !important" else "" });
        }
        try out.add("}");
        rest = d.trim(rest[close + 1 ..]);
    }
    try out.add("</style>");
}
