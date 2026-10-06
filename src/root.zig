const std = @import("std");
pub const FlowMeasurement = @import("flow_measurement.zig");
test { _ = @import("flow_inverted_ports.zig"); }
test { _ = @import("flow_port_graph.zig"); }
test { _ = @import("flow_barycenter.zig"); }
test { _ = @import("flow_inlayer_crossings.zig"); }
test { _ = @import("flow_self_loops.zig"); }
test { _ = @import("flow_measured_compound.zig"); }
test { _ = @import("flow_hierarchy.zig"); }
test {
    _ = @import("flow_measurement.zig");
}
test {
    _ = @import("flow_margins.zig");
}
test {
    _ = @import("flow_preparation.zig");
}
test {
    _ = @import("flow_bk.zig");
}
test {
    _ = @import("flow_compaction.zig");
}
test {
    _ = @import("flow_selection.zig");
}
test {
    _ = @import("flow_measured_layout.zig");
}
const flowchart = @import("flowchart.zig");
pub const measurementRequest = flowchart.measurementRequest;
pub const measuredGraph = flowchart.measuredGraph;
pub const measuredPlacement = flowchart.measuredPlacement;
pub const renderMeasured = flowchart.renderMeasured;
const sequence = @import("sequence.zig");
const document = @import("document.zig");
const pie = @import("pie.zig");
const timeline = @import("timeline.zig");
const journey = @import("journey.zig");
const packet = @import("packet.zig");
const xychart = @import("xychart.zig");
const radar = @import("radar.zig");
const quadrant = @import("quadrant.zig");
const sankey = @import("sankey.zig");
const treemap = @import("treemap.zig");
const class = @import("class.zig");
const entity = @import("entity.zig");
const state = @import("state.zig");
const git = @import("git.zig");
pub const Theme = @import("svg.zig").Theme;
pub const Error = flowchart.Error || error{ UnsupportedDiagram, InvalidUtf8 };
pub const compatibility_version = "11.17.1";
pub const Options = struct { theme: Theme = .light, id_prefix: u32 = 1, assets: []const u8 = "", now_ms: ?i64 = null };

