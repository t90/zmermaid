const std = @import("std");
const svg = @import("svg.zig");
const text = @import("sequence_text.zig");
pub const Error = text.Error;
fn textWidth(value: []const u8, size: f64) usize {
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(text.width(value))) * size / 14));
}
fn textHeight(value: []const u8, size: f64) usize {
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(text.height(value))) * size / 14));
}
const Align = enum { left, center, right };
fn drawText(out: *svg.Svg, x: usize, top: usize, value: []const u8, size: f64, alignment: Align) Error!void {
    return drawClassText(out, x, top, value, size, alignment, "");
}
fn drawClassText(out: *svg.Svg, x: usize, top: usize, value: []const u8, size: f64, alignment: Align, class_name: []const u8) Error!void {
    if (size == 14 and alignment == .center and class_name.len == 0) return text.draw(out, x, top, value);
    const style: @import("chart_text.zig").Text = .{ .size = size, .color = if (out.theme == .dark) "#e0e0e0" else "#24292f", .class_name = class_name };
    const w = style.width(value);
    var lines = std.mem.splitScalar(u8, value, '\n');
    var y: f64 = @floatFromInt(top);
    while (lines.next()) |line| {
        const offset = (w - style.width(line)) / 2;
        try style.draw(out, @as(f64, @floatFromInt(x)) + switch (alignment) {
            .left => -offset,
            .center => 0,
            .right => offset,
        }, y, line);
        y += size * 20 / 14;
    }
}
const ParticipantType = enum { participant, actor, boundary, control, entity, database, collections, queue };
const Properties = std.json.ArrayHashMap(std.json.Value);
const Participant = struct { id: []const u8, label: []const u8, shape: ParticipantType = .participant, box: ?usize = null, created: ?usize = null, destroyed: ?usize = null, properties: Properties = .{} };
fn propertyText(item: Participant, key: []const u8) Error![]const u8 {
    const value = item.properties.map.get(key) orelse return "";
    if (value == .null) return "";
    if (value != .string or value.string.len > 512) return error.InvalidSyntax;
    return value.string;
}
fn boundedProperty(value: std.json.Value, depth: usize) Error!void {
    if (depth > 16) return error.LimitExceeded;
    switch (value) {
        .array => |items| {
            if (items.items.len > 64) return error.LimitExceeded;
            for (items.items) |child| try boundedProperty(child, depth + 1);
        },
        .object => |items| {
            if (items.count() > 64) return error.LimitExceeded;
            for (items.values()) |child| try boundedProperty(child, depth + 1);
        },
        else => {},
    }
}
const Box = struct { label: []const u8, color: []const u8 };
const ParticipantLink = struct { actor: usize, label: []const u8, url: []const u8 };
const Head = enum { none, arrow, cross, open, top, bottom, stick_top, stick_bottom };
const Kind = enum { message, note, activate, deactivate, fragment_start, fragment_branch, fragment_end };
const FragmentKind = enum { loop, opt, alt, par, critical, @"break", rect };
const Fragment = struct {
    kind: FragmentKind,
    parent: ?usize,
    depth: usize,
    start: usize,
    end: ?usize = null,
    left: usize = std.math.maxInt(usize),
    right: usize = 0,
    min_width: usize = 180,
    color: []const u8 = "",
};
const Placement = enum { left, right, over };
const Event = struct {
    kind: Kind,
    from: usize,
    to: usize,
    label: []const u8 = "",
    head: Head = .none,
    dashed: bool = false,
    both: bool = false,
    reverse: bool = false,
    central_from: bool = false,
    central_to: bool = false,
    placement: Placement = .over,
    number: ?u32 = null,
    from_depth: usize = 0,
    to_depth: usize = 0,
    y: usize = 0,
    fragment: ?usize = null,
    markdown: bool = false,
};
const Span = struct { actor: usize, depth: usize, start: usize, end: ?usize = null };
fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r");
}
fn equal(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn fontWeight(value: []const u8) Error!f64 {
    const weight = if (equal(value, "normal")) 400 else if (equal(value, "bold")) 700 else try @import("document.zig").number(value);
    if (weight < 1 or weight > 1000) return error.InvalidSyntax;
    return weight;
}
fn keyword(line: []const u8, name: []const u8) bool {
    return text.starts(line, name) and (line.len == name.len or line[name.len] == ' ' or line[name.len] == '\t');
}

// Store decimal numbering in hundredths for identical native and WASM results.
fn hundredths(value: []const u8) Error!u32 {
    for (value) |ch| if (!std.ascii.isDigit(ch) and ch != '.') {
        return error.InvalidSyntax;
    };
    var parts = std.mem.splitScalar(u8, value, '.');
    const whole_text = parts.next().?;
    const whole = if (whole_text.len == 0) @as(u32, 0) else std.fmt.parseInt(u32, whole_text, 10) catch return error.InvalidSyntax;
    if (whole > 1000000) return error.LimitExceeded;
    var result = whole * 100;
    if (parts.next()) |fraction| {
        if (fraction.len == 0 or fraction.len > 2) return error.UnsupportedSyntax;
        const n = std.fmt.parseInt(u32, fraction, 10) catch return error.InvalidSyntax;
        result += n * (if (fraction.len == 1) @as(u32, 10) else 1);
    }
    if (parts.next() != null or value.len == 0) return error.InvalidSyntax;
    return result;
}

const Parser = struct {
    a: std.mem.Allocator,
    participants: std.ArrayList(Participant) = .empty,
    links: std.ArrayList(ParticipantLink) = .empty,
    boxes: std.ArrayList(Box) = .empty,
    box: ?usize = null,
    pending_create: ?usize = null,
    pending_destroy: ?usize = null,
    events: std.ArrayList(Event) = .empty,
    spans: std.ArrayList(Span) = .empty,
    fragments: std.ArrayList(Fragment) = .empty,
    fragment_stack: [16]usize = undefined,
    fragment_depth: usize = 0,
    depths: [64]usize = @splat(0),
    stack: [64][16]usize = undefined,
    title: []const u8 = "",
    acc_title: []const u8 = "",
    acc_description: []const u8 = "",
    numbered: bool = false,
    number: u32 = 100,
    increment: u32 = 100,
    messages: usize = 0,
    notes: usize = 0,
    rich_notes: bool = false,
    wrap_labels: bool = false,
    wrap_width: usize = 240,
    actor_size: f64 = 14,
    message_size: f64 = 14,
    note_size: f64 = 14,
    base_size: f64 = 14,
    fn hideUnused(self: *Parser) void {
        var used: [64]bool = @splat(false);
        for (self.events.items) |event| switch (event.kind) {
            .message, .note, .activate, .deactivate => {
                used[event.from] = true;
                used[event.to] = true;
            },
            else => {},
        };
        var map: [64]usize = @splat(0);
        var count: usize = 0;
        for (self.participants.items, 0..) |participant_item, i| {
            if (!used[i]) continue;
            map[i] = count;
            self.participants.items[count] = participant_item;
            count += 1;
        }
        self.participants.items.len = count;
        for (self.events.items) |*event| {
            event.from = map[event.from];
            event.to = map[event.to];
        }
        for (self.spans.items) |*span| span.actor = map[span.actor];
        count = 0;
        for (self.links.items) |link_item| {
            if (!used[link_item.actor]) continue;
            var item = link_item;
            item.actor = map[item.actor];
            self.links.items[count] = item;
            count += 1;
        }
        self.links.items.len = count;
    }
    fn eventSize(self: *const Parser, event: Event) f64 {
        return switch (event.kind) {
            .message => self.message_size,
            .note => self.note_size,
            else => self.base_size,
        };
    }
    fn eventWidth(self: *const Parser, event: Event) usize {
        return textWidth(event.label, self.eventSize(event));
    }
    fn eventHeight(self: *const Parser, event: Event) usize {
        return textHeight(event.label, self.eventSize(event));
    }
    fn label(self: *Parser, raw: []const u8) Error![]const u8 {
        return self.labelSized(raw, self.base_size);
    }
    fn labelSized(self: *Parser, raw: []const u8, size: f64) Error![]const u8 {
        var source = raw;
        var wrap = self.wrap_labels;
        if (text.starts(source, "wrap:")) {
            wrap = true;
            source = trim(source[5..]);
        }
        if (text.starts(source, "nowrap:")) {
            wrap = false;
            source = trim(source[7..]);
        }
        const decoded = try text.parse(self.a, source);
        if (!wrap) return decoded;
        const logical_width: usize = @intFromFloat(@max(1, @floor(@as(f64, @floatFromInt(self.wrap_width)) * 14 / size)));
        const wrapped = try @import("text_wrap.zig").wrap(self.a, decoded, logical_width);
        if (std.mem.count(u8, wrapped, "\n") >= 16) return error.LimitExceeded;
        return wrapped;
    }
    fn link(self: *Parser, actor: usize, link_label: []const u8, url: []const u8) Error!void {
        if (self.links.items.len == 128 or link_label.len > 512 or url.len > 2048) return error.LimitExceeded;
        if (!text.starts(url, "https://") and !text.starts(url, "http://") and !text.starts(url, "#")) return error.UnsupportedSyntax;
        for (url) |c| if (c < 32) return error.InvalidSyntax;
        for (link_label) |c| if (c < 32 and c != 10 and c != 9) return error.InvalidSyntax;
        try self.links.append(self.a, .{ .actor = actor, .label = try self.label(link_label), .url = url });
    }
    fn participant(self: *Parser, id: []const u8) Error!usize {
        if (id.len == 0) return error.InvalidSyntax;
        if (id.len > 512) return error.LimitExceeded;
        // IDs are data, not SVG element IDs. Preserve Unicode, spaces, dots
        // and hyphens while reserving sequence grammar punctuation.
        for (id) |ch| if (ch < 32 or ch == 127 or std.mem.indexOfScalar(u8, "<>:;,()\\/+{}@#\"", ch) != null) {
            return error.UnsupportedSyntax;
        };
        for (self.participants.items, 0..) |item, index| if (std.mem.eql(u8, item.id, id)) {
            return index;
        };
        if (self.participants.items.len == 64) return error.LimitExceeded;
        try self.participants.append(self.a, .{ .id = id, .label = id });
        return self.participants.items.len - 1;
    }
    fn append(self: *Parser, event: Event) Error!void {
        if (self.events.items.len == 2048) return error.LimitExceeded;
        var owned = event;
        if (owned.fragment == null and self.fragment_depth > 0) owned.fragment = self.fragment_stack[self.fragment_depth - 1];
        try self.events.append(self.a, owned);
    }
    fn activation(self: *Parser, actor: usize, active: bool) Error!void {
        const depth = self.depths[actor];
        if (active) {
            if (depth == 16 or self.spans.items.len == 512) return error.LimitExceeded;
            if (self.events.items.len > 0) {
                const previous = &self.events.items[self.events.items.len - 1];
                if (previous.kind == .message and previous.to == actor) previous.to_depth = depth + 1;
            }
            self.stack[actor][depth] = self.spans.items.len;
            try self.spans.append(self.a, .{ .actor = actor, .depth = depth, .start = self.events.items.len });
            self.depths[actor] += 1;
        } else {
            if (depth == 0) return error.InvalidSyntax;
            self.depths[actor] -= 1;
            self.spans.items[self.stack[actor][depth - 1]].end = self.events.items.len;
        }
        try self.append(.{ .kind = if (active) .activate else .deactivate, .from = actor, .to = actor });
    }
    fn statement(self: *Parser, line: []const u8) Error!void {
        if (line.len == 0) return;
        if (text.starts(line, "accTitle:")) {
            self.acc_title = trim(line[9..]);
            return;
        }
        if (text.starts(line, "accDescr:")) {
            self.acc_description = trim(line[9..]);
            return;
        }
        if (text.starts(line, "accDescr {") and std.mem.endsWith(u8, line, "}")) {
            self.acc_description = std.mem.trim(u8, line[10 .. line.len - 1], " \t\r\n");
            return;
        }
        if (text.starts(line, "%%{")) return error.UnsupportedSyntax;
        if (text.starts(line, "%%")) return;
        if (keyword(line, "par_over")) return self.statement(try std.fmt.allocPrint(self.a, "par{s}", .{line[8..]}));
        if (self.box != null and !equal(line, "end") and !keyword(line, "participant") and !keyword(line, "actor")) return error.InvalidSyntax;
        if (keyword(line, "box")) {
            if (self.fragment_depth != 0) return error.InvalidSyntax;
            if (self.boxes.items.len == 64) return error.LimitExceeded;
            const rest = trim(line[3..]);
            var split = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            if (std.mem.indexOfScalar(u8, rest, '(')) |open| {
                if (open <= split) split = (std.mem.indexOfScalarPos(u8, rest, open, ')') orelse return error.InvalidSyntax) + 1;
            }
            const candidate = rest[0..split];
            const colored = @import("document.zig").namedColor(candidate) or std.mem.indexOfScalar(u8, candidate, '(') != null;
            const color = if (colored) try @import("document.zig").color(candidate) else "transparent";
            const box_label = try self.label(if (colored) trim(rest[split..]) else rest);
            self.box = self.boxes.items.len;
            try self.boxes.append(self.a, .{ .label = box_label, .color = color });
            return;
        }
        if (keyword(line, "create")) {
            if (self.pending_create != null) return error.InvalidSyntax;
            const rest = trim(line[6..]);
            if (!keyword(rest, "participant") and !keyword(rest, "actor")) return error.InvalidSyntax;
            const previous = self.participants.items.len;
            try self.statement(rest);
            if (self.participants.items.len != previous + 1) return error.InvalidSyntax;
            self.pending_create = previous;
            return;
        }
        if (keyword(line, "destroy")) {
            if (self.pending_destroy != null) return error.InvalidSyntax;
            const n = try self.participant(trim(line[7..]));
            if (self.participants.items[n].destroyed != null) return error.InvalidSyntax;
            self.pending_destroy = n;
            return;
        }
        for (std.meta.tags(FragmentKind)) |kind| {
            const name = @tagName(kind);
            if (keyword(line, name)) {
                if (self.fragment_depth == 16 or self.fragments.items.len == 256) return error.LimitExceeded;
                const index = self.fragments.items.len;
                const value = trim(line[name.len..]);
                try self.fragments.append(self.a, .{ .kind = kind, .parent = if (self.fragment_depth > 0) self.fragment_stack[self.fragment_depth - 1] else null, .depth = self.fragment_depth, .start = self.events.items.len, .color = if (kind == .rect) (if (value.len == 0) "gray" else try @import("document.zig").color(value)) else "" });
                try self.append(.{ .kind = .fragment_start, .from = 0, .to = 0, .fragment = index, .label = if (kind == .rect) "" else try self.label(value) });
                self.fragment_stack[self.fragment_depth] = index;
                self.fragment_depth += 1;
                return;
            }
        }
        if (equal(line, "end")) {
            if (self.box != null) {
                self.box = null;
                return;
            }
            if (self.fragment_depth == 0) return error.InvalidSyntax;
            const index = self.fragment_stack[self.fragment_depth - 1];
            self.fragments.items[index].end = self.events.items.len;
            try self.append(.{ .kind = .fragment_end, .from = 0, .to = 0, .fragment = index });
            self.fragment_depth -= 1;
            return;
        }
        const branches = .{ .{ "else", FragmentKind.alt }, .{ "and", FragmentKind.par }, .{ "option", FragmentKind.critical } };
        inline for (branches) |branch| {
            if (keyword(line, branch[0])) {
                if (self.fragment_depth == 0) return error.InvalidSyntax;
                const index = self.fragment_stack[self.fragment_depth - 1];
                if (self.fragments.items[index].kind != branch[1]) return error.InvalidSyntax;
                try self.append(.{ .kind = .fragment_branch, .from = 0, .to = 0, .fragment = index, .label = try self.label(trim(line[branch[0].len..])) });
                return;
            }
        }
        if (text.starts(line, "title ") or text.starts(line, "title: ")) {
            self.title = try self.label(trim(line[if (line[5] == ':') @as(usize, 6) else 5..]));
            return;
        }
        if (equal(line, "autonumber") or text.starts(line, "autonumber ")) {
            const options = trim(line[10..]);
            if (equal(options, "off")) {
                self.numbered = false;
                return;
            }
            var words = std.mem.tokenizeAny(u8, options, " \t");
            if (words.next()) |start| {
                const number = try hundredths(start);
                const increment = if (words.next()) |step| try hundredths(step) else 100;
                if (number != 0) self.number = number;
                if (increment != 0) self.increment = increment;
                if (words.next() != null) return error.UnsupportedSyntax;
            }
            self.numbered = true;
            return;
        }
        const actor = text.starts(line, "actor ");
        if (actor or text.starts(line, "participant ")) {
            var rest = trim(line[if (actor) @as(usize, 6) else 12..]);
            var metadata_alias: ?[]const u8 = null;
            var shape: ParticipantType = if (actor) .actor else .participant;
            if (std.mem.indexOf(u8, rest, "@{")) |meta| {
                const close = std.mem.lastIndexOfScalar(u8, rest, '}') orelse return error.InvalidSyntax;
                const Metadata = struct { type: ?[]const u8 = null, alias: ?[]const u8 = null };
                const parsed = std.json.parseFromSlice(Metadata, self.a, rest[meta + 1 .. close + 1], .{ .allocate = .alloc_always }) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.UnknownField => error.UnsupportedSyntax,
                    else => error.InvalidSyntax,
                };
                metadata_alias = parsed.value.alias;
                if (parsed.value.type) |name| shape = std.meta.stringToEnum(ParticipantType, name) orelse return error.UnsupportedSyntax;
                rest = try std.fmt.allocPrint(self.a, "{s}{s}", .{ rest[0..meta], rest[close + 1 ..] });
            }
            var alias: ?usize = null;
            for (0..rest.len) |i| if (text.starts(rest[i..], " as ")) {
                alias = i;
                break;
            };
            const n = try self.participant(trim(rest[0 .. alias orelse rest.len]));
            if (self.box) |b| {
                if (self.participants.items[n].box) |old| if (old != b) return error.InvalidSyntax;
                self.participants.items[n].box = b;
            }
            self.participants.items[n].shape = shape;
            if (metadata_alias) |value| {
                for (value) |c| if (c < 32 and c != 10 and c != 9) return error.InvalidSyntax;
                self.participants.items[n].label = try self.labelSized(value, self.actor_size);
            }
            if (alias) |i| self.participants.items[n].label = try self.labelSized(trim(rest[i + 4 ..]), self.actor_size);
            return;
        }
        if (text.starts(line, "properties ")) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
            const id = try self.participant(trim(line[11..colon]));
            const rest = trim(line[colon + 1 ..]);
            if (rest.len > 4096) return error.LimitExceeded;
            const parsed = std.json.parseFromSlice(Properties, self.a, rest, .{ .allocate = .alloc_always }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidSyntax,
            };
            if (parsed.value.map.count() > 64) return error.LimitExceeded;
            var it = parsed.value.map.iterator();
            while (it.next()) |entry| {
                try boundedProperty(entry.value_ptr.*, 0);
                try self.participants.items[id].properties.map.put(self.a, entry.key_ptr.*, entry.value_ptr.*);
            }
            if (self.participants.items[id].properties.map.count() > 64) return error.LimitExceeded;
            _ = try propertyText(self.participants.items[id], "class");
            _ = try propertyText(self.participants.items[id], "icon");
            return;
        }
        if (text.starts(line, "link ") or text.starts(line, "links ")) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
            const multiple = text.starts(line, "links ");
            const id = try self.participant(trim(line[if (multiple) @as(usize, 6) else 5..colon]));
            const rest = trim(line[colon + 1 ..]);
            if (multiple) {
                const parsed = std.json.parseFromSlice(std.json.ArrayHashMap([]const u8), self.a, rest, .{ .allocate = .alloc_always }) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.InvalidSyntax,
                };
                var it = parsed.value.map.iterator();
                while (it.next()) |entry| try self.link(id, entry.key_ptr.*, entry.value_ptr.*);
            } else {
                const at = std.mem.indexOfScalar(u8, rest, '@') orelse return error.InvalidSyntax;
                try self.link(id, trim(rest[0..at]), trim(rest[at + 1 ..]));
            }
            return;
        }
        if (text.starts(line, "activate ") or text.starts(line, "deactivate ")) {
            const active = text.starts(line, "activate ");
            const n = try self.participant(trim(line[if (active) @as(usize, 9) else 11..]));
            try self.activation(n, active);
            return;
        }
        if (text.starts(line, "note ")) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
            const spec = trim(line[5..colon]);
            const placement: Placement = if (text.starts(spec, "left of ")) .left else if (text.starts(spec, "right of ")) .right else if (text.starts(spec, "over ")) .over else return error.UnsupportedSyntax;
            const ids = trim(spec[switch (placement) {
                .left => @as(usize, 8),
                .right => 9,
                .over => 5,
            }..]);
            const comma = std.mem.indexOfScalar(u8, ids, ',');
            if (comma != null and placement != .over) return error.InvalidSyntax;
            const from = try self.participant(trim(ids[0 .. comma orelse ids.len]));
            const to = if (comma) |i| try self.participant(trim(ids[i + 1 ..])) else from;
            if (self.notes == 512) return error.LimitExceeded;
            self.notes += 1;
            try self.append(.{ .kind = .note, .from = from, .to = to, .placement = placement, .label = try self.labelSized(trim(line[colon + 1 ..]), self.note_size), .markdown = self.rich_notes });
            return;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.UnsupportedSyntax;
        const forms = .{
            .{ "<<-->>", Head.arrow, true, true }, .{ "<<->>", Head.arrow, false, true },
            .{ "-->>", Head.arrow, true, false },  .{ "->>", Head.arrow, false, false },
            .{ "-->", Head.none, true, false },    .{ "->", Head.none, false, false },
            .{ "--x", Head.cross, true, false },   .{ "-x", Head.cross, false, false },
            .{ "--)", Head.open, true, false },    .{ "-)", Head.open, false, false },
        };
        const half_forms = .{
            .{ "--|\\", Head.top, true, false },        .{ "--|/", Head.bottom, true, false },
            .{ "--\\\\", Head.stick_top, true, false }, .{ "--//", Head.stick_bottom, true, false },
            .{ "/|--", Head.top, true, true },          .{ "\\|--", Head.bottom, true, true },
            .{ "//--", Head.stick_top, true, true },    .{ "\\\\--", Head.stick_bottom, true, true },
            .{ "-|\\", Head.top, false, false },        .{ "-|/", Head.bottom, false, false },
            .{ "-\\\\", Head.stick_top, false, false }, .{ "-//", Head.stick_bottom, false, false },
            .{ "/|-", Head.top, false, true },          .{ "\\|-", Head.bottom, false, true },
            .{ "//-", Head.stick_top, false, true },    .{ "\\\\-", Head.stick_bottom, false, true },
        };
        var arrow_at: ?usize = null;
        search: for (0..colon) |candidate| {
            inline for (half_forms ++ forms) |form| if (std.mem.startsWith(u8, line[candidate..colon], form[0])) {
                arrow_at = candidate;
                break :search;
            };
        }
        const at = arrow_at orelse return error.UnsupportedSyntax;
        var from_id = trim(line[0..at]);
        const central_from = std.mem.endsWith(u8, from_id, "()");
        if (central_from) from_id = trim(from_id[0 .. from_id.len - 2]);
        var event: Event = .{ .kind = .message, .from = try self.participant(from_id), .to = 0, .central_from = central_from };
        var end = at;
        inline for (half_forms) |form| {
            if (end == at and std.mem.startsWith(u8, line[at..colon], form[0])) {
                end += form[0].len;
                event.head = form[1];
                event.dashed = form[2];
                event.reverse = form[3];
            }
        }
        inline for (forms) |form| {
            if (end == at and std.mem.startsWith(u8, line[at..colon], form[0])) {
                end += form[0].len;
                event.head = form[1];
                event.dashed = form[2];
                event.both = form[3];
            }
        }
        if (end == at) return error.UnsupportedSyntax;
        while (end < colon and (line[end] == ' ' or line[end] == '\t')) end += 1;
        if (std.mem.startsWith(u8, line[end..colon], "()")) {
            event.central_to = true;
            end += 2;
        }
        var action: u8 = 0;
        if (end < colon and (line[end] == '+' or line[end] == '-')) {
            action = line[end];
            end += 1;
        }
        event.to = try self.participant(trim(line[end..colon]));
        if (self.participants.items[event.from].destroyed != null or self.participants.items[event.to].destroyed != null) return error.InvalidSyntax;
        if (self.pending_create) |n| {
            if (event.to != n or event.from == n) return error.InvalidSyntax;
            self.participants.items[n].created = self.events.items.len;
            self.pending_create = null;
        }
        if (self.pending_destroy) |n| {
            if (event.to != n and event.from != n) return error.InvalidSyntax;
            self.participants.items[n].destroyed = self.events.items.len;
            self.pending_destroy = null;
        }
        event.label = try self.labelSized(trim(line[colon + 1 ..]), self.message_size);
        event.from_depth = self.depths[event.from] + @as(usize, if (event.central_from) 1 else 0);
        event.to_depth = self.depths[event.to] + @as(usize, if (action == '+' or event.central_to) 1 else 0);
        if (self.messages == 512 or self.number > 100000000) return error.LimitExceeded;
        self.messages += 1;
        event.number = if (self.numbered) self.number else null;
        self.number += self.increment;
        try self.append(event);
        if (event.central_to) try self.activation(event.to, true);
        if (event.central_from) try self.activation(event.from, true);
        if (action != 0) try self.activation(if (action == '+') event.to else event.from, action == '+');
    }
    fn parse(self: *Parser, source: []const u8) Error!void {
        var start: usize = 0;
        var at: usize = 0;
        var header = true;
        var braces: usize = 0;
        var quoted = false;
        var escaped = false;
        while (at <= source.len) : (at += 1) {
            if (at < source.len) {
                const c = source[at];
                if (braces > 0) {
                    if (escaped) {
                        escaped = false;
                        continue;
                    }
                    if (quoted and c == '\\') {
                        escaped = true;
                        continue;
                    }
                    if (c == '"') quoted = !quoted;
                    if (quoted) continue;
                    if (c == '{') {
                        braces += 1;
                        if (braces > 16) return error.LimitExceeded;
                    }
                    if (c == '}') braces -= 1;
                    if (braces > 0) continue;
                } else if (c == '{') {
                    const before = trim(source[start..at]);
                    if (text.starts(before, "participant ") or text.starts(before, "actor ") or text.starts(before, "links ") or text.starts(before, "properties ") or text.starts(before, "create ") or equal(before, "accDescr")) {
                        braces = 1;
                        continue;
                    }
                }
            }
            if (at < source.len and source[at] == '#') {
                const before = trim(source[start..at]);
                // A URI fragment is not a Mermaid character entity.
                if (text.starts(before, "link ") and std.mem.indexOfScalar(u8, before, '@') != null) continue;
                if (std.mem.indexOfScalarPos(u8, source, at + 1, ';')) |end| {
                    var entity = end > at + 1;
                    for (source[at + 1 .. end]) |ch| if (!std.ascii.isAlphanumeric(ch)) {
                        entity = false;
                    };
                    if (entity) {
                        at = end;
                        continue;
                    }
                }
            }
            if (at < source.len and std.mem.startsWith(u8, source[at..], "%%")) {
                if (std.mem.startsWith(u8, source[at..], "%%{")) return error.UnsupportedSyntax;
                const before = trim(source[start..at]);
                if (header) {
                    if (!equal(before, "sequenceDiagram")) return error.InvalidSyntax;
                    header = false;
                } else try self.statement(before);
                while (at < source.len and source[at] != '\n') at += 1;
                start = at + 1;
                continue;
            }
            if (at == source.len or source[at] == '\n' or source[at] == ';') {
                const line = trim(source[start..at]);
                if (header) {
                    if (!equal(line, "sequenceDiagram")) return error.InvalidSyntax;
                    header = false;
                } else try self.statement(line);
                start = at + 1;
            }
        }
        if (self.participants.items.len == 0 or self.fragment_depth != 0 or braces > 0 or quoted or self.box != null or self.pending_create != null or self.pending_destroy != null) return error.InvalidSyntax;
        // Group members stay adjacent even when they were referenced before their declarations.
        var ordered: [64]Participant = undefined;
        var map: [64]usize = undefined;
        var seen: [64]bool = @splat(false);
        var count: usize = 0;
        for (self.participants.items, 0..) |p, i| {
            if (seen[i]) continue;
            for (self.participants.items, 0..) |q, j| {
                if (seen[j] or (j != i and (p.box == null or p.box != q.box))) continue;
                seen[j] = true;
                map[j] = count;
                ordered[count] = q;
                count += 1;
            }
        }
        @memcpy(self.participants.items, ordered[0..count]);
        for (self.events.items) |*event| {
            event.from = map[event.from];
            event.to = map[event.to];
        }
        for (self.spans.items) |*span| span.actor = map[span.actor];
        for (self.links.items) |*link_item| link_item.actor = map[link_item.actor];
    }
};

