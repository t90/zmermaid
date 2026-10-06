const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
const icons = @import("icons.zig");
const data = @import("chart_data.zig");
const Node = struct { name: []const u8, description: []const u8 = "", parent: ?usize = null, depth: usize = 0, folder: bool = false, highlight: bool = false, icon: ?[]const u8 = null, x: usize = 0, y: usize = 0 };
fn color(doc: *d.Document, key: []const u8, default: []const u8) d.Error![]const u8 {
    return if (doc.get(key)) |v| try d.color(v) else default;
}
fn text(out: *svg.Svg, x: usize, y: usize, label: []const u8, fg: []const u8, size: f64) !void {
    try out.fmt("<text x=\"{d}\" y=\"{d}\" text-anchor=\"start\" dominant-baseline=\"middle\" font-family=\"Consolas,monospace\" font-size=\"{d}\" fill=\"{s}\" stroke=\"none\">", .{ x, y, size, fg });
    try out.escape(label);
    try out.add("</text>");
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var nodes: std.ArrayList(Node) = .empty;
    var levels: [33]usize = undefined;
    var parents: [33]usize = undefined;
    var depth: usize = 0;
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const trimmed = d.trim(raw);
        if (trimmed.len == 0 or txt.starts(trimmed, "%%")) continue;
        if (txt.starts(trimmed, "title ")) {
            doc.title = d.unquote(trimmed[6..]);
            continue;
        }
        if (txt.starts(trimmed, "accTitle:")) {
            doc.acc_title = d.trim(trimmed[9..]);
            continue;
        }
        if (txt.starts(trimmed, "accDescr:")) {
            doc.acc_description = d.trim(trimmed[9..]);
            continue;
        }
        var at: usize = 0;
        var column: usize = 0;
        var branch: ?usize = null;
        while (at < raw.len) {
            if (raw[at] == ' ' or raw[at] == '\t') {
                column += if (raw[at] == '\t') @as(usize, 4) else 1;
                at += 1;
                continue;
            }
            var decoration = false;
            for ([_][]const u8{ "│", "┃", "├", "┣", "└", "┗", "─", "━" }, 0..) |part, i| if (std.mem.startsWith(u8, raw[at..], part)) {
                if (i >= 2 and i <= 5 and branch == null) branch = column;
                column += 1;
                at += part.len;
                decoration = true;
                break;
            };
            if (!decoration) break;
        }
        var rest = d.trim(raw[at..]);
        if (rest.len == 0) continue;
        const indent = if (branch) |v| v + 4 else column;
        if (nodes.items.len == 0) {
            levels[0] = indent;
        } else if (indent > levels[depth]) {
            if (depth == 32) return error.LimitExceeded;
            depth += 1;
            levels[depth] = indent;
        } else {
            while (depth > 0 and levels[depth] > indent) depth -= 1;
            if (indent != levels[depth]) return error.InvalidSyntax;
        }
        var label: []const u8 = undefined;
        if (rest[0] == '"' or rest[0] == '\'') {
            const end = std.mem.indexOfScalarPos(u8, rest, 1, rest[0]) orelse return error.InvalidSyntax;
            label = rest[1..end];
            rest = d.trim(rest[end + 1 ..]);
        } else {
            var end = rest.len;
            for ([_][]const u8{ " :::", " icon(", " ##", "\t:::", "\ticon(", "\t##" }) |marker| if (std.mem.indexOf(u8, rest, marker)) |i| {
                end = @min(end, i);
            };
            label = d.trim(rest[0..end]);
            rest = d.trim(rest[end..]);
        }
        if (label.len == 0 or label.len > 1024) return error.InvalidSyntax;
        var node: Node = .{ .name = label, .folder = std.mem.endsWith(u8, label, "/"), .depth = depth, .parent = if (depth == 0) null else parents[depth - 1] };
        if (node.folder) node.name = label[0 .. label.len - 1];
        var decorated: u8 = 0;
        while (rest.len > 0) {
            if (txt.starts(rest, "##")) {
                node.description = d.trim(rest[2..]);
                if (node.description.len > 1024) return error.LimitExceeded;
                rest = "";
            } else if (txt.starts(rest, ":::")) {
                if (decorated & 1 != 0) return error.InvalidSyntax;
                decorated |= 1;
                rest = d.trim(rest[3..]);
                const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                if (!std.mem.eql(u8, rest[0..end], "highlight")) return error.UnsupportedSyntax;
                node.highlight = true;
                rest = d.trim(rest[end..]);
            } else if (txt.starts(rest, "icon(")) {
                if (decorated & 2 != 0) return error.InvalidSyntax;
                decorated |= 2;
                const end = std.mem.indexOfScalar(u8, rest, ')') orelse return error.InvalidSyntax;
                node.icon = d.trim(rest[5..end]);
                rest = d.trim(rest[end + 1 ..]);
            } else return error.InvalidSyntax;
        }
        if (nodes.items.len == 2048) return error.LimitExceeded;
        parents[depth] = nodes.items.len;
        try nodes.append(temp, node);
    }
    if (nodes.items.len == 0) return error.InvalidSyntax;
    const show_icons = try doc.flag("config.treeView.showIcons", false);
    const icon_pack = doc.get("config.treeView.defaultIconPack") orelse "mermaid-treeview";
    const indent_size = data.coord(try doc.num("config.treeView.rowIndent", 28, 4, 500));
    const padding_x = data.coord(try doc.num("config.treeView.paddingX", 10, 0, 100));
    const padding_y = data.coord(try doc.num("config.treeView.paddingY", 8, 0, 100));
    const thickness = try doc.num("config.treeView.lineThickness", 1.5, 0.1, 20);
    const raw_font = doc.get("config.themeVariables.treeView.labelFontSize") orelse "16px";
    const font = try d.number(if (std.mem.endsWith(u8, raw_font, "px")) raw_font[0 .. raw_font.len - 2] else raw_font);
    if (font < 6 or font > 96) return error.InvalidSyntax;
    const fg = try color(doc, "config.themeVariables.treeView.labelColor", if (doc.theme == .dark) "#e0e0e0" else "#24292f");
    const line_color = try color(doc, "config.themeVariables.treeView.lineColor", fg);
    const icon_color = try color(doc, "config.themeVariables.treeView.iconColor", fg);
    const description_color = try color(doc, "config.themeVariables.treeView.descriptionColor", if (doc.theme == .dark) "#a7b1c2" else "#596579");
    const highlight = try color(doc, "config.themeVariables.treeView.highlightBg", if (doc.theme == .dark) "#594b21" else "#fff3c5");
    const highlight_stroke = try color(doc, "config.themeVariables.treeView.highlightStroke", "#c59a29");
    const row_height = data.coord(font) + @max(8, padding_y * 2);
    const icon_size = data.coord(font) + 4;
    var label_right: usize = 0;
    var description_width: usize = 0;
    for (nodes.items, 0..) |*n, i| {
        if (n.icon == null and show_icons) {
            if (!n.folder) {
                n.icon = doc.get(try std.fmt.allocPrint(temp, "config.treeView.filenameIcons.{s}", .{n.name}));
                if (n.icon == null) if (std.mem.lastIndexOfScalar(u8, n.name, '.')) |dot| {
                    const ext = try std.ascii.allocLowerString(temp, n.name[dot..]);
                    n.icon = doc.get(try std.fmt.allocPrint(temp, "config.treeView.extensionIcons.{s}", .{ext})) orelse doc.get(try std.fmt.allocPrint(temp, "config.treeView.extensionIcons.{s}", .{ext[1..]}));
                };
            }
            if (n.icon == null) n.icon = if (n.folder) "folder" else "file";
        }
        if (n.icon) |raw_icon| {
            const icon = if (txt.starts(raw_icon, "mermaid-treeview:")) raw_icon[17..] else raw_icon;
            if (icon.len == 0 or std.mem.eql(u8, icon, "none")) n.icon = null else if (std.mem.eql(u8, icon, "file") or std.mem.eql(u8, icon, "folder")) n.icon = icon else {
                n.icon = if (std.mem.indexOfScalar(u8, icon, ':') != null) icon else try std.fmt.allocPrint(temp, "{s}:{s}", .{ icon_pack, icon });
                _ = try doc.assets.get(n.icon.?);
            }
        }
        n.x = 30 + n.depth * (indent_size + padding_x);
        n.y = 20 + i * row_height + row_height / 2;
        label_right = @max(label_right, n.x + padding_x + (if (n.icon != null) icon_size + 6 else @as(usize, 0)) + data.coord(@as(f64, @floatFromInt(txt.width(n.name))) * font / 14));
        description_width = @max(description_width, data.coord(@as(f64, @floatFromInt(txt.width(n.description))) * font / 14));
    }
    // Known lookup maps may contain unused file types; they are not unknown options.
    for (doc.entries.items) |*entry| if (std.mem.startsWith(u8, entry.key, "config.treeView.filenameIcons.") or std.mem.startsWith(u8, entry.key, "config.treeView.extensionIcons.")) {
        entry.used = true;
    };
    const width = label_right + if (description_width > 0) description_width + 60 else @as(usize, 30);
    const height = 40 + nodes.items.len * row_height;
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(width, height, "tree", prefix);
    for (nodes.items) |n| if (n.highlight) {
        try out.fmt("<rect data-highlight=\"true\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"3\" fill=\"{s}\" stroke=\"{s}\"/>", .{ n.x, n.y - row_height / 2 + 1, width - n.x - 12, row_height - 2, highlight, highlight_stroke });
    };
    for (nodes.items, 0..) |n, i| if (n.parent) |parent| {
        const p = nodes.items[parent];
        try out.fmt("<path data-tree-edge=\"{d}\" data-parent=\"{d}\" d=\"M {d} {d} V {d} H {d}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d}\"/>", .{ i, parent, p.x + padding_x, p.y + row_height / 2, n.y, n.x, line_color, thickness });
    };
    for (nodes.items, 0..) |n, i| {
        try out.fmt("<g data-tree-node=\"{d}\" data-parent=\"{d}\" data-depth=\"{d}\" data-x=\"{d}\" data-y=\"{d}\">", .{ i, n.parent orelse 2048, n.depth, n.x, n.y });
        if (n.icon) |icon| {
            try out.fmt("<g fill=\"none\" stroke=\"{s}\">", .{icon_color});
            try icons.drawRegistered(&out, &doc.assets, icon, n.x + padding_x, n.y - icon_size / 2, icon_size);
            try out.add("</g>");
        }
        if (n.folder) try out.add("<g font-weight=\"bold\">");
        try text(&out, n.x + padding_x + (if (n.icon != null) icon_size + 6 else @as(usize, 0)), n.y, n.name, fg, font);
        if (n.folder) try out.add("</g>");
        if (n.description.len > 0) try text(&out, label_right + 24, n.y, n.description, description_color, font);
        try out.add("</g>");
    }
    return out.finish();
}