pub fn render(allocator: std.mem.Allocator, input: []const u8, options: Options) Error![]u8 {
    if (options.now_ms) |now| if (now < -62135596800000 or now > 253402300799999) return error.InvalidSyntax;
    if (input.len > 1024 * 1024) return error.LimitExceeded;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    for (input) |byte| {
        if (byte < 32 and byte != 9 and byte != 10 and byte != 13) return error.InvalidSyntax;
    }
    if (std.mem.indexOf(u8, input, "\xef\xbf\xbe") != null or std.mem.indexOf(u8, input, "\xef\xbf\xbf") != null) return error.InvalidSyntax;
    var source = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) source = std.mem.trimStart(u8, source[3..], " \t\r\n");
    while (std.mem.startsWith(u8, source, "%%") and !std.mem.startsWith(u8, source, "%%{")) {
        const newline = std.mem.indexOfScalar(u8, source, '\n') orelse return error.InvalidSyntax;
        source = std.mem.trimStart(u8, source[newline + 1 ..], " \t\r\n");
    }
    if (source.len == 0) return error.InvalidSyntax;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var doc = try document.Document.parse(arena.allocator(), source, options.theme);
    doc.now_ms = options.now_ms;
    doc.assets = try @import("assets.zig").Registry.parse(arena.allocator(), options.assets);
    source = doc.source;
    if (source.len == 0) return error.InvalidSyntax;
    const end = std.mem.indexOfAny(u8, source, " \t\r\n;") orelse source.len;
    const kind = source[0..end];
    if (std.mem.eql(u8, kind, "flowchart-elk") and doc.layout_hint.len == 0) doc.layout_hint = "elk";
    var result = if (std.mem.eql(u8, kind, "flowchart") or std.mem.eql(u8, kind, "graph") or std.mem.eql(u8, kind, "flowchart-elk"))
        try flowchart.renderDocument(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "sequenceDiagram"))
        try sequence.renderConfigured(allocator, source, doc.theme, options.id_prefix, "sequence", &doc)
    else if (std.mem.eql(u8, kind, "zenuml"))
        try @import("zenuml.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "mindmap"))
        try @import("mindmap.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "pie"))
        try pie.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "timeline"))
        try timeline.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "journey"))
        try journey.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "packet") or std.mem.eql(u8, kind, "packet-beta"))
        try packet.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "xychart") or std.mem.eql(u8, kind, "xychart-beta"))
        try xychart.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "radar-beta") or std.mem.eql(u8, kind, "radar-beta:"))
        try radar.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "quadrantChart"))
        try quadrant.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "sankey") or std.mem.eql(u8, kind, "sankey-beta"))
        try sankey.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "treemap") or std.mem.eql(u8, kind, "treemap-beta"))
        try treemap.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "classDiagram") or std.mem.eql(u8, kind, "classDiagram-v2"))
        try class.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "erDiagram"))
        try entity.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "stateDiagram") or std.mem.eql(u8, kind, "stateDiagram-v2"))
        try state.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "gitGraph") or std.mem.eql(u8, kind, "gitGraph:"))
        try git.render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "requirementDiagram"))
        try @import("requirement.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "kanban"))
        try @import("kanban.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "gantt"))
        try @import("gantt.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "cynefin-beta") or std.mem.eql(u8, kind, "cynefin-beta:"))
        try @import("cynefin.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "venn-beta"))
        try @import("venn.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "info"))
        try @import("info.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "block") or std.mem.eql(u8, kind, "block-beta"))
        try @import("block.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "architecture-beta"))
        try @import("architecture.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "treeView-beta"))
        try @import("tree.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "wardley-beta"))
        try @import("wardley.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "ishikawa-beta") or std.mem.eql(u8, kind, "ishikawa"))
        try @import("ishikawa.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "C4Context") or std.mem.eql(u8, kind, "C4Container") or std.mem.eql(u8, kind, "C4Component") or std.mem.eql(u8, kind, "C4Dynamic") or std.mem.eql(u8, kind, "C4Deployment"))
        try @import("c4.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "swimlane-beta"))
        try @import("swimlane.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "eventmodeling"))
        try @import("eventmodeling.zig").render(allocator, &doc, options.id_prefix)
    else if (std.mem.eql(u8, kind, "railroad-beta") or std.mem.eql(u8, kind, "railroad-ebnf-beta") or std.mem.eql(u8, kind, "railroad-abnf-beta") or std.mem.eql(u8, kind, "railroad-peg-beta"))
        try @import("railroad.zig").render(allocator, &doc, options.id_prefix)
    else
        return error.UnsupportedDiagram;
    errdefer allocator.free(result);
    try doc.finish();
    result = try doc.presentation(allocator, result);
    if (doc.sketch) {
        const sketched = try @import("sketch.zig").render(allocator, result, doc.sketch_seed);
        allocator.free(result);
        result = sketched;
    }
    return doc.wrap(allocator, result);
}

test "mindmaps own output and release parser state on success and errors" {
    const a = std.testing.allocator;
    const source = "mindmap\nRoot\n A[Square]\n  B(Rounded)\n   C((Circle))\n  D)Cloud(\n E))Bang((\n F{{Hexagon}}\n G[\"`**Bold** and *italic*`\"]\n ::icon(fa fa-book)\n :::hot";
    for ([_]Theme{ .light, .dark }) |theme| {
        const result = try render(a, source, .{ .theme = theme });
        defer a.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "data-mindmap-layout=\"freemind\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "data-mindmap-icon=\"book\"") != null);
    }
    try std.testing.expectError(error.InvalidSyntax, render(a, "mindmap\nRoot\n Child\nAnother root", .{}));
    try std.testing.expectError(error.MissingAsset, render(a, "mindmap\nRoot\n ::icon(unknown:custom)", .{}));
}
test "flowcharts produce SVG without JS HTML or external dependencies" {
    const result = try render(std.testing.allocator, "flowchart LR\nA[Read Markdown] --> B{Diagram?}\nB -->|Yes| C(Render SVG)\nB -->|No| D[Done]", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "<svg "));
    try std.testing.expect(std.mem.indexOf(u8, result, "<polygon") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Read Markdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<script") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "foreignObject") == null);
}

test "frontmatter scalars and scoped Gantt CSS allocate safely" {
    const a = std.testing.allocator;
    const source = "---\ntitle: 'A # title' # comment\nconfig:\n  themeCSS: |-\n    #task { fill: red; }\n    text[id^=task] { font-size: 15px; }\n  gantt:\n    topAxis: true # comment\n---\ngantt\ntickInterval 1month\nA:task,2024-01-01,2024-04-01";
    const result = try render(a, source, .{});
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "#zm-1-css [data-source-id=\"task\"]{fill:red;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2024-02-01") != null);
    try std.testing.expectError(error.UnsupportedSyntax, render(a, "---\nconfig:\n  themeCSS: 'rect { fill: url(https://example.test/x); }'\n---\ngantt\nA:2024-01-01,1d", .{}));
}
test "flowcharts handle directions chains cycles and escaped labels" {
    for ([_][]const u8{ "LR", "RL", "TD", "TB", "BT" }) |direction| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "graph {s}; A[one & two] --> B; B -.-> A", .{direction});
        defer std.testing.allocator.free(input);
        const result = try render(std.testing.allocator, input, .{ .theme = .dark, .id_prefix = 42 });
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "one &amp; two") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "#0d1117") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "zm-42") != null);
    }
}
test "sequence messages aliases actors and self calls" {
    const result = try render(std.testing.allocator, "sequenceDiagram\nactor U as User\nparticipant Z as Zig renderer\nU->>Z: Render diagram\nZ->>Z: Layout\nZ-->>U: SVG", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Zig renderer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "stroke-dasharray") != null);
}
test "sequence properties preserve metadata with owned escaped output" {
    const a = std.testing.allocator;
    const result = try render(a, "sequenceDiagram\nparticipant A\nproperties A: {\"class\":\"service\",\"custom\":{\"label\":\"<safe>\"}}\nproperties A: {\"class\":\"updated\"}\nA->>A: Hello", .{});
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "class=\"updated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&lt;safe&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<safe>") == null);
}
test "wrapping failure releases already registered label allocations" {
    try std.testing.expectError(error.LimitExceeded, render(std.testing.allocator, "%%{init:{flowchart:{wrappingWidth:16}}}%%\nflowchart TD\nA[\"`abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz`\"]", .{}));
}