fn numberLabel(out: *svg.Svg, x: usize, y: usize, value: u32) !void {
    var buffer: [32]u8 = undefined;
    const label = (if (value % 100 == 0) std.fmt.bufPrint(&buffer, "{d}", .{value / 100}) else if (value % 10 == 0) std.fmt.bufPrint(&buffer, "{d}.{d}", .{ value / 100, value % 100 / 10 }) else std.fmt.bufPrint(&buffer, "{d}.{d:0>2}", .{ value / 100, value % 100 })) catch return error.LimitExceeded;
    try out.add("<g data-sequence-number=\"");
    try out.escape(label);
    try out.add("\">");
    try out.text(x, y, label);
    try out.add("</g>");
}

const NoteBox = struct { x: usize, width: usize };
fn noteBox(parser: *const Parser, event: Event, x1: usize, x2: usize) NoteBox {
    const width = @max(parser.eventWidth(event) + 32, if (event.placement == .over) @max(x1, x2) - @min(x1, x2) + 80 else @as(usize, 80));
    const x = switch (event.placement) {
        .left => x1 - width - 24,
        .right => x1 + 24,
        .over => (x1 + x2) / 2 - width / 2,
    };
    return .{ .x = x, .width = width };
}

fn fragmentBounds(parser: *Parser, margin: usize, gap: usize, activation_width: usize) void {
    for (parser.events.items) |event| {
        const owner = event.fragment orelse continue;
        const fragment = &parser.fragments.items[owner];
        if (event.kind == .fragment_start or event.kind == .fragment_branch) {
            fragment.min_width = @max(fragment.min_width, parser.eventWidth(event) + textWidth(@tagName(fragment.kind), parser.base_size) + 80);
            continue;
        }
        if (event.kind == .fragment_end) continue;
        const x1 = margin + gap / 2 + event.from * gap;
        const x2 = margin + gap / 2 + event.to * gap;
        const depth = @max(event.from_depth, event.to_depth);
        const activation_extent = depth * (activation_width / 2) + activation_width;
        var left = @min(x1, x2) - @max(@as(usize, 12), activation_width / 2);
        var right = @max(x1, x2) + 12 + activation_extent;
        if (event.kind == .message) {
            const center = if (event.from == event.to) x1 + 60 else (x1 + x2) / 2;
            left = @min(left, center - parser.eventWidth(event) / 2);
            right = @max(right, center + parser.eventWidth(event) / 2);
            if (event.from == event.to) right = @max(right, x1 + 72 + activation_extent);
        } else if (event.kind == .note) {
            const box = noteBox(parser, event, x1, x2);
            left = box.x;
            right = box.x + box.width;
        }
        fragment.left = @min(fragment.left, left);
        fragment.right = @max(fragment.right, right);
    }
    // Children are always created after parents; no recursive layout needed.
    var i = parser.fragments.items.len;
    while (i > 0) {
        i -= 1;
        const fragment = &parser.fragments.items[i];
        if (fragment.right == 0) {
            fragment.left = margin + gap / 2 - 40;
            fragment.right = margin + gap / 2 + 40;
        }
        fragment.left -= @min(fragment.left, 24);
        fragment.right += 24;
        if (fragment.right - fragment.left < fragment.min_width) {
            const extra = fragment.min_width - (fragment.right - fragment.left);
            const shift = @min(fragment.left, extra / 2);
            fragment.left -= shift;
            fragment.right += extra - shift;
        }
        if (fragment.parent) |parent| {
            parser.fragments.items[parent].left = @min(parser.fragments.items[parent].left, fragment.left);
            parser.fragments.items[parent].right = @max(parser.fragments.items[parent].right, fragment.right);
        }
    }
}

