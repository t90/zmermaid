// SPDX-License-Identifier: EPL-2.0
// Mermaid 11.16.1 implementation/behavior references:
// https://github.com/mermaid-js/mermaid/blob/7ecca0cd7f1658ef74f4e7e91f925724ef403bbf/packages/mermaid/src/diagrams/flowchart/
// Upstream copyright: (c) 2014 - 2022 Knut Sveidqvist.
// Upstream MIT notice: LICENSES/Mermaid-MIT.txt; project license: LICENSE.
const std = @import("std");
const svg = @import("svg.zig");
const shapes = @import("flow_shapes.zig");
const links = @import("flow_links.zig");
const txt = @import("sequence_text.zig");
const data = @import("chart_data.zig");
const document = @import("document.zig");
const compound = @import("flow_compound.zig");
const styles = @import("chart_style.zig");
const paint = @import("flow_paint.zig");
const layout = @import("flow_layout.zig");
fn isMarkdown(raw: []const u8) bool {
    return (raw.len >= 2 and raw[0] == '`' and raw[raw.len - 1] == '`') or @import("rich_text.zig").hasFormatting(raw);
}
const Shape = shapes.Shape;
pub const Member = struct { text: []const u8, method: bool = false, italic: bool = false, underlined: bool = false, markdown: bool = false, cells: [4][]const u8 = .{ "", "", "", "" } };
pub const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: Shape = .box,
    rank: usize = 0,
    x: usize = 0,
    y: usize = 0,
    w: usize = 0,
    h: usize = 0,
    parent: ?usize = null,
    container: bool = false,
    collapsed: bool = false,
    direction: ?[]const u8 = null,
    classes: []const u8 = "",
    style: styles.Style = .{},
    table: bool = false,
    markdown: bool = false,
    members: std.ArrayList(Member) = .empty,
    annotation: []const u8 = "",
    state_description_count: usize = 0,
    state_title: []const u8 = "",
    state_body: []const u8 = "",
    hide_empty: bool = false,
    entity: bool = false,
    columns: [4]usize = .{ 0, 0, 0, 0 },
    region: bool = false,
    note_for: ?usize = null,
    note_left: bool = false,
    external_input: ?bool = null,
    external_order: ?usize = null,
    action: @import("interaction.zig").Action = .{},
    asset: ?*const @import("assets.zig").Asset = null,
    asset_width: usize = 64,
    asset_height: usize = 64,
    asset_form: []const u8 = "none",
    asset_top: bool = false,
    assets: ?*const @import("assets.zig").Registry = null,
};
pub const Edge = struct { from: usize, to: usize, link: links.Link, left_label: []const u8 = "", right_label: []const u8 = "", id: []const u8 = "", classes: []const u8 = "", style: styles.Style = .{}, index_style: styles.Style = .{}, curve: links.Curve = .smooth, curve_explicit: bool = false };
const Binding = struct { ids: []const u8, classes: []const u8 = "", style: styles.Style = .{} };
pub const Error = txt.Error;
pub const Parser = struct {
    // ELK model-order options belong to a scope, not to all descendants.
    ordering_model: bool = true,
    ordering_sides: ?[]const layout.EdgeSides = null,
    ordering_parent_state: ?u64 = null,
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    labels: std.ArrayList([]const u8) = .empty,
    stack: [16]usize = undefined,
    depth: usize = 0,
    containers: usize = 0,
    classes: std.ArrayList(styles.Class) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    kind: []const u8 = "flowchart",
    entity_horizontal: bool = false,
    assets: ?*const @import("assets.zig").Registry = null,
    default_edge_style: styles.Style = .{},
    default_curve: ?links.Curve = null,
    config_curve: links.Curve = .rounded,
    node_spacing: usize = 40,
    direction_override: ?[]const u8 = null,
    inherit_direction: bool = false,
    rank_spacing: usize = 45,
    title_margin_top: usize = 0,
    title_margin_bottom: usize = 0,
    wrap_markdown: bool = true,
    // The font-engine adapter must receive unwrapped labels.
    defer_measurement: bool = false,
    wrapping_width: usize = 230,
    diagram_padding: usize = 16,
    pub fn deinit(self: *Parser) void {
        for (self.nodes.items) |*n| n.members.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        for (self.labels.items) |label| self.allocator.free(label);
        self.labels.deinit(self.allocator);
        self.classes.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
    }
    fn parseLabel(self: *Parser, raw: []const u8) Error![]const u8 {
        if (raw.len > 512) return error.LimitExceeded;
        var image_at: usize = 0;
        while (@import("inline_image.zig").find(raw, image_at)) |pos| {
            const item = try @import("inline_image.zig").parse(raw[pos..]);
            if (item.name.len > 0) {
                const registry = self.assets orelse return error.MissingAsset;
                _ = try registry.get(item.name);
            }
            image_at = pos + item.end;
        }
        var at: usize = 0;
        while (@import("assets.zig").inlineIcon(raw, at)) |icon| {
            const registry = self.assets orelse return error.MissingAsset;
            _ = try registry.get(icon.name);
            at = icon.end;
        }
        if (isMarkdown(raw)) {
            const decoded = try @import("rich_text.zig").parse(self.allocator, if (raw.len >= 2 and raw[0] == '`' and raw[raw.len - 1] == '`') raw[1 .. raw.len - 1] else raw);
            self.labels.append(self.allocator, decoded) catch |err| {
                self.allocator.free(decoded);
                return err;
            };
            if (!self.defer_measurement and self.wrap_markdown and raw.len >= 2 and raw[0] == '`' and raw[raw.len - 1] == '`') {
                const wrapped = try @import("rich_text.zig").wrap(self.allocator, decoded, self.wrapping_width);
                errdefer self.allocator.free(wrapped);
                try self.labels.append(self.allocator, wrapped);
                return wrapped;
            }
            return decoded;
        }
        if (std.mem.indexOfAny(u8, raw, "<#") == null) return raw;
        const decoded = try txt.parse(self.allocator, raw);
        errdefer self.allocator.free(decoded);
        try self.labels.append(self.allocator, decoded);
        return decoded;
    }
    pub fn resolveStyles(self: *Parser) Error!void {
        for (self.nodes.items) |*n| {
            for (self.classes.items) |cls| if (std.mem.eql(u8, cls.name, "default")) {
                n.style.merge(cls.style);
            };
            for (self.bindings.items) |binding| {
                if (binding.classes.len == 0) continue;
                var ids = std.mem.splitScalar(u8, binding.ids, ',');
                while (ids.next()) |id| if (std.mem.eql(u8, document.trim(id), n.id)) {
                    n.classes = try self.joinClasses(n.classes, binding.classes);
                };
            }
            var names = std.mem.tokenizeAny(u8, n.classes, ", ");
            while (names.next()) |name| {
                for (self.classes.items) |cls| if (std.mem.eql(u8, cls.name, name)) {
                    n.style.merge(cls.style);
                };
                // Undeclared CSS classes are retained for caller-provided styling.
            }
            for (self.bindings.items) |binding| {
                if (binding.classes.len > 0) continue;
                var ids = std.mem.splitScalar(u8, binding.ids, ',');
                while (ids.next()) |id| if (std.mem.eql(u8, document.trim(id), n.id)) {
                    n.style.merge(binding.style);
                };
            }
        }
        for (self.edges.items) |*edge| {
            if (edge.id.len > 0) for (self.nodes.items) |n| {
                if (std.mem.eql(u8, n.id, edge.id)) return error.InvalidSyntax;
            };
            var base = self.default_edge_style;
            base.merge(edge.index_style);
            base.merge(edge.style);
            edge.style = base;
            if (!edge.curve_explicit) edge.curve = self.default_curve orelse self.config_curve;
            for (self.bindings.items) |binding| {
                var ids = std.mem.splitScalar(u8, binding.ids, ',');
                while (ids.next()) |id| if (edge.id.len > 0 and std.mem.eql(u8, document.trim(id), edge.id)) {
                    if (binding.classes.len > 0) edge.classes = try self.joinClasses(edge.classes, binding.classes) else edge.style.merge(binding.style);
                };
            }
            var names = std.mem.tokenizeAny(u8, edge.classes, ", ");
            while (names.next()) |name| {
                for (self.classes.items) |cls| if (std.mem.eql(u8, cls.name, name)) {
                    edge.style.merge(cls.style);
                };
            }
        }
        for (self.bindings.items) |binding| {
            var ids = std.mem.splitScalar(u8, binding.ids, ',');
            while (ids.next()) |id| {
                if (document.trim(id).len == 0) return error.InvalidSyntax;
                var found = false;
                for (self.nodes.items) |n| if (std.mem.eql(u8, document.trim(id), n.id)) {
                    found = true;
                };
                for (self.edges.items) |edge| if (edge.id.len > 0 and std.mem.eql(u8, document.trim(id), edge.id)) {
                    found = true;
                };
                // Class assignments to absent IDs are no-ops in Mermaid;
                // they neither create vertices nor perform wildcard matching.
                if (!found and binding.classes.len == 0 and !std.mem.eql(u8, self.kind, "flowchart")) return error.InvalidSyntax;
            }
        }
    }
    fn wrapLabels(self: *Parser) Error!void {
        const wrapper = @import("text_wrap.zig");
        for (self.nodes.items) |*item| {
            if (item.markdown or item.label.len == 0 or paint.labelWidth(item.label, false) <= self.wrapping_width) continue;
            const wrapped = try wrapper.wrap(self.allocator, item.label, self.wrapping_width);
            errdefer self.allocator.free(wrapped);
            try self.labels.append(self.allocator, wrapped);
            item.label = wrapped;
        }
        for (self.edges.items) |*edge| {
            if (edge.link.markdown or edge.link.label.len == 0 or paint.labelWidth(edge.link.label, false) <= self.wrapping_width) continue;
            const wrapped = try wrapper.wrap(self.allocator, edge.link.label, self.wrapping_width);
            errdefer self.allocator.free(wrapped);
            try self.labels.append(self.allocator, wrapped);
            edge.link.label = wrapped;
        }
    }
    fn joinClasses(self: *Parser, first: []const u8, second: []const u8) Error![]const u8 {
        if (first.len == 0) return second;
        const result = try std.fmt.allocPrint(self.allocator, "{s},{s}", .{ first, second });
        errdefer self.allocator.free(result);
        try self.labels.append(self.allocator, result);
        return result;
    }
    fn node(self: *Parser, source: []const u8, pos: *usize) Error!usize {
        skip(source, pos);
        const begin = pos.*;
        while (pos.* < source.len) {
            const c = source[pos.*];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c >= 128) {
                pos.* += 1;
            } else if ((c == '-' or c == '.') and !std.mem.startsWith(u8, source[pos.*..], "--") and !std.mem.startsWith(u8, source[pos.*..], "-.") and !std.mem.startsWith(u8, source[pos.*..], "..")) {
                pos.* += 1;
            } else break;
        }
        if (pos.* == begin) return error.UnsupportedSyntax;
        const id = source[begin..pos.*];
        if (id.len > 512) return error.LimitExceeded;
        if (std.mem.eql(u8, id, "subgraph") or std.mem.eql(u8, id, "end") or std.mem.eql(u8, id, "style") or std.mem.eql(u8, id, "classDef") or std.mem.eql(u8, id, "class") or std.mem.eql(u8, id, "click") or std.mem.eql(u8, id, "direction") or std.mem.eql(u8, id, "linkStyle")) return error.UnsupportedSyntax;
        skip(source, pos);
        var label = id;
        var shape: Shape = .box;
        var explicit = false;
        var explicit_shape = false;
        var markdown = false;
        var collapsed: ?bool = null;
        var asset: ?*const @import("assets.zig").Asset = null;
        var asset_width: ?usize = null;
        var asset_height: usize = 64;
        var asset_form: []const u8 = "none";
        var asset_top = false;
        var asset_options = false;
        if (pos.* < source.len and std.mem.indexOfScalar(u8, "[({>", source[pos.*]) != null) {
            explicit = true;
            explicit_shape = true;
            const forms = [_]struct { open: []const u8, close: []const u8, shape: Shape }{
                .{ .open = "(((", .close = ")))", .shape = .double_circle },
                .{ .open = "((", .close = "))", .shape = .circle },
                .{ .open = "([", .close = "])", .shape = .stadium },
                .{ .open = "[[", .close = "]]", .shape = .subroutine },
                .{ .open = "[(", .close = ")]", .shape = .cylinder },
                .{ .open = "{{", .close = "}}", .shape = .hexagon },
                .{ .open = "[/", .close = "/]", .shape = .lean_right },
                .{ .open = "[\\", .close = "\\]", .shape = .lean_left },
                .{ .open = "[", .close = "]", .shape = .box },
                .{ .open = "(", .close = ")", .shape = .round },
                .{ .open = "{", .close = "}", .shape = .diamond },
                .{ .open = ">", .close = "]", .shape = .asymmetric },
            };
            var close: []const u8 = "";
            for (forms) |form| {
                if (std.mem.startsWith(u8, source[pos.*..], form.open)) {
                    shape = form.shape;
                    close = form.close;
                    pos.* += form.open.len;
                    break;
                }
            }
            const start = pos.*;
            var quoted = false;
            while (pos.* < source.len) : (pos.* += 1) {
                if (source[pos.*] == '"') quoted = !quoted;
                if (!quoted and shape == .lean_right and std.mem.startsWith(u8, source[pos.*..], "\\]")) {
                    shape = .trapezoid;
                    close = "\\]";
                }
                if (!quoted and shape == .lean_left and std.mem.startsWith(u8, source[pos.*..], "/]")) {
                    shape = .inverse_trapezoid;
                    close = "/]";
                }
                if (!quoted and std.mem.startsWith(u8, source[pos.*..], close)) break;
            }
            if (pos.* == source.len) return error.InvalidSyntax;
            label = std.mem.trim(u8, source[start..pos.*], " \t");
            if (label.len >= 2 and label[0] == '"' and label[label.len - 1] == '"') {
                label = label[1 .. label.len - 1];
            } else if (std.mem.indexOfAny(u8, label, "[](){}") != null) return error.UnsupportedSyntax;
            markdown = isMarkdown(label);
            label = try self.parseLabel(label);
            pos.* += close.len;
        }
        skip(source, pos);
        if (std.mem.startsWith(u8, source[pos.*..], "@{")) {
            pos.* += 2;
            const start = pos.*;
            var quoted = false;
            while (pos.* < source.len) : (pos.* += 1) {
                if (source[pos.*] == '"') quoted = !quoted;
                if (source[pos.*] == '}' and !quoted) break;
            }
            if (pos.* == source.len) return error.InvalidSyntax;
            var parts: data.Parts = .{ .rest = source[start..pos.*] };
            var seen_label = false;
            var seen_shape = false;
            while (try parts.next()) |part| {
                const colon = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidSyntax;
                const key = document.trim(part[0..colon]);
                const value = document.unquote(part[colon + 1 ..]);
                if (std.mem.eql(u8, key, "shape")) {
                    if (seen_shape) return error.InvalidSyntax;
                    seen_shape = true;
                    shape = shapes.named(value) orelse return error.UnsupportedSyntax;
                    explicit_shape = true;
                } else if (std.mem.eql(u8, key, "label")) {
                    if (seen_label) return error.InvalidSyntax;
                    seen_label = true;
                    markdown = isMarkdown(value);
                    label = try self.parseLabel(value);
                    explicit = true;
                } else if (std.mem.eql(u8, key, "view")) {
                    if (!std.mem.eql(u8, value, "collapsed") and !std.mem.eql(u8, value, "expanded")) return error.UnsupportedSyntax;
                    collapsed = std.mem.eql(u8, value, "collapsed");
                } else if (std.mem.eql(u8, key, "icon") or std.mem.eql(u8, key, "img")) {
                    if (asset != null) return error.InvalidSyntax;
                    const registry = self.assets orelse return error.MissingAsset;
                    asset = try registry.get(value);
                } else if (std.mem.eql(u8, key, "h") or std.mem.eql(u8, key, "w")) {
                    const n = try document.number(value);
                    if (n < 1 or n > 4096 or @floor(n) != n) return error.InvalidSyntax;
                    if (std.mem.eql(u8, key, "h")) asset_height = @intFromFloat(n) else asset_width = @intFromFloat(n);
                    asset_options = true;
                } else if (std.mem.eql(u8, key, "pos")) {
                    if (!std.mem.eql(u8, value, "t") and !std.mem.eql(u8, value, "b")) return error.InvalidSyntax;
                    asset_top = std.mem.eql(u8, value, "t");
                    asset_options = true;
                } else if (std.mem.eql(u8, key, "form")) {
                    if (!std.mem.eql(u8, value, "square") and !std.mem.eql(u8, value, "rounded") and !std.mem.eql(u8, value, "circle")) return error.UnsupportedSyntax;
                    asset_form = value;
                    asset_options = true;
                } else if (std.mem.eql(u8, key, "constraint")) {
                    if (!std.mem.eql(u8, value, "on") and !std.mem.eql(u8, value, "off")) return error.InvalidSyntax;
                    asset_options = true;
                } else return error.UnsupportedSyntax;
            }
            if (!seen_shape and !seen_label and collapsed == null and asset == null) return error.InvalidSyntax;
            if (asset_options and asset == null) return error.InvalidSyntax;
            if (asset != null and !seen_label) {
                label = "";
                explicit = true;
            }
            pos.* += 1;
        }
        var class_names: []const u8 = "";
        skip(source, pos);
        if (std.mem.startsWith(u8, source[pos.*..], ":::")) {
            pos.* += 3;
            const class_start = pos.*;
            while (pos.* < source.len and (std.ascii.isAlphanumeric(source[pos.*]) or source[pos.*] == '_' or source[pos.*] == ',')) pos.* += 1;
            if (pos.* == class_start) return error.InvalidSyntax;
            class_names = source[class_start..pos.*];
        }
        for (self.nodes.items, 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.id, id)) {
                if (explicit) {
                    existing.label = label;
                    existing.markdown = markdown;
                }
                if (explicit_shape) existing.shape = shape;
                if (collapsed) |value| existing.collapsed = value;
                if (asset) |item| {
                    existing.asset = item;
                    existing.asset_height = asset_height;
                    existing.asset_width = asset_width orelse @as(usize, @intFromFloat(@max(1, @min(4096, item.width / item.height * @as(f64, @floatFromInt(asset_height))))));
                    if (std.mem.eql(u8, asset_form, "circle")) {
                        existing.asset_height = @max(existing.asset_height, existing.asset_width);
                        existing.asset_width = existing.asset_height;
                    }
                    existing.asset_form = asset_form;
                    existing.asset_top = asset_top;
                }
                if (class_names.len > 0) existing.classes = try self.joinClasses(existing.classes, class_names);
                if (self.depth > 0 and existing.parent == null and !existing.container) existing.parent = self.stack[self.depth - 1];
                return index;
            }
        }
        if (self.nodes.items.len >= 256) return error.LimitExceeded;
        try self.nodes.append(self.allocator, .{ .id = id, .label = label, .shape = shape, .parent = if (self.depth > 0) self.stack[self.depth - 1] else null, .classes = class_names, .markdown = markdown, .collapsed = collapsed orelse false, .asset = asset, .asset_height = asset_height, .asset_width = asset_width orelse if (asset) |item| @as(usize, @intFromFloat(@max(1, @min(4096, item.width / item.height * @as(f64, @floatFromInt(asset_height)))))) else 64, .asset_top = asset_top, .asset_form = asset_form, .assets = self.assets });
        if (asset != null and std.mem.eql(u8, asset_form, "circle")) {
            const n = &self.nodes.items[self.nodes.items.len - 1];
            n.asset_height = @max(n.asset_height, n.asset_width);
            n.asset_width = n.asset_height;
        }
        return self.nodes.items.len - 1;
    }
    const Group = struct { items: [256]usize = undefined, len: usize = 0 };
    fn group(self: *Parser, source: []const u8, pos: *usize) Error!Group {
        var result: Group = .{};
        while (true) {
            if (result.len == result.items.len) return error.LimitExceeded;
            result.items[result.len] = try self.node(source, pos);
            result.len += 1;
            skip(source, pos);
            if (pos.* == source.len or source[pos.*] != '&') break;
            pos.* += 1;
        }
        return result;
    }
    pub fn statement(self: *Parser, source: []const u8) Error!void {
        if (std.mem.startsWith(u8, source, "click ") or std.mem.startsWith(u8, source, "callback ") or std.mem.startsWith(u8, source, "link ")) return @import("interaction.zig").parse(self, source);
        if (std.mem.indexOf(u8, source, "@{")) |at| {
            const id = document.trim(source[0..at]);
            for (self.edges.items) |*edge| if (edge.id.len > 0 and std.mem.eql(u8, id, edge.id)) {
                if (!std.mem.endsWith(u8, source, "}")) return error.InvalidSyntax;
                var parts: data.Parts = .{ .rest = source[at + 2 .. source.len - 1] };
                while (try parts.next()) |part| {
                    const colon = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidSyntax;
                    const key = document.trim(part[0..colon]);
                    const value = document.unquote(part[colon + 1 ..]);
                    if (std.mem.eql(u8, key, "animate")) {
                        if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.InvalidSyntax;
                        edge.style.animation = if (std.mem.eql(u8, value, "true")) 2 else 0;
                    } else if (std.mem.eql(u8, key, "animation")) {
                        edge.style.animation = if (std.mem.eql(u8, value, "fast")) 1 else if (std.mem.eql(u8, value, "slow")) 2 else return error.UnsupportedSyntax;
                    } else if (std.mem.eql(u8, key, "curve")) {
                        edge.curve = std.meta.stringToEnum(links.Curve, value) orelse return error.UnsupportedSyntax;
                        edge.curve_explicit = true;
                    } else return error.UnsupportedSyntax;
                }
                return;
            };
        }
        if (std.mem.startsWith(u8, source, "classDef ")) {
            const cls = try styles.graphClass(source[9..]);
            var names = std.mem.splitScalar(u8, cls.name, ',');
            while (names.next()) |raw_name| {
                const name = document.trim(raw_name);
                if (name.len == 0) return error.InvalidSyntax;
                if (self.classes.items.len == 128) return error.LimitExceeded;
                try self.classes.append(self.allocator, .{ .name = name, .style = cls.style });
            }
            return;
        }
        if (std.mem.startsWith(u8, source, "linkStyle ")) {
            try self.linkStyle(source[10..]);
            return;
        }
        if (std.mem.startsWith(u8, source, "class ") or std.mem.startsWith(u8, source, "style ")) {
            if (self.bindings.items.len == 512) return error.LimitExceeded;
            const is_class = std.mem.startsWith(u8, source, "class ");
            const rest = document.trim(source[6..]);
            const space = (if (is_class) std.mem.lastIndexOfAny(u8, rest, " \t") else std.mem.indexOfAny(u8, rest, " \t")) orelse return error.InvalidSyntax;
            const ids = rest[0..space];
            const value = document.trim(rest[space + 1 ..]);
            if (value.len == 0) return error.InvalidSyntax;
            try self.bindings.append(self.allocator, if (is_class) .{ .ids = ids, .classes = value } else .{ .ids = ids, .style = try styles.parseGraph(value) });
            return;
        }
        if (std.mem.startsWith(u8, source, "subgraph ")) {
            if (self.depth == self.stack.len) return error.LimitExceeded;
            const header = document.trim(source[9..]);
            if (header.len == 0) return error.InvalidSyntax;
            const open = std.mem.indexOfScalar(u8, header, '[');
            const id = if (open) |at| document.trim(header[0..at]) else document.unquote(header);
            if (id.len == 0) return error.InvalidSyntax;
            var label = id;
            if (open) |at| {
                if (header[header.len - 1] != ']') return error.InvalidSyntax;
                label = document.unquote(header[at + 1 .. header.len - 1]);
            }
            const markdown = isMarkdown(label);
            label = try self.parseLabel(label);
            const parent = if (self.depth > 0) self.stack[self.depth - 1] else null;
            var found: ?usize = null;
            for (self.nodes.items, 0..) |existing, i| if (std.mem.eql(u8, existing.id, id)) {
                found = i;
            };
            if (found) |i| {
                if (self.nodes.items[i].container) return error.InvalidSyntax;
                self.nodes.items[i].container = true;
                self.nodes.items[i].label = label;
                self.nodes.items[i].markdown = markdown;
                self.nodes.items[i].parent = parent;
            } else {
                if (self.nodes.items.len == 256) return error.LimitExceeded;
                found = self.nodes.items.len;
                try self.nodes.append(self.allocator, .{ .id = id, .label = label, .container = true, .parent = parent, .markdown = markdown, .assets = self.assets });
            }
            self.stack[self.depth] = found.?;
            self.depth += 1;
            self.containers += 1;
            return;
        }
        if (std.mem.eql(u8, source, "end")) {
            if (self.depth == 0) return error.InvalidSyntax;
            self.depth -= 1;
            return;
        }
        if (std.mem.startsWith(u8, source, "direction ")) {
            const dir = if (std.mem.eql(u8, self.kind, "flowchart")) directionAlias(document.trim(source[10..])) else document.trim(source[10..]);
            if (!compound.validDirection(dir)) return error.InvalidSyntax;
            if (self.depth == 0) self.direction_override = dir else self.nodes.items[self.stack[self.depth - 1]].direction = dir;
            return;
        }
        var pos: usize = 0;
        var from = try self.group(source, &pos);
        while (true) {
            skip(source, &pos);
            if (pos == source.len or std.mem.startsWith(u8, source[pos..], "%%")) return;
            var id: []const u8 = "";
            const id_start = pos;
            var id_end = pos;
            while (id_end < source.len and (std.ascii.isAlphanumeric(source[id_end]) or source[id_end] == '_')) id_end += 1;
            if (id_end > id_start and id_end < source.len and source[id_end] == '@') {
                id = source[id_start..id_end];
                pos = id_end + 1;
                // A repeated ID belongs to its first edge; subsequent edges
                // still exist but receive only our generated SVG identity.
                for (self.edges.items) |edge| if (std.mem.eql(u8, edge.id, id)) {
                    id = "";
                    break;
                };
                for (self.nodes.items) |n| if (std.mem.eql(u8, n.id, id)) return error.InvalidSyntax;
            }
            var link = try links.parse(source, &pos);
            link.markdown = isMarkdown(link.label);
            link.label = try self.parseLabel(link.label);
            const to = try self.group(source, &pos);
            if (self.edges.items.len + from.len * to.len > 512) return error.LimitExceeded;
            for (from.items[0..from.len], 0..) |a, from_index| for (to.items[0..to.len], 0..) |b, to_index| {
                // In grouped links the explicit ID attaches to the last
                // source and first destination, matching the grammar binding.
                const edge_id = if (from_index + 1 == from.len and to_index == 0) id else "";
                try self.edges.append(self.allocator, .{ .from = a, .to = b, .link = link, .id = edge_id, .curve = self.default_curve orelse .smooth, .curve_explicit = self.default_curve != null });
            };
            from = to;
        }
    }
    fn linkStyle(self: *Parser, raw: []const u8) Error!void {
        const rest = document.trim(raw);
        var at: usize = 0;
        const all = std.mem.startsWith(u8, rest, "default ") or std.mem.startsWith(u8, rest, "default\t");
        var indices: [512]usize = undefined;
        var count: usize = 0;
        if (all) {
            at = 7;
        } else {
            while (true) {
                skip(rest, &at);
                const begin = at;
                while (at < rest.len and std.ascii.isDigit(rest[at])) at += 1;
                if (begin == at) return error.InvalidSyntax;
                const index = std.fmt.parseInt(usize, rest[begin..at], 10) catch return error.InvalidSyntax;
                if (index >= self.edges.items.len) return error.InvalidSyntax;
                if (count == indices.len) return error.LimitExceeded;
                indices[count] = index;
                count += 1;
                skip(rest, &at);
                if (at == rest.len or rest[at] != ',') break;
                at += 1;
            }
        }
        var value = document.trim(rest[at..]);
        var curve: ?links.Curve = null;
        if (std.mem.startsWith(u8, value, "interpolate ") or std.mem.startsWith(u8, value, "interpolate\t")) {
            value = document.trim(value[12..]);
            const end = std.mem.indexOfAny(u8, value, " \t") orelse value.len;
            curve = std.meta.stringToEnum(links.Curve, value[0..end]) orelse return error.UnsupportedSyntax;
            value = document.trim(value[end..]);
        }
        if (value.len == 0 and curve == null) return error.InvalidSyntax;
        const style = if (value.len > 0) try styles.parseGraph(value) else styles.Style{};
        if (all) {
            if (value.len > 0) self.default_edge_style = style;
            if (curve) |c| self.default_curve = c;
        } else for (indices[0..count]) |index| {
            if (value.len > 0) self.edges.items[index].index_style = style;
            if (curve) |c| {
                self.edges.items[index].curve = c;
                self.edges.items[index].curve_explicit = true;
            }
        }
    }
    pub fn collapse(self: *Parser) Error!void {
        var replacement: [256]usize = undefined;
        var map: [256]usize = undefined;
        for (self.nodes.items, 0..) |n, i| {
            if (n.collapsed and !n.container) return error.InvalidSyntax;
            replacement[i] = i;
            var parent = n.parent;
            var depth: usize = 0;
            while (parent) |p| {
                if (depth == 16) return error.LimitExceeded;
                depth += 1;
                if (self.nodes.items[p].collapsed) replacement[i] = p;
                parent = self.nodes.items[p].parent;
            }
        }
        var count: usize = 0;
        for (self.nodes.items, 0..) |_, i| if (replacement[i] == i) {
            map[i] = count;
            count += 1;
        };
        for (self.nodes.items, 0..) |_, i| map[i] = map[replacement[i]];
        var edge_count: usize = 0;
        for (self.edges.items) |edge| {
            var e = edge;
            e.from = map[e.from];
            e.to = map[e.to];
            if (e.from == e.to and (replacement[edge.from] != edge.from or replacement[edge.to] != edge.to)) continue;
            self.edges.items[edge_count] = e;
            edge_count += 1;
        }
        self.edges.items.len = edge_count;
        count = 0;
        self.containers = 0;
        for (0..self.nodes.items.len) |i| {
            var n = self.nodes.items[i];
            if (replacement[i] != i) {
                n.members.deinit(self.allocator);
                continue;
            }
            if (n.parent) |p| n.parent = map[p];
            if (n.note_for) |p| n.note_for = map[p];
            if (n.collapsed) {
                n.container = false;
                n.shape = .round;
            }
            if (n.container) self.containers += 1;
            self.nodes.items[count] = n;
            count += 1;
        }
        self.nodes.items.len = count;
    }
};
fn skip(text: []const u8, pos: *usize) void {
    while (pos.* < text.len and std.mem.indexOfScalar(u8, " \t\r\n", text[pos.*]) != null) pos.* += 1;
}

