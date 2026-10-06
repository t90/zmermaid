const std = @import("std");
const svg = @import("svg.zig");
const styles = @import("chart_style.zig");
/// Shared decision appearance for measured and legacy graph painters.
pub fn beginDecision(out: *svg.Svg, shape: shapes.Shape, style: anytype) !bool {
    const enabled = shape == .diamond and style.fill == null and style.stroke == null;
    if (enabled) try out.fmt("<g data-decision-style=\"default\" fill=\"{s}\" stroke=\"{s}\" stroke-dasharray=\"3 3\">", .{
        if (out.theme == .dark) "#111827" else "#fafafa",
        if (out.theme == .dark) "#94a3b8" else "#d1d5db",
    });
    return enabled;
}
pub fn labelWidth(value: []const u8, markdown: bool) usize {
    return if (markdown) @import("rich_text.zig").width(value) else txt.width(value);
}
pub fn labelHeight(value: []const u8) usize {
    var lines = std.mem.splitScalar(u8, value, '\n');
    var total: usize = 0;
    while (lines.next()) |line| total += lineHeight(line);
    return total;
}
pub fn lineHeight(value: []const u8) usize {
    var height = @import("inline_image.zig").height(value);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, value, at, "$$")) |start| {
        const len = @import("math_text.zig").token(value[start..]) orelse break;
        const layout = @import("math_text.zig").Layout.init(value[start .. start + len]) catch {
            at = start + len;
            continue;
        };
        height = @max(height, layout.pixelHeight() + 4);
        at = start + len;
    }
    return height;
}
pub fn hasMedia(value: []const u8) bool {
    return @import("inline_image.zig").find(value, 0) != null or std.mem.indexOf(u8, value, "$$") != null;
}
pub fn imageEdgePadding(edges: anytype) struct { w: usize = 0, h: usize = 0 } {
    var size: struct { w: usize = 0, h: usize = 0 } = .{};
    for (edges) |edge| if (hasMedia(edge.link.label)) {
        size.w = @max(size.w, edge.style.measure(labelWidth(edge.link.label, edge.link.markdown)) / 2 + 40);
        size.h = @max(size.h, edge.style.measure(labelHeight(edge.link.label)) + 40);
    };
    return .{ .w = size.w, .h = size.h };
}
const shapes = @import("flow_shapes.zig");
const txt = @import("sequence_text.zig");
pub fn begin(out: *svg.Svg, style: styles.Style) !void {
    try out.add("<g");
    if (style.fill) |v| try out.fmt(" fill=\"{s}\" style=\"--zm-node-fill:{s}\"", .{ v, v });
    if (style.stroke) |v| try out.fmt(" stroke=\"{s}\"", .{v});
    if (style.width) |v| try out.fmt(" stroke-width=\"{d}\"", .{v});
    if (style.dash) |v| {
        try out.add(" stroke-dasharray=\"");
        for (v) |c| if (c != '\\') {
            try out.bytes.append(out.allocator, c);
        };
        try out.add("\"");
    } else if ((style.animation orelse 0) > 0) try out.add(" stroke-dasharray=\"9 5\"");
    if (style.offset) |v| try out.fmt(" stroke-dashoffset=\"{d}\"", .{v});
    try out.add(">");
    if (style.animation) |seconds| if (seconds > 0) {
        const distance = style.offset orelse 28;
        try out.fmt("<animate attributeName=\"stroke-dashoffset\" from=\"{d}\" to=\"0\" dur=\"{d}s\" repeatCount=\"indefinite\"/>", .{ distance, seconds });
    };
}
pub fn text(out: *svg.Svg, x: usize, y: usize, value: []const u8, style: styles.Style) !void {
    try textMode(out, x, y, value, style, false);
}
pub fn textMode(out: *svg.Svg, x: usize, y: usize, value: []const u8, style: styles.Style, markdown: bool) !void {
    try textAssets(out, x, y, value, style, markdown, null);
}
pub fn textAssets(out: *svg.Svg, x: usize, y: usize, value: []const u8, style: styles.Style, markdown: bool, registry: ?*const @import("assets.zig").Registry) @import("sequence_text.zig").Error!void {
    try out.add("<g");
    if (style.italic) |v| try out.fmt(" font-style=\"{s}\"", .{if (v) "italic" else "normal"});
    if (style.bold) |v| try out.fmt(" font-weight=\"{s}\"", .{if (v) "bold" else "normal"});
    const sized = style.font_size != null and style.font_size.? != 14;
    const anchor = if (sized) labelWidth(value, markdown) / 2 + 32 else x;
    if (sized) try out.fmt(" transform=\"translate({d} {d}) scale({d}) translate(-{d} 0)\"", .{ x, y, style.font_size.? / 14, anchor });
    try out.add(">");
    var lines = std.mem.splitScalar(u8, value, '\n');
    var top = if (sized) @as(usize, 0) else y;
    const fg = style.text orelse if (out.theme == .dark) "#e0e0e0" else "#24292f";
    while (lines.next()) |line| {
        const line_height = lineHeight(line);
        const middle = top + line_height / 2;
        if (hasMedia(line)) {
            const empty: @import("assets.zig").Registry = .{};
            try @import("assets.zig").inlineText(out, registry orelse &empty, line, anchor, middle, fg, true);
        } else if (registry != null and @import("assets.zig").inlineIcon(line, 0) != null) try @import("assets.zig").inlineText(out, registry.?, line, anchor, middle, fg, markdown) else if (markdown) try @import("rich_text.zig").draw(out, anchor, middle, line, fg) else try out.textColor(anchor, middle, line, fg);
        top += line_height;
    }
    try out.add("</g>");
}
pub fn node(out: *svg.Svg, n: anytype, w: usize, h: usize) !void {
    try @import("interaction.zig").begin(out, n.action, n.id, n.classes);
    try begin(out, n.style);
    if (n.asset) |asset| {
        const icon_x = n.x + (w - n.asset_width) / 2;
        const icon_y = n.y + 20 + (if (n.asset_top and n.label.len > 0) n.style.measure(labelHeight(n.label)) + 16 else @as(usize, 0));
        if (std.mem.eql(u8, n.asset_form, "circle")) try out.fmt("<ellipse cx=\"{d}\" cy=\"{d}\" rx=\"{d}\" ry=\"{d}\"/>", .{ icon_x + n.asset_width / 2, icon_y + n.asset_height / 2, n.asset_width / 2 + 8, n.asset_height / 2 + 8 }) else if (!std.mem.eql(u8, n.asset_form, "none")) try out.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"{d}\"/>", .{ icon_x - 8, icon_y - 8, n.asset_width + 16, n.asset_height + 16, if (std.mem.eql(u8, n.asset_form, "rounded")) @as(usize, 8) else 0 });
        try @import("assets.zig").draw(out, asset, icon_x, icon_y, n.asset_width, n.asset_height);
        if (n.label.len > 0) try textAssets(out, n.x + w / 2, if (n.asset_top) n.y + 12 else icon_y + n.asset_height + 16, n.label, n.style, n.markdown, n.assets);
        try out.add("</g>");
        try @import("interaction.zig").end(out, n.action);
        return;
    }
    if (n.table) {
        try out.fmt("<rect data-compartments=\"true\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\"/>", .{ n.x, n.y, w, h });
        var top = n.y + 12;
        if (n.annotation.len > 0) {
            try text(out, n.x + w / 2, top, n.annotation, n.style);
            top += n.style.measure(labelHeight(n.annotation)) + 8;
        }
        try textMode(out, n.x + w / 2, top, n.label, n.style, n.markdown);
        top += n.style.measure(labelHeight(n.label)) + 12;
        if (n.members.items.len > 0 or !n.hide_empty) try out.fmt("<path d=\"M {d} {d} H {d}\" fill=\"none\"/>", .{ n.x, top, n.x + w });
        if (n.entity and n.members.items.len > 0) {
            var column_x = n.x;
            for (n.columns) |cw| {
                column_x += cw;
                if (column_x < n.x + w and cw > 0) try out.fmt("<path d=\"M {d} {d} V {d}\" fill=\"none\"/>", .{ column_x, top, n.y + h });
            }
            for (n.members.items, 0..) |member, row| {
                top += 6;
                column_x = n.x;
                try out.fmt("<g data-attribute=\"{d}\">", .{row});
                for (member.cells, 0..) |cell, c| {
                    if (cell.len > 0) try text(out, column_x + 12 + n.style.measure(txt.width(cell)) / 2, top, cell, n.style);
                    column_x += n.columns[c];
                }
                try out.add("</g>");
                top += n.style.measure(labelHeight(member.text)) + 6;
                if (row + 1 < n.members.items.len) try out.fmt("<path d=\"M {d} {d} H {d}\" fill=\"none\"/>", .{ n.x, top, n.x + w });
            }
            try out.add("</g>");
            try @import("interaction.zig").end(out, n.action);
            return;
        }
        var methods = false;
        for ([_]bool{ false, true }) |method| for (n.members.items) |member| {
            if (member.method != method) continue;
            if (method and !methods) {
                methods = true;
                try out.fmt("<path d=\"M {d} {d} H {d}\" fill=\"none\"/>", .{ n.x, top, n.x + w });
            }
            top += 6;
            try out.fmt("<g font-style=\"{s}\" text-decoration=\"{s}\">", .{ if (member.italic) "italic" else "normal", if (member.underlined) "underline" else "none" });
            try textMode(out, n.x + 16 + n.style.measure(labelWidth(member.text, member.markdown or n.markdown)) / 2, top, member.text, n.style, member.markdown or n.markdown);
            try out.add("</g>");
            top += n.style.measure(labelHeight(member.text)) + 6;
        };
        try out.add("</g>");
        try @import("interaction.zig").end(out, n.action);
        return;
    }
    const default_decision = try beginDecision(out, n.shape, n.style);
    try shapes.draw(out, n.shape, n.x, n.y, w, h);
    if (default_decision) try out.add("</g>");
    if (n.collapsed) try out.fmt("<path data-collapsed=\"true\" d=\"M {d} {d} h 12 v 12 h -12 Z m 2 6 h 8 m -4 -4 v 8\" fill=\"none\"/>", .{ n.x + w - 22, n.y + h - 22 });
    try textAssets(out, n.x + w / 2, n.y + if (shapes.externalLabel(n.shape)) h + 4 else (h - n.style.measure(labelHeight(n.label))) / 2, n.label, n.style, n.markdown, n.assets);
    try out.add("</g>");
    try @import("interaction.zig").end(out, n.action);
}