fn themeRule(out: *svg.Svg, selectors: []const u8, property: []const u8, value: []const u8) Error!void {
    const color = try @import("document.zig").color(value);
    try out.add("<style>");
    var parts = std.mem.splitScalar(u8, selectors, ',');
    var first = true;
    while (parts.next()) |selector| {
        if (!first) try out.add(",");
        first = false;
        try out.fmt("#zm-{d}-css {s}", .{ out.id_prefix, selector });
    }
    try out.fmt("{{{s}:{s};}}</style>", .{ property, color });
}
fn sequenceTheme(out: *svg.Svg, doc: *@import("document.zig").Document) Error!void {
    const forest = std.mem.eql(u8, doc.style, "forest");
    const neutral = std.mem.eql(u8, doc.style, "neutral");
    if (forest or neutral) {
        doc.palette_used = true;
        const fill = if (forest) (if (out.theme == .dark) "#213b2a" else "#cde498") else if (out.theme == .dark) "#252525" else "#eeeeee";
        const border = if (forest) (if (out.theme == .dark) "#8abb8f" else "#13540c") else if (out.theme == .dark) "#aab0b8" else "#666666";
        try themeRule(out, ".zm-sequence-actor,[data-activation],.labelBox", "fill", fill);
        try themeRule(out, ".zm-sequence-actor,[data-activation],[data-frame],.labelBox", "stroke", border);
    }
    const entries = .{
        .{ "textColor", "text", "fill" },
        .{ "primaryColor", ".zm-sequence-actor,.labelBox", "fill" },
        .{ "primaryBorderColor", ".zm-sequence-actor,.labelBox,[data-activation],[data-frame]", "stroke" },
        .{ "primaryTextColor", "[data-participant] text,.labelText,.loopText", "fill" },
        .{ "lineColor", "[data-lifeline],[data-message],[data-central]", "stroke" },
        .{ "actorBkg", ".zm-sequence-actor", "fill" },
        .{ "actorBorder", ".zm-sequence-actor", "stroke" },
        .{ "actorTextColor", "[data-participant] text", "fill" },
        .{ "actorLineColor", "[data-lifeline]", "stroke" },
        .{ "signalColor", "[data-message],[data-central]", "stroke" },
        .{ "signalTextColor", "[data-message-label] text", "fill" },
        .{ "sequenceNumberColor", "[data-sequence-number] text", "fill" },
        .{ "labelBoxBkgColor", ".labelBox", "fill" },
        .{ "labelBoxBorderColor", ".labelBox,[data-frame]", "stroke" },
        .{ "labelTextColor", ".labelText", "fill" },
        .{ "loopTextColor", ".loopText", "fill" },
        .{ "noteBkgColor", "[data-note] > rect", "fill" },
        .{ "noteBorderColor", "[data-note] > rect", "stroke" },
        .{ "noteTextColor", "[data-note] text", "fill" },
        .{ "activationBkgColor", "[data-activation]", "fill" },
        .{ "activationBorderColor", "[data-activation]", "stroke" },
    };
    inline for (entries) |entry| if (doc.get("config.themeVariables." ++ entry[0])) |value| try themeRule(out, entry[1], entry[2], value);
    // Marker definitions inherit paint; preserve fill="none" on open arrow paths.
    const signal = doc.get("config.themeVariables.signalColor") orelse doc.get("config.themeVariables.lineColor");
    if (signal) |value| {
        var selector: [96]u8 = undefined;
        const markers = std.fmt.bufPrint(&selector, "marker[id^=\"zm-{d}-seq-\"]", .{out.id_prefix}) catch unreachable;
        try themeRule(out, markers, "stroke", value);
        try themeRule(out, markers, "fill", value);
        try themeRule(out, "[data-central]", "fill", value);
    }
}
fn drawFragments(out: *svg.Svg, parser: *const Parser) !void {
    const bg = if (out.theme == .dark) "#0d1117" else "#ffffff";
    const tab = if (out.theme == .dark) "#16213e" else "#eef4ff";
    for (parser.fragments.items, 0..) |fragment, i| {
        if (fragment.kind == .rect) continue;
        const first = parser.events.items[fragment.start];
        const bottom = parser.events.items[fragment.end.?].y;
        const width = fragment.right - fragment.left;
        const tab_width = textWidth(@tagName(fragment.kind), parser.base_size) + 24;
        try out.fmt("<g data-fragment=\"{s}\" data-fragment-id=\"{d}\" data-depth=\"{d}\"><rect data-frame=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"none\"/>", .{ @tagName(fragment.kind), i, fragment.depth, i, fragment.left, first.y, width, bottom - first.y });
        try out.fmt("<rect class=\"labelBox\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" stroke=\"none\"/>", .{ fragment.left + 1, first.y + 1, width - 2, parser.eventHeight(first) + 16, bg });
        try out.fmt("<path class=\"labelBox\" d=\"M {d} {d} h {d} v {d} l -8 8 H {d} Z\" fill=\"{s}\"/>", .{ fragment.left, first.y, tab_width, textHeight(@tagName(fragment.kind), parser.base_size), fragment.left, tab });
        try drawClassText(out, fragment.left + tab_width / 2, first.y + 4, @tagName(fragment.kind), parser.base_size, .center, "labelText");
        try drawClassText(out, fragment.left + tab_width + (width - tab_width) / 2, first.y + 8, first.label, parser.base_size, .center, "loopText");
        for (parser.events.items) |event| {
            if (event.kind != .fragment_branch or event.fragment.? != i) continue;
            try out.fmt("<g data-branch=\"{d}\"><rect class=\"labelBox\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" stroke=\"none\"/><path d=\"M {d} {d} H {d}\" fill=\"none\" stroke-dasharray=\"6 4\"/>", .{ i, fragment.left + 1, event.y, width - 2, parser.eventHeight(event) + 16, bg, fragment.left, event.y, fragment.right });
            try drawClassText(out, (fragment.left + fragment.right) / 2, event.y + 8, event.label, parser.base_size, .center, "loopText");
            try out.add("</g>");
        }
        try out.add("</g>");
    }
}

