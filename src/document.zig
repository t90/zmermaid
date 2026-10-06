const std = @import("std");
const svg = @import("svg.zig");
const txt = @import("sequence_text.zig");
pub const Error = txt.Error;
const Entry = struct { key: []const u8, value: []const u8, used: bool = false };
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
pub fn unquote(s: []const u8) []const u8 {
    const v = trim(s);
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) return v[1 .. v.len - 1];
    return v;
}
pub fn number(s: []const u8) Error!f64 {
    const n = std.fmt.parseFloat(f64, trim(s)) catch return error.InvalidSyntax;
    if (!std.math.isFinite(n) or @abs(n) > 1e12) return error.LimitExceeded;
    return n;
}
pub fn fontFamily(family: []const u8) Error![]const u8 {
    if (family.len == 0 or family.len > 256) return error.InvalidSyntax;
    for (family) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, " ,_-'\"", c) == null) return error.UnsupportedSyntax;
    return family;
}
// The standard CSS named-color vocabulary is needed to distinguish optional
// color prefixes from ordinary titles without relying on a browser DOM.
pub fn namedColor(value: []const u8) bool {
    const names = "aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod darkgray darkgrey darkgreen darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen darkslateblue darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray grey green greenyellow honeydew hotpink indianred indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgrey lightgreen lightpink lightsalmon lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum powderblue purple rebeccapurple red rosybrown royalblue saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray slategrey snow springgreen steelblue tan teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen transparent currentColor";
    var it = std.mem.tokenizeScalar(u8, names, ' ');
    while (it.next()) |name| if (std.ascii.eqlIgnoreCase(value, name)) return true;
    return false;
}
pub fn color(s: []const u8) Error![]const u8 {
    const v = unquote(s);
    if (v.len == 0 or v.len > 80) return error.InvalidSyntax;
    const open = std.mem.indexOfScalar(u8, v, '(');
    if (open) |at| {
        if (v[v.len - 1] != ')') return error.InvalidSyntax;
        const name = v[0..at];
        const rgb = std.ascii.eqlIgnoreCase(name, "rgb") or std.ascii.eqlIgnoreCase(name, "rgba");
        const hsl = std.ascii.eqlIgnoreCase(name, "hsl") or std.ascii.eqlIgnoreCase(name, "hsla");
        if (!rgb and !hsl) return error.UnsupportedSyntax;
        const alpha = name.len == 4;
        var parts = std.mem.splitScalar(u8, v[at + 1 .. v.len - 1], ',');
        var count: usize = 0;
        while (parts.next()) |raw| {
            const part = trim(raw);
            const percent = std.mem.endsWith(u8, part, "%");
            const value = try number(if (percent) part[0 .. part.len - 1] else part);
            const max: f64 = if (percent) 100 else if (count == 3) 1 else if (rgb) 255 else if (count == 0) 360000 else return error.InvalidSyntax;
            if (value < 0 or value > max or count >= (if (alpha) @as(usize, 4) else 3)) return error.InvalidSyntax;
            count += 1;
        }
        if (count != (if (alpha) @as(usize, 4) else 3)) return error.InvalidSyntax;
        return v;
    }
    if (v[0] == '#') {
        if (v.len != 4 and v.len != 5 and v.len != 7 and v.len != 9) return error.InvalidSyntax;
        for (v[1..]) |c| if (!std.ascii.isHex(c)) {
            return error.InvalidSyntax;
        };
    } else {
        for (v) |c| if (!std.ascii.isAlphabetic(c)) {
            return error.UnsupportedSyntax;
        };
    }
    return v;
}
pub const Document = struct {
    a: std.mem.Allocator,
    source: []const u8,
    title: []const u8 = "",
    acc_title: []const u8 = "",
    acc_description: []const u8 = "",
    theme: svg.Theme,
    style: []const u8 = "default",
    palette_used: bool = false,
    now_ms: ?i64 = null,
    entries: std.ArrayList(Entry) = .empty,
    assets: @import("assets.zig").Registry = .{},
    layout_hint: []const u8 = "",
    font_family: []const u8 = "",
    max_width: bool = true,
    security_requested: []const u8 = "",
    marker_color: []const u8 = "",
    title_gap: usize = 20,
    sketch: bool = false,
    sketch_seed: u32 = 0,
    pub fn parse(a: std.mem.Allocator, source: []const u8, theme: svg.Theme) Error!Document {
        var doc: Document = .{ .a = a, .source = source, .theme = theme };
        if (std.mem.startsWith(u8, source, "---\n") or std.mem.startsWith(u8, source, "---\r\n")) {
            const Level = struct { indent: usize, path: []const u8 };
            var stack: [32]Level = undefined;
            var depth: usize = 0;
            var offset = (std.mem.indexOfScalar(u8, source, '\n').?) + 1;
            var closed = false;
            while (offset < source.len) {
                const line_start = offset;
                const line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
                const raw = source[offset..line_end];
                offset = @min(line_end + 1, source.len);
                const line = trim(raw);
                if (std.mem.eql(u8, line, "---")) {
                    closed = true;
                    break;
                }
                if (line.len == 0 or line[0] == '#') continue;
                const indent = raw.len - std.mem.trimStart(u8, raw, " ").len;
                if (indent < raw.len and raw[indent] == '\t') return error.UnsupportedSyntax;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.UnsupportedSyntax;
                const key = unquote(line[0..colon]);
                if (key.len == 0) return error.InvalidSyntax;
                while (depth > 0 and stack[depth - 1].indent >= indent) depth -= 1;
                const path = if (depth > 0) try std.fmt.allocPrint(a, "{s}.{s}", .{ stack[depth - 1].path, key }) else key;
                const scalar = @import("yaml_scalar.zig");
                var value = trim(line[colon + 1 ..]);
                var is_scalar = value.len > 0;
                var object_value = false;
                if (value.len > 0 and (value[0] == '"' or value[0] == '\'')) {
                    var at = line_start + indent + colon + 1;
                    while (at < source.len and (source[at] == ' ' or source[at] == '\t')) at += 1;
                    value = try scalar.quoted(a, source, &at);
                    const end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
                    if (scalar.plain(source[at..end]).len > 0) return error.InvalidSyntax;
                    offset = @min(end + 1, source.len);
                } else {
                    value = scalar.plain(value);
                    is_scalar = value.len > 0;
                    object_value = std.mem.startsWith(u8, value, "{");
                    if (value.len > 0 and (value[0] == '|' or value[0] == '>')) value = try scalar.block(a, source, &offset, indent, value);
                }
                if (!is_scalar) {
                    if (depth == stack.len) return error.LimitExceeded;
                    stack[depth] = .{ .indent = indent, .path = path };
                    depth += 1;
                } else {
                    if (doc.entries.items.len == 128) return error.LimitExceeded;
                    for (doc.entries.items) |entry| if (std.mem.eql(u8, entry.key, path)) {
                        return error.InvalidSyntax;
                    };
                    if (object_value) try @import("config_object.zig").parse(&doc, path, value) else try doc.entries.append(a, .{ .key = path, .value = value });
                }
            }
            if (!closed) return error.InvalidSyntax;
            doc.source = trim(source[@min(offset, source.len)..]);
        }
        try @import("config_object.zig").directives(&doc);
        if (doc.get("title")) |title| doc.title = try txt.parse(a, title);
        while (std.mem.startsWith(u8, doc.source, "%%") and !std.mem.startsWith(u8, doc.source, "%%{")) {
            const newline = std.mem.indexOfScalar(u8, doc.source, '\n') orelse return error.InvalidSyntax;
            doc.source = trim(doc.source[newline + 1 ..]);
        }
        if (doc.get("config.look")) |look| {
            if (std.mem.eql(u8, look, "handDrawn")) doc.sketch = true else if (!std.mem.eql(u8, look, "classic")) return error.UnsupportedSyntax;
        }
        const sketch_seed = try doc.num("config.handDrawnSeed", 0, 0, 4294967295);
        if (@floor(sketch_seed) != sketch_seed) return error.InvalidSyntax;
        doc.sketch_seed = @intFromFloat(sketch_seed);
        if (doc.get("config.securityLevel")) |level| {
            if (!std.mem.eql(u8, level, "strict") and !std.mem.eql(u8, level, "loose") and !std.mem.eql(u8, level, "antiscript") and !std.mem.eql(u8, level, "sandbox")) return error.InvalidSyntax;
            // This is host policy in Mermaid, not permission for source text to
            // relax our SVG validation or execute code. Record the request only.
            doc.security_requested = level;
        }
        if (doc.get("config.fontFamily")) |family| {
            doc.font_family = try fontFamily(family);
        }
        const kind_end = std.mem.indexOfAny(u8, doc.source, " \t\r\n;") orelse doc.source.len;
        const kind = doc.source[0..kind_end];
        const groups = .{ .{ "flowchart", "flowchart graph flowchart-elk swimlane-beta" }, .{ "class", "classDiagram classDiagram-v2" }, .{ "sequence", "sequenceDiagram zenuml" }, .{ "er", "erDiagram" }, .{ "state", "stateDiagram stateDiagram-v2" }, .{ "gantt", "gantt" }, .{ "journey", "journey" }, .{ "timeline", "timeline" }, .{ "gitGraph", "gitGraph gitGraph:" }, .{ "pie", "pie" }, .{ "requirement", "requirementDiagram" }, .{ "sankey", "sankey sankey-beta" }, .{ "xyChart", "xychart xychart-beta" } };
        inline for (groups) |group| {
            var names = std.mem.tokenizeScalar(u8, group[1], ' ');
            while (names.next()) |name| if (std.mem.eql(u8, kind, name)) {
                // Legacy init.config settings apply to the active diagram family.
                for (doc.entries.items) |*entry| {
                    if (!std.mem.startsWith(u8, entry.key, "config.config.")) continue;
                    const key = try std.fmt.allocPrint(a, "config.{s}.{s}", .{ group[0], entry.key[14..] });
                    var replaced = false;
                    for (doc.entries.items) |*existing| if (std.mem.eql(u8, existing.key, key)) {
                        existing.value = entry.value;
                        entry.used = true;
                        replaced = true;
                        break;
                    };
                    if (!replaced) entry.key = key;
                }
                doc.max_width = try doc.flag("config." ++ group[0] ++ ".useMaxWidth", true);
                _ = try doc.flag("config." ++ group[0] ++ ".htmlLabels", false);
            };
        }
        // HTML labels use the native SVG text path in this implementation.
        _ = try doc.flag("config.htmlLabels", false);
        _ = try doc.flag("config.flowchart.htmlLabels", false);
        doc.title_gap = @intFromFloat(try doc.num("config.flowchart.titleTopMargin", 20, 0, 2000));
        if (doc.get("config.theme")) |style| {
            var valid = false;
            for ([_][]const u8{ "default", "base", "forest", "dark", "neutral" }) |name| if (std.mem.eql(u8, style, name)) {
                valid = true;
            };
            if (!valid) return error.UnsupportedSyntax;
            doc.style = style;
            if (std.mem.eql(u8, style, "dark")) doc.theme = .dark;
        }
        if (try doc.flag("config.themeVariables.darkMode", false)) doc.theme = .dark;
        // Development logging has no effect on the SVG.
        _ = doc.get("config.logLevel");
        _ = doc.get("config.loglevel");
        if (doc.get("config.layout")) |layout| {
            if (!std.mem.eql(u8, layout, "elk") and !std.mem.eql(u8, layout, "dagre") and !(std.mem.eql(u8, layout, "tidy-tree") and std.mem.eql(u8, kind, "mindmap")) and !(std.mem.eql(u8, layout, "swimlane") and std.mem.eql(u8, kind, "swimlane-beta"))) return error.UnsupportedSyntax;
            doc.layout_hint = layout;
        }
        if (doc.get("config.flowchart.defaultRenderer")) |layout| {
            if (!std.mem.eql(u8, layout, "elk") and !std.mem.eql(u8, layout, "dagre-d3") and !std.mem.eql(u8, layout, "dagre-wrapper")) return error.UnsupportedSyntax;
            if (doc.layout_hint.len == 0) doc.layout_hint = layout;
        }
        return doc;
    }
    pub fn get(self: *Document, key: []const u8) ?[]const u8 {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.key, key)) {
            entry.used = true;
            return entry.value;
        };
        return null;
    }
    pub fn num(self: *Document, key: []const u8, default: f64, min: f64, max: f64) Error!f64 {
        const v = if (self.get(key)) |raw| try number(raw) else default;
        if (v < min or v > max) return error.InvalidSyntax;
        return v;
    }
    pub fn flag(self: *Document, key: []const u8, default: bool) Error!bool {
        if (self.get(key)) |v| {
            if (std.mem.eql(u8, v, "true")) return true;
            if (std.mem.eql(u8, v, "false")) return false;
            return error.InvalidSyntax;
        }
        return default;
    }
    pub fn palette(self: *Document, index: usize) Error![]const u8 {
        self.palette_used = true;
        var buf: [80]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "config.themeVariables.cScale{d}", .{index}) catch return error.LimitExceeded;
        if (self.get(key)) |v| return color(v);
        const normal = [_][]const u8{ "#8ecae6", "#ffb703", "#90be6d", "#f28482", "#b8a1d9", "#43aa8b", "#f4a261", "#9bb1ff" };
        const forest = [_][]const u8{ "#86b88a", "#c4db9c", "#619b8a", "#a2c5ac", "#d4c685", "#6a994e", "#9ec1a3", "#bfd8bd" };
        const dark = [_][]const u8{ "#315d78", "#866621", "#42653c", "#804340", "#5d4979", "#2f6a58", "#855a3c", "#4b5488" };
        if (self.theme == .dark) return dark[index % dark.len];
        if (std.mem.eql(u8, self.style, "forest")) return forest[index % forest.len];
        if (std.mem.eql(u8, self.style, "neutral")) return "#d2d2d2";
        return normal[index % normal.len];
    }
    pub fn graphTheme(self: *Document, graph: anytype) Error!void {
        const spacing_groups = .{ .{ "class", "class" }, .{ "entity", "er" }, .{ "state", "state" } };
        inline for (spacing_groups) |group| if (std.mem.eql(u8, graph.kind, group[0])) {
            const entity = std.mem.eql(u8, graph.kind, "entity");
            graph.node_spacing = @intFromFloat(try self.num("config." ++ group[1] ++ ".nodeSpacing", if (entity) 72 else 40, 0, 2000));
            graph.rank_spacing = @intFromFloat(try self.num("config." ++ group[1] ++ ".rankSpacing", if (entity) 112 else 50, 0, 2000));
            if (entity) graph.diagram_padding = 24;
        };
        const Style = @import("chart_style.zig").Style;
        const forest = std.mem.eql(u8, self.style, "forest");
        const neutral = std.mem.eql(u8, self.style, "neutral");
        var node: Style = .{};
        if (forest) node = if (self.theme == .dark) .{ .fill = "#213b2a", .stroke = "#8abb8f", .text = "#e0e0e0" } else .{ .fill = "#cde498", .stroke = "#13540c", .text = "#263a24" };
        if (neutral) node = if (self.theme == .dark) .{ .fill = "#252525", .stroke = "#aab0b8", .text = "#e0e0e0" } else .{ .fill = "#eeeeee", .stroke = "#666666", .text = "#222222" };
        if (self.get("config.themeVariables.fontSize")) |raw| {
            const value = try number(if (std.mem.endsWith(u8, raw, "px")) raw[0 .. raw.len - 2] else raw);
            if (value < 1 or value > 256) return error.InvalidSyntax;
            node.font_size = value;
        }
        if (self.get("config.themeVariables.primaryColor")) |v| node.fill = try color(v);
        if (self.get("config.themeVariables.primaryTextColor")) |v| node.text = try color(v);
        if (self.get("config.themeVariables.primaryBorderColor")) |v| node.stroke = try color(v);
        if (self.get("config.themeVariables.mainBkg")) |v| node.fill = try color(v);
        if (self.get("config.themeVariables.nodeBorder")) |v| node.stroke = try color(v);
        var group = node;
        if (forest) group.fill = if (self.theme == .dark) "#162d1c" else "#e5f1dc";
        if (neutral) group.fill = if (self.theme == .dark) "#181818" else "#fafafa";
        if (self.get("config.themeVariables.secondaryColor")) |v| group.fill = try color(v);
        if (self.get("config.themeVariables.clusterBkg")) |v| group.fill = try color(v);
        if (self.get("config.themeVariables.clusterBorder")) |v| group.stroke = try color(v);
        if (self.get("config.themeVariables.titleColor")) |v| group.text = try color(v);
        var note = node;
        if (self.get("config.themeVariables.tertiaryColor")) |v| note.fill = try color(v);
        var edge: Style = .{ .text = node.text, .font_size = node.font_size };
        if (forest or neutral) edge.stroke = node.stroke;
        if (self.get("config.themeVariables.lineColor")) |v| edge.stroke = try color(v);
        for (graph.nodes.items) |*n| {
            var base = if (n.container) group else if (n.note_for != null) note else node;
            base.merge(n.style);
            n.style = base;
        }
        for (graph.edges.items) |*e| {
            var base = edge;
            base.merge(e.style);
            e.style = base;
        }
        if (edge.stroke) |v| self.marker_color = v;
        if (forest or neutral) self.palette_used = true;
    }
    pub fn finish(self: *Document) Error!void {
        if (!self.palette_used and (std.mem.eql(u8, self.style, "forest") or std.mem.eql(u8, self.style, "neutral"))) return error.UnsupportedSyntax;
        for (self.entries.items) |entry| if (!entry.used) return error.UnsupportedSyntax;
    }
    pub fn wrap(self: *Document, a: std.mem.Allocator, inner: []u8) Error![]u8 {
        if (self.title.len == 0 and self.acc_title.len == 0 and self.acc_description.len == 0) {
            if (self.layout_hint.len == 0) return inner;
            const result = try std.fmt.allocPrint(a, "<svg data-layout-engine=\"zmermaid\" data-layout-requested=\"{s}\"{s}", .{ self.layout_hint, inner[4..] });
            a.free(inner);
            return result;
        }
        const start = (std.mem.indexOf(u8, inner, "viewBox=\"0 0 ") orelse return error.InvalidSyntax) + 13;
        const end = std.mem.indexOfScalarPos(u8, inner, start, '"') orelse return error.InvalidSyntax;
        var dimensions = std.mem.tokenizeScalar(u8, inner[start..end], ' ');
        const w = std.fmt.parseInt(usize, dimensions.next() orelse return error.InvalidSyntax, 10) catch return error.InvalidSyntax;
        const h = std.fmt.parseInt(usize, dimensions.next() orelse return error.InvalidSyntax, 10) catch return error.InvalidSyntax;
        const width = @max(w, txt.width(self.title) + 40);
        const top = if (self.title.len > 0) txt.height(self.title) + self.title_gap + 12 else 0;
        var out: svg.Svg = .{ .allocator = a, .theme = self.theme };
        defer out.deinit();
        try out.fmt("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\" style=\"{s}height:auto\" data-layout-engine=\"zmermaid\" data-layout-requested=\"{s}\"><rect width=\"100%\" height=\"100%\" fill=\"{s}\"/>", .{ width, h + top, width, h + top, if (self.max_width) "max-width:100%;" else "", self.layout_hint, if (self.theme == .dark) "#0d1117" else "#ffffff" });
        if (self.acc_title.len > 0) {
            try out.add("<title>");
            try out.escape(self.acc_title);
            try out.add("</title>");
        }
        if (self.acc_description.len > 0) {
            try out.add("<desc>");
            try out.escape(self.acc_description);
            try out.add("</desc>");
        }
        if (self.title.len > 0) try txt.draw(&out, width / 2, 12, self.title);
        try out.fmt("<svg x=\"{d}\" y=\"{d}\"", .{ (width - w) / 2, top });
        try out.add(inner[4..]);
        try out.add("</svg>");
        const result = try out.bytes.toOwnedSlice(a);
        a.free(inner);
        return result;
    }
    pub fn presentation(self: *Document, a: std.mem.Allocator, inner: []u8) Error![]u8 {
        if (self.font_family.len == 0 and self.max_width and self.security_requested.len == 0 and self.marker_color.len == 0) return inner;
        const end = std.mem.indexOfScalar(u8, inner, '>') orelse return error.InvalidSyntax;
        var out: svg.Svg = .{ .allocator = a, .theme = self.theme };
        defer out.deinit();
        if (!self.max_width) {
            const at = std.mem.indexOf(u8, inner[0..end], "max-width:100%;") orelse return error.InvalidSyntax;
            try out.add(inner[0..at]);
            try out.add(inner[at + 15 .. end]);
        } else try out.add(inner[0..end]);
        if (self.security_requested.len > 0) try out.fmt(" data-security-policy=\"bounded-svg\" data-security-requested=\"{s}\"", .{self.security_requested});
        try out.add(">");
        if (self.font_family.len > 0) {
            const id_at = (std.mem.indexOf(u8, inner[0..end], "id=\"") orelse return error.InvalidSyntax) + 4;
            const id_end = std.mem.indexOfScalarPos(u8, inner, id_at, '"') orelse return error.InvalidSyntax;
            try out.fmt("<style>#{s} text{{font-family:{s};}}</style>", .{ inner[id_at..id_end], self.font_family });
        }
        if (self.marker_color.len > 0) {
            const id_at = (std.mem.indexOf(u8, inner[0..end], "id=\"") orelse return error.InvalidSyntax) + 4;
            const id_end = std.mem.indexOfScalarPos(u8, inner, id_at, '"') orelse return error.InvalidSyntax;
            const id = inner[id_at..id_end];
            try out.fmt("<style>#{s} marker,#{s} marker path,#{s} marker circle{{stroke:{s};}}", .{ id, id, id, self.marker_color });
            try out.fmt("#{s} marker[id$=\"-arrow\"] path,#{s} marker[id$=\"-composition\"] path{{fill:{s};}}</style>", .{ id, id, self.marker_color });
        }
        try out.add(inner[end + 1 ..]);
        const result = try out.bytes.toOwnedSlice(a);
        a.free(inner);
        return result;
    }
};
