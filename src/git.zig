const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const data = @import("chart_data.zig");
const Branch = struct { name: []const u8, head: ?usize = null, order: f64, rank: usize = 0 };
const Commit = struct { id: []const u8, message: []const u8 = "", branch: usize, parents: [2]?usize = .{ null, null }, tags: std.ArrayList([]const u8) = .empty, kind: []const u8 = "NORMAL", merge: bool = false, level: usize = 0, x: usize = 0, y: usize = 0 };
const Cursor = struct {
    rest: []const u8,
    fn trim(self: *Cursor) void {
        self.rest = d.trim(self.rest);
    }
    fn value(self: *Cursor) d.Error![]const u8 {
        self.trim();
        if (self.rest.len == 0) return error.InvalidSyntax;
        if (self.rest[0] == '"') {
            const end = std.mem.indexOfScalarPos(u8, self.rest, 1, '"') orelse return error.InvalidSyntax;
            const result = self.rest[1..end];
            self.rest = self.rest[end + 1 ..];
            return result;
        }
        const end = std.mem.indexOfAny(u8, self.rest, " \t:") orelse self.rest.len;
        if (end == 0) return error.InvalidSyntax;
        const result = self.rest[0..end];
        self.rest = self.rest[end..];
        return result;
    }
};
fn statement(source: []const u8, at: *usize) d.Error!?[]const u8 {
    if (at.* == source.len) return null;
    const start = at.*;
    var quoted = false;
    var escaped = false;
    while (at.* < source.len) : (at.* += 1) {
        const c = source[at.*];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quoted and c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') quoted = !quoted;
        if (!quoted and (c == '\n' or c == ';')) {
            const result = source[start..at.*];
            at.* += 1;
            return result;
        }
        if (!quoted and std.mem.startsWith(u8, source[at.*..], "%%")) {
            const result = source[start..at.*];
            at.* = @min((std.mem.indexOfScalarPos(u8, source, at.*, '\n') orelse source.len) + 1, source.len);
            return result;
        }
    }
    if (quoted) return error.InvalidSyntax;
    return source[start..];
}
fn branchId(branches: []Branch, name: []const u8) d.Error!usize {
    for (branches, 0..) |b, i| if (std.mem.eql(u8, b.name, name)) return i;
    return error.InvalidSyntax;
}
fn commitId(commits: []Commit, name: []const u8) d.Error!usize {
    var i = commits.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, commits[i].id, name)) return i;
    }
    return error.InvalidSyntax;
}
fn color(doc: *d.Document, key: []const u8, default: []const u8) d.Error![]const u8 {
    return if (doc.get(key)) |c| try d.color(c) else default;
}
fn font(doc: *d.Document, key: []const u8) d.Error!f64 {
    const raw = doc.get(key) orelse return 14;
    const n = try d.number(if (std.mem.endsWith(u8, raw, "px")) raw[0 .. raw.len - 2] else raw);
    if (n < 6 or n > 72) return error.InvalidSyntax;
    return n;
}
fn label(out: *svg.Svg, x: usize, y: usize, value: []const u8, fg: []const u8, bg: []const u8, border: []const u8, size: f64, rotate: bool) !void {
    const w = data.coord(@as(f64, @floatFromInt(txt.width(value))) * size / 14) + 12;
    const h = (1 + std.mem.count(u8, value, "\n")) * (data.coord(size) + 4) + 8;
    try out.fmt("<g transform=\"translate({d} {d}){s}\"><rect x=\"0\" y=\"0\" width=\"{d}\" height=\"{d}\" rx=\"3\" fill=\"{s}\" stroke=\"{s}\"/>", .{ x, y, if (rotate) " rotate(45)" else "", w, h, bg, border });
    var lines = std.mem.splitScalar(u8, value, '\n');
    var text_y = size / 2 + 6;
    while (lines.next()) |line| {
        try out.fmt("<text x=\"6\" y=\"{d:.2}\" dominant-baseline=\"middle\" font-family=\"Consolas,monospace\" font-size=\"{d}\" fill=\"{s}\" stroke=\"none\">", .{ text_y, size, fg });
        try out.escape(d.trim(line));
        try out.add("</text>");
        text_y += size + 4;
    }
    try out.add("</g>");
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var branches: std.ArrayList(Branch) = .empty;
    var commits: std.ArrayList(Commit) = .empty;
    const main_name = doc.get("config.gitGraph.mainBranchName") orelse "main";
    if (main_name.len == 0 or main_name.len > 512) return error.InvalidSyntax;
    const main_order = try doc.num("config.gitGraph.mainBranchOrder", 0, -10000, 10000);
    try branches.append(temp, .{ .name = main_name, .order = main_order });
    var current: usize = 0;
    const parallel = try doc.flag("config.gitGraph.parallelCommits", false);
    const show_branches = try doc.flag("config.gitGraph.showBranches", true);
    const show_labels = try doc.flag("config.gitGraph.showCommitLabel", true);
    const rotate = try doc.flag("config.gitGraph.rotateCommitLabel", true);
    var source_at: usize = 0;
    const header = std.mem.trim(u8, (try statement(doc.source, &source_at)) orelse return error.InvalidSyntax, " \t\r:");
    var words = std.mem.tokenizeAny(u8, header, " \t");
    _ = words.next();
    const direction = words.next() orelse "LR";
    if (words.next() != null or (!std.mem.eql(u8, direction, "LR") and !std.mem.eql(u8, direction, "TB") and !std.mem.eql(u8, direction, "BT"))) return error.InvalidSyntax;
    while (try statement(doc.source, &source_at)) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (txt.starts(line, "title ")) {
            doc.title = try txt.parse(doc.a, d.unquote(line[6..]));
            continue;
        }
        if (txt.starts(line, "accTitle:")) {
            doc.acc_title = d.trim(line[9..]);
            continue;
        }
        if (txt.starts(line, "accDescr:")) {
            doc.acc_description = d.trim(line[9..]);
            continue;
        }
        var cur: Cursor = .{ .rest = line };
        const cmd = try cur.value();
        cur.trim();
        if (std.mem.eql(u8, cmd, "branch")) {
            const name = try cur.value();
            if (name.len == 0 or name.len > 512) return error.InvalidSyntax;
            for (branches.items) |b| if (std.mem.eql(u8, b.name, name)) return error.InvalidSyntax;
            if (branches.items.len == 64) return error.LimitExceeded;
            // Unspecified orders sort between 0 and 1 in insertion order.
            var order = @as(f64, @floatFromInt(branches.items.len)) / 1000;
            cur.trim();
            if (cur.rest.len > 0) {
                if (!txt.starts(cur.rest, "order:")) return error.UnsupportedSyntax;
                order = try d.number(cur.rest[6..]);
                if (@floor(order) != order) return error.InvalidSyntax;
            }
            try branches.append(temp, .{ .name = name, .head = branches.items[current].head, .order = order });
            current = branches.items.len - 1;
            continue;
        }
        if (std.mem.eql(u8, cmd, "checkout") or std.mem.eql(u8, cmd, "switch")) {
            current = try branchId(branches.items, try cur.value());
            cur.trim();
            if (cur.rest.len > 0) return error.InvalidSyntax;
            continue;
        }
        const merge = std.mem.eql(u8, cmd, "merge");
        const cherry = std.mem.eql(u8, cmd, "cherry-pick");
        if (!merge and !cherry and !std.mem.eql(u8, cmd, "commit")) return error.UnsupportedSyntax;
        if (commits.items.len == 512) return error.LimitExceeded;
        var commit: Commit = .{ .id = try std.fmt.allocPrint(temp, "commit-{d}", .{commits.items.len + 1}), .branch = current, .parents = .{ branches.items[current].head, null } };
        if (merge) {
            const other = try branchId(branches.items, try cur.value());
            if (other == current or branches.items[current].head == null or branches.items[other].head == null or branches.items[current].head == branches.items[other].head) return error.InvalidSyntax;
            commit.parents[1] = branches.items[other].head;
            commit.kind = "MERGE";
            commit.merge = true;
        }
        var cherry_source: []const u8 = "";
        var cherry_parent: []const u8 = "";
        while (true) {
            cur.trim();
            if (cur.rest.len == 0 or txt.starts(cur.rest, "%%")) break;
            if (cur.rest[0] == '"') {
                if (merge or cherry) return error.InvalidSyntax;
                commit.message = try cur.value();
                continue;
            }
            const key = try cur.value();
            cur.trim();
            if (!txt.starts(cur.rest, ":")) return error.InvalidSyntax;
            cur.rest = cur.rest[1..];
            const value = try cur.value();
            if (value.len > 512) return error.LimitExceeded;
            if (std.mem.eql(u8, key, "id")) {
                if (cherry) cherry_source = value else commit.id = value;
            } else if (std.mem.eql(u8, key, "msg") and !merge and !cherry) commit.message = value else if (std.mem.eql(u8, key, "parent") and cherry) cherry_parent = value else if (std.mem.eql(u8, key, "tag")) {
                if (commit.tags.items.len == 32) return error.LimitExceeded;
                try commit.tags.append(temp, value);
            } else if (std.mem.eql(u8, key, "type") and !cherry) {
                if (!std.mem.eql(u8, value, "NORMAL") and !std.mem.eql(u8, value, "REVERSE") and !std.mem.eql(u8, value, "HIGHLIGHT")) return error.InvalidSyntax;
                commit.kind = value;
            } else return error.UnsupportedSyntax;
        }
        if (commit.id.len == 0 or commit.id.len > 512 or commit.message.len > 512) return error.InvalidSyntax;
        if (cherry) {
            const source = try commitId(commits.items, cherry_source);
            if (commits.items[source].branch == current or commit.parents[0] == null) return error.InvalidSyntax;
            if (commits.items[source].merge and cherry_parent.len == 0) return error.InvalidSyntax;
            if (cherry_parent.len > 0) {
                const p = try commitId(commits.items, cherry_parent);
                if (commits.items[source].parents[0] != p and commits.items[source].parents[1] != p) return error.InvalidSyntax;
            }
            commit.parents[1] = source;
            commit.kind = "CHERRY_PICK";
            if (commit.tags.items.len == 0) try commit.tags.append(temp, try std.fmt.allocPrint(temp, "cherry-pick:{s}", .{cherry_source}));
        }
        commit.level = if (parallel) 0 else commits.items.len;
        if (parallel) for (commit.parents) |parent| if (parent) |p| {
            commit.level = @max(commit.level, commits.items[p].level + 1);
        };
        try commits.append(temp, commit);
        branches.items[current].head = commits.items.len - 1;
    }
    if (commits.items.len == 0) return error.InvalidSyntax;
    for (branches.items, 0..) |*b, i| {
        var rank: usize = 0;
        for (branches.items, 0..) |other, j| if (other.order < b.order or (other.order == b.order and j < i)) {
            rank += 1;
        };
        b.rank = rank;
    }
    const fg = if (doc.theme == .dark) "#e0e0e0" else "#24292f";
    const bg = if (doc.theme == .dark) "#0d1117" else "#ffffff";
    var colors: [64][]const u8 = undefined;
    var inverted: [64][]const u8 = undefined;
    var branch_fg: [64][]const u8 = undefined;
    for (0..64) |i| {
        colors[i] = try color(doc, try std.fmt.allocPrint(temp, "config.themeVariables.git{d}", .{i}), try doc.palette(i));
        inverted[i] = try color(doc, try std.fmt.allocPrint(temp, "config.themeVariables.gitInv{d}", .{i}), bg);
        branch_fg[i] = try color(doc, try std.fmt.allocPrint(temp, "config.themeVariables.gitBranchLabel{d}", .{i}), fg);
    }
    const commit_fg = try color(doc, "config.themeVariables.commitLabelColor", fg);
    const commit_bg = try color(doc, "config.themeVariables.commitLabelBackground", bg);
    const tag_fg = try color(doc, "config.themeVariables.tagLabelColor", fg);
    const tag_bg = try color(doc, "config.themeVariables.tagLabelBackground", if (doc.theme == .dark) "#35435c" else "#fff1b8");
    const tag_border = try color(doc, "config.themeVariables.tagLabelBorder", fg);
    const commit_font = try font(doc, "config.themeVariables.commitLabelFontSize");
    const tag_font = try font(doc, "config.themeVariables.tagLabelFontSize");
    var label_width: usize = 0;
    var branch_width: usize = 0;
    var branch_height: usize = 0;
    var tag_height: usize = 0;
    var max_level: usize = 0;
    for (branches.items) |b| {
        branch_width = @max(branch_width, txt.width(b.name) + 24);
        branch_height = @max(branch_height, txt.height(b.name) + 12);
    }
    for (commits.items) |c| {
        max_level = @max(max_level, c.level);
        if (show_labels) label_width = @max(label_width, data.coord(@as(f64, @floatFromInt(txt.width(c.id))) * commit_font / 14) + 20);
        tag_height = @max(tag_height, c.tags.items.len * (data.coord(tag_font) + 20));
        for (c.tags.items) |tag| label_width = @max(label_width, data.coord(@as(f64, @floatFromInt(txt.width(tag))) * tag_font / 14) + 20);
    }
    const vertical = !std.mem.eql(u8, direction, "LR");
    const reverse = std.mem.eql(u8, direction, "BT");
    const step = if (vertical) @max(100, tag_height + 50) else @max(100, if (rotate) label_width * 3 / 4 + 30 else label_width + 24);
    const lane_step = @max(branch_height + 60, if (vertical) @max(160, label_width + 80) else @max(150, (if (rotate) label_width else 30) + tag_height + 60));
    const left = if (vertical) @as(usize, 80) else branch_width + 40;
    const top = tag_height + if (vertical) branch_width + 40 else @as(usize, 60);
    const width = left + if (vertical) branches.items.len * lane_step + label_width + 80 else (max_level + 2) * step + label_width + 80;
    const height = top + if (vertical) (max_level + 2) * step + label_width + 80 else branches.items.len * lane_step + label_width + 80;
    for (commits.items) |*c| {
        const level = if (reverse) max_level - c.level else c.level;
        c.x = left + if (vertical) branches.items[c.branch].rank * lane_step else level * step;
        c.y = top + if (vertical) level * step else branches.items[c.branch].rank * lane_step;
    }
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "git", prefix);
    if (show_branches) for (branches.items) |b| {
        const index = b.rank;
        const x = left + if (vertical) index * lane_step else @as(usize, 0);
        const y = top + if (vertical) @as(usize, 0) else index * lane_step;
        try out.fmt("<path data-branch=\"{d}\" d=\"M {d} {d} {s} {d}\" fill=\"none\" stroke=\"{s}\" stroke-dasharray=\"4 4\" opacity=\"0.45\"/>", .{ index, x, y, if (vertical) "V" else "H", if (vertical) height - 50 else width - 50, colors[index] });
        try label(&out, if (vertical) x - 20 else 12, if (vertical) @as(usize, 12) else y - 14, b.name, branch_fg[index], colors[index], colors[index], 14, vertical);
    };
    for (commits.items, 0..) |c, i| for (c.parents, 0..) |parent, pi| if (parent) |p| {
        const previous = commits.items[p];
        const mid = if (vertical) (previous.y + c.y) / 2 else (previous.x + c.x) / 2;
        try out.fmt("<path data-parent=\"{d}\" data-commit=\"{d}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"3\"{s} d=\"M {d} {d} C {d} {d} {d} {d} {d} {d}\"/>", .{ p, i, colors[branches.items[c.branch].rank], if (pi == 1 and std.mem.eql(u8, c.kind, "CHERRY_PICK")) " stroke-dasharray=\"4 4\"" else "", previous.x, previous.y, if (vertical) previous.x else mid, if (vertical) mid else previous.y, if (vertical) c.x else mid, if (vertical) mid else c.y, c.x, c.y });
    };
    for (commits.items, 0..) |c, i| {
        const branch_index = branches.items[c.branch].rank;
        const fill = colors[branch_index];
        try out.fmt("<g data-commit-node=\"{d}\" data-branch-index=\"{d}\" data-level=\"{d}\" data-x=\"{d}\" data-y=\"{d}\"><title>", .{ i, c.branch, c.level, c.x, c.y });
        try out.escape(c.message);
        try out.add("</title>");
        if (std.mem.eql(u8, c.kind, "HIGHLIGHT")) try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"22\" height=\"22\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"4\"/>", .{ c.x - 11, c.y - 11, inverted[branch_index], fill }) else {
            try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"9\" fill=\"{s}\" stroke=\"{s}\" stroke-width=\"3\"/>", .{ c.x, c.y, if (std.mem.eql(u8, c.kind, "REVERSE")) bg else fill, fill });
            if (std.mem.eql(u8, c.kind, "REVERSE")) try out.fmt("<path d=\"M {d} {d} l 12 12 M {d} {d} l -12 12\" stroke=\"{s}\"/>", .{ c.x - 6, c.y - 6, c.x + 6, c.y - 6, fill });
            if (c.parents[1] != null) try out.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"4\" fill=\"{s}\" stroke=\"none\"/>", .{ c.x, c.y, bg });
        }
        if (show_labels) try label(&out, c.x + 14, c.y + 16, c.id, commit_fg, commit_bg, commit_bg, commit_font, rotate and !vertical);
        for (c.tags.items, 0..) |tag, ti| try label(&out, c.x + 14, c.y - 30 - ti * (data.coord(tag_font) + 20), tag, tag_fg, tag_bg, tag_border, tag_font, false);
        try out.add("</g>");
    }
    return out.finish();
}