fn bodyStatement(parser: *Parser, statement: []const u8, doc: ?*document.Document) Error!void {
    if (doc) |value| {
        if (std.mem.startsWith(u8, statement, "accTitle:")) {
            value.acc_title = document.trim(statement[9..]);
            return;
        }
        if (std.mem.startsWith(u8, statement, "accDescr:")) {
            value.acc_description = document.trim(statement[9..]);
            return;
        }
    }
    try parser.statement(statement);
}
pub fn parseBody(parser: *Parser, source: []const u8, doc: ?*document.Document) Error!void {
    if (doc) |value| {
        parser.wrap_markdown = try value.flag("config.markdownAutoWrap", true);
        parser.wrapping_width = @intFromFloat(try value.num("config.flowchart.wrappingWidth", 230, 16, 2000));
        if (std.mem.eql(u8, parser.kind, "flowchart")) parser.diagram_padding = @intFromFloat(try value.num("config.flowchart.diagramPadding", 16, 0, 2000));
        parser.node_spacing = @intFromFloat(try value.num("config.flowchart.nodeSpacing", 40, 0, 2000));
        parser.inherit_direction = try value.flag("config.flowchart.inheritDir", false);
        parser.rank_spacing = @intFromFloat(try value.num("config.flowchart.rankSpacing", 45, 0, 2000));
        parser.title_margin_top = @intFromFloat(try value.num("config.flowchart.subGraphTitleMargin.top", 0, 0, 2000));
        parser.title_margin_bottom = @intFromFloat(try value.num("config.flowchart.subGraphTitleMargin.bottom", 0, 0, 2000));
    }
    if (doc) |value| if (value.get("config.flowchart.curve")) |curve| {
        parser.config_curve = std.meta.stringToEnum(links.Curve, curve) orelse return error.UnsupportedSyntax;
    };
    var start: usize = 0;
    var index = start;
    var quote = false;
    var pipe = false;
    var brackets: usize = 0;
    while (index <= source.len) : (index += 1) {
        if (!quote and !pipe and brackets == 0 and index < source.len and std.mem.startsWith(u8, source[index..], "%%")) {
            if (std.mem.startsWith(u8, source[index..], "%%{")) return error.UnsupportedSyntax;
            const before_comment = std.mem.trim(u8, source[start..index], " \t\r");
            if (before_comment.len > 0) try bodyStatement(parser, before_comment, doc);
            while (index < source.len and source[index] != '\n') index += 1;
            start = index + 1;
            continue;
        }
        const byte: u8 = if (index == source.len) '\n' else source[index];
        if (byte == '"') quote = !quote;
        if (!quote and brackets == 0 and byte == '|') pipe = !pipe;
        if (!quote and !pipe) {
            if (byte == '>' and brackets == 0 and index > start) {
                var before = index;
                while (before > start and (source[before - 1] == ' ' or source[before - 1] == '\t')) before -= 1;
                const directive = std.mem.eql(u8, document.trim(source[start..index]), "direction");
                if (!directive and before > start) {
                    const previous = source[before - 1];
                    const prior = if (before > start + 1) source[before - 2] else 0;
                    const id_hyphen = previous == '-' and (std.ascii.isAlphanumeric(prior) or prior == '_' or prior >= 128);
                    if (std.ascii.isAlphanumeric(previous) or previous == '_' or previous >= 128 or id_hyphen) brackets += 1;
                }
            }
            if (byte == '[' or byte == '(' or byte == '{') brackets += 1;
            if (byte == ']' or byte == ')' or byte == '}') {
                if (brackets == 0) return error.InvalidSyntax;
                brackets -= 1;
            }
        }
        if (!quote and !pipe and brackets == 0 and (byte == '\n' or byte == ';')) {
            if (byte == '\n' and index < source.len) {
                const next = std.mem.trimStart(u8, source[index + 1 ..], " \t\r\n");
                var continuation = false;
                for ([_][]const u8{ "--", "-.", "==", "~~~", "<--", "<==", "o--", "x--", "o-.", "x-." }) |prefix| if (std.mem.startsWith(u8, next, prefix)) {
                    continuation = true;
                };
                if (continuation) continue;
            }
            const statement = std.mem.trim(u8, source[start..index], " \t\r");
            if (std.mem.startsWith(u8, statement, "%%{")) return error.UnsupportedSyntax;
            if (statement.len > 0 and !std.mem.startsWith(u8, statement, "%%")) try bodyStatement(parser, statement, doc);
            start = index + 1;
        }
    }
    if (quote or pipe or brackets > 0) return error.InvalidSyntax;
    if (parser.depth != 0) return error.InvalidSyntax;
    if (parser.nodes.items.len == 0) return error.InvalidSyntax;
    try parser.resolveStyles();
}

pub fn render(allocator: std.mem.Allocator, source: []const u8, theme: svg.Theme, prefix: u32) Error![]u8 {
    return renderWithDocument(allocator, source, theme, prefix, null);
}
pub fn renderDocument(allocator: std.mem.Allocator, doc: *document.Document, prefix: u32) Error![]u8 {
    _ = try doc.flag("config.htmlLabels", false);
    _ = try doc.flag("config.flowchart.htmlLabels", false);
    return renderWithDocument(allocator, doc.source, doc.theme, prefix, doc);
}

/// Emits a JSON snapshot of the parsed layout input.
/// Exports phase boundaries through placement; routing is audited via SVG.
pub fn measurementTrace(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    var doc = try document.Document.parse(allocator, input, .light);
    const source = doc.source;
    const header_end = std.mem.indexOfAny(u8, source, ";\n") orelse source.len;
    var parser: Parser = .{ .allocator = allocator, .assets = &doc.assets };
    defer parser.deinit();
    try parseBody(&parser, source[@min(header_end + 1, source.len)..], &doc);
    try parser.collapse();
    try doc.graphTheme(&parser);
    try parser.wrapLabels();
    if (parser.containers > 0) return error.UnsupportedSyntax;
    const MeasuredNode = struct { id: []const u8, shape: []const u8, label: []const u8, markdown: bool, width: usize, height: usize, text_width: usize, text_height: usize, font_size: f64 };
    const MeasuredEdge = struct { index: usize, source: []const u8, target: []const u8, label: []const u8, markdown: bool, width: usize, height: usize };
    const nodes = try allocator.alloc(MeasuredNode, parser.nodes.items.len);
    defer allocator.free(nodes);
    const edges = try allocator.alloc(MeasuredEdge, parser.edges.items.len);
    defer allocator.free(edges);
    for (parser.nodes.items, 0..) |node, i| {
        const size = layout.nodeSize(node);
        nodes[i] = .{ .id = node.id, .shape = @tagName(node.shape), .label = node.label, .markdown = node.markdown, .width = size.w, .height = size.h, .text_width = node.style.measure(paint.labelWidth(node.label, node.markdown)), .text_height = node.style.measure(paint.labelHeight(node.label)), .font_size = node.style.font_size orelse 14 };
    }
    for (parser.edges.items, 0..) |edge, i| edges[i] = .{ .index = i, .source = parser.nodes.items[edge.from].id, .target = parser.nodes.items[edge.to].id, .label = edge.link.label, .markdown = edge.link.markdown, .width = if (edge.link.label.len == 0) 0 else edge.style.measure(paint.labelWidth(edge.link.label, edge.link.markdown)), .height = if (edge.link.label.len == 0) 0 else edge.style.measure(paint.labelHeight(edge.link.label)) };
    return std.json.Stringify.valueAlloc(allocator, .{ .schema = "zmermaid-measurement-trace-v1", .nodes = nodes, .edges = edges, .font_family = if (doc.font_family.len > 0) doc.font_family else "Arial,Helvetica,sans-serif", .wrapping_width = parser.wrapping_width }, .{});
}

