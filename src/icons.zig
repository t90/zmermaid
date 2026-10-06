const std = @import("std");
const svg = @import("svg.zig");
pub fn known(name: []const u8) bool {
    for ([_][]const u8{ "cloud", "database", "disk", "server", "internet", "file", "folder" }) |v| if (std.mem.eql(u8, name, v)) return true;
    return false;
}
pub fn drawRegistered(out: *svg.Svg, registry: *const @import("assets.zig").Registry, name: []const u8, x: usize, y: usize, size: usize) @import("sequence_text.zig").Error!void {
    if (known(name)) return draw(out, name, x, y, size);
    try @import("assets.zig").draw(out, try registry.get(name), x, y, size, size);
}
// Small, independently drawn symbols in a shared 64-unit coordinate system.
pub fn draw(out: *svg.Svg, name: []const u8, x: usize, y: usize, size: usize) !void {
    try out.fmt("<g data-icon=\"{s}\" transform=\"translate({d} {d}) scale({d:.5})\" stroke-width=\"2\">", .{ name, x, y, @as(f64, @floatFromInt(size)) / 64 });
    if (std.mem.eql(u8, name, "cloud")) try out.add("<path d=\"M 16 48 C 1 48 1 27 15 25 C 15 5 46 5 49 24 C 67 24 68 48 49 48 Z\"/>") else if (std.mem.eql(u8, name, "database")) try out.add("<path d=\"M 8 14 C 8 2 56 2 56 14 V 50 C 56 62 8 62 8 50 Z\"/><ellipse cx=\"32\" cy=\"14\" rx=\"24\" ry=\"9\"/><path d=\"M 8 31 C 8 43 56 43 56 31 M 8 46 C 8 58 56 58 56 46\" fill=\"none\"/>") else if (std.mem.eql(u8, name, "server")) try out.add("<rect x=\"10\" y=\"4\" width=\"44\" height=\"56\" rx=\"5\"/><path d=\"M 10 23 H 54 M 10 41 H 54 M 29 14 H 46 M 29 32 H 46 M 29 50 H 46\"/><circle cx=\"20\" cy=\"14\" r=\"2\"/><circle cx=\"20\" cy=\"32\" r=\"2\"/><circle cx=\"20\" cy=\"50\" r=\"2\"/>") else if (std.mem.eql(u8, name, "disk")) try out.add("<rect x=\"7\" y=\"5\" width=\"50\" height=\"54\" rx=\"5\"/><circle cx=\"32\" cy=\"29\" r=\"17\"/><circle cx=\"32\" cy=\"29\" r=\"4\"/><path d=\"M 48 49 L 31 34 L 27 38 Z\"/>") else if (std.mem.eql(u8, name, "internet")) try out.add("<circle cx=\"32\" cy=\"32\" r=\"28\"/><ellipse cx=\"32\" cy=\"32\" rx=\"13\" ry=\"28\" fill=\"none\"/><path d=\"M 4 32 H 60 M 9 17 H 55 M 9 47 H 55\"/>") else if (std.mem.eql(u8, name, "folder")) try out.add("<path d=\"M 5 15 H 26 L 32 22 H 59 V 53 H 5 Z\"/>") else try out.add("<path d=\"M 13 4 H 39 L 53 18 V 60 H 13 Z M 39 4 V 18 H 53 M 22 31 H 44 M 22 40 H 44 M 22 49 H 39\"/>");
    try out.add("</g>");
}