test "unsupported syntax is explicit rather than silently discarded" {
    try std.testing.expectError(error.UnsupportedDiagram, render(std.testing.allocator, "unknownDiagram\nUnsupported", .{}));
    try std.testing.expectError(error.UnsupportedSyntax, render(std.testing.allocator, "flowchart TD\nA-->B\nclick A \"javascript:alert(1)\"", .{}));
    try std.testing.expectError(error.InvalidSyntax, render(std.testing.allocator, "sequenceDiagram\nparticipant A\nproperties A: {\"icon\":42}", .{}));
    try std.testing.expectError(error.UnsupportedSyntax, render(std.testing.allocator, "%%{unknown: {}}%%\nflowchart LR\nA-->B", .{}));
    try std.testing.expectError(error.InvalidSyntax, render(std.testing.allocator, "flowchart LR\nA[broken", .{}));
    try std.testing.expectError(error.InvalidUtf8, render(std.testing.allocator, "\xff", .{}));
}
test "BOM CRLF comments and Unicode" {
    const result = try render(std.testing.allocator, "\xef\xbb\xbf%% hello\r\nflowchart LR\r\nA[文書] --> B[SVG]", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "文書") != null);
}

test "comments cannot alter bracket parsing and circles stay circular" {
    const result = try render(std.testing.allocator, "flowchart LR\n%% unmatched (( { comment\nA((Start)) --> B[End] %% another ) comment\nB-->B", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<ellipse") == null);
    const initialized = try render(std.testing.allocator, "flowchart LR\n%%{init:{}}%%\nA-->B", .{});
    defer std.testing.allocator.free(initialized);
    try std.testing.expect(std.mem.indexOf(u8, initialized, "data-edge=") != null);
}

test "rendering is deterministic and resource limits are explicit" {
    const input = "flowchart LR; A-->B; B-->C";
    const first = try render(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(first);
    const second = try render(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    const oversized = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.LimitExceeded, render(std.testing.allocator, oversized, .{}));
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "flowchart LR\n");
    for (0..257) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "N{d}\n", .{i});
        defer std.testing.allocator.free(line);
        try source.appendSlice(std.testing.allocator, line);
    }
    try std.testing.expectError(error.LimitExceeded, render(std.testing.allocator, source.items, .{}));
}