/// Font-engine requests, independent of the reference renderer or its output.
/// Family adapters stop at semantics; geometry is owned by the shared pipeline.
fn parseMeasured(parser: *Parser, doc: *document.Document) Error![]const u8 {
    const source = std.mem.trimStart(u8, doc.source, " \t\r\n");
    const header_end = std.mem.indexOfAny(u8, source, ";\n") orelse source.len;
    var header = std.mem.tokenizeAny(u8, source[0..header_end], " \t\r");
    const kind = header.next() orelse return error.InvalidSyntax;
    if (std.mem.eql(u8, kind, "stateDiagram") or std.mem.eql(u8, kind, "stateDiagram-v2")) {
        if (header.next() != null) return error.UnsupportedSyntax;
        doc.source = source;
        const direction = try @import("state.zig").parse(parser, doc);
        @import("flow_hierarchy.zig").normalizeNotes(parser) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidSyntax;
        for (parser.nodes.items) |node| {
            // Multi-section descriptions need separate title/body measurements.
            // Notes and concurrent regions still require boundary-port layout.
            if (node.region or
                (node.annotation.len > 0 and !std.mem.eql(u8, node.annotation, "description") and !std.mem.eql(u8, node.annotation, "note-group")) or
                (!node.container and node.note_for == null and node.shape != .round and node.shape != .diamond and node.shape != .small_circle and node.shape != .framed_circle and node.shape != .fork)) return error.UnsupportedSyntax;
        }
        // Separate-child compounds are the first hierarchical boundary. Do
        // not flatten cross-hierarchy edges until boundary ports are ported.
        for (parser.edges.items) |edge| {
            const from = parser.nodes.items[edge.from];
            const to = parser.nodes.items[edge.to];
            _ = to;
            if (edge.from == edge.to and from.parent != null) return error.UnsupportedSyntax;
        }
        return direction;
    }
    if (!std.mem.eql(u8, kind, "flowchart") and !std.mem.eql(u8, kind, "graph") and !std.mem.eql(u8, kind, "flowchart-elk")) return error.UnsupportedSyntax;
    const direction_raw = directionAlias(header.next() orelse "TB");
    const direction = if (std.mem.eql(u8, direction_raw, "TD")) "TB" else direction_raw;
    if (header.next() != null or !compound.validDirection(direction)) return error.UnsupportedSyntax;
    try parseBody(parser, source[@min(header_end + 1, source.len)..], doc);
    try parser.collapse();
    try doc.graphTheme(parser);
    if (parser.containers > 0) return error.UnsupportedSyntax;
    return direction;
}

pub fn measurementRequest(backing_allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    if (input.len > 1024 * 1024) return error.LimitExceeded;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidSyntax;
    for (input) |byte| if (byte < 32 and byte != 9 and byte != 10 and byte != 13) return error.InvalidSyntax;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var doc = try document.Document.parse(allocator, input, .light);
    if (try doc.flag("config.htmlLabels", false) or try doc.flag("config.flowchart.htmlLabels", false)) return error.UnsupportedSyntax;
    var parser: Parser = .{ .allocator = allocator, .assets = &doc.assets, .defer_measurement = true };
    defer parser.deinit();
    const requested_direction = try parseMeasured(&parser, &doc);
    const family: @import("flow_measurement.zig").Family = if (std.mem.eql(u8, parser.kind, "state")) .state else .flowchart;
    const RequestNode = struct { id: []const u8, shape: Shape, label: []const u8, markdown: bool, font_size: f64, bold: bool, italic: bool, sections: []const []const u8, padding: ?f64 = null };
    const RequestEdge = struct { index: usize, source: []const u8, target: []const u8, label: []const u8, markdown: bool, font_size: f64 };
    const nodes = try allocator.alloc(RequestNode, parser.nodes.items.len);
    defer allocator.free(nodes);
    const edges = try allocator.alloc(RequestEdge, parser.edges.items.len);
    defer allocator.free(edges);
    for (parser.nodes.items, 0..) |node, i| {
        var sections: []const []const u8 = &.{};
        if (node.state_description_count > 1) {
            const values = try allocator.alloc([]const u8, 2);
            values[0] = node.state_title;
            values[1] = node.state_body;
            sections = values;
        }
        nodes[i] = .{ .id = node.id, .shape = node.shape, .label = node.label, .markdown = node.markdown, .font_size = node.style.font_size orelse 16, .bold = node.style.bold orelse false, .italic = node.style.italic orelse false, .sections = sections, .padding = if (node.note_for != null) try doc.num("config.flowchart.padding", 15, 0, 2000) else null };
    }
    for (parser.edges.items, 0..) |edge, i| edges[i] = .{ .index = i, .source = parser.nodes.items[edge.from].id, .target = parser.nodes.items[edge.to].id, .label = edge.link.label, .markdown = edge.link.markdown, .font_size = edge.style.font_size orelse 16 };
    // State dataFetcher.ts supplies padding:8 for each state node. ELK's
    // shape adapter does not pass state config or direction to forkJoin.
    const padding = if (family == .state) @as(f64, 8) else try doc.num("config.flowchart.padding", 15, 0, 2000);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    const request_key = std.fmt.bytesToHex(digest, .lower);
    return std.json.Stringify.valueAlloc(backing_allocator, .{ .schema = "zmermaid-measurement-request-v1", .request_key = &request_key, .nodes = nodes, .edges = edges, .font_family = if (doc.font_family.len > 0) doc.font_family else "Arial,Helvetica,sans-serif", .wrapping_width = try doc.num("config.flowchart.wrappingWidth", 200, 16, 2000), .padding = if (padding == 0) @as(f64, 8) else padding, .direction = requested_direction, .diagram_family = family }, .{});
}

/// Rebuild the request from source before accepting host measurements. No
/// cached request or reference geometry is trusted as the source of identity.
/// The caller receives fractional shape bounds; placement must not round them.
pub fn measuredGraph(backing_allocator: std.mem.Allocator, input: []const u8, shaped_text: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request_json = try measurementRequest(allocator, input);
    const measurement = @import("flow_measurement.zig");
    const result = measurement.trace(allocator, shaped_text) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSyntax,
    };
    const Request = struct {
        schema: []const u8,
        request_key: []const u8,
        nodes: []const struct { id: []const u8, shape: Shape, label: []const u8, markdown: bool, font_size: f64, bold: bool, italic: bool, sections: []const []const u8 = &.{}, padding: ?f64 = null },
        edges: []const struct { index: usize, source: []const u8, target: []const u8, label: []const u8, markdown: bool, font_size: f64 },
        font_family: []const u8,
        wrapping_width: f64,
        padding: f64,
        direction: []const u8,
        diagram_family: measurement.Family = .flowchart,
    };
    const request = (std.json.parseFromSlice(Request, allocator, request_json, .{}) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidSyntax).value;
    const shaped = (std.json.parseFromSlice(measurement.Input, allocator, shaped_text, .{}) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidSyntax).value;
    if (!std.mem.eql(u8, request.request_key, shaped.request_key orelse return error.InvalidSyntax) or
        request.nodes.len != shaped.nodes.len or request.edges.len != shaped.edges.len or
        !std.mem.eql(u8, request.font_family, shaped.font_family) or request.padding != shaped.padding or
        !std.mem.eql(u8, request.direction, shaped.direction) or
        request.diagram_family != shaped.diagram_family) return error.InvalidSyntax;
    for (request.nodes, shaped.nodes) |expected, actual| {
        if (!std.mem.eql(u8, expected.id, actual.id) or expected.shape != actual.shape or
            !std.mem.eql(u8, expected.label, actual.label) or expected.markdown != actual.markdown or
            expected.font_size != actual.font_size or expected.sections.len != actual.sections.len or expected.padding != actual.padding) return error.InvalidSyntax;
        for (expected.sections, actual.sections) |label, section| if (!std.mem.eql(u8, label, section.label) or section.font_size != expected.font_size) return error.InvalidSyntax;
    }
    for (request.edges, shaped.edges) |expected, actual| {
        if (expected.index != actual.index or !std.mem.eql(u8, expected.source, actual.source) or
            !std.mem.eql(u8, expected.target, actual.target) or !std.mem.eql(u8, expected.label, actual.label) or
            expected.markdown != actual.markdown or expected.font_size != actual.font_size) return error.InvalidSyntax;
    }
    return backing_allocator.dupe(u8, result);
}

/// Source-built fractional BK boundary. Reference captures are never inputs.
pub fn measuredPlacement(backing_allocator: std.mem.Allocator, input: []const u8, shaped_text: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try measuredGraph(a, input, shaped_text);
    const measured = (std.json.parseFromSlice(@import("flow_measurement.zig").Input, a, shaped_text, .{}) catch return error.InvalidSyntax).value;
    var compound_doc = try document.Document.parse(a, input, .light);
    var compound_parser: Parser = .{ .allocator = a, .assets = &compound_doc.assets, .defer_measurement = true };
    defer compound_parser.deinit();
    const compound_direction = try parseMeasured(&compound_parser, &compound_doc);
    for (compound_parser.nodes.items) |node| if (node.container) {
        var crossing = false;
        for (compound_parser.edges.items) |edge| if (compound_parser.nodes.items[edge.from].parent != compound_parser.nodes.items[edge.to].parent) { crossing = true; };
        const scene = (if (crossing) @import("flow_measured_boundary.zig").compute(a, &compound_parser, measured, compound_direction) else @import("flow_measured_compound.zig").compute(a, &compound_parser, measured, compound_direction)) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.UnsupportedSyntax;
        return std.json.Stringify.valueAlloc(backing_allocator, .{ .schema = "zmermaid-measured-placement-v1", .request_key = measured.request_key, .hierarchical = true, .scene = scene }, .{});
    };
    const ordering = try rankTrace(a, input);
    const Phase = struct {
        nodes: []const struct { id: []const u8, rank: usize },
        edges: []const struct { index: usize, source: []const u8, target: []const u8 },
        positioned: []const layout.PositionedEntry,
        port_order: []const layout.OrderedArc,
        routing_random_state_after_ordering: u64,
    };
    const phase = (std.json.parseFromSlice(Phase, a, ordering, .{ .ignore_unknown_fields = true }) catch return error.InvalidSyntax).value;
    const pipeline = @import("flow_measured_layout.zig");
    const ranks = try a.alloc(usize, phase.nodes.len);
    const edges = try a.alloc(pipeline.Edge, phase.edges.len);
    for (phase.nodes, 0..) |node, id| {
        if (!std.mem.eql(u8, node.id, measured.nodes[id].id)) return error.InvalidSyntax;
        ranks[id] = node.rank;
    }
    for (phase.edges, 0..) |edge, id| {
        var from: ?usize = null;
        var to: ?usize = null;
        for (phase.nodes, 0..) |node, index| {
            if (std.mem.eql(u8, edge.source, node.id)) from = index;
            if (std.mem.eql(u8, edge.target, node.id)) to = index;
        }
        edges[id] = .{ .from = from orelse return error.InvalidSyntax, .to = to orelse return error.InvalidSyntax };
    }
    const placed = pipeline.compute(a, measured, edges, ranks, phase.positioned, phase.port_order, 40, 20, 4) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.UnsupportedSyntax;
    const routed = @import("flow_orthogonal.zig").compute(a, placed, phase.routing_random_state_after_ordering) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.UnsupportedSyntax;
    const scene = @import("flow_scene.zig").compute(a, measured, placed, routed, phase.port_order) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.UnsupportedSyntax;
    return std.json.Stringify.valueAlloc(backing_allocator, .{ .schema = "zmermaid-measured-placement-v1", .request_key = measured.request_key, .nodes = placed.nodes, .graph = placed.graph, .cross = placed.cross, .real = placed.real, .edge = placed.edge, .gaps = placed.gaps, .ordered_arcs = phase.port_order, .routing_random_state = phase.routing_random_state_after_ordering, .routing = routed, .scene = scene }, .{});
}

/// The measured pipeline is opt-in; unsupported graph families remain explicit.
pub fn renderMeasured(backing_allocator: std.mem.Allocator, input: []const u8, shaped_text: []const u8, theme: svg.Theme, prefix: u32) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try measuredPlacement(a, input, shaped_text);
    const graph = (std.json.parseFromSlice(struct { scene: @import("flow_scene.zig").Scene }, a, result, .{ .ignore_unknown_fields = true }) catch return error.InvalidSyntax).value.scene;
    const measured = (std.json.parseFromSlice(@import("flow_measurement.zig").Input, a, shaped_text, .{}) catch return error.InvalidSyntax).value;
    var doc = try document.Document.parse(a, input, theme);
    var parser: Parser = .{ .allocator = a, .assets = &doc.assets, .defer_measurement = true };
    defer parser.deinit();
    _ = try parseMeasured(&parser, &doc);
    // Interaction/media need their existing specialized SVG path, not a silent approximation.
    if (doc.sketch) return error.UnsupportedSyntax;
    for (parser.nodes.items) |node| if (node.asset != null or node.action.href.len > 0 or node.action.callback.len > 0 or node.action.tooltip.len > 0 or paint.hasMedia(node.label)) return error.UnsupportedSyntax;
    for (parser.edges.items) |edge| if (paint.hasMedia(edge.link.label)) return error.UnsupportedSyntax;
    const rendered = @import("flow_measured_svg.zig").render(a, measured, graph, parser.nodes.items, parser.edges.items, theme, prefix) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.UnsupportedSyntax;
    return backing_allocator.dupe(u8, rendered);
}

test "host measurements are bound to the parsed source, not a previous request" {
    const source = "flowchart LR\nA[Hi]";
    const shaped = "{\"schema\":\"zmermaid-shaped-text-v1\",\"nodes\":[{\"id\":\"A\",\"shape\":\"box\",\"label\":\"Hi\",\"markdown\":false,\"text_width\":10.125,\"text_height\":17,\"font_size\":16,\"lines\":[\"Hi\"]}],\"edges\":[],\"font_family\":\"Arial,Helvetica,sans-serif\",\"padding\":15,\"direction\":\"LR\"}";
    const request_json = try measurementRequest(std.testing.allocator, source);
    defer std.testing.allocator.free(request_json);
    var request = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request_json, .{});
    defer request.deinit();
    const key_field = try std.fmt.allocPrint(std.testing.allocator, "\"request_key\":\"{s}\",\"nodes\":", .{request.value.object.get("request_key").?.string});
    defer std.testing.allocator.free(key_field);
    const valid = try std.mem.replaceOwned(u8, std.testing.allocator, shaped, "\"nodes\":", key_field);
    defer std.testing.allocator.free(valid);
    const result = try measuredGraph(std.testing.allocator, source, valid);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "70.125") != null);
    try std.testing.expectError(error.InvalidSyntax, measuredGraph(std.testing.allocator, "flowchart LR\nA[Different]", valid));
    try std.testing.expectError(error.InvalidSyntax, measuredGraph(std.testing.allocator, "flowchart TB\nA[Hi]", shaped));
    try std.testing.expectError(error.UnsupportedSyntax, measurementRequest(std.testing.allocator, "sequenceDiagram\nA->>B: Hi"));
    try std.testing.expectError(error.UnsupportedSyntax, measurementRequest(std.testing.allocator, "flowchart XY\nA[Hi]"));
}

test "font requests release parsed document allocations and preserve unwrapped labels" {
    const request = try measurementRequest(std.testing.allocator, "---\nconfig: {\"fontFamily\":\"Arial\",\"flowchart\":{\"wrappingWidth\":80}}\n---\nflowchart LR\nA[\"`A long **bold** sentence that must not be wrapped by the old estimator`\"] -->|Yes| B[Peer]");
    defer std.testing.allocator.free(request);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{});
    defer parsed.deinit();
    const node = parsed.value.object.get("nodes").?.array.items[0].object;
    try std.testing.expectEqualStrings("A long **bold** sentence that must not be wrapped by the old estimator", node.get("label").?.string);
    try std.testing.expectEqualStrings("Arial", parsed.value.object.get("font_family").?.string);
    try std.testing.expectEqual(@as(i64, 80), parsed.value.object.get("wrapping_width").?.integer);
}

pub fn rankTrace(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    var doc = try document.Document.parse(allocator, input, .light);
    var parser: Parser = .{ .allocator = allocator, .assets = &doc.assets };
    defer parser.deinit();
    const direction = try parseMeasured(&parser, &doc);
    try parser.wrapLabels();
    for (parser.nodes.items) |node| if (node.container) return error.UnsupportedSyntax;
    return rankTraceParser(allocator, &parser, direction);
}