pub fn render(a: std.mem.Allocator, source: []const u8, theme: svg.Theme, prefix: u32) Error![]u8 {
    return renderNamed(a, source, theme, prefix, "sequence");
}
pub fn renderNamed(a: std.mem.Allocator, source: []const u8, theme: svg.Theme, prefix: u32, kind: []const u8) Error![]u8 {
    return renderConfigured(a, source, theme, prefix, kind, null);
}
pub fn renderConfigured(a: std.mem.Allocator, source: []const u8, theme: svg.Theme, prefix: u32, kind: []const u8, doc: ?*@import("document.zig").Document) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var parser: Parser = .{ .a = arena.allocator(), .rich_notes = std.mem.eql(u8, kind, "zenuml") };
    var margin_y: usize = 30;
    var margin_x: usize = 100;
    var message_margin: usize = 45;
    var configured_width = false;
    var actor_margin: usize = 48;
    var actor_font: []const u8 = "";
    var note_font: []const u8 = "";
    var message_font: []const u8 = "";
    var base_font: []const u8 = "";
    var font_weight: ?f64 = null;
    var actor_weight: ?f64 = null;
    var message_weight: ?f64 = null;
    var note_weight: ?f64 = null;
    var custom_css: []const u8 = "";
    var actor_align: Align = .center;
    var message_align: Align = .center;
    var note_align: Align = .center;
    var mirror_actors = std.mem.eql(u8, kind, "sequence");
    var right_angles = false;
    var activation_width: usize = 10;
    var actor_height: usize = 65;
    var bottom_margin: usize = 1;
    var hide_unused = false;
    if (doc) |config| {
        custom_css = config.get("config.themeCSS") orelse "";
        if (config.get("config.sequence.fontFamily")) |value| base_font = try @import("document.zig").fontFamily(value);
        if (config.get("config.sequence.fontWeight")) |value| font_weight = try fontWeight(value);
        if (config.get("config.sequence.actorFontWeight")) |value| actor_weight = try fontWeight(value);
        if (config.get("config.sequence.messageFontWeight")) |value| message_weight = try fontWeight(value);
        if (config.get("config.sequence.noteFontWeight")) |value| note_weight = try fontWeight(value);
        margin_x = @intFromFloat(try config.num("config.sequence.diagramMarginX", 100, 0, 2000));
        margin_y = @intFromFloat(try config.num("config.sequence.diagramMarginY", 30, 0, 2000));
        message_margin = @intFromFloat(try config.num("config.sequence.messageMargin", 45, 0, 2000));
        mirror_actors = try config.flag("config.sequence.mirrorActors", mirror_actors);
        hide_unused = try config.flag("config.sequence.hideUnusedParticipants", false);
        right_angles = try config.flag("config.sequence.rightAngles", false);
        activation_width = @intFromFloat(try config.num("config.sequence.activationWidth", 10, 0, 256));
        actor_height = @intFromFloat(try config.num("config.sequence.height", 65, 0, 2000));
        bottom_margin = @intFromFloat(try config.num("config.sequence.bottomMarginAdj", 1, 0, 2000));
        parser.wrap_labels = try config.flag("config.sequence.wrap", try config.flag("config.wrap", false));
        configured_width = config.get("config.sequence.width") != null;
        parser.wrap_width = @intFromFloat(try config.num("config.sequence.width", 240, 32, 2000));
        if (config.get("config.sequence.actorMargin") != null) configured_width = true;
        actor_margin = @intFromFloat(try config.num("config.sequence.actorMargin", 48, 0, 2000));
        parser.numbered = try config.flag("config.sequence.showSequenceNumbers", false);
        if (config.get("config.sequence.actorFontFamily")) |value| actor_font = try @import("document.zig").fontFamily(value);
        if (config.get("config.sequence.noteFontFamily")) |value| note_font = try @import("document.zig").fontFamily(value);
        if (config.get("config.sequence.messageFontFamily")) |value| message_font = try @import("document.zig").fontFamily(value);
        var theme_size: f64 = 14;
        if (config.get("config.themeVariables.fontSize")) |raw| {
            theme_size = try @import("document.zig").number(if (std.mem.endsWith(u8, raw, "px")) raw[0 .. raw.len - 2] else raw);
            if (theme_size < 1 or theme_size > 256) return error.InvalidSyntax;
        }
        parser.base_size = try config.num("config.sequence.fontSize", theme_size, 1, 256);
        parser.actor_size = try config.num("config.sequence.actorFontSize", parser.base_size, 1, 256);
        parser.note_size = try config.num("config.sequence.noteFontSize", parser.base_size, 1, 256);
        parser.message_size = try config.num("config.sequence.messageFontSize", parser.base_size, 1, 256);
        if (config.get("config.sequence.actorAlign")) |value| actor_align = std.meta.stringToEnum(Align, value) orelse return error.InvalidSyntax;
        if (config.get("config.sequence.messageAlign")) |value| message_align = std.meta.stringToEnum(Align, value) orelse return error.InvalidSyntax;
        if (config.get("config.sequence.noteAlign")) |value| note_align = std.meta.stringToEnum(Align, value) orelse return error.InvalidSyntax;
    }
    try parser.parse(source);
    if (hide_unused) parser.hideUnused();
    if (doc) |config| {
        if (parser.acc_title.len > 0) config.acc_title = try config.a.dupe(u8, parser.acc_title);
        if (parser.acc_description.len > 0) config.acc_description = try config.a.dupe(u8, parser.acc_description);
    }
    var gap: usize = if (configured_width) parser.wrap_width + actor_margin else 220;
    var margin: usize = margin_x;
    var label_height: usize = 20;
    for (parser.participants.items) |item| {
        const icon = try propertyText(item, "icon");
        if (icon.len > 0) {
            const config = doc orelse return error.MissingAsset;
            _ = try config.assets.get(icon);
        }
        gap = @max(gap, textWidth(item.label, parser.actor_size) + actor_margin + (if (icon.len > 0) @as(usize, 64) else 24));
        label_height = @max(label_height, textHeight(item.label, parser.actor_size));
    }
    var link_counts: [64]usize = @splat(0);
    var max_links: usize = 0;
    for (parser.links.items) |link| {
        link_counts[link.actor] += textHeight(link.label, parser.base_size) + 8;
        max_links = @max(max_links, link_counts[link.actor]);
        gap = @max(gap, textWidth(link.label, parser.base_size) + 72);
    }
    for (parser.events.items) |event| {
        gap = @max(gap, parser.eventWidth(event) + 100);
        if (event.kind == .note and event.placement != .over) margin = @max(margin, parser.eventWidth(event) + 60);
        if (event.kind == .message and event.from == event.to) margin = @max(margin, parser.eventWidth(event) / 2 + 100);
    }
    var activation_extent: usize = 0;
    for (parser.spans.items) |span| activation_extent = @max(activation_extent, span.depth * (activation_width / 2) + activation_width);
    gap = @max(gap, activation_extent * 2 + actor_margin + 80);
    margin = @max(margin, activation_extent + 80);
    var max_depth: usize = 0;
    for (parser.fragments.items) |fragment| max_depth = @max(max_depth, fragment.depth + 1);
    margin += max_depth * 32;
    gap = @max(gap, textWidth(parser.title, parser.base_size) / @max(parser.participants.items.len, 1) + 72);
    var box_height: usize = 0;
    for (parser.boxes.items, 0..) |box, b| {
        var members: usize = 0;
        for (parser.participants.items) |p| if (p.box == b) {
            members += 1;
        };
        gap = @max(gap, (textWidth(box.label, parser.base_size) + 48) / @max(members, 1));
        box_height = @max(box_height, textHeight(box.label, parser.base_size) + 24);
    }
    fragmentBounds(&parser, margin, gap, activation_width);
    var width = 2 * margin + @max(parser.participants.items.len, 1) * gap;
    for (parser.fragments.items) |fragment| width = @max(width, fragment.right + 40);
    const box_top = if (parser.title.len > 0) textHeight(parser.title, parser.base_size) + 24 + margin_y else margin_y;
    const header_top = box_top + box_height;
    const participant_height = @max(actor_height, label_height + 40);
    const header_height = @max(participant_height + 40, 100 + label_height);
    const header_bottom = header_top + header_height + max_links;
    var cursor = header_bottom + 35;
    var attachment = cursor;
    for (parser.events.items, 0..) |*event, event_index| {
        switch (event.kind) {
            .message => {
                event.y = cursor + parser.eventHeight(event.*) + 12;
                if (parser.participants.items[event.to].created == event_index) event.y += participant_height / 2 + 10;
                attachment = event.y + @as(usize, if (event.from == event.to) 30 else 0);
                cursor = attachment + message_margin;
                if (parser.participants.items[event.to].created == event_index) cursor += header_height + max_links;
            },
            .note => {
                event.y = cursor;
                cursor += parser.eventHeight(event.*) + 56;
                attachment = cursor;
            },
            .activate, .deactivate => event.y = attachment,
            .fragment_start, .fragment_branch => {
                event.y = cursor;
                cursor += parser.eventHeight(event.*) + 44;
                attachment = cursor;
            },
            .fragment_end => {
                event.y = cursor;
                cursor += 32;
                attachment = cursor;
            },
        }
    }
    const footer_top = cursor + 10;
    const lifeline_end = if (mirror_actors) footer_top else cursor + margin_y -| 15;
    const height = footer_top + margin_y + bottom_margin + (if (mirror_actors) header_height else @as(usize, 0));
    var out: svg.Svg = .{ .allocator = a, .theme = theme };
    defer out.deinit();
    try out.start(width, height, kind, prefix);
    if (base_font.len > 0 or font_weight != null) {
        try out.fmt("<style>#zm-{d}-css text{{", .{prefix});
        if (base_font.len > 0) {
            try out.add("font-family:");
            try out.escape(base_font);
            try out.add(";");
        }
        if (font_weight) |weight| try out.fmt("font-weight:{d};", .{weight});
        try out.add("}</style>");
    }
    if (doc) |config| try sequenceTheme(&out, config);
    if (custom_css.len > 0) try @import("scoped_css.zig").emit(&out, custom_css);
    const fonts = .{ .{ "[data-participant] text", actor_font }, .{ "[data-note] text", note_font }, .{ "[data-message-label] text", message_font } };
    inline for (fonts) |font| if (font[1].len > 0) {
        try out.fmt("<style>#zm-{d}-css {s}{{font-family:", .{ prefix, font[0] });
        try out.escape(font[1]);
        try out.add(";}</style>");
    };
    const weights = .{ .{ "[data-participant] text", actor_weight }, .{ "[data-note] text", note_weight }, .{ "[data-message-label] text", message_weight } };
    inline for (weights) |weight| if (weight[1]) |value| try out.fmt("<style>#zm-{d}-css {s}{{font-weight:{d};}}</style>", .{ prefix, weight[0], value });
    if (doc == null) {
        if (parser.acc_title.len > 0) {
            try out.add("<title>");
            try out.escape(parser.acc_title);
            try out.add("</title>");
        }
        if (parser.acc_description.len > 0) {
            try out.add("<desc>");
            try out.escape(parser.acc_description);
            try out.add("</desc>");
        }
    }
    try out.sequenceMarkers(prefix);
    for (parser.boxes.items, 0..) |box, b| {
        var first: usize = parser.participants.items.len;
        var last: usize = 0;
        for (parser.participants.items, 0..) |p, i| if (p.box == b) {
            first = @min(first, i);
            last = @max(last, i);
        };
        if (first == parser.participants.items.len) continue;
        const x = margin + first * gap + 8;
        const w = (last - first + 1) * gap - 16;
        try out.fmt("<g data-participant-box=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" fill-opacity=\"0.16\"/>", .{ b, x, box_top, w, height - 15 - box_top, box.color });
        try drawText(&out, x + w / 2, box_top + 12, box.label, parser.base_size, .center);
        try out.add("</g>");
    }
    for (parser.fragments.items, 0..) |fragment, i| if (fragment.kind == .rect) {
        const top = parser.events.items[fragment.start].y;
        const bottom = parser.events.items[fragment.end.?].y;
        try out.fmt("<rect data-highlight=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\"/>", .{ i, fragment.left, top, fragment.right - fragment.left, bottom - top, fragment.color, if (theme == .dark) "0.22" else "0.55" });
    };
    if (parser.title.len > 0) try drawText(&out, width / 2, 12, parser.title, parser.base_size, .center);
    for (parser.participants.items, 0..) |item, index| {
        const x = margin + gap / 2 + index * gap;
        const top_y = if (item.created) |i| parser.events.items[i].y - (if (item.shape == .participant) participant_height / 2 else 28) else header_top;
        const start_y = if (item.created != null) top_y + header_height + max_links else header_bottom;
        const end_y = if (item.destroyed) |i| parser.events.items[i].y + @as(usize, if (parser.events.items[i].from == parser.events.items[i].to) 30 else 0) else lifeline_end;
        try out.fmt("<g data-participant=\"{d}\"", .{index});
        try @import("interaction.zig").classAttribute(&out, try propertyText(item, "class"));
        if (item.properties.map.count() > 0) {
            const json = try std.json.Stringify.valueAlloc(a, item.properties, .{});
            defer a.free(json);
            try out.add(" data-zm-properties=\"");
            try out.escape(json);
            try out.add("\"");
        }
        try out.fmt("><path data-lifeline=\"{d}\" d=\"M {d} {d} V {d}\" fill=\"none\" stroke-dasharray=\"5 5\"/>", .{ index, x, start_y, end_y });
        if (item.destroyed != null) try out.fmt("<path data-destroyed=\"{d}\" d=\"M {d} {d} l 16 16 m 0 -16 l -16 16\" fill=\"none\" stroke-width=\"3\"/>", .{ index, x - 8, end_y - 8 });
        if (item.created) |i| try out.fmt("<g data-created=\"{d}\" data-event=\"{d}\">", .{ index, i });
        try out.fmt("<g id=\"zm-{d}-actor-{d}\" class=\"zm-sequence-actor\">", .{ prefix, index });
        if (item.shape == .actor) {
            const cy = top_y + 14;
            try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"12\"/><path d=\"M {d} {d} v 25 M {d} {d} h 44 M {d} {d} l -20 17 M {d} {d} l 20 17\" fill=\"none\"/>", .{ x, cy, x, cy + 12, x - 22, cy + 23, x, cy + 37, x, cy + 37 });
            try drawText(&out, x, cy + 65, item.label, parser.actor_size, actor_align);
        } else if (item.shape == .participant) {
            try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"6\"/>", .{ x - gap / 2 + actor_margin / 2, top_y, gap - actor_margin, participant_height });
            try drawText(&out, x, top_y + (participant_height - label_height) / 2, item.label, parser.actor_size, actor_align);
        } else {
            try out.fmt("<g data-participant-type=\"{s}\">", .{@tagName(item.shape)});
            const top = top_y + 4;
            switch (item.shape) {
                .boundary => try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"22\"/><path d=\"M {d} {d} h -26 m 0 -16 v 32\" fill=\"none\"/>", .{ x, top + 24, x - 22, top + 24 }),
                .control => try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"22\"/><path d=\"M {d} {d} l -11 -6 l 2 12 Z\"/>", .{ x, top + 28, x - 8, top + 6 }),
                .entity => try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"22\"/><path d=\"M {d} {d} h 56\"/>", .{ x, top + 24, x - 28, top + 52 }),
                .database => try @import("flow_shapes.zig").draw(&out, .cylinder, x - 40, top, 80, 58),
                .collections => {
                    for (0..3) |layer| try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"64\" height=\"42\" rx=\"3\"/>", .{ x - 24 - layer * 5, top + layer * 6 });
                },
                .queue => try out.fmt("<path d=\"M {d} {d} H {d} A 10 24 0 0 1 {d} {d} H {d} Z\"/><ellipse cx=\"{d}\" cy=\"{d}\" rx=\"10\" ry=\"24\"/>", .{ x - 34, top + 4, x + 34, x + 34, top + 52, x - 34, x - 34, top + 28 }),
                else => unreachable,
            }
            try drawText(&out, x, top + 72, item.label, parser.actor_size, actor_align);
            try out.add("</g>");
        }
        const icon = try propertyText(item, "icon");
        if (icon.len > 0) try @import("assets.zig").draw(&out, try doc.?.assets.get(icon), x + gap / 2 - actor_margin / 2 - 24, top_y + 8, 16, 16);
        try out.add("</g>");
        var link_y = top_y + header_height;
        for (parser.links.items) |link| if (link.actor == index) {
            try out.add("<a href=\"");
            try out.escape(link.url);
            try out.add("\" text-decoration=\"underline\">");
            try drawText(&out, x, link_y, link.label, parser.base_size, .center);
            try out.add("</a>");
            link_y += textHeight(link.label, parser.base_size) + 8;
        };
        if (item.created != null) try out.add("</g>");
        if (mirror_actors and item.destroyed == null) try out.fmt("<use data-mirrored-participant=\"{d}\" href=\"#zm-{d}-actor-{d}\" transform=\"translate(0 {d})\"/>", .{ index, prefix, index, footer_top - top_y });
        try out.add("</g>");
    }
    for (parser.spans.items) |span| {
        const x = margin + gap / 2 + span.actor * gap + span.depth * (activation_width / 2);
        var y = parser.events.items[span.start].y;
        const participant_item = parser.participants.items[span.actor];
        if (participant_item.created) |i| y = @max(y, parser.events.items[i].y - (if (participant_item.shape == .participant) participant_height / 2 else 28) + header_height + max_links);
        var end = if (span.end) |event| parser.events.items[event].y else lifeline_end;
        if (parser.participants.items[span.actor].destroyed) |i| end = @min(end, parser.events.items[i].y + @as(usize, if (parser.events.items[i].from == parser.events.items[i].to) 30 else 0));
        if (end < y) return error.InvalidSyntax;
        try out.fmt("<rect data-activation=\"{d}\" data-depth=\"{d}\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\"/>", .{ span.actor, span.depth, x - activation_width / 2, y, activation_width, end - y });
    }
    try drawFragments(&out, &parser);
    for (parser.events.items, 0..) |event, index| {
        const x1 = margin + gap / 2 + event.from * gap;
        const x2 = margin + gap / 2 + event.to * gap;
        if (event.kind == .note) {
            const note_width = @max(parser.eventWidth(event) + 32, if (event.placement == .over) @max(x1, x2) - @min(x1, x2) + 80 else @as(usize, 80));
            const x = switch (event.placement) {
                .left => x1 - note_width - 24,
                .right => x1 + 24,
                .over => (x1 + x2) / 2 - note_width / 2,
            };
            const fill = if (theme == .dark) "#393523" else "#fff5bf";
            try out.fmt("<g data-note=\"{d}\"><rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\"/>", .{ index, x, event.y, note_width, parser.eventHeight(event) + 24, fill });
            if (event.markdown) {
                try out.fmt("<g transform=\"translate({d} {d}) scale({d})\">", .{ x + note_width / 2, event.y + 12, parser.note_size / 14 });
                try @import("flow_paint.zig").textMode(&out, 0, 0, event.label, .{}, true);
                try out.add("</g>");
            } else try drawText(&out, x + note_width / 2, event.y + 12, event.label, parser.note_size, note_align);
            try out.add("</g>");
        } else if (event.kind == .message) {
            const right = x2 >= x1;
            const from_offset = if (event.from_depth > 0) (event.from_depth - 1) * (activation_width / 2) else 0;
            const to_offset = if (event.to_depth > 0) (event.to_depth - 1) * (activation_width / 2) else 0;
            const half_activation = activation_width / 2;
            const right_activation = activation_width - half_activation;
            var from_x = x1 + from_offset + @as(usize, if (event.from_depth > 0 and right) right_activation else 0) - @as(usize, if (event.from_depth > 0 and !right) half_activation else 0);
            var to_x = x2 + to_offset + @as(usize, if (event.to_depth > 0 and (!right or event.from == event.to)) right_activation else 0) - @as(usize, if (event.to_depth > 0 and right and event.from != event.to) half_activation else 0);
            if (parser.participants.items[event.to].created == index) {
                const half = if (parser.participants.items[event.to].shape == .participant) (gap - actor_margin) / 2 else 28;
                to_x = if (right) x2 - half else x2 + half;
            }
            if (event.central_from) {
                try out.fmt("<circle data-central=\"from\" cx=\"{d}\" cy=\"{d}\" r=\"5\"/>", .{ from_x, event.y });
                from_x = if (right) from_x + 5 else from_x - 5;
            }
            if (event.central_to) {
                try out.fmt("<circle data-central=\"to\" cx=\"{d}\" cy=\"{d}\" r=\"5\"/>", .{ to_x, event.y + @as(usize, if (event.from == event.to) 30 else 0) });
                to_x = if (right and event.from != event.to) to_x - 5 else to_x + 5;
            }
            try out.fmt("<path data-message=\"{d}\" fill=\"none\" ", .{index});
            if (event.head != .none) {
                var head = event.head;
                // Keep top/bottom in screen coordinates when the path reverses.
                if (right == event.reverse) head = switch (head) {
                    .top => .bottom,
                    .bottom => .top,
                    .stick_top => .stick_bottom,
                    .stick_bottom => .stick_top,
                    else => head,
                };
                try out.fmt("marker-{s}=\"url(#zm-{d}-seq-{s})\" ", .{ if (event.reverse) "start" else "end", prefix, @tagName(head) });
            }
            if (event.both) try out.fmt("marker-start=\"url(#zm-{d}-seq-arrow)\" ", .{prefix});
            if (event.dashed) try out.add("stroke-dasharray=\"5 4\" ");
            if (event.from == event.to) {
                const reach = @max(from_x, to_x) + 60;
                if (right_angles) {
                    try out.fmt("d=\"M {d} {d} H {d} v 30 H {d}\"/>", .{ from_x, event.y, reach, to_x });
                } else {
                    const links = @import("flow_links.zig");
                    try links.terminalCubic(&out, links.point(from_x, event.y), links.point(reach, event.y), links.point(reach, event.y + 30), links.point(to_x, event.y + 30));
                    try out.add("/>");
                }
            } else try out.fmt("d=\"M {d} {d} H {d}\"/>", .{ from_x, event.y, to_x });
            const label_top = event.y - parser.eventHeight(event) - 12 - (if (parser.participants.items[event.to].created == index) participant_height / 2 else @as(usize, 0));
            try out.fmt("<g data-message-label=\"{d}\">", .{index});
            try drawText(&out, if (event.from == event.to) x1 + 60 else (x1 + x2) / 2, label_top, event.label, parser.message_size, message_align);
            try out.add("</g>");
            if (event.number) |number| try numberLabel(&out, if (right) from_x + 20 else from_x - 20, event.y + 15, number);
        }
    }
    return out.finish();
}