test "missing assets and invalid entities are not literal labels" {
    try std.testing.expectError(error.MissingAsset, render(std.testing.allocator, "flowchart LR; A[fa:fa-twitter]", .{}));
    try std.testing.expectError(error.UnsupportedSyntax, render(std.testing.allocator, "flowchart LR; A[\"#unknown;\"]", .{}));
    try std.testing.expectError(error.InvalidSyntax, render(std.testing.allocator, "graph LR; A[bad\x01label]", .{}));
}

test "all legacy flowchart shapes have distinct SVG geometry" {
    const cases = .{
        .{ "A[Box]", "box" },                  .{ "A(Round)", "round" },                  .{ "A([Stadium])", "stadium" },
        .{ "A[[Subroutine]]", "subroutine" },  .{ "A[(Database)]", "cylinder" },          .{ "A((Circle))", "circle" },
        .{ "A(((Double)))", "double_circle" }, .{ "A{Decision}", "diamond" },             .{ "A{{Hexagon}}", "hexagon" },
        .{ "A>Asymmetric]", "asymmetric" },    .{ "A[/Right/]", "lean_right" },           .{ "A[\\Left\\]", "lean_left" },
        .{ "A[/Trap\\]", "trapezoid" },        .{ "A[\\Inverse/]", "inverse_trapezoid" },
    };
    inline for (cases) |case| {
        const result = try render(std.testing.allocator, "flowchart LR; " ++ case[0] ++ "-->B", .{});
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "data-shape=\"" ++ case[1] ++ "\"") != null);
    }
}

test "link rendering preserves markers styles and invisible constraints" {
    const result = try render(std.testing.allocator, "flowchart LR; A o--o B; B x--x C; C <==> D; D -. dotted .-> E; E ~~~ F", .{ .id_prefix = 9 });
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "marker-start=\"url(#zm-9-circle)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "marker-end=\"url(#zm-9-cross)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "stroke-width=\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "stroke-dasharray=\"5 4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-edge=\"4\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, ">F</text>") != null);
}

test "charts and frontmatter are leak free and deterministic" {
    for ([_][]const u8{
        "---\r\ntitle: Test & title\r\n---\r\npie showData\r\n\"A\": 2\r\n\"B\": 3",
        "timeline TD\nsection Group\nFirst<br>period : one<br>two : three\nNext : event",
        "journey\nsection Part<br>one\nTask<br>detail: 5: Alice, Bob\nFinish: 0: Alice",
        "packet-beta\n0-3: \"Header\"\n+32: \"Body\"",
        "xychart horizontal\nx-axis [a,b,c]\ny-axis -10 --> 10\nbar [-5,0,10]\nline [3,7,-2]",
        "radar-beta\naxis A, B, C\ncurve one{C: 3, A: 1, B: 2}\nmax 5",
        "sankey\nA,B,10\nA,C,20",
        "treemap\n\"A\"\n  \"X\": 10\n  \"Y\": 20\n\"B\":30",
        "quadrantChart\nquadrant-1 High\nA:::style: [0.5,0.6] radius:12\nclassDef style color:red",
    }) |source| {
        const first = try render(std.testing.allocator, source, .{});
        defer std.testing.allocator.free(first);
        const second = try render(std.testing.allocator, source, .{});
        defer std.testing.allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
    }
}