/// The exact same discrete pipeline for a source-built hierarchy level.
/// Children are not reparsed as generated Mermaid strings.
pub fn rankTraceParser(allocator: std.mem.Allocator, parser: *Parser, direction: []const u8) Error![]u8 {

    const flow_rank = @import("flow_rank.zig");
    var simplex_detail: flow_rank.SimplexDetail = .{};
    const reversed = flow_rank.assignDetailed(parser.nodes.items, parser.edges.items, &simplex_detail);
    // Hierarchical WEST/EAST dummy constraints: first/last layer. External
    // outputs cannot share an early layer with an ordinary target branch.
    var last_rank: usize = 0;
    for (parser.nodes.items) |node| last_rank = @max(last_rank, node.rank);
    for (parser.nodes.items) |*node| if (node.external_input) |input_port| { node.rank = if (input_port) 0 else last_rank; };
    const TraceNode = struct { id: []const u8, rank: usize };
    const TraceEdge = struct {
        index: usize,
        id: []const u8,
        source: []const u8,
        target: []const u8,
        label: []const u8,
        min_length: usize,
        reversed: bool,
    };
    const TraceVirtualNode = struct {
        source_edge: usize,
        segment: usize,
        rank: isize,
        label_dummy: bool,
    };
    const TraceOrderEntry = struct {
        rank: usize,
        position: usize,
        real: ?[]const u8 = null,
        source_edge: ?usize = null,
        label_dummy: bool = false,
    };
    var nodes = try allocator.alloc(TraceNode, parser.nodes.items.len);
    defer allocator.free(nodes);
    var edges = try allocator.alloc(TraceEdge, parser.edges.items.len);
    defer allocator.free(edges);
    const virtual_count = if (simplex_detail.node_count > simplex_detail.real_node_count)
        simplex_detail.node_count - simplex_detail.real_node_count
    else
        0;
    var virtual_nodes = try allocator.alloc(TraceVirtualNode, virtual_count);
    defer allocator.free(virtual_nodes);
    var label_rank_hints = [_]?usize{null} ** 256;
    for (parser.nodes.items, 0..) |node, index| nodes[index] = .{ .id = node.id, .rank = node.rank };
    for (parser.edges.items, 0..) |edge, index| edges[index] = .{
        .index = index,
        .id = edge.id,
        .source = parser.nodes.items[edge.from].id,
        .target = parser.nodes.items[edge.to].id,
        .label = edge.link.label,
        .min_length = edge.link.length + @as(usize, @intFromBool(edge.link.label.len > 0)),
        .reversed = reversed[index],
    };
    var virtual_index: usize = 0;
    for (simplex_detail.real_node_count..simplex_detail.node_count) |node| {
        const source_edge = simplex_detail.source_edge[node] orelse continue;
        virtual_nodes[virtual_index] = .{
            .source_edge = source_edge,
            .segment = simplex_detail.segment[node],
            .rank = simplex_detail.ranks[node],
            .label_dummy = simplex_detail.label_dummy[node],
        };
        virtual_index += 1;
        if (simplex_detail.label_dummy[node] and source_edge < label_rank_hints.len)
            label_rank_hints[source_edge] = @intCast(simplex_detail.ranks[node]);
    }
    var order_ids: [256]usize = undefined;
    for (parser.nodes.items, 0..) |*node, index| {
        order_ids[index] = index;
        const size = layout.nodeSize(node.*);
        node.w = size.w;
        node.h = size.h;
    }
    const horizontal = std.mem.eql(u8, direction, "LR") or std.mem.eql(u8, direction, "RL");
    var order_guide = try layout.orderWithSides(allocator, parser.nodes.items, parser.edges.items, order_ids[0..parser.nodes.items.len], horizontal, parser.node_spacing, label_rank_hints[0..parser.edges.items.len], simplex_detail.random_state, &simplex_detail, true, parser.ordering_model, parser.ordering_parent_state, parser.ordering_sides);
    defer allocator.free(order_guide.arcs);
    defer allocator.free(order_guide.positioned);
    defer allocator.free(order_guide.sweep_random_states);
    defer allocator.free(order_guide.sweep_random_bits);
    var ordered = try allocator.alloc(TraceOrderEntry, order_guide.order_count);
    defer allocator.free(ordered);
    var model_ordered = try allocator.alloc(TraceOrderEntry, order_guide.model_order_count);
    defer allocator.free(model_ordered);
    var initial_ordered = try allocator.alloc(TraceOrderEntry, order_guide.initial_order_count);
    defer allocator.free(initial_ordered);
    for (order_guide.initial_order[0..order_guide.initial_order_count], 0..) |entry, index| initial_ordered[index] = .{
        .rank = entry.rank,
        .position = entry.position,
        .real = if (entry.real) |real| parser.nodes.items[real].id else null,
        .source_edge = entry.edge,
        .label_dummy = entry.label,
    };
    for (order_guide.order[0..order_guide.order_count], 0..) |entry, index| ordered[index] = .{
        .rank = entry.rank,
        .position = entry.position,
        .real = if (entry.real) |real| parser.nodes.items[real].id else null,
        .source_edge = entry.edge,
        .label_dummy = entry.label,
    };
    for (order_guide.model_order[0..order_guide.model_order_count], 0..) |entry, index| model_ordered[index] = .{
        .rank = entry.rank,
        .position = entry.position,
        .real = if (entry.real) |real| parser.nodes.items[real].id else null,
        .source_edge = entry.edge,
        .label_dummy = entry.label,
    };
    const endpoint_ports = try layout.endpointPorts(parser.edges.items, &reversed, order_guide.arcs[0..order_guide.arc_count]);
    _ = layout.place(parser.nodes.items, order_ids[0..parser.nodes.items.len], horizontal, std.mem.eql(u8, direction, "RL") or std.mem.eql(u8, direction, "BT"), parser.node_spacing, parser.rank_spacing, null, &order_guide);
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "zmermaid-layout-phase-v1",
        .engine = "zmermaid",
        .phase = "cycle-break-and-layering",
        .direction = direction,
        .random_state_after_cycle_breaking = simplex_detail.random_state,
        .nodes = nodes,
        .edges = edges,
        .virtual_nodes = virtual_nodes[0..virtual_index],
        .order = ordered,
        .model_order = model_ordered,
        .initial_order = initial_ordered,
        .port_order = order_guide.arcs[0..order_guide.arc_count],
        .endpoint_ports = endpoint_ports,
        .positioned = order_guide.positioned,
        .sweep_random_states = order_guide.sweep_random_states[0..order_guide.sweep_random_count],
        .sweep_random_bits = order_guide.sweep_random_bits[0..order_guide.sweep_random_count],
        .routing_random_state_after_ordering = order_guide.routing_random_state,
    }, .{});
}
fn directionAlias(direction: []const u8) []const u8 {
    if (direction.len == 1) return switch (direction[0]) {
        '>' => "LR",
        '<' => "RL",
        '^' => "BT",
        'v' => "TB",
        else => direction,
    };
    return direction;
}

fn spreadPort(start: usize, extent: usize, ordinal: usize, count: usize) usize {
    if (count <= 1) return start + extent / 2;
    return start + extent * (ordinal + 1) / (count + 1);
}

fn forwardLabel(x1: usize, y1: usize, x2: usize, y2: usize, horizontal: bool) links.Point {
    if (horizontal) {
        if (y1 == y2) return links.point((x1 + x2) / 2, y1);
        const middle = (x1 + x2) / 2;
        return links.point((middle + x2) / 2, y2);
    }
    if (x1 == x2) return links.point(x1, (y1 + y2) / 2);
    const middle = (y1 + y2) / 2;
    return links.point(x2, (middle + y2) / 2);
}

fn directionalSegmentLabel(points: []const links.Point, horizontal: bool) links.Point {
    var best: f64 = -1;
    var label = points[0];
    for (1..points.len) |i| {
        const a = points[i - 1];
        const b = points[i];
        const parallel = if (horizontal) @abs(b.y - a.y) < 0.001 else @abs(b.x - a.x) < 0.001;
        if (!parallel) continue;
        const length = if (horizontal) @abs(b.x - a.x) else @abs(b.y - a.y);
        if (length > best) {
            best = length;
            label = .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
        }
    }
    return label;
}

fn advanceToward(start: usize, end: usize, distance: usize) usize {
    return if (end >= start) start + @min(distance, end - start) else start -| @min(distance, start - end);
}

const GridPoint = struct { x: usize, y: usize };

fn forwardLane(start: usize, end: usize, count: usize, ordinal: usize, label_spacing: usize) usize {
    if (label_spacing > 0) return advanceToward(start, end, label_spacing * (count - ordinal));
    return (start * (count - ordinal) + end * (ordinal + 1)) / (count + 1);
}

fn strictSegmentConflict(a: GridPoint, b: GridPoint, c: GridPoint, d: GridPoint) usize {
    const ab_vertical = a.x == b.x;
    const cd_vertical = c.x == d.x;
    if (ab_vertical != cd_vertical) {
        const vx = if (ab_vertical) a.x else c.x;
        const vy1 = if (ab_vertical) a.y else c.y;
        const vy2 = if (ab_vertical) b.y else d.y;
        const hy = if (ab_vertical) c.y else a.y;
        const hx1 = if (ab_vertical) c.x else a.x;
        const hx2 = if (ab_vertical) d.x else b.x;
        return @intFromBool(vx > @min(hx1, hx2) and vx < @max(hx1, hx2) and hy > @min(vy1, vy2) and hy < @max(vy1, vy2));
    }
    if (ab_vertical and a.x == c.x) {
        // A shared corridor is substantially less legible than one discrete
        // crossing: the two connectors become indistinguishable for the full
        // overlap. ELK's routing graph prevents this by reserving separate
        // channel slots, so model the same preference in our route cost.
        return 4 * @as(usize, @intFromBool(@min(@max(a.y, b.y), @max(c.y, d.y)) > @max(@min(a.y, b.y), @min(c.y, d.y))));
    }
    if (!ab_vertical and a.y == c.y) {
        return 4 * @as(usize, @intFromBool(@min(@max(a.x, b.x), @max(c.x, d.x)) > @max(@min(a.x, b.x), @min(c.x, d.x))));
    }
    return 0;
}

fn routeConflicts(a: []const GridPoint, b: []const GridPoint) usize {
    var result: usize = 0;
    for (1..a.len) |i| for (1..b.len) |j| {
        result += strictSegmentConflict(a[i - 1], a[i], b[j - 1], b[j]);
    };
    return result;
}

fn routeNodeConflicts(route: []const GridPoint, nodes: anytype, skip_a: usize, skip_b: usize) usize {
    var result: usize = 0;
    const clearance: usize = 10;
    for (nodes, 0..) |node, node_i| {
        if (node_i == skip_a or node_i == skip_b) continue;
        const left = node.x -| clearance;
        const right = node.x + node.w + clearance;
        const top = node.y -| clearance;
        const bottom = node.y + node.h + clearance;
        for (1..route.len) |segment| {
            const a = route[segment - 1];
            const b = route[segment];
            const hits = if (a.x == b.x)
                a.x > left and a.x < right and @max(a.y, b.y) > top and @min(a.y, b.y) < bottom
            else
                a.y > top and a.y < bottom and @max(a.x, b.x) > left and @min(a.x, b.x) < right;
            if (hits) result += 1;
        }
    }
    return result;
}

fn refineForwardRoutesAgainst(
    nodes: anytype,
    edges: anytype,
    horizontal: bool,
    routes: *[256][8]GridPoint,
    lengths: *[256]usize,
    present: *const [256]bool,
    obstacles: *const [256][8]GridPoint,
    obstacle_lengths: *const [256]usize,
    obstacle_present: *const [256]bool,
) void {
    for (edges, 0..) |edge, i| {
        if (!present[i]) continue;
        const from_rank = nodes[edge.from].rank;
        const to_rank = nodes[edge.to].rank;
        const rank_span = if (from_rank > to_rank) from_rank - to_rank else to_rank - from_rank;
        // Adjacent-layer edges already own a channel in that layer gap. The
        // LONG_EDGE corridor search is only for edges represented by one or
        // more dummy nodes; applying it to local edges creates needless
        // excursions across neighbouring branches.
        const proper_span = edge.link.length + @as(usize, @intFromBool(edge.link.label.len > 0));
        const start = routes[i][0];
        const end = routes[i][lengths[i] - 1];
        const initial_node_conflicts = routeNodeConflicts(routes[i][0..lengths[i]], nodes, edge.from, edge.to);
        if (rank_span <= proper_span and initial_node_conflicts == 0) continue;
        var best_score = initial_node_conflicts * 16;
        for (routes, lengths, present, 0..) |other_route, other_length, other_present, j| {
            if (j != i and other_present) best_score += 2 * routeConflicts(routes[i][0..lengths[i]], other_route[0..other_length]);
        }
        for (obstacles, obstacle_lengths, obstacle_present) |other_route, other_length, other_present| {
            if (other_present) best_score += routeConflicts(routes[i][0..lengths[i]], other_route[0..other_length]);
        }
        var candidates = [_]usize{0} ** 2051;
        var candidate_count: usize = 0;
        candidates[candidate_count] = if (horizontal) start.y else start.x;
        candidate_count += 1;
        candidates[candidate_count] = if (horizontal) end.y else end.x;
        candidate_count += 1;
        candidates[candidate_count] = if (horizontal) (start.y + end.y) / 2 else (start.x + end.x) / 2;
        candidate_count += 1;
        const corridor_clearances = [_]usize{ 18, 30, 42 };
        for (nodes) |node| for (corridor_clearances) |clearance| {
            candidates[candidate_count] = if (horizontal) node.y -| clearance else node.x -| clearance;
            candidate_count += 1;
            candidates[candidate_count] = if (horizontal) node.y + node.h + clearance else node.x + node.w + clearance;
            candidate_count += 1;
        };
        const offsets = [_]usize{ 18, 30, 42, 54 };
        for (candidates[0..candidate_count]) |candidate| for (offsets) |source_offset| for (offsets) |target_offset| {
            var route: [6]GridPoint = undefined;
            if (horizontal) {
                const source_corridor_x = advanceToward(start.x, end.x, source_offset);
                const target_corridor_x = advanceToward(end.x, start.x, target_offset);
                route = .{ start, .{ .x = source_corridor_x, .y = start.y }, .{ .x = source_corridor_x, .y = candidate }, .{ .x = target_corridor_x, .y = candidate }, .{ .x = target_corridor_x, .y = end.y }, end };
            } else {
                const source_corridor_y = advanceToward(start.y, end.y, source_offset);
                const target_corridor_y = advanceToward(end.y, start.y, target_offset);
                route = .{ start, .{ .x = start.x, .y = source_corridor_y }, .{ .x = candidate, .y = source_corridor_y }, .{ .x = candidate, .y = target_corridor_y }, .{ .x = end.x, .y = target_corridor_y }, end };
            }
            var score = routeNodeConflicts(&route, nodes, edge.from, edge.to) * 16;
            for (routes, lengths, present, 0..) |other_route, other_length, other_present, j| {
                if (j != i and other_present) score += 2 * routeConflicts(&route, other_route[0..other_length]);
            }
            for (obstacles, obstacle_lengths, obstacle_present) |other_route, other_length, other_present| {
                if (other_present) score += routeConflicts(&route, other_route[0..other_length]);
            }
            if (score < best_score) {
                best_score = score;
                for (route, 0..) |point, point_i| routes[i][point_i] = point;
                lengths[i] = route.len;
            }
        };

        // A single transverse spine cannot avoid two obstacles that require
        // opposite-side corridors. ELK's orthogonal router changes channels
        // at a layer boundary; search the same two-spine shape generically.
        if (best_score > 0) {
            var lanes = [_]usize{0} ** 515;
            var lane_count: usize = 3;
            lanes[0] = if (horizontal) start.y else start.x;
            lanes[1] = if (horizontal) end.y else end.x;
            lanes[2] = if (horizontal) (start.y + end.y) / 2 else (start.x + end.x) / 2;
            for (nodes) |node| {
                lanes[lane_count] = if (horizontal) node.y -| 18 else node.x -| 18;
                lane_count += 1;
                lanes[lane_count] = if (horizontal) node.y + node.h + 18 else node.x + node.w + 18;
                lane_count += 1;
            }
            var switches = [_]usize{0} ** 515;
            var switch_count: usize = 1;
            switches[0] = if (horizontal) (start.x + end.x) / 2 else (start.y + end.y) / 2;
            for (nodes) |node| {
                switches[switch_count] = if (horizontal) node.x -| 8 else node.y -| 8;
                switch_count += 1;
                switches[switch_count] = if (horizontal) node.x + node.w + 8 else node.y + node.h + 8;
                switch_count += 1;
            }
            for (lanes[0..lane_count]) |first_lane| for (lanes[0..lane_count]) |second_lane| {
                if (first_lane == second_lane) continue;
                for (switches[0..switch_count]) |switch_position| {
                    var route: [8]GridPoint = undefined;
                    if (horizontal) {
                        const source_corridor_x = advanceToward(start.x, end.x, 18);
                        const target_corridor_x = advanceToward(end.x, start.x, 18);
                        if (switch_position <= @min(source_corridor_x, target_corridor_x) or switch_position >= @max(source_corridor_x, target_corridor_x)) continue;
                        route = .{ start, .{ .x = source_corridor_x, .y = start.y }, .{ .x = source_corridor_x, .y = first_lane }, .{ .x = switch_position, .y = first_lane }, .{ .x = switch_position, .y = second_lane }, .{ .x = target_corridor_x, .y = second_lane }, .{ .x = target_corridor_x, .y = end.y }, end };
                    } else {
                        const source_corridor_y = advanceToward(start.y, end.y, 18);
                        const target_corridor_y = advanceToward(end.y, start.y, 18);
                        if (switch_position <= @min(source_corridor_y, target_corridor_y) or switch_position >= @max(source_corridor_y, target_corridor_y)) continue;
                        route = .{ start, .{ .x = start.x, .y = source_corridor_y }, .{ .x = first_lane, .y = source_corridor_y }, .{ .x = first_lane, .y = switch_position }, .{ .x = second_lane, .y = switch_position }, .{ .x = second_lane, .y = target_corridor_y }, .{ .x = end.x, .y = target_corridor_y }, end };
                    }
                    var score = routeNodeConflicts(&route, nodes, edge.from, edge.to) * 16;
                    for (routes, lengths, present, 0..) |other_route, other_length, other_present, j| {
                        if (j != i and other_present) score += 2 * routeConflicts(&route, other_route[0..other_length]);
                    }
                    for (obstacles, obstacle_lengths, obstacle_present) |other_route, other_length, other_present| {
                        if (other_present) score += routeConflicts(&route, other_route[0..other_length]);
                    }
                    if (score < best_score) {
                        best_score = score;
                        routes[i] = route;
                        lengths[i] = route.len;
                    }
                }
            };
        }
    }
}

fn routeLabelCenter(route: []const GridPoint, horizontal: bool) GridPoint {
    var best: usize = 0;
    var center = route[0];
    for (1..route.len) |i| {
        const a = route[i - 1];
        const b = route[i];
        const parallel = if (horizontal) a.y == b.y else a.x == b.x;
        if (!parallel) continue;
        const length = if (horizontal) @max(a.x, b.x) - @min(a.x, b.x) else @max(a.y, b.y) - @min(a.y, b.y);
        if (length > best) {
            best = length;
            center = .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
        }
    }
    return center;
}

fn routeCrossesRect(route: []const GridPoint, center: GridPoint, label_width: usize, label_height: usize) usize {
    const left = center.x -| (label_width / 2 + 4);
    const right = center.x + (label_width + 1) / 2 + 4;
    const top = center.y -| (label_height / 2 + 2);
    const bottom = center.y + (label_height + 1) / 2 + 2;
    var score: usize = 0;
    for (1..route.len) |i| {
        const a = route[i - 1];
        const b = route[i];
        if (a.x == b.x) {
            if (a.x >= left and a.x <= right and @max(a.y, b.y) >= top and @min(a.y, b.y) <= bottom) score += 1;
        } else if (a.y == b.y) {
            if (a.y >= top and a.y <= bottom and @max(a.x, b.x) >= left and @min(a.x, b.x) <= right) score += 1;
        }
    }
    return score;
}

fn forwardRoute(from: anytype, to: anytype, horizontal: bool, reverse: bool, source_ordinal: usize, source_count: usize, target_ordinal: usize, target_count: usize, lane_ordinal: usize, lane_count: usize, label_spacing: usize) [4]GridPoint {
    if (horizontal) {
        const start_y = spreadPort(from.y, from.h, source_ordinal, source_count);
        const end_y = spreadPort(to.y, to.h, target_ordinal, target_count);
        const start_x = horizontalPortX(from, start_y, !reverse);
        const end_x = horizontalPortX(to, end_y, reverse);
        const lane_x = forwardLane(start_x, end_x, lane_count, lane_ordinal, label_spacing);
        return .{ .{ .x = start_x, .y = start_y }, .{ .x = lane_x, .y = start_y }, .{ .x = lane_x, .y = end_y }, .{ .x = end_x, .y = end_y } };
    }
    const start_x = spreadPort(from.x, from.w, source_ordinal, source_count);
    const end_x = spreadPort(to.x, to.w, target_ordinal, target_count);
    const start_y = verticalPortY(from, start_x, !reverse);
    const end_y = verticalPortY(to, end_x, reverse);
    const lane_y = forwardLane(start_y, end_y, lane_count, lane_ordinal, label_spacing);
    return .{ .{ .x = start_x, .y = start_y }, .{ .x = start_x, .y = lane_y }, .{ .x = end_x, .y = lane_y }, .{ .x = end_x, .y = end_y } };
}

fn rankPairConflictScore(nodes: anytype, edges: anytype, from_rank: usize, to_rank: usize, horizontal: bool, reverse: bool, source_ordinals: *const [256]usize, target_ordinals: *const [256]usize, endpoint_counts: *const [512]usize, gap_ordinals: *const [256]usize, gap_counts: *const [256]usize, label_spacing: usize) usize {
    var score: usize = 0;
    for (edges, 0..) |a, i| {
        if (nodes[a.from].rank != from_rank or nodes[a.to].rank != to_rank) continue;
        const a_route = forwardRoute(nodes[a.from], nodes[a.to], horizontal, reverse, source_ordinals[i], endpoint_counts[a.from * 2 + 1], target_ordinals[i], endpoint_counts[a.to * 2], gap_ordinals[i], gap_counts[i], label_spacing);
        for (edges, 0..) |b, j| {
            if (j <= i or nodes[b.from].rank != from_rank or nodes[b.to].rank != to_rank) continue;
            const b_route = forwardRoute(nodes[b.from], nodes[b.to], horizontal, reverse, source_ordinals[j], endpoint_counts[b.from * 2 + 1], target_ordinals[j], endpoint_counts[b.to * 2], gap_ordinals[j], gap_counts[j], label_spacing);
            score += routeConflicts(&a_route, &b_route);
        }
    }
    return score;
}

