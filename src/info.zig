const std = @import("std");
const d = @import("document.zig");
const txt = @import("sequence_text.zig");
const svg = @import("svg.zig");
pub fn render(a: std.mem.Allocator, doc: *d.Document, prefix: u32) d.Error![]u8 {
    var lines = std.mem.splitScalar(u8, doc.source, '\n');
    _ = lines.next();
    var shown = false;
    while (lines.next()) |raw| {
        const line = d.trim(raw);
        if (line.len == 0 or txt.starts(line, "%%")) continue;
        if (std.mem.eql(u8, line, "showInfo") and !shown) {
            shown = true;
            continue;
        }
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
        return error.InvalidSyntax;
    }
    var out: svg.Svg = .{ .allocator = a, .theme = doc.theme };
    defer out.deinit();
    try out.start(550, 110, "info", prefix);
    try out.text(275, 35, "zmermaid — independent Zig SVG renderer");
    try out.text(275, 70, "Mermaid syntax target: 11.17.1 (partial)");
    return out.finish();
}
