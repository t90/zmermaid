const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const wrap = @import("text_wrap.zig");
const svg = @import("svg.zig");
const eq = std.mem.eql;
const Kind = enum { ui, processor, command, readmodel, event };
const Payload = struct { kind: []const u8 = "text", value: []const u8 = "" };
const NamedData = struct { name: []const u8, payload: Payload };
const Frame = struct { id: []const u8, name: []const u8, kind: Kind, reset: bool, lane: usize = 0, payload: Payload = .{}, reference: []const u8 = "", refs: std.ArrayList([]const u8) = .empty, note: []const u8 = "", spec: []const u8 = "", label: []const u8 = "", x: usize = 0, y: usize = 0, w: usize = 280, h: usize = 100 };
const Lane = struct { category: usize, namespace: []const u8, label: []const u8, y: usize = 0, h: usize = 100 };
const Edge = struct { from: usize, to: usize };
const Note = struct { frame: []const u8, payload: Payload };
const Spec = struct { frame: []const u8, text: []const u8 };
const Scanner = struct {
    source: []const u8,
    fn space(self: *Scanner) d.Error!void {
        while (true) {
            self.source = std.mem.trimStart(u8, self.source, " \t\r\n");
            if (txt.starts(self.source, "%%") or txt.starts(self.source, "//")) {
                if (txt.starts(self.source, "%%{")) return error.UnsupportedSyntax;
                self.source = self.source[std.mem.indexOfScalar(u8, self.source, '\n') orelse self.source.len ..];
            } else if (txt.starts(self.source, "/*")) {
                const end = std.mem.indexOf(u8, self.source, "*/") orelse return error.InvalidSyntax;
                self.source = self.source[end + 2 ..];
            } else break;
        }
    }
    fn word(self: *Scanner) d.Error![]const u8 {
        try self.space();
        var end: usize = 0;
        while (end < self.source.len and (std.ascii.isAlphanumeric(self.source[end]) or self.source[end] == '_' or self.source[end] == '.')) : (end += 1) {}
        if (end == 0) return error.InvalidSyntax;
        const value = self.source[0..end];
        self.source = self.source[end..];
        return value;
    }
    fn payload(self: *Scanner) d.Error!Payload {
        try self.space();
        var p: Payload = .{};
        if (txt.starts(self.source, "`")) {
            const end = std.mem.indexOfScalarPos(u8, self.source, 1, '`') orelse return error.InvalidSyntax;
            p.kind = self.source[1..end];
            self.source = self.source[end + 1 ..];
            try self.space();
            var valid = false;
            for ([_][]const u8{ "json", "jsobj", "figma", "salt", "uri", "md", "html", "text" }) |name| if (eq(u8, p.kind, name)) {
                valid = true;
            };
            if (!valid) return error.UnsupportedSyntax;
        }
        if (self.source.len == 0) return error.InvalidSyntax;
        const first = self.source[0];
        if (first != '{' and first != '"' and first != '\'') return error.InvalidSyntax;
        var level: usize = if (first == '{') 1 else 0;
        var quote: u8 = if (first == '{') 0 else first;
        var escape = false;
        var i: usize = 1;
        while (i < self.source.len) : (i += 1) {
            const c = self.source[i];
            if (escape) {
                escape = false;
                continue;
            }
            if (quote != 0 and c == '\\') {
                escape = true;
                continue;
            }
            if (quote != 0) {
                if (c == quote) {
                    quote = 0;
                    if (first != '{') break;
                }
                continue;
            }
            if (c == '"' or (c == '\'' and !std.ascii.isAlphanumeric(self.source[i - 1]))) {
                quote = c;
                continue;
            }
            if (c == '{') {
                level += 1;
                if (level > 32) return error.LimitExceeded;
            }
            if (c == '}') {
                level -= 1;
                if (level == 0) break;
            }
        }
        if (i == self.source.len) return error.InvalidSyntax;
        p.value = d.trim(self.source[1..i]);
        self.source = self.source[i + 1 ..];
        if (p.value.len > 8192 or std.mem.count(u8, p.value, "\n") > 128) return error.LimitExceeded;
        return p;
    }
};
fn kind(word: []const u8) d.Error!Kind {
    if (eq(u8, word, "ui")) return .ui;
    if (eq(u8, word, "pcr") or eq(u8, word, "processor")) return .processor;
    if (eq(u8, word, "cmd") or eq(u8, word, "command")) return .command;
    if (eq(u8, word, "rmo") or eq(u8, word, "readmodel")) return .readmodel;
    if (eq(u8, word, "evt") or eq(u8, word, "event")) return .event;
    return error.InvalidSyntax;
}
fn fid(id: []const u8) d.Error!void {
    if (id.len == 0 or id.len > 3) return error.InvalidSyntax;
    for (id) |c| if (!std.ascii.isDigit(c)) return error.InvalidSyntax;
}
fn identifier(id: []const u8) d.Error!void {
    if (id.len == 0 or id.len > 512) return error.InvalidSyntax;
    var parts = std.mem.splitScalar(u8, id, '.');
    while (parts.next()) |part| {
        if (part.len == 0 or (!std.ascii.isAlphabetic(part[0]) and part[0] != '_')) return error.InvalidSyntax;
    }
}
fn find(frames: []Frame, id: []const u8) d.Error!usize {
    for (frames, 0..) |f, i| if (eq(u8, f.id, id)) return i;
    return error.InvalidSyntax;
}
fn format(a: std.mem.Allocator, value: []const u8, width: usize) d.Error![]const u8 {
    const result = try wrap.wrap(a, value, width);
    if (std.mem.count(u8, result, "\n") > 256) return error.LimitExceeded;
    return result;
}
fn literal(a: std.mem.Allocator, value: []const u8, width: usize) d.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    var line: usize = 0;
    var count: usize = 1;
    while (at < value.len) {
        if (value[at] == '\r') {
            at += 1;
            continue;
        }
        if (value[at] == '\n') {
            try out.append(a, '\n');
            line = 0;
            count += 1;
            at += 1;
            continue;
        }
        const size = std.unicode.utf8ByteSequenceLength(value[at]) catch return error.InvalidSyntax;
        const char = value[at .. at + size];
        const w = if (value[at] == '\t') @as(usize, 36) else txt.width(char);
        if (line > 0 and line + w > width) {
            try out.append(a, '\n');
            line = 0;
            count += 1;
        }
        if (count > 256) return error.LimitExceeded;
        try out.appendSlice(a, if (value[at] == '\t') "    " else char);
        line += w;
        at += size;
    }
    return out.toOwnedSlice(a);
}
fn label(out: *svg.Svg, x: usize, y: usize, value: []const u8, color: []const u8, bold: bool) !void {
    var lines = std.mem.splitScalar(u8, value, '\n');
    var py = y;
    while (lines.next()) |line| {
        try out.fmt("<text xml:space=\"preserve\" x=\"{d}\" y=\"{d}\" fill=\"{s}\" stroke=\"none\" font-family=\"Consolas,monospace\" font-size=\"14\" font-weight=\"{s}\">", .{ x, py, color, if (bold) "bold" else "normal" });
        try out.escape(line);
        try out.add("</text>");
        py += 20;
    }
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var frames: std.ArrayList(Frame) = .empty;
    var datasets: std.ArrayList(NamedData) = .empty;
    var entities: std.ArrayList([]const u8) = .empty;
    var entity_refs: std.ArrayList([]const u8) = .empty;
    var notes: std.ArrayList(Note) = .empty;
    var specs: std.ArrayList(Spec) = .empty;
    var lanes: std.ArrayList(Lane) = .empty;
    var edges: std.ArrayList(Edge) = .empty;
    var scanner: Scanner = .{ .source = doc.source };
    _ = try scanner.word();
    while (true) {
        try scanner.space();
        if (scanner.source.len == 0) break;
        const token = try scanner.word();
        if (eq(u8, token, "title") or eq(u8, token, "accTitle") or eq(u8, token, "accDescr")) {
            scanner.source = std.mem.trimStart(u8, scanner.source, " \t");
            if (eq(u8, token, "accDescr") and txt.starts(scanner.source, "{")) {
                doc.acc_description = (try scanner.payload()).value;
                continue;
            }
            if (!eq(u8, token, "title")) {
                if (!txt.starts(scanner.source, ":")) return error.InvalidSyntax;
                scanner.source = scanner.source[1..];
            }
            const end = std.mem.indexOfScalar(u8, scanner.source, '\n') orelse scanner.source.len;
            const value = d.trim(scanner.source[0..end]);
            scanner.source = scanner.source[end..];
            if (eq(u8, token, "title")) doc.title = value else if (eq(u8, token, "accTitle")) doc.acc_title = value else doc.acc_description = value;
            continue;
        }
        if (eq(u8, token, "entity")) {
            const name = try scanner.word();
            try identifier(name);
            for (entities.items) |old| if (eq(u8, old, name)) return error.InvalidSyntax;
            if (entities.items.len == 512) return error.LimitExceeded;
            try entities.append(temp, name);
            continue;
        }
        if (eq(u8, token, "data")) {
            const name = try scanner.word();
            try identifier(name);
            for (datasets.items) |old| if (eq(u8, old.name, name)) return error.InvalidSyntax;
            if (datasets.items.len == 512) return error.LimitExceeded;
            try datasets.append(temp, .{ .name = name, .payload = try scanner.payload() });
            continue;
        }
        if (eq(u8, token, "note")) {
            const id = try scanner.word();
            try fid(id);
            if (notes.items.len == 512) return error.LimitExceeded;
            try notes.append(temp, .{ .frame = id, .payload = try scanner.payload() });
            continue;
        }
        if (eq(u8, token, "gwt")) {
            const id = try scanner.word();
            try fid(id);
            if (!eq(u8, try scanner.word(), "given")) return error.InvalidSyntax;
            var content: std.ArrayList(u8) = .empty;
            var phase: usize = 0;
            var counts: [3]usize = @splat(0);
            while (true) {
                try scanner.space();
                if (scanner.source.len == 0) break;
                const saved = scanner.source;
                const word = try scanner.word();
                if (eq(u8, word, "when")) {
                    if (phase != 0 or counts[0] == 0) return error.InvalidSyntax;
                    phase = 1;
                    continue;
                }
                if (eq(u8, word, "then")) {
                    if (phase == 2 or counts[phase] == 0) return error.InvalidSyntax;
                    phase = 2;
                    continue;
                }
                const k = kind(word) catch {
                    scanner.source = saved;
                    break;
                };
                const name = try scanner.word();
                try identifier(name);
                if (entity_refs.items.len == 2048) return error.LimitExceeded;
                try entity_refs.append(temp, name);
                counts[phase] += 1;
                if (counts[phase] > 128) return error.LimitExceeded;
                const line = try std.fmt.allocPrint(temp, "{s}: {s} {s}\n", .{ ([_][]const u8{ "Given", "When", "Then" })[phase], @tagName(k), name });
                try content.appendSlice(temp, line);
            }
            if (counts[0] == 0 or counts[2] == 0) return error.InvalidSyntax;
            if (specs.items.len == 512) return error.LimitExceeded;
            try specs.append(temp, .{ .frame = id, .text = d.trim(content.items) });
            continue;
        }
        const reset = eq(u8, token, "rf") or eq(u8, token, "resetframe");
        if (!reset and !eq(u8, token, "tf") and !eq(u8, token, "timeframe")) return error.UnsupportedSyntax;
        const id = try scanner.word();
        try fid(id);
        for (frames.items) |old| if (eq(u8, old.id, id)) return error.InvalidSyntax;
        const k = try kind(try scanner.word());
        const name = try scanner.word();
        try identifier(name);
        var f: Frame = .{ .id = id, .name = name, .kind = k, .reset = reset };
        while (true) {
            try scanner.space();
            if (!txt.starts(scanner.source, "->>")) break;
            scanner.source = scanner.source[3..];
            const ref = try scanner.word();
            try fid(ref);
            if (f.refs.items.len == 512) return error.LimitExceeded;
            try f.refs.append(temp, ref);
        }
        if (txt.starts(scanner.source, "[[")) {
            scanner.source = scanner.source[2..];
            f.reference = try scanner.word();
            try scanner.space();
            if (!txt.starts(scanner.source, "]]")) return error.InvalidSyntax;
            scanner.source = scanner.source[2..];
            try scanner.space();
        }
        if (scanner.source.len > 0 and std.mem.indexOfScalar(u8, "{\"'`", scanner.source[0]) != null) f.payload = try scanner.payload();
        if (frames.items.len == 512) return error.LimitExceeded;
        try frames.append(temp, f);
    }
    if (frames.items.len == 0) return error.InvalidSyntax;
    for (entity_refs.items) |name| {
        var declared = false;
        for (entities.items) |entity| if (eq(u8, entity, name)) {
            declared = true;
        };
        if (!declared) return error.InvalidSyntax;
    }
    for (notes.items) |note| {
        const f = &frames.items[try find(frames.items, note.frame)];
        f.note = try std.fmt.allocPrint(temp, "{s}{s}{s}", .{ f.note, if (f.note.len > 0) "\n" else "", note.payload.value });
    }
    for (specs.items) |spec| {
        const f = &frames.items[try find(frames.items, spec.frame)];
        f.spec = try std.fmt.allocPrint(temp, "{s}{s}{s}", .{ f.spec, if (f.spec.len > 0) "\n" else "", spec.text });
    }
    for (frames.items) |*f| {
        if (f.reference.len > 0) {
            var found = false;
            for (datasets.items) |dataset| if (eq(u8, f.reference, dataset.name)) {
                f.payload = dataset.payload;
                found = true;
                break;
            };
            if (!found) return error.InvalidSyntax;
        }
        const dot = std.mem.lastIndexOfScalar(u8, f.name, '.');
        const namespace = if (dot) |at| f.name[0..at] else "";
        const name = if (dot) |at| f.name[at + 1 ..] else f.name;
        const category: usize = switch (f.kind) {
            .ui, .processor => 0,
            .command, .readmodel => 1,
            .event => 2,
        };
        var lane: ?usize = null;
        for (lanes.items, 0..) |existing, i| if (existing.category == category and eq(u8, existing.namespace, namespace)) {
            lane = i;
            break;
        };
        if (lane == null) {
            if (lanes.items.len == 128) return error.LimitExceeded;
            const base = ([_][]const u8{ "UI/Automation", "Command/Read Model", "Events" })[category];
            const name_space = if (namespace.len > 0) try std.fmt.allocPrint(temp, "{s}: {s}", .{ base, namespace }) else base;
            lane = lanes.items.len;
            try lanes.append(temp, .{ .category = category, .namespace = namespace, .label = try format(temp, name_space, 210) });
        }
        f.lane = lane.?;
        f.label = try format(temp, try std.fmt.allocPrint(temp, "{s}  {s}", .{ f.id, name }), 252);
        f.payload.value = try literal(temp, f.payload.value, 252);
        f.note = try format(temp, f.note, 252);
        f.spec = try format(temp, f.spec, 252);
        f.h = txt.height(f.label) + 64;
        if (f.payload.value.len > 0) f.h += txt.height(f.payload.value) + 32;
        if (f.note.len > 0) f.h += txt.height(f.note) + 40;
        if (f.spec.len > 0) f.h += txt.height(f.spec) + 40;
        lanes.items[f.lane].h = @max(lanes.items[f.lane].h, f.h + 60);
    }
    var y: usize = 40;
    for (0..3) |category| for (lanes.items) |*lane| if (lane.category == category) {
        lane.y = y;
        lane.h = @max(lane.h, txt.height(lane.label) + 60);
        y += lane.h + 12;
    };
    var right: usize = 300;
    for (frames.items, 0..) |*f, i| {
        f.x = 300 + i * 330;
        f.y = lanes.items[f.lane].y + 30;
        right = f.x + f.w + 40;
        for (f.refs.items) |ref| {
            const source_kind = frames.items[try find(frames.items, ref)].kind;
            const valid = switch (f.kind) {
                .command => source_kind == .ui or source_kind == .processor,
                .event => source_kind == .command,
                .readmodel => source_kind == .event,
                .processor, .ui => source_kind == .readmodel,
            };
            if (!valid) return error.InvalidSyntax;
        }
        if (f.reset) continue;
        if (f.refs.items.len > 0) {
            for (f.refs.items, 0..) |ref, r| {
                var duplicate = false;
                for (f.refs.items[0..r]) |prior| if (eq(u8, prior, ref)) {
                    duplicate = true;
                };
                if (duplicate) continue;
                if (edges.items.len == 2048) return error.LimitExceeded;
                try edges.append(temp, .{ .from = try find(frames.items, ref), .to = i });
            }
        } else {
            var prev = i;
            while (prev > 0) {
                prev -= 1;
                if (frames.items[prev].lane != f.lane) {
                    if (edges.items.len == 2048) return error.LimitExceeded;
                    try edges.append(temp, .{ .from = prev, .to = i });
                    break;
                }
            }
        }
    }
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    var fills = [_][]const u8{ if (doc.theme == .dark) "#253448" else "#ffffff", if (doc.theme == .dark) "#613d6c" else "#edb3f6", if (doc.theme == .dark) "#244b75" else "#bcd6fe", if (doc.theme == .dark) "#3b5528" else "#d3f1a2", if (doc.theme == .dark) "#744a22" else "#ffb778" };
    var strokes = [_][]const u8{ fg, fg, fg, fg, fg };
    for ([_][]const u8{ "Ui", "Processor", "Command", "ReadModel", "Event" }, 0..) |name, i| {
        const fillkey = try std.fmt.allocPrint(temp, "config.themeVariables.em{s}Fill", .{name});
        const strokekey = try std.fmt.allocPrint(temp, "config.themeVariables.em{s}Stroke", .{name});
        if (doc.get(fillkey)) |v| fills[i] = try d.color(v);
        if (doc.get(strokekey)) |v| strokes[i] = try d.color(v);
    }
    const line = if (doc.get("config.themeVariables.emRelationStroke")) |v| try d.color(v) else fg;
    const arrow = if (doc.get("config.themeVariables.emArrowhead")) |v| try d.color(v) else line;
    const lanefill = if (doc.get("config.themeVariables.emSwimlaneBackgroundOdd")) |v| try d.color(v) else if (doc.theme == .dark) "#161b22" else "#f6f8fa";
    const lanestroke = if (doc.get("config.themeVariables.emSwimlaneBackgroundStroke")) |v| try d.color(v) else if (doc.theme == .dark) "#303b4b" else "#d0d7de";
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(right + 30, y + 20, "eventmodeling", prefix);
    try out.fmt("<defs><marker id=\"zm-{d}-em\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"10\" markerHeight=\"10\" markerUnits=\"userSpaceOnUse\" orient=\"auto\"><path d=\"M 1 1 L 9 5 L 1 9 Z\" fill=\"{s}\" stroke=\"none\"/></marker></defs>", .{ prefix, arrow });
    for (lanes.items, 0..) |lane, i| {
        try out.fmt("<rect data-event-lane=\"{d}\" x=\"20\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" fill=\"{s}\" stroke=\"{s}\"/>", .{ i, lane.y, right, lane.h, lanefill, lanestroke });
        try label(&out, 40, lane.y + 30, lane.label, fg, true);
    }
    for (edges.items, 0..) |e, i| {
        const from = frames.items[e.from];
        const to = frames.items[e.to];
        const x1 = from.x + from.w / 2;
        const x2 = to.x + to.w / 2;
        const y1 = if (from.y < to.y) from.y + from.h else from.y;
        const y2 = if (from.y < to.y) to.y else to.y + to.h;
        try out.fmt("<path data-event-edge=\"{d}\" data-from=\"{d}\" data-to=\"{d}\" fill=\"none\" stroke=\"{s}\" marker-end=\"url(#zm-{d}-em)\"", .{ i, e.from, e.to, line, prefix });
        if (from.lane == to.lane) {
            const sy = from.y + from.h / 2;
            const ty = to.y + to.h / 2;
            if (e.from == e.to) {
                const links = @import("flow_links.zig");
                try out.add(" ");
                try links.terminalCubic(&out, links.point(from.x + from.w, sy), links.point(from.x + from.w + 40, sy), links.point(from.x + from.w + 40, from.y + from.h - 10), links.point(from.x + from.w, from.y + from.h - 10));
                try out.add("/>");
            } else try out.fmt(" d=\"M {d} {d} L {d} {d}\"/>", .{ if (from.x < to.x) from.x + from.w else from.x, sy, if (from.x < to.x) to.x else to.x + to.w, ty });
        } else {
            try out.add(" ");
            try @import("flow_links.zig").route(&out, .smooth, x1, y1, x2, y2, false);
        }
    }
    for (frames.items, 0..) |f, i| {
        const ki = @intFromEnum(f.kind);
        try out.fmt("<g data-event-frame=\"{d}\" data-frame-id=\"{s}\" data-kind=\"{s}\" data-reset=\"{s}\" data-lane=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"4\" fill=\"{s}\" stroke=\"{s}\"{s}/>", .{ i, f.id, @tagName(f.kind), if (f.reset) "true" else "false", f.lane, f.x, f.y, f.w, f.h, f.x, f.y, f.w, f.h, fills[ki], strokes[ki], if (f.reset) " stroke-dasharray=\"6 4\"" else "" });
        var top = f.y + 26;
        try label(&out, f.x + 14, top, f.label, fg, true);
        top += txt.height(f.label) + 8;
        try label(&out, f.x + 14, top, @tagName(f.kind), fg, false);
        top += 24;
        if (f.payload.value.len > 0) {
            try out.fmt("<g data-payload-type=\"{s}\">", .{f.payload.kind});
            try label(&out, f.x + 14, top, f.payload.value, fg, false);
            try out.add("</g>");
            top += txt.height(f.payload.value) + 32;
        }
        if (f.note.len > 0) {
            try label(&out, f.x + 14, top, "Note", fg, true);
            top += 20;
            try label(&out, f.x + 14, top, f.note, fg, false);
            top += txt.height(f.note) + 20;
        }
        if (f.spec.len > 0) {
            try label(&out, f.x + 14, top, "Specification", fg, true);
            top += 20;
            try label(&out, f.x + 14, top, f.spec, fg, false);
        }
        try out.add("</g>");
    }
    return out.finish();
}