fn verticalPortY(node: anytype, x: usize, bottom: bool) usize {
    if (shapes.circular(node.shape)) {
        const rx: f64 = @floatFromInt(node.w / 2);
        const ry: f64 = @floatFromInt(node.h / 2);
        const center_x = node.x + node.w / 2;
        const dx: f64 = @floatFromInt(if (x > center_x) x - center_x else center_x - x);
        const ratio = @min(dx / @max(rx, 1), 1);
        const offset: usize = @intFromFloat(@floor(ry * @sqrt(@max(0, 1 - ratio * ratio))));
        const center_y = node.y + node.h / 2;
        return if (bottom) center_y + offset else center_y -| offset;
    }
    if (node.shape == .stadium) {
        const radius = node.h / 2;
        const left_center = node.x + radius;
        const right_center = node.x + node.w -| radius;
        if (x >= left_center and x <= right_center) return if (bottom) node.y + node.h else node.y;
        const cap_center = if (x < left_center) left_center else right_center;
        const dx: f64 = @floatFromInt(if (x > cap_center) x - cap_center else cap_center - x);
        const r: f64 = @floatFromInt(radius);
        const offset: usize = @intFromFloat(@floor(@sqrt(@max(0, r * r - dx * dx))));
        const center_y = node.y + node.h / 2;
        return if (bottom) center_y + offset else center_y -| offset;
    }
    if (node.shape != .diamond) return if (bottom) node.y + node.h else node.y;
    const center = node.x + node.w / 2;
    const distance = if (x > center) x - center else center - x;
    const slope = distance * node.h / @max(node.w, 1);
    return if (bottom) node.y + node.h - slope else node.y + slope;
}