test "sequence activation stacks and notes preserve event semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser: Parser = .{ .a = arena.allocator() };
    try parser.parse("sequenceDiagram\nA->>+B: one\nA->>+B: two\nNote over B,A: shared\nB-->>-A: three\nB-->>-A: four");
    try std.testing.expectEqual(@as(usize, 2), parser.spans.items.len);
    try std.testing.expectEqual(@as(usize, 1), parser.spans.items[1].depth);
    try std.testing.expect(parser.spans.items[1].end.? < parser.spans.items[0].end.?);
    try std.testing.expectEqual(@as(usize, 0), parser.depths[1]);
    try std.testing.expectEqual(@as(usize, 4), parser.messages);
    try std.testing.expectEqual(@as(usize, 1), parser.notes);
    var bad: Parser = .{ .a = arena.allocator() };
    try std.testing.expectError(error.InvalidSyntax, bad.parse("sequenceDiagram\ndeactivate A"));
}
test "decimal numbering and off state match message order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser: Parser = .{ .a = arena.allocator() };
    try parser.parse("sequenceDiagram; autonumber 1.25 .5; A->B: one; autonumber off; A->B: two; autonumber; A->B: three");
    try std.testing.expectEqual(@as(?u32, 125), parser.events.items[0].number);
    try std.testing.expectEqual(@as(?u32, null), parser.events.items[1].number);
    try std.testing.expectEqual(@as(?u32, 225), parser.events.items[2].number);
}