test "invalid chart values config and bounds fail safely" {
    for ([_][]const u8{
        "---\n---",
        "pie\n\"Empty\": 0",
        "packet\n1: \"Gap\"",
        "packet\n+0: \"Zero\"",
        "journey\nTask: 6: Alice",
        "xychart\nx-axis [a,b]\nbar [1]",
        "xychart\ny-axis 5 --> 5\nbar [1]",
        "radar-beta\naxis A,B,C\ncurve x{1,2}",
        "radar-beta\naxis A,B,C\ncurve x{A:1,A:2,C:3}",
    }) |source| try std.testing.expectError(error.InvalidSyntax, render(std.testing.allocator, source, .{}));
    try std.testing.expectError(error.UnsupportedSyntax, render(std.testing.allocator, "---\nconfig:\n  unknown: 4\n---\npie\n\"A\": 1", .{}));
}

test "class and entity models release member namespace and label allocations" {
    for ([_][]const u8{
        "classDiagram\nnamespace Group {\nclass A{\n +List~List~int~~ values\n +get() int$\n}\n}\nA <|-- B : extends\nnote for A \"Note<br>detail\"",
        "erDiagram\nsubgraph Group\nA {\n string name PK \"Comment\"\n int[] values FK\n}\nend\nA ||--o{ B : owns",
        "stateDiagram-v2\naccTitle: Test\n[*] --> A\nstate A {\n[*] --> B\n--\n[*] --> C\n}\nnote left of A: Detail\nA --> [*]",
    }) |source| {
        const result = try render(std.testing.allocator, source, .{});
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "data-subgraph") != null);
    }
}

test "git graph allocation and branch relationships" {
    const result = try render(std.testing.allocator, "gitGraph\ncommit id:\"a\"\nbranch dev\ncommit id:\"b\"\ncheckout main\ncommit\nmerge dev tag:\"v1\"", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-parent=\"1\" data-commit=\"3\"") != null);
}

test "requirement and kanban allocation cleanup" {
    for ([_][]const u8{
        "requirementDiagram\nrequirement R {\nid: 1\ntext: **Bold** and *italic*\n}\nelement E {\ntype: test\n}\nE - verifies -> R",
        "kanban\nTodo\n  task[Long task label that will wrap across multiple lines]@{ticket: T-1, assigned: 'Someone', priority: 'Very High'}\nDone",
    }) |source| {
        const result = try render(std.testing.allocator, source, .{});
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.startsWith(u8, result, "<svg "));
    }
}

test "calendar and framework diagrams release all allocations" {
    for ([_][]const u8{
        "gantt\nsection Plan\nA:2024-01-05,1d\nB:2d",
        "cynefin-beta\ncomplex\n\"Investigate\"\nclear\n\"Follow procedure\"\ncomplex --> clear: \"Resolved\"",
        "venn-beta\nset A:20\nset B:12\nunion A,B[Overlap]:3",
        "info\nshowInfo",
    }) |source| {
        const result = try render(std.testing.allocator, source, .{});
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.startsWith(u8, result, "<svg "));
    }
}