fn horizontalPortX(node: anytype, y: usize, right: bool) usize {
    if (shapes.circular(node.shape)) {
        const rx: f64 = @floatFromInt(node.w / 2);
        const ry: f64 = @floatFromInt(node.h / 2);
        const center_y = node.y + node.h / 2;
        const dy: f64 = @floatFromInt(if (y > center_y) y - center_y else center_y - y);
        const ratio = @min(dy / @max(ry, 1), 1);
        const offset: usize = @intFromFloat(@floor(rx * @sqrt(@max(0, 1 - ratio * ratio))));
        const center_x = node.x + node.w / 2;
        return if (right) center_x + offset else center_x -| offset;
    }
    if (node.shape == .stadium) {
        const radius = node.h / 2;
        const center_y = node.y + node.h / 2;
        const dy: f64 = @floatFromInt(if (y > center_y) y - center_y else center_y - y);
        const r: f64 = @floatFromInt(radius);
        const offset: usize = @intFromFloat(@floor(@sqrt(@max(0, r * r - dy * dy))));
        return if (right) node.x + node.w -| radius + offset else node.x + radius -| offset;
    }
    if (node.shape != .diamond) return if (right) node.x + node.w else node.x;
    const center = node.y + node.h / 2;
    const distance = if (y > center) y - center else center - y;
    const slope = distance * node.w / @max(node.h, 1);
    return if (right) node.x + node.w - slope else node.x + slope;
}
fn renderWithDocument(allocator: std.mem.Allocator, source: []const u8, theme: svg.Theme, prefix: u32, doc: ?*document.Document) Error![]u8 {
    var parser: Parser = .{ .allocator = allocator, .assets = if (doc) |value| &value.assets else null };
    defer parser.deinit();
    const header_end = std.mem.indexOfAny(u8, source, ";\n") orelse source.len;
    var words = std.mem.tokenizeAny(u8, source[0..header_end], " \t\r");
    _ = words.next() orelse return error.InvalidSyntax;
    var direction = directionAlias(words.next() orelse "TB");
    if (words.next() != null) return error.UnsupportedSyntax;
    if (!compound.validDirection(direction)) return error.InvalidSyntax;
    try parseBody(&parser, source[@min(header_end + 1, source.len)..], doc);
    direction = parser.direction_override orelse direction;
    const horizontal = std.mem.eql(u8, direction, "LR") or std.mem.eql(u8, direction, "RL");
    const reverse = std.mem.eql(u8, direction, "RL") or std.mem.eql(u8, direction, "BT");
    if (!horizontal and !std.mem.eql(u8, direction, "TD") and !std.mem.eql(u8, direction, "TB") and !reverse) return error.InvalidSyntax;
    try parser.collapse();
    if (doc) |value| try value.graphTheme(&parser);
    try parser.wrapLabels();
    if (parser.containers > 0) return compound.render(allocator, &parser, theme, prefix, direction);
    // Choose feedback edges as a set, then rank the remaining DAG. Optimizing
    // the complete cycle structure avoids needlessly tall declaration-order
    // layouts for nested loops.
    // Keep ELK P1's orientation as first-class layout state.  A reversed edge
    // is restored only after routing; inferring feedback later from rank
    // comparisons loses same-rank and constrained-edge information.
    const flow_rank = @import("flow_rank.zig");
    var simplex_detail: flow_rank.SimplexDetail = .{};
    const reversed_edges = flow_rank.assignDetailed(parser.nodes.items, parser.edges.items, &simplex_detail);
    var ids: [256]usize = undefined;
    for (parser.nodes.items, 0..) |*node, i| {
        ids[i] = i;
        const size = layout.nodeSize(node.*);
        node.w = size.w;
        node.h = size.h;
    }
    const rank_gap = parser.rank_spacing;
    const node_gap = parser.node_spacing;
    var label_rank_hints = [_]?usize{null} ** 256;
    for (simplex_detail.real_node_count..simplex_detail.node_count) |node| {
        const edge_i = simplex_detail.source_edge[node] orelse continue;
        if (simplex_detail.label_dummy[node] and edge_i < label_rank_hints.len)
            label_rank_hints[edge_i] = @intCast(simplex_detail.ranks[node]);
    }
    var expanded_guide = try layout.order(allocator, parser.nodes.items, parser.edges.items, ids[0..parser.nodes.items.len], horizontal, node_gap, label_rank_hints[0..parser.edges.items.len], simplex_detail.random_state, &simplex_detail, false);
    defer allocator.free(expanded_guide.arcs);
    defer allocator.free(expanded_guide.positioned);
    var rank_gaps = [_]usize{0} ** 4096;
    for (&rank_gaps) |*gap| gap.* = rank_gap;
    var labelled_count = [_]usize{0} ** 4096;
    var labelled_extent = [_]usize{0} ** 4096;
    for (parser.edges.items, 0..) |edge, edge_i| {
        const from_rank = parser.nodes.items[edge.from].rank;
        const to_rank = parser.nodes.items[edge.to].rank;
        if (reversed_edges[edge_i] or edge.link.label.len == 0 or to_rank != from_rank + 1) continue;
        labelled_count[from_rank] += 1;
        const extent = if (horizontal) paint.labelWidth(edge.link.label, edge.link.markdown) else paint.labelHeight(edge.link.label);
        labelled_extent[from_rank] = @max(labelled_extent[from_rank], edge.style.measure(extent));
    }
    // Edge labels are measured vertices in the proper layered graph. Their
    // local dummy rank reserves the required width and depth through `guide`;
    // they must not inflate every rank or every sibling gap in the diagram.
    const size = layout.place(parser.nodes.items, ids[0..parser.nodes.items.len], horizontal, reverse, node_gap, rank_gap, &rank_gaps, &expanded_guide);
    // Do not compact only the real nodes after ordering the proper graph. That
    // drops the dummy corridors and can recreate crossings already removed by
    // the layer sweep. Coordinate compaction belongs on the expanded graph.
    const image_padding = paint.imageEdgePadding(parser.edges.items);
    for (parser.nodes.items) |*node| {
        node.x += parser.diagram_padding + image_padding.w;
        node.y += parser.diagram_padding + image_padding.h;
    }
    const guide_along_padding = parser.diagram_padding + if (horizontal) image_padding.w else image_padding.h;
    const guide_cross_padding = parser.diagram_padding + if (horizontal) image_padding.h else image_padding.w;
    for (expanded_guide.positioned) |*entry| {
        entry.along += guide_along_padding;
        entry.cross += guide_cross_padding;
    }
    for (&expanded_guide.centers) |*center| center.* += guide_along_padding;
    for (0..expanded_guide.near_low_cross.len) |edge_i| {
        if (expanded_guide.near_low_valid[edge_i]) expanded_guide.near_low_cross[edge_i] += guide_cross_padding;
        if (expanded_guide.near_high_valid[edge_i]) expanded_guide.near_high_cross[edge_i] += guide_cross_padding;
        if (expanded_guide.label_valid[edge_i]) expanded_guide.label_cross[edge_i] += guide_cross_padding;
    }
    var width = size.w + 2 * (parser.diagram_padding + image_padding.w);
    var height = size.h + 2 * (parser.diagram_padding + image_padding.h);
    var label_left: usize = 0;
    var label_top: usize = 0;
    for (parser.edges.items, 0..) |edge, edge_i| {
        const from = parser.nodes.items[edge.from];
        const to = parser.nodes.items[edge.to];
        if (reversed_edges[edge_i] or edge.link.label.len == 0) continue;
        const p = shapes.anchor(from.shape, from.x, from.y, from.w, from.h, if (horizontal) (if (reverse) .left else .right) else (if (reverse) .top else .bottom));
        const q = shapes.anchor(to.shape, to.x, to.y, to.w, to.h, if (horizontal) (if (reverse) .right else .left) else (if (reverse) .bottom else .top));
        const x = (p.x + q.x) / 2;
        const y = (p.y + q.y) / 2;
        const lw = edge.style.measure(paint.labelWidth(edge.link.label, edge.link.markdown));
        const lh = edge.style.measure(paint.labelHeight(edge.link.label));
        label_left = @max(label_left, lw / 2 + parser.diagram_padding -| x);
        label_top = @max(label_top, lh / 2 + parser.diagram_padding -| y);
        width = @max(width, x + (lw + 1) / 2 + parser.diagram_padding);
        height = @max(height, y + (lh + 1) / 2 + parser.diagram_padding);
    }
    for (parser.nodes.items) |*node| {
        node.x += label_left;
        node.y += label_top;
    }
    width += label_left;
    height += label_top;
    // Feedback edges use dedicated exterior lanes. Local cycles return on the
    // leading side while long enclosing cycles return on the trailing side, so
    // nested loops read separately instead of collapsing into one distant path.
    var feedback_lanes = [_]usize{0} ** 256;
    var feedback_leading = [_]bool{false} ** 256;
    var feedback_internal = [_]bool{false} ** 256;
    var feedback_position = [_]usize{0} ** 256;
    var feedback_secondary_position = [_]usize{0} ** 256;
    var feedback_switch_position = [_]usize{0} ** 256;
    var feedback_dogleg = [_]bool{false} ** 256;
    var leading_count: usize = 0;
    var trailing_count: usize = 0;
    var leading_extent: usize = 0;
    var trailing_extent: usize = 0;
    for (parser.edges.items, 0..) |edge, i| {
        const from = parser.nodes.items[edge.from];
        const to = parser.nodes.items[edge.to];
        const lw = edge.style.measure(paint.labelWidth(edge.link.label, edge.link.markdown));
        const lh = edge.style.measure(paint.labelHeight(edge.link.label));
        if (edge.from == edge.to) {
            width = @max(width, from.x + from.w + 80 + lw / 2);
            height = @max(height, from.y + from.h + 80 + lh);
        } else if (reversed_edges[i]) {
            const rank_span = from.rank - to.rank;
            var leading = rank_span <= 3;
            var leading_blocked = false;
            var trailing_blocked = false;
            if (horizontal) {
                const source_y = from.y + from.h / 2;
                const corridor_x = if (reverse) from.x + from.w + 18 else from.x -| 18;
                const target_corridor_x = if (reverse) to.x -| 18 else to.x + to.w + 18;
                for (parser.nodes.items, 0..) |node, node_i| {
                    if (node_i == edge.from or node_i == edge.to) continue;
                    if (corridor_x > node.x and corridor_x < node.x + node.w) {
                        if (node.y < source_y) leading_blocked = true;
                        if (node.y + node.h > source_y) trailing_blocked = true;
                    }
                    if (target_corridor_x > node.x and target_corridor_x < node.x + node.w) {
                        if (node.y < to.y) leading_blocked = true;
                        if (node.y + node.h > to.y + to.h) trailing_blocked = true;
                    }
                }
            } else {
                const source_x = from.x + from.w / 2;
                const target_x = to.x + to.w / 2;
                const corridor_y = if (reverse) from.y + from.h + 18 else from.y -| 18;
                const target_corridor_y = if (reverse) to.y -| 18 else to.y + to.h + 18;
                for (parser.nodes.items, 0..) |node, node_i| {
                    if (node_i == edge.from or node_i == edge.to) continue;
                    if (corridor_y > node.y and corridor_y < node.y + node.h) {
                        if (node.x < source_x) leading_blocked = true;
                        if (node.x + node.w > source_x) trailing_blocked = true;
                    }
                    if (target_corridor_y > node.y and target_corridor_y < node.y + node.h) {
                        if (node.x < target_x) leading_blocked = true;
                        if (node.x + node.w > target_x) trailing_blocked = true;
                    }
                }
            }
            var leading_score: usize = 0;
            var trailing_score: usize = 0;
            if (horizontal) {
                const leading_source_y = from.y + from.h / 4;
                const leading_target_y = to.y + to.h / 4;
                const trailing_source_y = from.y + from.h * 3 / 4;
                const trailing_target_y = to.y + to.h * 3 / 4;
                const leading_source_x = horizontalPortX(from, leading_source_y, reverse);
                const leading_target_x = horizontalPortX(to, leading_target_y, !reverse);
                const trailing_source_x = horizontalPortX(from, trailing_source_y, reverse);
                const trailing_target_x = horizontalPortX(to, trailing_target_y, !reverse);
                const leading_lane_y: usize = 0;
                const trailing_lane_y = height + 64;
                const leading_route = [_]GridPoint{ .{ .x = leading_source_x, .y = leading_source_y }, .{ .x = if (reverse) leading_source_x + 18 else leading_source_x -| 18, .y = leading_source_y }, .{ .x = if (reverse) leading_source_x + 18 else leading_source_x -| 18, .y = leading_lane_y }, .{ .x = if (reverse) leading_target_x -| 18 else leading_target_x + 18, .y = leading_lane_y }, .{ .x = if (reverse) leading_target_x -| 18 else leading_target_x + 18, .y = leading_target_y }, .{ .x = leading_target_x, .y = leading_target_y } };
                const trailing_route = [_]GridPoint{ .{ .x = trailing_source_x, .y = trailing_source_y }, .{ .x = if (reverse) trailing_source_x + 18 else trailing_source_x -| 18, .y = trailing_source_y }, .{ .x = if (reverse) trailing_source_x + 18 else trailing_source_x -| 18, .y = trailing_lane_y }, .{ .x = if (reverse) trailing_target_x -| 18 else trailing_target_x + 18, .y = trailing_lane_y }, .{ .x = if (reverse) trailing_target_x -| 18 else trailing_target_x + 18, .y = trailing_target_y }, .{ .x = trailing_target_x, .y = trailing_target_y } };
                for (parser.edges.items, 0..) |other, other_i| {
                    const other_from = parser.nodes.items[other.from];
                    const other_to = parser.nodes.items[other.to];
                    if (reversed_edges[other_i]) continue;
                    const sy = other_from.y + other_from.h / 2;
                    const ty = other_to.y + other_to.h / 2;
                    const sx = horizontalPortX(other_from, sy, !reverse);
                    const tx = horizontalPortX(other_to, ty, reverse);
                    const lane = (sx + tx) / 2;
                    const forward_route = [_]GridPoint{ .{ .x = sx, .y = sy }, .{ .x = lane, .y = sy }, .{ .x = lane, .y = ty }, .{ .x = tx, .y = ty } };
                    leading_score += routeConflicts(&leading_route, &forward_route);
                    trailing_score += routeConflicts(&trailing_route, &forward_route);
                }
            } else {
                const leading_source_x = from.x + from.w / 4;
                const leading_target_x = to.x + to.w / 4;
                const trailing_source_x = from.x + from.w * 3 / 4;
                const trailing_target_x = to.x + to.w * 3 / 4;
                const leading_source_y = verticalPortY(from, leading_source_x, reverse);
                const leading_target_y = verticalPortY(to, leading_target_x, !reverse);
                const trailing_source_y = verticalPortY(from, trailing_source_x, reverse);
                const trailing_target_y = verticalPortY(to, trailing_target_x, !reverse);
                const leading_lane_x: usize = 0;
                const trailing_lane_x = width + 64;
                const leading_route = [_]GridPoint{ .{ .x = leading_source_x, .y = leading_source_y }, .{ .x = leading_source_x, .y = if (reverse) leading_source_y + 18 else leading_source_y -| 18 }, .{ .x = leading_lane_x, .y = if (reverse) leading_source_y + 18 else leading_source_y -| 18 }, .{ .x = leading_lane_x, .y = if (reverse) leading_target_y -| 18 else leading_target_y + 18 }, .{ .x = leading_target_x, .y = if (reverse) leading_target_y -| 18 else leading_target_y + 18 }, .{ .x = leading_target_x, .y = leading_target_y } };
                const trailing_route = [_]GridPoint{ .{ .x = trailing_source_x, .y = trailing_source_y }, .{ .x = trailing_source_x, .y = if (reverse) trailing_source_y + 18 else trailing_source_y -| 18 }, .{ .x = trailing_lane_x, .y = if (reverse) trailing_source_y + 18 else trailing_source_y -| 18 }, .{ .x = trailing_lane_x, .y = if (reverse) trailing_target_y -| 18 else trailing_target_y + 18 }, .{ .x = trailing_target_x, .y = if (reverse) trailing_target_y -| 18 else trailing_target_y + 18 }, .{ .x = trailing_target_x, .y = trailing_target_y } };
                for (parser.edges.items, 0..) |other, other_i| {
                    const other_from = parser.nodes.items[other.from];
                    const other_to = parser.nodes.items[other.to];
                    if (reversed_edges[other_i]) continue;
                    const sx = other_from.x + other_from.w / 2;
                    const tx = other_to.x + other_to.w / 2;
                    const sy = verticalPortY(other_from, sx, !reverse);
                    const ty = verticalPortY(other_to, tx, reverse);
                    const lane = (sy + ty) / 2;
                    const forward_route = [_]GridPoint{ .{ .x = sx, .y = sy }, .{ .x = sx, .y = lane }, .{ .x = tx, .y = lane }, .{ .x = tx, .y = ty } };
                    leading_score += routeConflicts(&leading_route, &forward_route);
                    trailing_score += routeConflicts(&trailing_route, &forward_route);
                }
            }
            var internal_score: usize = std.math.maxInt(usize);
            var internal_position: usize = 0;
            if (!horizontal) {
                const source_x = from.x + from.w / 2;
                const target_x = to.x + to.w / 2;
                const source_y = verticalPortY(from, source_x, reverse);
                const target_y = verticalPortY(to, target_x, !reverse);
                var candidates = [_]usize{0} ** 515;
                var candidate_count: usize = 3;
                candidates[0] = source_x;
                candidates[1] = target_x;
                candidates[2] = (source_x + target_x) / 2;
                // Dummy-node corridors live in the free channels beside real
                // nodes. Sample both sides of every node so an internal return
                // can occupy the same kind of channel ELK discovers.
                for (parser.nodes.items) |node| {
                    candidates[candidate_count] = node.x -| 18;
                    candidate_count += 1;
                    candidates[candidate_count] = node.x + node.w + 18;
                    candidate_count += 1;
                }
                for (candidates[0..candidate_count]) |candidate| {
                    const source_corridor_y = if (reverse) source_y + 18 else source_y -| 18;
                    const target_corridor_y = if (reverse) target_y -| 18 else target_y + 18;
                    const candidate_route = [_]GridPoint{ .{ .x = source_x, .y = source_y }, .{ .x = source_x, .y = source_corridor_y }, .{ .x = candidate, .y = source_corridor_y }, .{ .x = candidate, .y = target_corridor_y }, .{ .x = target_x, .y = target_corridor_y }, .{ .x = target_x, .y = target_y } };
                    var score: usize = 0;
                    for (parser.edges.items, 0..) |other, other_i| {
                        const other_from = parser.nodes.items[other.from];
                        const other_to = parser.nodes.items[other.to];
                        if (reversed_edges[other_i]) continue;
                        const sx = other_from.x + other_from.w / 2;
                        const tx = other_to.x + other_to.w / 2;
                        const sy = verticalPortY(other_from, sx, !reverse);
                        const ty = verticalPortY(other_to, tx, reverse);
                        const lane = (sy + ty) / 2;
                        const forward_route = [_]GridPoint{ .{ .x = sx, .y = sy }, .{ .x = sx, .y = lane }, .{ .x = tx, .y = lane }, .{ .x = tx, .y = ty } };
                        score += routeConflicts(&candidate_route, &forward_route);
                    }
                    for (parser.nodes.items, 0..) |node, node_i| {
                        if (node_i == edge.from or node_i == edge.to) continue;
                        for (1..candidate_route.len) |segment| {
                            const a = candidate_route[segment - 1];
                            const b = candidate_route[segment];
                            const hits = if (a.x == b.x)
                                a.x > node.x and a.x < node.x + node.w and @max(a.y, b.y) > node.y and @min(a.y, b.y) < node.y + node.h
                            else
                                a.y > node.y and a.y < node.y + node.h and @max(a.x, b.x) > node.x and @min(a.x, b.x) < node.x + node.w;
                            if (hits) score += 8;
                        }
                    }
                    if (score < internal_score) {
                        internal_score = score;
                        internal_position = candidate;
                    }
                }
            }
            if (internal_score <= @min(leading_score, trailing_score)) {
                feedback_internal[i] = true;
                feedback_position[i] = internal_position;
                leading = internal_position < (from.x + from.w / 2 + to.x + to.w / 2) / 2;
            } else {
                if (leading_score < trailing_score) leading = true;
                if (trailing_score < leading_score) leading = false;
            }
            // The node-corridor probe is deliberately coarse. Use it only as
            // a tie-breaker; otherwise it can veto a route that demonstrably
            // removes connector crossings (the full ELK router makes the same
            // trade-off with exact geometry rather than this probe).
            if (!feedback_internal[i] and leading_score == trailing_score) {
                if (leading and leading_blocked and !trailing_blocked) leading = false;
                if (!leading and trailing_blocked and !leading_blocked) leading = true;
            }
            feedback_leading[i] = leading;
            feedback_lanes[i] = if (leading) leading_count else trailing_count;
            if (!feedback_internal[i]) {
                if (leading) leading_count += 1 else trailing_count += 1;
            }
            const offset = 24 + feedback_lanes[i] * 18;
            if (feedback_internal[i]) {
                // Internal corridors consume no exterior canvas.
            } else if (horizontal) {
                const extent = offset + 20 + lh;
                if (leading) leading_extent = @max(leading_extent, extent) else trailing_extent = @max(trailing_extent, extent);
                if (!reverse) width = @max(width, @max(from.x + from.w, to.x + to.w) + 18 + parser.diagram_padding);
            } else {
                const extent = offset + 16 + lw / 2;
                if (leading) leading_extent = @max(leading_extent, extent) else trailing_extent = @max(trailing_extent, extent);
                if (!reverse) height = @max(height, @max(from.y + from.h, to.y + to.h) + 18 + parser.diagram_padding);
            }
        }
    }
    for (expanded_guide.positioned) |*entry| entry.cross += leading_extent;
    if (horizontal) {
        for (parser.nodes.items) |*node| node.y += leading_extent;
        for (0..expanded_guide.near_low_cross.len) |edge_i| {
            if (expanded_guide.near_low_valid[edge_i]) expanded_guide.near_low_cross[edge_i] += leading_extent;
            if (expanded_guide.near_high_valid[edge_i]) expanded_guide.near_high_cross[edge_i] += leading_extent;
            if (expanded_guide.label_valid[edge_i]) expanded_guide.label_cross[edge_i] += leading_extent;
        }
        for (&feedback_position, feedback_internal) |*position, internal| {
            if (internal) position.* += leading_extent;
        }
        height += leading_extent + trailing_extent;
    } else {
        for (parser.nodes.items) |*node| node.x += leading_extent;
        for (0..expanded_guide.near_low_cross.len) |edge_i| {
            if (expanded_guide.near_low_valid[edge_i]) expanded_guide.near_low_cross[edge_i] += leading_extent;
            if (expanded_guide.near_high_valid[edge_i]) expanded_guide.near_high_cross[edge_i] += leading_extent;
            if (expanded_guide.label_valid[edge_i]) expanded_guide.label_cross[edge_i] += leading_extent;
        }
        for (&feedback_position, feedback_internal) |*position, internal| {
            if (internal) position.* += leading_extent;
        }
        width += leading_extent + trailing_extent;
    }
    const content_right = width - trailing_extent;
    const content_bottom = height - trailing_extent;
    // The crossing minimizer owns port order. Do not infer it again from
    // positioned endpoints: that discards dummy-chain neighbours and braids
    // connectors whose winning permutation has already been verified.
    const endpoint_ports = try layout.endpointPorts(parser.edges.items, &reversed_edges, expanded_guide.arcs[0..expanded_guide.arc_count]);
    const endpoint_count = endpoint_ports.counts;
    const source_port_ordinal = endpoint_ports.source;
    const target_port_ordinal = endpoint_ports.target;
    // Give every forward edge in the same pair of layers its own channel.
    // Sharing a midpoint makes unrelated connectors blend into one apparent
    // edge; ordered parallel lanes keep their identities visible.
    var gap_count = [_]usize{0} ** 256;
    var gap_ordinal = [_]usize{0} ** 256;
    for (parser.edges.items, 0..) |edge, i| {
        const from_rank = parser.nodes.items[edge.from].rank;
        const to_rank = parser.nodes.items[edge.to].rank;
        if (reversed_edges[i]) continue;
        var count: usize = 0;
        var ordinal: usize = 0;
        const edge_key = if (horizontal)
            parser.nodes.items[edge.from].y + parser.nodes.items[edge.from].h / 2 + parser.nodes.items[edge.to].y + parser.nodes.items[edge.to].h / 2
        else
            parser.nodes.items[edge.from].x + parser.nodes.items[edge.from].w / 2 + parser.nodes.items[edge.to].x + parser.nodes.items[edge.to].w / 2;
        for (parser.edges.items, 0..) |other, j| {
            if (parser.nodes.items[other.from].rank == from_rank and parser.nodes.items[other.to].rank == to_rank) {
                const other_key = if (horizontal)
                    parser.nodes.items[other.from].y + parser.nodes.items[other.from].h / 2 + parser.nodes.items[other.to].y + parser.nodes.items[other.to].h / 2
                else
                    parser.nodes.items[other.from].x + parser.nodes.items[other.from].w / 2 + parser.nodes.items[other.to].x + parser.nodes.items[other.to].w / 2;
                if (other_key < edge_key or (other_key == edge_key and j < i)) ordinal += 1;
                count += 1;
            }
        }
        gap_count[i] = count;
        gap_ordinal[i] = ordinal;
    }
    // ELK's crossing minimizer considers the bend order as well as the port
    // order. For each layer pair, compare the two monotone channel orders and
    // retain the one with fewer proper crossings or shared segments. This
    // removes the common two-crossing braid without changing already-clean
    // labelled branches merely because their transverse order is reversed.
    for (parser.edges.items, 0..) |edge, first| {
        const from_rank = parser.nodes.items[edge.from].rank;
        const to_rank = parser.nodes.items[edge.to].rank;
        if (reversed_edges[first] or gap_count[first] < 2) continue;
        var earlier = false;
        for (0..first) |i| if (parser.nodes.items[parser.edges.items[i].from].rank == from_rank and parser.nodes.items[parser.edges.items[i].to].rank == to_rank) {
            earlier = true;
            break;
        };
        if (earlier) continue;
        const labelled = labelled_count[from_rank] > 1;
        const label_spacing = if (labelled) @max(@as(usize, 20), labelled_extent[from_rank] + 8) else 0;
        var best_score = rankPairConflictScore(parser.nodes.items, parser.edges.items, from_rank, to_rank, horizontal, reverse, &source_port_ordinal, &target_port_ordinal, &endpoint_count, &gap_ordinal, &gap_count, label_spacing);
        var reversed_ordinals = gap_ordinal;
        for (parser.edges.items, 0..) |candidate, i| if (parser.nodes.items[candidate.from].rank == from_rank and parser.nodes.items[candidate.to].rank == to_rank) {
            reversed_ordinals[i] = gap_count[i] - 1 - gap_ordinal[i];
        };
        const reversed_score = rankPairConflictScore(parser.nodes.items, parser.edges.items, from_rank, to_rank, horizontal, reverse, &source_port_ordinal, &target_port_ordinal, &endpoint_count, &reversed_ordinals, &gap_count, label_spacing);
        if (reversed_score < best_score) {
            gap_ordinal = reversed_ordinals;
            best_score = reversed_score;
        }
        // Full reversal is sufficient for simple fans. Mixed fan-in/fan-out
        // groups need local swaps, the same refinement role played by ELK's
        // greedy-switch crossing minimizer.
        var improved = true;
        while (improved) {
            improved = false;
            for (parser.edges.items, 0..) |a, i| {
                if (parser.nodes.items[a.from].rank != from_rank or parser.nodes.items[a.to].rank != to_rank) continue;
                for (parser.edges.items, 0..) |b, j| {
                    if (j <= i or parser.nodes.items[b.from].rank != from_rank or parser.nodes.items[b.to].rank != to_rank) continue;
                    const saved = gap_ordinal[i];
                    gap_ordinal[i] = gap_ordinal[j];
                    gap_ordinal[j] = saved;
                    const score = rankPairConflictScore(parser.nodes.items, parser.edges.items, from_rank, to_rank, horizontal, reverse, &source_port_ordinal, &target_port_ordinal, &endpoint_count, &gap_ordinal, &gap_count, label_spacing);
                    if (score < best_score) {
                        best_score = score;
                        improved = true;
                    } else {
                        gap_ordinal[j] = gap_ordinal[i];
                        gap_ordinal[i] = saved;
                    }
                }
            }
        }
    }

    var final_forward_routes: [256][8]GridPoint = undefined;
    var final_forward_lengths = [_]usize{0} ** 256;
    var final_forward = [_]bool{false} ** 256;
    for (parser.edges.items, 0..) |edge, i| {
        const from = parser.nodes.items[edge.from];
        const to = parser.nodes.items[edge.to];
        if (reversed_edges[i]) continue;
        const spacing = if (labelled_count[from.rank] > 1) @max(@as(usize, 20), labelled_extent[from.rank] + 8) else 0;
        const route = forwardRoute(from, to, horizontal, reverse, source_port_ordinal[i], endpoint_count[edge.from * 2 + 1], target_port_ordinal[i], endpoint_count[edge.to * 2], gap_ordinal[i], gap_count[i], spacing);
        if (expanded_guide.label_valid[i]) {
            const label_rank = expanded_guide.label_rank[i];
            const label_center = expanded_guide.centers[label_rank];
            const label_half_depth = expanded_guide.depths[label_rank] / 2 + 4;
            const label_cross = expanded_guide.label_cross[i];
            if (horizontal) {
                const before = if (route[0].x <= route[route.len - 1].x) label_center -| label_half_depth else label_center + label_half_depth;
                const after = if (route[0].x <= route[route.len - 1].x) label_center + label_half_depth else label_center -| label_half_depth;
                const labelled_route = [_]GridPoint{ route[0], .{ .x = before, .y = route[0].y }, .{ .x = before, .y = label_cross }, .{ .x = after, .y = label_cross }, .{ .x = after, .y = route[route.len - 1].y }, route[route.len - 1] };
                for (labelled_route, 0..) |point, point_i| final_forward_routes[i][point_i] = point;
            } else {
                const before = if (route[0].y <= route[route.len - 1].y) label_center -| label_half_depth else label_center + label_half_depth;
                const after = if (route[0].y <= route[route.len - 1].y) label_center + label_half_depth else label_center -| label_half_depth;
                const labelled_route = [_]GridPoint{ route[0], .{ .x = route[0].x, .y = before }, .{ .x = label_cross, .y = before }, .{ .x = label_cross, .y = after }, .{ .x = route[route.len - 1].x, .y = after }, route[route.len - 1] };
                for (labelled_route, 0..) |point, point_i| final_forward_routes[i][point_i] = point;
            }
            final_forward_lengths[i] = 6;
        } else {
            for (route, 0..) |point, point_i| final_forward_routes[i][point_i] = point;
            final_forward_lengths[i] = route.len;
        }
        final_forward[i] = true;
    }

    var provisional_feedback_routes: [256][6]GridPoint = undefined;
    var provisional_feedback = [_]bool{false} ** 256;
    for (parser.edges.items, 0..) |edge, i| {
        const from = parser.nodes.items[edge.from];
        const to = parser.nodes.items[edge.to];
        if (edge.from == edge.to or !reversed_edges[i]) continue;
        const offset = 24 + feedback_lanes[i] * 18;
        if (horizontal) {
            const source_slot = edge.from * 2;
            const target_slot = edge.to * 2 + 1;
            const source_y = spreadPort(from.y, from.h, source_port_ordinal[i], endpoint_count[source_slot]);
            const target_y = spreadPort(to.y, to.h, target_port_ordinal[i], endpoint_count[target_slot]);
            const source_x = horizontalPortX(from, source_y, reverse);
            const target_x = horizontalPortX(to, target_y, !reverse);
            const source_corridor_x = if (reverse) source_x + 18 else source_x -| 18;
            const target_corridor_x = if (reverse) target_x -| 18 else target_x + 18;
            const lane = if (feedback_internal[i]) feedback_position[i] else if (feedback_leading[i]) leading_extent - offset else content_bottom + offset;
            provisional_feedback_routes[i] = .{ .{ .x = source_x, .y = source_y }, .{ .x = source_corridor_x, .y = source_y }, .{ .x = source_corridor_x, .y = lane }, .{ .x = target_corridor_x, .y = lane }, .{ .x = target_corridor_x, .y = target_y }, .{ .x = target_x, .y = target_y } };
        } else {
            const source_slot = edge.from * 2;
            const target_slot = edge.to * 2 + 1;
            const source_x = spreadPort(from.x, from.w, source_port_ordinal[i], endpoint_count[source_slot]);
            const target_x = spreadPort(to.x, to.w, target_port_ordinal[i], endpoint_count[target_slot]);
            const source_y = verticalPortY(from, source_x, reverse);
            const target_y = verticalPortY(to, target_x, !reverse);
            const source_corridor_y = if (reverse) source_y + 18 else source_y -| 18;
            const target_corridor_y = if (reverse) target_y -| 18 else target_y + 18;
            const lane = if (feedback_internal[i]) feedback_position[i] else if (feedback_leading[i]) leading_extent - offset else content_right + offset;
            provisional_feedback_routes[i] = .{ .{ .x = source_x, .y = source_y }, .{ .x = source_x, .y = source_corridor_y }, .{ .x = lane, .y = source_corridor_y }, .{ .x = lane, .y = target_corridor_y }, .{ .x = target_x, .y = target_corridor_y }, .{ .x = target_x, .y = target_y } };
        }
        provisional_feedback[i] = true;
    }

    // Long forward edges need the same obstacle-aware corridor choice as
    // returns. Their source/target ranks can have real nodes between them, so
    // the simple three-segment route is only a starting candidate.
    for (parser.edges.items, 0..) |edge, i| {
        if (!final_forward[i]) continue;
        const from_rank = parser.nodes.items[edge.from].rank;
        const to_rank = parser.nodes.items[edge.to].rank;
        const rank_span = if (from_rank > to_rank) from_rank - to_rank else to_rank - from_rank;
        const proper_span = edge.link.length + @as(usize, @intFromBool(edge.link.label.len > 0));
        const start = final_forward_routes[i][0];
        const end = final_forward_routes[i][final_forward_lengths[i] - 1];
        const initial_node_conflicts = routeNodeConflicts(final_forward_routes[i][0..final_forward_lengths[i]], parser.nodes.items, edge.from, edge.to);
        if (rank_span <= proper_span and initial_node_conflicts == 0) continue;
        var best_score = initial_node_conflicts * 16;
        for (final_forward_routes, final_forward_lengths, final_forward, 0..) |other_route, other_length, present, j| {
            if (j != i and present) best_score += 2 * routeConflicts(final_forward_routes[i][0..final_forward_lengths[i]], other_route[0..other_length]);
        }
        for (provisional_feedback_routes, provisional_feedback) |other_route, present| {
            if (present) best_score += routeConflicts(final_forward_routes[i][0..final_forward_lengths[i]], &other_route);
        }
        if (best_score == 0) continue;
        var candidates = [_]usize{0} ** 2051;
        var candidate_count: usize = 0;
        candidates[candidate_count] = if (horizontal) start.y else start.x;
        candidate_count += 1;
        candidates[candidate_count] = if (horizontal) end.y else end.x;
        candidate_count += 1;
        candidates[candidate_count] = if (horizontal) (start.y + end.y) / 2 else (start.x + end.x) / 2;
        candidate_count += 1;
        const corridor_clearances = [_]usize{ 18, 30, 42 };
        for (parser.nodes.items) |node| for (corridor_clearances) |clearance| {
            candidates[candidate_count] = if (horizontal) node.y -| clearance else node.x -| clearance;
            candidate_count += 1;
            candidates[candidate_count] = if (horizontal) node.y + node.h + clearance else node.x + node.w + clearance;
            candidate_count += 1;
        };
        for (candidates[0..candidate_count]) |candidate| {
            var route: [6]GridPoint = undefined;
            if (horizontal) {
                const source_corridor_x = advanceToward(start.x, end.x, 18);
                const target_corridor_x = advanceToward(end.x, start.x, 18);
                route = .{ start, .{ .x = source_corridor_x, .y = start.y }, .{ .x = source_corridor_x, .y = candidate }, .{ .x = target_corridor_x, .y = candidate }, .{ .x = target_corridor_x, .y = end.y }, end };
            } else {
                const source_corridor_y = advanceToward(start.y, end.y, 18);
                const target_corridor_y = advanceToward(end.y, start.y, 18);
                route = .{ start, .{ .x = start.x, .y = source_corridor_y }, .{ .x = candidate, .y = source_corridor_y }, .{ .x = candidate, .y = target_corridor_y }, .{ .x = end.x, .y = target_corridor_y }, end };
            }
            var score = routeNodeConflicts(&route, parser.nodes.items, edge.from, edge.to) * 16;
            for (final_forward_routes, final_forward_lengths, final_forward, 0..) |other_route, other_length, present, j| {
                if (j != i and present) score += 2 * routeConflicts(&route, other_route[0..other_length]);
            }
            for (provisional_feedback_routes, provisional_feedback) |other_route, present| {
                if (present) score += routeConflicts(&route, &other_route);
            }
            if (score < best_score) {
                best_score = score;
                for (route, 0..) |point, point_i| final_forward_routes[i][point_i] = point;
                final_forward_lengths[i] = route.len;
            }
        }
    }

    // Refine return corridors against the routes that will actually be drawn.
    // The early pass has to estimate ports and channels before they exist;
    // ELK instead routes all layer gaps as one dependency graph. This global
    // pass is its practical equivalent here: every available node-side
    // corridor competes using the final free ports and forward-edge lanes.
    for (parser.edges.items, 0..) |edge, i| {
        const from = parser.nodes.items[edge.from];
        const to = parser.nodes.items[edge.to];
        if (edge.from == edge.to or !reversed_edges[i]) continue;
        var candidates = [_]usize{0} ** 519;
        var candidate_count: usize = 0;
        const offset = 24 + feedback_lanes[i] * 18;
        const current_lane = if (feedback_internal[i]) feedback_position[i] else if (horizontal)
            (if (feedback_leading[i]) leading_extent - offset else content_bottom + offset)
        else
            (if (feedback_leading[i]) leading_extent - offset else content_right + offset);
        candidates[candidate_count] = current_lane;
        candidate_count += 1;
        candidates[candidate_count] = if (horizontal) leading_extent - offset else leading_extent - offset;
        candidate_count += 1;
        candidates[candidate_count] = if (horizontal) content_bottom + offset else content_right + offset;
        candidate_count += 1;
        for (parser.nodes.items) |node| {
            candidates[candidate_count] = if (horizontal) node.y -| 18 else node.x -| 18;
            candidate_count += 1;
            candidates[candidate_count] = if (horizontal) node.y + node.h + 18 else node.x + node.w + 18;
            candidate_count += 1;
        }

        var best_lane = current_lane;
        var best_score: usize = std.math.maxInt(usize);
        for (candidates[0..candidate_count]) |candidate| {
            var feedback_route: [6]GridPoint = undefined;
            if (horizontal) {
                const source_slot = edge.from * 2;
                const target_slot = edge.to * 2 + 1;
                const source_y = spreadPort(from.y, from.h, source_port_ordinal[i], endpoint_count[source_slot]);
                const target_y = spreadPort(to.y, to.h, target_port_ordinal[i], endpoint_count[target_slot]);
                const source_x = horizontalPortX(from, source_y, reverse);
                const target_x = horizontalPortX(to, target_y, !reverse);
                const source_corridor_x = if (reverse) source_x + 18 else source_x -| 18;
                const target_corridor_x = if (reverse) target_x -| 18 else target_x + 18;
                feedback_route = .{ .{ .x = source_x, .y = source_y }, .{ .x = source_corridor_x, .y = source_y }, .{ .x = source_corridor_x, .y = candidate }, .{ .x = target_corridor_x, .y = candidate }, .{ .x = target_corridor_x, .y = target_y }, .{ .x = target_x, .y = target_y } };
            } else {
                const source_slot = edge.from * 2;
                const target_slot = edge.to * 2 + 1;
                const source_x = spreadPort(from.x, from.w, source_port_ordinal[i], endpoint_count[source_slot]);
                const target_x = spreadPort(to.x, to.w, target_port_ordinal[i], endpoint_count[target_slot]);
                const source_y = verticalPortY(from, source_x, reverse);
                const target_y = verticalPortY(to, target_x, !reverse);
                const source_corridor_y = if (reverse) source_y + 18 else source_y -| 18;
                const target_corridor_y = if (reverse) target_y -| 18 else target_y + 18;
                feedback_route = .{ .{ .x = source_x, .y = source_y }, .{ .x = source_x, .y = source_corridor_y }, .{ .x = candidate, .y = source_corridor_y }, .{ .x = candidate, .y = target_corridor_y }, .{ .x = target_x, .y = target_corridor_y }, .{ .x = target_x, .y = target_y } };
            }
            var score = routeNodeConflicts(&feedback_route, parser.nodes.items, edge.from, edge.to) * 16;
            for (final_forward_routes, final_forward_lengths, final_forward) |other_route, other_length, present| {
                if (present) score += routeConflicts(&feedback_route, other_route[0..other_length]);
            }
            if (score < best_score) {
                best_score = score;
                best_lane = candidate;
            }
        }
        feedback_internal[i] = true;
        feedback_position[i] = best_lane;

        // A single spine cannot pass two obstacles whose free corridors are
        // on opposite sides. Allow one layer-boundary transfer and score the
        // complete route globally. This is the same reason ELK retains every
        // LONG_EDGE dummy until orthogonal routing is finished.
        if (best_score > 0) {
            var switches = [_]usize{0} ** 519;
            var switch_count: usize = 0;
            switches[switch_count] = if (horizontal) (from.x + to.x) / 2 else (from.y + to.y) / 2;
            switch_count += 1;
            for (parser.nodes.items) |node| {
                switches[switch_count] = if (horizontal) node.x -| 8 else node.y -| 8;
                switch_count += 1;
                switches[switch_count] = if (horizontal) node.x + node.w + 8 else node.y + node.h + 8;
                switch_count += 1;
            }
            for (candidates[0..candidate_count]) |first_lane| for (candidates[0..candidate_count]) |second_lane| {
                if (first_lane == second_lane) continue;
                for (switches[0..switch_count]) |switch_position| {
                    var dogleg_route: [8]GridPoint = undefined;
                    if (horizontal) {
                        const source_slot = edge.from * 2;
                        const target_slot = edge.to * 2 + 1;
                        const source_y = spreadPort(from.y, from.h, source_port_ordinal[i], endpoint_count[source_slot]);
                        const target_y = spreadPort(to.y, to.h, target_port_ordinal[i], endpoint_count[target_slot]);
                        const source_x = horizontalPortX(from, source_y, reverse);
                        const target_x = horizontalPortX(to, target_y, !reverse);
                        const source_corridor_x = if (reverse) source_x + 18 else source_x -| 18;
                        const target_corridor_x = if (reverse) target_x -| 18 else target_x + 18;
                        if (switch_position <= @min(source_corridor_x, target_corridor_x) or switch_position >= @max(source_corridor_x, target_corridor_x)) continue;
                        dogleg_route = .{ .{ .x = source_x, .y = source_y }, .{ .x = source_corridor_x, .y = source_y }, .{ .x = source_corridor_x, .y = first_lane }, .{ .x = switch_position, .y = first_lane }, .{ .x = switch_position, .y = second_lane }, .{ .x = target_corridor_x, .y = second_lane }, .{ .x = target_corridor_x, .y = target_y }, .{ .x = target_x, .y = target_y } };
                    } else {
                        const source_slot = edge.from * 2;
                        const target_slot = edge.to * 2 + 1;
                        const source_x = spreadPort(from.x, from.w, source_port_ordinal[i], endpoint_count[source_slot]);
                        const target_x = spreadPort(to.x, to.w, target_port_ordinal[i], endpoint_count[target_slot]);
                        const source_y = verticalPortY(from, source_x, reverse);
                        const target_y = verticalPortY(to, target_x, !reverse);
                        const source_corridor_y = if (reverse) source_y + 18 else source_y -| 18;
                        const target_corridor_y = if (reverse) target_y -| 18 else target_y + 18;
                        if (switch_position <= @min(source_corridor_y, target_corridor_y) or switch_position >= @max(source_corridor_y, target_corridor_y)) continue;
                        dogleg_route = .{ .{ .x = source_x, .y = source_y }, .{ .x = source_x, .y = source_corridor_y }, .{ .x = first_lane, .y = source_corridor_y }, .{ .x = first_lane, .y = switch_position }, .{ .x = second_lane, .y = switch_position }, .{ .x = second_lane, .y = target_corridor_y }, .{ .x = target_x, .y = target_corridor_y }, .{ .x = target_x, .y = target_y } };
                    }
                    var score = routeNodeConflicts(&dogleg_route, parser.nodes.items, edge.from, edge.to) * 16;
                    for (final_forward_routes, final_forward_lengths, final_forward) |other_route, other_length, present| {
                        if (present) score += routeConflicts(&dogleg_route, other_route[0..other_length]);
                    }
                    if (score < best_score) {
                        best_score = score;
                        feedback_position[i] = first_lane;
                        feedback_secondary_position[i] = second_lane;
                        feedback_switch_position[i] = switch_position;
                        feedback_dogleg[i] = true;
                    }
                }
            };
        }
    }
    var final_feedback_routes: [256][8]GridPoint = undefined;
    var final_feedback_lengths = [_]usize{0} ** 256;
    var final_feedback = [_]bool{false} ** 256;
    for (parser.edges.items, 0..) |edge, i| {
        const from = parser.nodes.items[edge.from];
        const to = parser.nodes.items[edge.to];
        if (edge.from == edge.to or !reversed_edges[i]) continue;
        const offset = 24 + feedback_lanes[i] * 18;
        if (horizontal) {
            const source_slot = edge.from * 2;
            const target_slot = edge.to * 2 + 1;
            const source_y = spreadPort(from.y, from.h, source_port_ordinal[i], endpoint_count[source_slot]);
            const target_y = spreadPort(to.y, to.h, target_port_ordinal[i], endpoint_count[target_slot]);
            const source_x = horizontalPortX(from, source_y, reverse);
            const target_x = horizontalPortX(to, target_y, !reverse);
            const source_corridor_x = if (reverse) source_x + 18 else source_x -| 18;
            const target_corridor_x = if (reverse) target_x -| 18 else target_x + 18;
            const lane = if (feedback_internal[i]) feedback_position[i] else if (feedback_leading[i]) leading_extent - offset else content_bottom + offset;
            if (feedback_dogleg[i]) {
                final_feedback_routes[i] = .{ .{ .x = source_x, .y = source_y }, .{ .x = source_corridor_x, .y = source_y }, .{ .x = source_corridor_x, .y = feedback_position[i] }, .{ .x = feedback_switch_position[i], .y = feedback_position[i] }, .{ .x = feedback_switch_position[i], .y = feedback_secondary_position[i] }, .{ .x = target_corridor_x, .y = feedback_secondary_position[i] }, .{ .x = target_corridor_x, .y = target_y }, .{ .x = target_x, .y = target_y } };
                final_feedback_lengths[i] = 8;
            } else {
                const route = [_]GridPoint{ .{ .x = source_x, .y = source_y }, .{ .x = source_corridor_x, .y = source_y }, .{ .x = source_corridor_x, .y = lane }, .{ .x = target_corridor_x, .y = lane }, .{ .x = target_corridor_x, .y = target_y }, .{ .x = target_x, .y = target_y } };
                for (route, 0..) |point, point_i| final_feedback_routes[i][point_i] = point;
                final_feedback_lengths[i] = 6;
            }
        } else {
            const source_slot = edge.from * 2;
            const target_slot = edge.to * 2 + 1;
            const source_x = spreadPort(from.x, from.w, source_port_ordinal[i], endpoint_count[source_slot]);
            const target_x = spreadPort(to.x, to.w, target_port_ordinal[i], endpoint_count[target_slot]);
            const source_y = verticalPortY(from, source_x, reverse);
            const target_y = verticalPortY(to, target_x, !reverse);
            const source_corridor_y = if (reverse) source_y + 18 else source_y -| 18;
            const target_corridor_y = if (reverse) target_y -| 18 else target_y + 18;
            const lane = if (feedback_internal[i]) feedback_position[i] else if (feedback_leading[i]) leading_extent - offset else content_right + offset;
            if (feedback_dogleg[i]) {
                final_feedback_routes[i] = .{ .{ .x = source_x, .y = source_y }, .{ .x = source_x, .y = source_corridor_y }, .{ .x = feedback_position[i], .y = source_corridor_y }, .{ .x = feedback_position[i], .y = feedback_switch_position[i] }, .{ .x = feedback_secondary_position[i], .y = feedback_switch_position[i] }, .{ .x = feedback_secondary_position[i], .y = target_corridor_y }, .{ .x = target_x, .y = target_corridor_y }, .{ .x = target_x, .y = target_y } };
                final_feedback_lengths[i] = 8;
            } else {
                const route = [_]GridPoint{ .{ .x = source_x, .y = source_y }, .{ .x = source_x, .y = source_corridor_y }, .{ .x = lane, .y = source_corridor_y }, .{ .x = lane, .y = target_corridor_y }, .{ .x = target_x, .y = target_corridor_y }, .{ .x = target_x, .y = target_y } };
                for (route, 0..) |point, point_i| final_feedback_routes[i][point_i] = point;
                final_feedback_lengths[i] = 6;
            }
        }
        final_feedback[i] = true;
    }
    // Forward detours interact: moving a later edge can make a better lane
    // available to an earlier one. Revisit the set until those choices have
    // had a chance to propagate instead of freezing them in edge order.
    for (0..4) |_| refineForwardRoutesAgainst(parser.nodes.items, parser.edges.items, horizontal, &final_forward_routes, &final_forward_lengths, &final_forward, &final_feedback_routes, &final_feedback_lengths, &final_feedback);

    // Place labels after channel selection, treating every other connector in
    // the same layer gap as an obstacle. ELK feeds measured labels into the
    // router; choosing among the three orthogonal segments gives the same key
    // property without letting a connector run beneath a sibling's label.
    var label_hint_x = [_]usize{0} ** 256;
    var label_hint_y = [_]usize{0} ** 256;
    var label_hint_w = [_]usize{0} ** 256;
    var label_hint_h = [_]usize{0} ** 256;
    for (parser.edges.items, 0..) |edge, i| {
        if (edge.link.label.len == 0) continue;
        if (!final_forward[i] and !final_feedback[i]) continue;
        const route = if (final_forward[i])
            final_forward_routes[i][0..final_forward_lengths[i]]
        else
            final_feedback_routes[i][0..final_feedback_lengths[i]];
        const lw = edge.style.measure(paint.labelWidth(edge.link.label, edge.link.markdown));
        const lh = edge.style.measure(paint.labelHeight(edge.link.label));
        const anchor: GridPoint = if (expanded_guide.label_valid[i])
            (if (horizontal)
                .{ .x = expanded_guide.centers[expanded_guide.label_rank[i]], .y = expanded_guide.label_cross[i] }
            else
                .{ .x = expanded_guide.label_cross[i], .y = expanded_guide.centers[expanded_guide.label_rank[i]] })
        else
            routeLabelCenter(route, horizontal);
        var best_score: usize = std.math.maxInt(usize);
        var best = routeLabelCenter(route, horizontal);
        for (1..route.len) |segment| {
            for (1..4) |quarter| {
                const candidate: GridPoint = .{
                    .x = (route[segment - 1].x * (4 - quarter) + route[segment].x * quarter) / 4,
                    .y = (route[segment - 1].y * (4 - quarter) + route[segment].y * quarter) / 4,
                };
                const anchor_distance = (if (candidate.x > anchor.x) candidate.x - anchor.x else anchor.x - candidate.x) +
                    (if (candidate.y > anchor.y) candidate.y - anchor.y else anchor.y - candidate.y);
                var score: usize = anchor_distance / 8;
                for (final_forward_routes, final_forward_lengths, final_forward, 0..) |other_route, other_length, present, j| {
                    if (j != i and present) score += 16 * routeCrossesRect(other_route[0..other_length], candidate, lw, lh);
                }
                for (final_feedback_routes, final_feedback_lengths, final_feedback, 0..) |other_route, other_length, present, j| {
                    if (j != i and present) score += 16 * routeCrossesRect(other_route[0..other_length], candidate, lw, lh);
                }
                const left = candidate.x -| (lw / 2 + 4);
                const right = candidate.x + (lw + 1) / 2 + 4;
                const top = candidate.y -| (lh / 2 + 2);
                const bottom = candidate.y + (lh + 1) / 2 + 2;
                for (0..i) |j| if (label_hint_x[j] > 0) {
                    const other_left = label_hint_x[j] -| (label_hint_w[j] / 2 + 4);
                    const other_right = label_hint_x[j] + (label_hint_w[j] + 1) / 2 + 4;
                    const other_top = label_hint_y[j] -| (label_hint_h[j] / 2 + 2);
                    const other_bottom = label_hint_y[j] + (label_hint_h[j] + 1) / 2 + 2;
                    const label_gap: usize = 4;
                    if (right + label_gap > other_left and left < other_right + label_gap and bottom + label_gap > other_top and top < other_bottom + label_gap) score += 4096;
                };
                if (score < best_score) {
                    best_score = score;
                    best = candidate;
                }
            }
        }
        label_hint_x[i] = best.x;
        label_hint_y[i] = best.y;
        label_hint_w[i] = lw;
        label_hint_h[i] = lh;
    }
    // Resolve global conflicts without detaching a label from its connector.
    // ELK routes around label dummies; until the router consumes the complete
    // dummy chain, the safe equivalent is to reconsider only points that are
    // actually on this edge's orthogonal segments.
    for (0..2) |_| for (parser.edges.items, 0..) |edge, i| {
        if (edge.link.label.len == 0 or label_hint_x[i] == 0) continue;
        var best: GridPoint = .{ .x = label_hint_x[i], .y = label_hint_y[i] };
        var best_score: usize = std.math.maxInt(usize);
        const route = if (final_forward[i])
            final_forward_routes[i][0..final_forward_lengths[i]]
        else
            final_feedback_routes[i][0..final_feedback_lengths[i]];
        const anchor: GridPoint = if (expanded_guide.label_valid[i])
            (if (horizontal)
                .{ .x = expanded_guide.centers[expanded_guide.label_rank[i]], .y = expanded_guide.label_cross[i] }
            else
                .{ .x = expanded_guide.label_cross[i], .y = expanded_guide.centers[expanded_guide.label_rank[i]] })
        else
            routeLabelCenter(route, horizontal);
        for (1..route.len) |segment| for (1..8) |eighth| {
            const base: GridPoint = .{
                .x = (route[segment - 1].x * (8 - eighth) + route[segment].x * eighth) / 8,
                .y = (route[segment - 1].y * (8 - eighth) + route[segment].y * eighth) / 8,
            };
            const segment_vertical = route[segment - 1].x == route[segment].x;
            const normal_clearance = if (segment_vertical) (label_hint_w[i] + 1) / 2 + 8 else (label_hint_h[i] + 1) / 2 + 4;
            for ([_]usize{ 0, normal_clearance, normal_clearance + 12 }) |normal_offset| for ([_]bool{ false, true }) |negative| {
                if (normal_offset == 0 and negative) continue;
                var candidate = base;
                if (segment_vertical) {
                    candidate.x = if (negative) candidate.x -| normal_offset else candidate.x + normal_offset;
                } else {
                    candidate.y = if (negative) candidate.y -| normal_offset else candidate.y + normal_offset;
                }
                const anchor_distance = (if (candidate.x > anchor.x) candidate.x - anchor.x else anchor.x - candidate.x) +
                    (if (candidate.y > anchor.y) candidate.y - anchor.y else anchor.y - candidate.y);
                var score: usize = anchor_distance / 8 + normal_offset / 4;
                for (final_forward_routes, final_forward_lengths, final_forward, 0..) |other_route, other_length, present, j| {
                    if (j != i and present) score += 16 * routeCrossesRect(other_route[0..other_length], candidate, label_hint_w[i], label_hint_h[i]);
                }
                for (final_feedback_routes, final_feedback_lengths, final_feedback, 0..) |other_route, other_length, present, j| {
                    if (j != i and present) score += 16 * routeCrossesRect(other_route[0..other_length], candidate, label_hint_w[i], label_hint_h[i]);
                }
                const candidate_left = candidate.x -| (label_hint_w[i] / 2 + 4);
                const candidate_right = candidate.x + (label_hint_w[i] + 1) / 2 + 4;
                const candidate_top = candidate.y -| (label_hint_h[i] / 2 + 2);
                const candidate_bottom = candidate.y + (label_hint_h[i] + 1) / 2 + 2;
                for (parser.nodes.items) |node| {
                    const node_left = node.x;
                    const node_right = node.x + node.w;
                    const node_top = node.y;
                    const node_bottom = node.y + node.h;
                    if (candidate_right > node_left and candidate_left < node_right and candidate_bottom > node_top and candidate_top < node_bottom) score += 64;
                }
                for (label_hint_x, label_hint_y, label_hint_w, label_hint_h, 0..) |other_x, other_y, other_w, other_h, j| {
                    if (j == i or other_x == 0) continue;
                    const other_left = other_x -| (other_w / 2 + 4);
                    const other_right = other_x + (other_w + 1) / 2 + 4;
                    const other_top = other_y -| (other_h / 2 + 2);
                    const other_bottom = other_y + (other_h + 1) / 2 + 2;
                    // ELK reserves label rectangles as first-class routing
                    // obstacles. A label-on-label collision is therefore more
                    // expensive than crossing a connector and must not win a
                    // close-distance tie.
                    const label_gap: usize = 4;
                    if (candidate_right + label_gap > other_left and candidate_left < other_right + label_gap and candidate_bottom + label_gap > other_top and candidate_top < other_bottom + label_gap) score += 4096;
                }
                if (score < best_score) {
                    best_score = score;
                    best = candidate;
                }
            };
        };
        label_hint_x[i] = best.x;
        label_hint_y[i] = best.y;
    };
    var output: svg.Svg = .{ .allocator = allocator, .theme = theme };
    defer output.deinit();
    try output.start(width, height, "flowchart", prefix);
    try output.flowMarkers(prefix);
    var terminal_x = [_]usize{0} ** 256;
    var terminal_y = [_]usize{0} ** 256;
    var terminal_prev_x = [_]usize{0} ** 256;
    var terminal_prev_y = [_]usize{0} ** 256;
    var terminal_valid = [_]bool{false} ** 256;
    var marker_paths = [_]?[]u8{null} ** 256;
    defer for (marker_paths) |path_value| if (path_value) |value| allocator.free(value);
    for (parser.edges.items, 0..) |edge, i| {
        if (edge.link.stroke == .invisible) continue;
        try paint.begin(&output, edge.style);
        const from = parser.nodes.items[edge.from];
        const to = parser.nodes.items[edge.to];
        const x1 = from.x + from.w / 2;
        const y1 = from.y + from.h / 2;
        const x2 = to.x + to.w / 2;
        const y2 = to.y + to.h / 2;
        var label_x = (x1 + x2) / 2;
        var label_y = (y1 + y2) / 2;
        try output.add("<path fill=\"none\" ");
        try output.fmt("data-edge=\"{d}\" ", .{i});
        try @import("interaction.zig").classAttribute(&output, edge.classes);
        try output.add(" ");
        if (edge.id.len > 0) try output.fmt("id=\"zm-{d}-edge-{s}\" data-edge-id=\"{s}\" ", .{ prefix, edge.id, edge.id });
        // End markers are painted once in the terminal overlay after nodes.
        // Leaving one on this underlying route creates two tips a few pixels
        // apart, which reads as a playing-card spade.
        if (edge.link.start != .none) try output.fmt("marker-start=\"url(#zm-{d}-{s})\" ", .{ prefix, @tagName(edge.link.start) });
        if (edge.link.stroke == .dotted and edge.style.dash == null) try output.add("stroke-dasharray=\"5 4\" ");
        if (edge.link.stroke == .thick and edge.style.width == null) try output.add("stroke-width=\"3\" ");
        const geometry_start = output.bytes.items.len;
        const feedback = reversed_edges[i];
        if (edge.from == edge.to) {
            const right = shapes.anchor(from.shape, from.x, from.y, from.w, from.h, .right);
            try links.terminalCubic(&output, links.point(right.x, y1), links.point(from.x + from.w + 72, y1), links.point(x1, from.y + from.h + 72), links.point(x1, from.y + from.h));
            try output.add("/>");
            terminal_x[i] = x1;
            terminal_y[i] = from.y + from.h;
            terminal_prev_x[i] = x1;
            terminal_prev_y[i] = terminal_y[i] + 12;
            terminal_valid[i] = true;
            label_x = from.x + from.w + 25;
            label_y = from.y + from.h + 20;
        } else if (horizontal) {
            const start_x = shapes.anchor(from.shape, from.x, from.y, from.w, from.h, if (reverse) .left else .right).x;
            const end_x = shapes.anchor(to.shape, to.x, to.y, to.w, to.h, if (reverse) .right else .left).x;
            label_x = (start_x + end_x) / 2;
            if (feedback) {
                const leading = feedback_leading[i];
                const offset = 24 + feedback_lanes[i] * 18;
                const lane_y = if (feedback_internal[i]) feedback_position[i] else if (leading) leading_extent - offset else content_bottom + offset;
                // Return edges use the backward-facing source port and the
                // target's forward-facing port, matching layered graph routes.
                const source_slot = edge.from * 2;
                const target_slot = edge.to * 2 + 1;
                const source_y = spreadPort(from.y, from.h, source_port_ordinal[i], endpoint_count[source_slot]);
                const target_y = spreadPort(to.y, to.h, target_port_ordinal[i], endpoint_count[target_slot]);
                const source_x = horizontalPortX(from, source_y, reverse);
                const target_x = horizontalPortX(to, target_y, !reverse);
                const source_corridor_x = if (reverse) source_x + 18 else source_x -| 18;
                const target_corridor_x = if (reverse) target_x -| 18 else target_x + 18;
                const points = if (feedback_dogleg[i])
                    [_]links.Point{ links.point(source_x, source_y), links.point(source_corridor_x, source_y), links.point(source_corridor_x, feedback_position[i]), links.point(feedback_switch_position[i], feedback_position[i]), links.point(feedback_switch_position[i], feedback_secondary_position[i]), links.point(target_corridor_x, feedback_secondary_position[i]), links.point(target_corridor_x, target_y), links.point(target_x, target_y) }
                else
                    [_]links.Point{ links.point(source_x, source_y), links.point(source_corridor_x, source_y), links.point(source_corridor_x, lane_y), links.point(target_corridor_x, lane_y), links.point(target_corridor_x, target_y), links.point(target_x, target_y), links.point(target_x, target_y), links.point(target_x, target_y) };
                try links.roundedPolyline(&output, if (feedback_dogleg[i]) &points else points[0..6]);
                terminal_x[i] = target_x;
                terminal_y[i] = target_y;
                terminal_prev_x[i] = target_corridor_x;
                terminal_prev_y[i] = target_y;
                terminal_valid[i] = true;
                const label = directionalSegmentLabel(if (feedback_dogleg[i]) &points else points[0..6], true);
                label_x = @intFromFloat(label.x);
                label_y = @intFromFloat(label.y);
            } else {
                const start_slot = edge.from * 2 + 1;
                const end_slot = edge.to * 2;
                const start_y = spreadPort(from.y, from.h, source_port_ordinal[i], endpoint_count[start_slot]);
                const end_y = spreadPort(to.y, to.h, target_port_ordinal[i], endpoint_count[end_slot]);
                const routed_start_x = horizontalPortX(from, start_y, !reverse);
                const routed_end_x = horizontalPortX(to, end_y, reverse);
                var label = forwardLabel(routed_start_x, start_y, routed_end_x, end_y, true);
                if (edge.curve == .rounded and final_forward_lengths[i] > 4) {
                    var points: [8]links.Point = undefined;
                    for (final_forward_routes[i][0..final_forward_lengths[i]], 0..) |point, point_i| points[point_i] = links.point(point.x, point.y);
                    try links.roundedPolyline(&output, points[0..final_forward_lengths[i]]);
                    label = directionalSegmentLabel(points[0..final_forward_lengths[i]], true);
                } else if (edge.curve == .rounded and gap_count[i] > 1) {
                    const lane_x = if (labelled_count[from.rank] > 1)
                        advanceToward(routed_start_x, routed_end_x, @max(@as(usize, 20), labelled_extent[from.rank] + 8) * (gap_count[i] - gap_ordinal[i]))
                    else
                        (routed_start_x * (gap_count[i] - gap_ordinal[i]) + routed_end_x * (gap_ordinal[i] + 1)) / (gap_count[i] + 1);
                    const points = [_]links.Point{ links.point(routed_start_x, start_y), links.point(lane_x, start_y), links.point(lane_x, end_y), links.point(routed_end_x, end_y) };
                    try links.roundedPolyline(&output, &points);
                    label = directionalSegmentLabel(&points, true);
                } else try links.route(&output, edge.curve, routed_start_x, start_y, routed_end_x, end_y, true);
                terminal_x[i] = routed_end_x;
                terminal_y[i] = end_y;
                if (final_forward_lengths[i] > 4) {
                    terminal_prev_x[i] = final_forward_routes[i][final_forward_lengths[i] - 2].x;
                    terminal_prev_y[i] = final_forward_routes[i][final_forward_lengths[i] - 2].y;
                } else {
                    terminal_prev_x[i] = if (routed_end_x >= routed_start_x) routed_end_x -| 12 else routed_end_x + 12;
                    terminal_prev_y[i] = end_y;
                }
                terminal_valid[i] = true;
                label_x = @intFromFloat(label.x);
                label_y = @intFromFloat(label.y);
            }
        } else {
            const start_y = shapes.anchor(from.shape, from.x, from.y, from.w, from.h, if (reverse) .top else .bottom).y;
            const end_y = shapes.anchor(to.shape, to.x, to.y, to.w, to.h, if (reverse) .bottom else .top).y;
            label_y = (start_y + end_y) / 2;
            if (feedback) {
                const leading = feedback_leading[i];
                const offset = 24 + feedback_lanes[i] * 18;
                const lane_x = if (feedback_internal[i]) feedback_position[i] else if (leading) leading_extent - offset else content_right + offset;
                // Upward returns leave through the source top and re-enter the
                // target bottom (reversed for BT), using an exterior channel.
                const source_slot = edge.from * 2;
                const target_slot = edge.to * 2 + 1;
                const source_x = spreadPort(from.x, from.w, source_port_ordinal[i], endpoint_count[source_slot]);
                const target_x = spreadPort(to.x, to.w, target_port_ordinal[i], endpoint_count[target_slot]);
                const source_y = verticalPortY(from, source_x, reverse);
                const target_y = verticalPortY(to, target_x, !reverse);
                const source_corridor_y = if (reverse) source_y + 18 else source_y -| 18;
                const target_corridor_y = if (reverse) target_y -| 18 else target_y + 18;
                const points = if (feedback_dogleg[i])
                    [_]links.Point{ links.point(source_x, source_y), links.point(source_x, source_corridor_y), links.point(feedback_position[i], source_corridor_y), links.point(feedback_position[i], feedback_switch_position[i]), links.point(feedback_secondary_position[i], feedback_switch_position[i]), links.point(feedback_secondary_position[i], target_corridor_y), links.point(target_x, target_corridor_y), links.point(target_x, target_y) }
                else
                    [_]links.Point{ links.point(source_x, source_y), links.point(source_x, source_corridor_y), links.point(lane_x, source_corridor_y), links.point(lane_x, target_corridor_y), links.point(target_x, target_corridor_y), links.point(target_x, target_y), links.point(target_x, target_y), links.point(target_x, target_y) };
                try links.roundedPolyline(&output, if (feedback_dogleg[i]) &points else points[0..6]);
                terminal_x[i] = target_x;
                terminal_y[i] = target_y;
                terminal_prev_x[i] = target_x;
                terminal_prev_y[i] = target_corridor_y;
                terminal_valid[i] = true;
                const label = directionalSegmentLabel(if (feedback_dogleg[i]) &points else points[0..6], false);
                label_x = @intFromFloat(label.x);
                label_y = @intFromFloat(label.y);
            } else {
                const start_slot = edge.from * 2 + 1;
                const end_slot = edge.to * 2;
                const start_x = spreadPort(from.x, from.w, source_port_ordinal[i], endpoint_count[start_slot]);
                const end_x = spreadPort(to.x, to.w, target_port_ordinal[i], endpoint_count[end_slot]);
                const routed_start_y = verticalPortY(from, start_x, !reverse);
                const routed_end_y = verticalPortY(to, end_x, reverse);
                var label = forwardLabel(start_x, routed_start_y, end_x, routed_end_y, false);
                if (edge.curve == .rounded and final_forward_lengths[i] > 4) {
                    var points: [8]links.Point = undefined;
                    for (final_forward_routes[i][0..final_forward_lengths[i]], 0..) |point, point_i| points[point_i] = links.point(point.x, point.y);
                    try links.roundedPolyline(&output, points[0..final_forward_lengths[i]]);
                    label = directionalSegmentLabel(points[0..final_forward_lengths[i]], false);
                } else if (edge.curve == .rounded and gap_count[i] > 1) {
                    const lane_y = if (labelled_count[from.rank] > 1)
                        advanceToward(routed_start_y, routed_end_y, @max(@as(usize, 20), labelled_extent[from.rank] + 8) * (gap_count[i] - gap_ordinal[i]))
                    else
                        (routed_start_y * (gap_count[i] - gap_ordinal[i]) + routed_end_y * (gap_ordinal[i] + 1)) / (gap_count[i] + 1);
                    const points = [_]links.Point{ links.point(start_x, routed_start_y), links.point(start_x, lane_y), links.point(end_x, lane_y), links.point(end_x, routed_end_y) };
                    try links.roundedPolyline(&output, &points);
                    label = directionalSegmentLabel(&points, false);
                } else try links.route(&output, edge.curve, start_x, routed_start_y, end_x, routed_end_y, false);
                terminal_x[i] = end_x;
                terminal_y[i] = routed_end_y;
                if (final_forward_lengths[i] > 4) {
                    terminal_prev_x[i] = final_forward_routes[i][final_forward_lengths[i] - 2].x;
                    terminal_prev_y[i] = final_forward_routes[i][final_forward_lengths[i] - 2].y;
                } else {
                    terminal_prev_x[i] = end_x;
                    terminal_prev_y[i] = if (routed_end_y >= routed_start_y) routed_end_y -| 12 else routed_end_y + 12;
                }
                terminal_valid[i] = true;
                label_x = @intFromFloat(label.x);
                label_y = @intFromFloat(label.y);
            }
        }
        if (edge.link.end != .none) {
            const geometry = output.bytes.items[geometry_start..];
            if (std.mem.indexOf(u8, geometry, "d=\"")) |start| {
                const end = std.mem.indexOfScalarPos(u8, geometry, start + 3, '"') orelse return error.InvalidSyntax;
                marker_paths[i] = try allocator.dupe(u8, geometry[start + 3 .. end]);
            }
        }
        if (label_hint_x[i] > 0) {
            label_x = label_hint_x[i];
            label_y = label_hint_y[i];
        }
        if (edge.link.label.len > 0) {
            const label_width = edge.style.measure(paint.labelWidth(edge.link.label, edge.link.markdown));
            const label_height = edge.style.measure(paint.labelHeight(edge.link.label));
            const background = if (theme == .dark) "#0d1117" else "#ffffff";
            try output.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"3\" fill=\"{s}\" stroke=\"none\"/>", .{ label_x -| label_width / 2 -| 4, label_y -| label_height / 2 -| 2, label_width + 8, label_height + 4, background });
            try paint.textAssets(&output, label_x, label_y -| label_height / 2, edge.link.label, edge.style, edge.link.markdown, parser.assets);
        }
        try output.add("</g>");
    }
    for (parser.nodes.items, 0..) |node, i| {
        try output.fmt("<g data-node=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-width=\"{d}\" data-height=\"{d}\">", .{ i, node.x, node.y, node.w, node.h });
        try paint.node(&output, node, node.w, node.h);
        try output.add("</g>");
    }
    // Paint only the marker above node fills, using the full original route.
    // A second shortened shaft changes the tangent and hides routing defects.
    for (parser.edges.items, 0..) |edge, i| {
        if (!terminal_valid[i] or edge.link.stroke == .invisible or edge.link.end == .none) continue;
        try paint.begin(&output, edge.style);
        const route = marker_paths[i] orelse continue;
        try output.fmt("<path fill=\"none\" stroke=\"none\" d=\"{s}\" marker-end=\"url(#zm-{d}-{s})\"", .{ route, prefix, @tagName(edge.link.end) });
        if (edge.link.stroke == .dotted and edge.style.dash == null) try output.add(" stroke-dasharray=\"5 4\"");
        if (edge.link.stroke == .thick and edge.style.width == null) try output.add(" stroke-width=\"3\"");
        try output.add("/></g>");
    }
    return output.finish();
}