test "fragments preserve nesting ownership branches and message numbering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser: Parser = .{ .a = arena.allocator() };
    try parser.parse("sequenceDiagram; autonumber; loop Retry; alt Ready; A->B: one; else Wait; par Poll; A->B: two; and Log; B->A: three; end; end; end; opt Cleanup; A->A: four; end");
    try std.testing.expectEqual(@as(usize, 4), parser.fragments.items.len);
    try std.testing.expectEqual(@as(?usize, null), parser.fragments.items[0].parent);
    try std.testing.expectEqual(@as(?usize, 0), parser.fragments.items[1].parent);
    try std.testing.expectEqual(@as(?usize, 1), parser.fragments.items[2].parent);
    try std.testing.expectEqual(@as(?usize, null), parser.fragments.items[3].parent);
    var number: u32 = 100;
    for (parser.events.items) |event| {
        if (event.kind == .message) {
            try std.testing.expectEqual(@as(?u32, number), event.number);
            number += 100;
        }
        if (event.kind == .fragment_branch) try std.testing.expect(event.fragment != null);
    }
    for (parser.fragments.items) |fragment| try std.testing.expect(fragment.end.? > fragment.start);
    fragmentBounds(&parser, 300, 260, 10);
    for (parser.fragments.items) |fragment| {
        if (fragment.parent) |p| {
            try std.testing.expect(parser.fragments.items[p].left < fragment.left);
            try std.testing.expect(parser.fragments.items[p].right > fragment.right);
        }
    }
}

test "misplaced branches and unbalanced fragments are invalid" {
    for ([_][]const u8{
        "sequenceDiagram; A->B: hi; end",
        "sequenceDiagram; loop retry; A->B: hi",
        "sequenceDiagram; else unexpected; A->B: hi",
        "sequenceDiagram; loop retry; and invalid; A->B: hi; end",
        "sequenceDiagram; alt condition; option invalid; A->B: hi; end",
        "sequenceDiagram; par task; else invalid; A->B: hi; end",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser: Parser = .{ .a = arena.allocator() };
        try std.testing.expectError(error.InvalidSyntax, parser.parse(source));
    }
}
