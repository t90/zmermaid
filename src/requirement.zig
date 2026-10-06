const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const rich = @import("rich_text.zig");
const flow = @import("flowchart.zig");
const compound = @import("flow_compound.zig");
const getNode = @import("class.zig").getNode;
fn oneOf(s: []const u8, values: []const []const u8) bool {
    for (values) |v| if (std.ascii.eqlIgnoreCase(s, v)) return true;
    return false;
}
fn name(rest: *[]const u8) d.Error![]const u8 {
    rest.* = d.trim(rest.*);
    if (rest.len == 0) return error.InvalidSyntax;
    var value: []const u8 = undefined;
    if (rest.*[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, rest.*, 1, '"') orelse return error.InvalidSyntax;
        value = rest.*[1..end];
        rest.* = rest.*[end + 1 ..];
    } else {
        const end = std.mem.indexOfAny(u8, rest.*, " \t:{<") orelse rest.len;
        value = rest.*[0..end];
        rest.* = rest.*[end..];
    }
    if (value.len == 0 or value.len > 512) return error.InvalidSyntax;
    rest.* = d.trim(rest.*);
    return value;
}
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var graph: flow.Parser = .{ .allocator = temp, .kind = "requirement" };
    defer graph.deinit();
    var defined = [_]bool{false} ** 256;
    var active: ?usize = null;
    var element = false;
    var fields: u8 = 0;
    var direction: []const u8 = "TB";
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (active) |id| {
            if (std.mem.eql(u8, line, "}")) {
                active = null;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
            const key = d.trim(line[0..colon]);
            const value = d.unquote(line[colon + 1 ..]);
            const keys = if (element) &[_][]const u8{ "type", "docRef" } else &[_][]const u8{ "id", "text", "risk", "verifymethod" };
            const labels = if (element) &[_][]const u8{ "Type", "Doc Ref" } else &[_][]const u8{ "ID", "Text", "Risk", "Verification" };
            var found = false;
            for (keys, 0..) |key_name, i| if (std.ascii.eqlIgnoreCase(key, key_name)) {
                const bit = @as(u8, 1) << @as(u3, @intCast(i));
                if (fields & bit != 0) return error.InvalidSyntax;
                fields |= bit;
                if (!element and i == 2 and !oneOf(value, &.{ "low", "medium", "high" })) return error.InvalidSyntax;
                if (!element and i == 3 and !oneOf(value, &.{ "analysis", "demonstration", "inspection", "test" })) return error.InvalidSyntax;
                try graph.nodes.items[id].members.append(temp, .{ .text = try std.fmt.allocPrint(temp, "{s}: {s}", .{ labels[i], try rich.parse(temp, value) }) });
                found = true;
                break;
            };
            if (!found) return error.UnsupportedSyntax;
            continue;
        }
        if (txt.starts(line, "direction ")) {
            direction = d.trim(line[10..]);
            if (!compound.validDirection(direction)) return error.InvalidSyntax;
            continue;
        }
        if (txt.starts(line, "classDef ") or txt.starts(line, "class ") or txt.starts(line, "style ")) {
            try graph.statement(line);
            continue;
        }
        var rest = line;
        const first = try name(&rest);
        if (oneOf(first, &.{ "requirement", "functionalRequirement", "interfaceRequirement", "performanceRequirement", "physicalRequirement", "designConstraint", "element" })) {
            const id = try getNode(&graph, try name(&rest), null, true);
            if (defined[id]) return error.InvalidSyntax;
            defined[id] = true;
            graph.nodes.items[id].markdown = true;
            graph.nodes.items[id].hide_empty = true;
            graph.nodes.items[id].label = try rich.parse(temp, graph.nodes.items[id].id);
            graph.nodes.items[id].annotation = try std.fmt.allocPrint(temp, "«{s}»", .{first});
            if (txt.starts(rest, ":::")) {
                rest = rest[3..];
                graph.nodes.items[id].classes = try name(&rest);
            }
            if (!std.mem.eql(u8, rest, "{")) return error.InvalidSyntax;
            active = id;
            element = std.ascii.eqlIgnoreCase(first, "element");
            fields = 0;
            continue;
        }
        const from = try getNode(&graph, first, null, true);
        if (txt.starts(rest, ":::")) {
            rest = rest[3..];
            graph.nodes.items[from].classes = try name(&rest);
            if (rest.len > 0) return error.InvalidSyntax;
            continue;
        }
        const reversed = txt.starts(rest, "<-");
        if (!reversed and !txt.starts(rest, "-")) return error.InvalidSyntax;
        rest = d.trim(rest[if (reversed) @as(usize, 2) else 1..]);
        const relationship = try name(&rest);
        if (!oneOf(relationship, &.{ "contains", "copies", "derives", "satisfies", "verifies", "refines", "traces" })) return error.InvalidSyntax;
        const finish = if (reversed) "-" else "->";
        if (!txt.starts(rest, finish)) return error.InvalidSyntax;
        rest = rest[finish.len..];
        const to = try getNode(&graph, try name(&rest), null, true);
        if (rest.len > 0) return error.InvalidSyntax;
        if (graph.edges.items.len == 512) return error.LimitExceeded;
        const contains = std.ascii.eqlIgnoreCase(relationship, "contains");
        try graph.edges.append(temp, .{ .from = if (reversed) to else from, .to = if (reversed) from else to, .link = .{ .start = if (contains) .contains else .none, .end = if (contains) .none else .open, .stroke = if (contains) .normal else .dotted, .label = try std.fmt.allocPrint(temp, "«{s}»", .{relationship}) } });
    }
    if (active != null or graph.nodes.items.len == 0) return error.InvalidSyntax;
    for (defined[0..graph.nodes.items.len]) |v| if (!v) return error.InvalidSyntax;
    try graph.resolveStyles();
    try doc.graphTheme(&graph);
    return compound.render(a, &graph, doc.theme, prefix, direction);
}