test "grouped chains expand to the correct endpoint pairs" {
    var parser: Parser = .{ .allocator = std.testing.allocator };
    defer parser.deinit();
    try parser.statement("A & B --> C & D --> E");
    try std.testing.expectEqual(@as(usize, 5), parser.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 6), parser.edges.items.len);
    const pairs = [_][2]usize{ .{ 0, 2 }, .{ 0, 3 }, .{ 1, 2 }, .{ 1, 3 }, .{ 2, 4 }, .{ 3, 4 } };
    for (parser.edges.items, pairs) |edge, pair| {
        try std.testing.expectEqual(pair[0], edge.from);
        try std.testing.expectEqual(pair[1], edge.to);
    }
    try parser.statement("C[Updated label]");
    try std.testing.expectEqualStrings("Updated label", parser.nodes.items[2].label);
}

test "long and invisible edges change layout rather than just appearance" {
    const a = std.testing.allocator;
    const short = try render(a, "flowchart LR; A-->B", .light, 1);
    defer a.free(short);
    const long = try render(a, "flowchart LR; A---->B", .light, 1);
    defer a.free(long);
    const hidden = try render(a, "flowchart LR; A~~~~~B", .light, 1);
    defer a.free(hidden);
    try std.testing.expect(std.mem.indexOf(u8, short, "viewBox=\"0 0 205 76\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, long, "viewBox=\"0 0 295 76\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "viewBox=\"0 0 295 76\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "data-edge=") == null);
}

test "modern metadata decoded labels and styled compound graphs release allocations" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "flowchart LR; A@{shape:doc,label:\"A<br/>B #9829;\"}; A@{label:\"Updated\"}",
        "flowchart TD; subgraph Parent; direction LR; subgraph Child; A-->B; end; C; end; Outside-->Parent; style Parent fill:#eee; class A,B hot; classDef hot fill:red,color:blue",
    }) |source| {
        const result = try render(a, source, .light, 42);
        defer a.free(result);
        try std.testing.expect(std.mem.startsWith(u8, result, "<svg "));
    }
}