test "nested block grids release temporary allocations" {
    const result = try render(std.testing.allocator, "block\ncolumns 2\nblock:G\ncolumns 1\nA\nB\nend\nC\nB-->C", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-block-group") != null);
}

test "architecture constraints and group allocations" {
    const result = try render(std.testing.allocator, "architecture-beta\ngroup G(cloud)[Group]\nservice A(server)[A] in G\nservice B(database)[B] in G\nA:R --> L:B", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-architecture-group") != null);
}

test "tree labels and icons release allocations" {
    const result = try render(std.testing.allocator, "treeView-beta\n  src/ icon(folder)\n    main.zig :::highlight ## Entry point\n  README.md", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-tree-node") != null);
}

test "wardley pipeline and annotation allocations" {
    const result = try render(std.testing.allocator, "wardley-beta\ncomponent A [0.5,0.5]\npipeline A {\ncomponent X [0.1]\ncomponent Y [0.9]\n}\nX +> Y\nannotation 1,[0.5,0.5] \"Note\"", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-pipeline") != null);
}

test "fishbone nested cause allocation cleanup" {
    const result = try render(std.testing.allocator, "ishikawa\nEffect\nCause\n  Subcause\n    Detail\nOther cause", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-ishikawa-node") != null);
}

test "C4 boundary and named attribute allocation cleanup" {
    const result = try render(std.testing.allocator, "C4Container\nBoundary(g,\"Group\"){\nContainer(a,\"App\",$descr=\"Named description\",$techn=\"C#\")\nSystem(b,\"Database\")\n}\nRel(a,b,\"Reads\")\nUpdateRelStyle(a,b,$offsetX=\"20\")", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-c4-rel") != null);
}

test "swimlane parsing and placement allocation cleanup" {
    const result = try render(std.testing.allocator, "swimlane-beta LR\nsubgraph One\nA\nB\nend\nsubgraph Two\nC\nend\nA-->B-->C", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-swimlane-node") != null);
}

test "event modeling data and reference allocation cleanup" {
    const result = try render(std.testing.allocator, "eventmodeling\nrf 01 evt Start\ntf 02 rmo View ->> 01 [[Payload]]\ndata Payload {\nfield: value\n}\nnote 02 {\nExplanation\n}", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-event-frame") != null);
}

test "railroad variants release parser and layout allocations" {
    for ([_][]const u8{
        "railroad-beta\nr=sequence(terminal(\"x\"),oneOrMore(nonterminal(\"Y\")));",
        "railroad-ebnf-beta\nr=[\"a\"] {\"b\"} - \"c\";",
        "railroad-abnf-beta\nr=2*4%x41-5A;",
        "railroad-peg-beta\nr<-!(\"a\"/\"b\") B+;",
    }) |source| {
        const result = try render(std.testing.allocator, source, .{});
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "data-railroad-rule") != null);
    }
}

test "sequence JSON links grouping highlights and lifecycle allocation cleanup" {
    const result = try render(std.testing.allocator, "sequenceDiagram\nbox Purple Group\nparticipant A@{\"type\":\"boundary\",\"alias\":\"Client\"}\nend\nlinks A: {\"Docs\":\"https://example.test\"}\nrect rgb(20,30,40)\ncreate actor B\nA->B: created\nA()->>()B: connected\ndeactivate A\ndeactivate B\ndestroy B\nB->A: finished\nend", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-created") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-participant-box") != null);
}

test "graph metadata and interactions release allocations" {
    const result = try render(std.testing.allocator, "flowchart LR\nsubgraph G[\"`**Group**`\"]\nA-->B\nend\nG@{view:collapsed}\nA e1@-->C\ne1@{animate:true,curve:natural}\nclick G call selected(\"one\",2) \"Tooltip\"\nclass C external", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-collapsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "data-zm-callback") != null);
}

test "independent ZenUML parser allocation cleanup" {
    const result = try render(std.testing.allocator, "zenuml\n@Actor Client\nClient->A.method() {\n// **Explanation**\nvalue = B.method()\nif (ready) { return value\n} else { B->A: waiting\n}\n}\nnew C", .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "zenuml diagram") != null);
}

test "host asset registry allocation cleanup and SVG reference scoping" {
    const asset_json = "{\"test:icon\":{\"svg\":\"<defs><linearGradient id='g'><stop offset='0' stop-color='red'/></linearGradient></defs><rect width='24' height='24' fill='url(#g)'/>\"}}";
    const result = try render(std.testing.allocator, "flowchart LR\nA@{icon:\"test:icon\",label:\"Asset\",form:circle,h:60}\nA-->B", .{ .assets = asset_json });
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "zm-1-asset-0-g") != null);
}
