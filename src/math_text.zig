const std = @import("std");
const svg = @import("svg.zig");
const Error = @import("sequence_text.zig").Error;
const nil = std.math.maxInt(u16);
const Kind = enum { row, text, space, fraction, radical, scripts, accent, matrix };
const Box = struct {
    kind: Kind,
    text: []const u8 = "",
    size: f64 = 14,
    w: f64 = 0,
    h: f64 = 0,
    base: f64 = 0,
    x: f64 = 0,
    y: f64 = 0,
    a: u16 = nil,
    b: u16 = nil,
    c: u16 = nil,
    next: u16 = nil,
};
pub fn token(raw: []const u8) ?usize {
    if (!std.mem.startsWith(u8, raw, "$$")) return null;
    const end = std.mem.indexOfPos(u8, raw, 2, "$$") orelse return null;
    return end + 2;
}
pub const Layout = struct {
    source: []const u8,
    at: usize = 0,
    boxes: [512]Box = undefined,
    count: u16 = 0,
    root: u16 = nil,
    fn add(self: *Layout, value: Box) Error!u16 {
        if (self.count == self.boxes.len) return error.LimitExceeded;
        const index = self.count;
        self.boxes[index] = value;
        self.count += 1;
        return index;
    }
    fn skip(self: *Layout) void {
        while (self.at < self.source.len and std.ascii.isWhitespace(self.source[self.at])) : (self.at += 1) {}
    }
    fn text(self: *Layout, value: []const u8, size: f64) Error!u16 {
        return self.add(.{ .kind = .text, .text = value, .size = size, .w = @as(f64, @floatFromInt(svg.textWidth(value))) * size / 14, .h = size * 1.3, .base = size });
    }
    fn group(self: *Layout, size: f64, depth: usize) Error!u16 {
        self.skip();
        if (self.at == self.source.len) return error.InvalidSyntax;
        if (self.source[self.at] != '{') return self.atom(size, depth + 1);
        self.at += 1;
        const result = try self.row(size, depth + 1);
        if (self.at == self.source.len or self.source[self.at] != '}') return error.InvalidSyntax;
        self.at += 1;
        return result;
    }
    fn row(self: *Layout, size: f64, depth: usize) Error!u16 {
        if (depth > 24) return error.LimitExceeded;
        const result = try self.add(.{ .kind = .row, .size = size, .h = size * 1.3, .base = size });
        var tail: u16 = nil;
        while (true) {
            self.skip();
            if (self.at == self.source.len or self.source[self.at] == '}' or self.source[self.at] == '&' or std.mem.startsWith(u8, self.source[self.at..], "\\\\") or std.mem.startsWith(u8, self.source[self.at..], "\\end{")) break;
            var child = try self.atom(size, depth + 1);
            var sup: u16 = nil;
            var sub: u16 = nil;
            self.skip();
            while (self.at < self.source.len and (self.source[self.at] == '^' or self.source[self.at] == '_')) {
                const upper = self.source[self.at] == '^';
                self.at += 1;
                if ((upper and sup != nil) or (!upper and sub != nil)) return error.InvalidSyntax;
                const script = try self.group(@max(6, size * 0.7), depth + 1);
                if (upper) sup = script else sub = script;
                self.skip();
            }
            if (sup != nil or sub != nil) {
                const main = self.boxes[child];
                const upper_h = if (sup != nil) self.boxes[sup].h else 0;
                const lower_h = if (sub != nil) self.boxes[sub].h else 0;
                const rise = if (sup != nil) @max(0, upper_h - size * 0.35) else 0;
                self.boxes[child].y = rise;
                if (sup != nil) {
                    self.boxes[sup].x = main.w + 1;
                    self.boxes[sup].y = 0;
                }
                if (sub != nil) {
                    self.boxes[sub].x = main.w + 1;
                    self.boxes[sub].y = rise + main.base - size * 0.15;
                }
                child = try self.add(.{ .kind = .scripts, .a = child, .b = sup, .c = sub, .w = main.w + 1 + @max(if (sup != nil) self.boxes[sup].w else 0, if (sub != nil) self.boxes[sub].w else 0), .h = @max(rise + main.h, if (sub != nil) rise + main.base - size * 0.15 + lower_h else 0), .base = rise + main.base });
            }
            if (tail == nil) self.boxes[result].a = child else self.boxes[tail].next = child;
            tail = child;
            self.boxes[result].base = @max(self.boxes[result].base, self.boxes[child].base);
        }
        var child = self.boxes[result].a;
        var width: f64 = 0;
        var height = self.boxes[result].h;
        while (child != nil) : (child = self.boxes[child].next) {
            var box = &self.boxes[child];
            box.x = width;
            box.y = self.boxes[result].base - box.base;
            width += box.w;
            height = @max(height, box.y + box.h);
        }
        self.boxes[result].w = width;
        self.boxes[result].h = height;
        return result;
    }
    fn literalGroup(self: *Layout) Error![]const u8 {
        self.skip();
        if (self.at == self.source.len or self.source[self.at] != '{') return error.InvalidSyntax;
        self.at += 1;
        const start = self.at;
        var depth: usize = 1;
        while (self.at < self.source.len) : (self.at += 1) {
            if (self.source[self.at] == '{') depth += 1;
            if (self.source[self.at] == '}') {
                depth -= 1;
                if (depth == 0) {
                    const value = self.source[start..self.at];
                    self.at += 1;
                    return value;
                }
            }
        }
        return error.InvalidSyntax;
    }
    fn atom(self: *Layout, size: f64, depth: usize) Error!u16 {
        if (depth > 24) return error.LimitExceeded;
        self.skip();
        if (self.at == self.source.len) return error.InvalidSyntax;
        const c = self.source[self.at];
        if (c == '{') return self.group(size, depth + 1);
        if (c == '}' or c == '^' or c == '_' or c == '&' or c == '$') return error.InvalidSyntax;
        if (c != '\\') {
            const len = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidSyntax;
            if (self.at + len > self.source.len) return error.InvalidSyntax;
            const value = self.source[self.at .. self.at + len];
            self.at += len;
            return self.text(value, size);
        }
        self.at += 1;
        const start = self.at;
        while (self.at < self.source.len and std.ascii.isAlphabetic(self.source[self.at])) : (self.at += 1) {}
        if (self.at == start) {
            if (self.at == self.source.len) return error.InvalidSyntax;
            const symbol = self.source[self.at];
            self.at += 1;
            if (std.mem.indexOfScalar(u8, ",;:! ", symbol) != null) return self.add(.{ .kind = .space, .w = if (symbol == '!') 0 else size * (if (symbol == ';') @as(f64, 0.3) else 0.2) });
            if (std.mem.indexOfScalar(u8, "{}%#_&$|", symbol) != null) return self.text(self.source[start..self.at], size);
            return error.UnsupportedSyntax;
        }
        const command = self.source[start..self.at];
        if (eq(command, "relax")) return self.add(.{ .kind = .space });
        if (eq(command, "quad") or eq(command, "qquad")) return self.add(.{ .kind = .space, .w = size * (if (eq(command, "quad")) @as(f64, 1) else 2) });
        if (eq(command, "text") or eq(command, "mathrm") or eq(command, "operatorname")) return self.text(try self.literalGroup(), size);
        if (eq(command, "frac") or eq(command, "dfrac") or eq(command, "tfrac")) {
            const numerator = try self.group(@max(6, size * 0.85), depth + 1);
            const denominator = try self.group(@max(6, size * 0.85), depth + 1);
            const n = self.boxes[numerator];
            const den = self.boxes[denominator];
            const w = @max(n.w, den.w) + 8;
            self.boxes[numerator].x = (w - n.w) / 2;
            self.boxes[denominator].x = (w - den.w) / 2;
            self.boxes[denominator].y = n.h + 6;
            return self.add(.{ .kind = .fraction, .a = numerator, .b = denominator, .w = w, .h = n.h + den.h + 6, .base = n.h + 3 + size * 0.3, .size = size });
        }
        if (eq(command, "sqrt")) {
            const child = try self.group(size, depth + 1);
            const box = self.boxes[child];
            self.boxes[child].x = 10;
            self.boxes[child].y = 4;
            return self.add(.{ .kind = .radical, .a = child, .w = box.w + 13, .h = box.h + 5, .base = box.base + 4 });
        }
        if (eq(command, "hat") or eq(command, "widehat") or eq(command, "tilde") or eq(command, "widetilde") or eq(command, "bar") or eq(command, "overline") or eq(command, "vec") or eq(command, "overbrace") or eq(command, "phase")) {
            const child = try self.group(size, depth + 1);
            const box = self.boxes[child];
            const phase = eq(command, "phase");
            self.boxes[child].y = if (phase) 0 else 7;
            self.boxes[child].x = if (phase) 10 else 0;
            return self.add(.{ .kind = .accent, .text = command, .a = child, .w = box.w + (if (phase) @as(f64, 12) else 0), .h = box.h + (if (phase) @as(f64, 3) else 7), .base = box.base + (if (phase) @as(f64, 0) else 7) });
        }
        if (eq(command, "big") or eq(command, "Big") or eq(command, "bigg") or eq(command, "Bigg") or eq(command, "left") or eq(command, "right")) {
            const factor: f64 = if (eq(command, "big")) 1.2 else if (eq(command, "Big")) 1.5 else if (eq(command, "bigg")) 1.8 else if (eq(command, "Bigg")) 2.1 else 1;
            return self.atom(size * factor, depth + 1);
        }
        if (eq(command, "begin")) return self.matrix(try self.literalGroup(), size, depth + 1);
        if (symbols(command)) |value| return self.text(value, if (eq(command, "int") or eq(command, "sum") or eq(command, "prod")) size * 1.6 else size);
        var words = std.mem.tokenizeScalar(u8, "sin cos tan cot sec csc sinh cosh tanh log ln exp lim min max det gcd", ' ');
        while (words.next()) |word| if (eq(command, word)) return self.text(word, size);
        return error.UnsupportedSyntax;
    }
    fn matrix(self: *Layout, environment: []const u8, size: f64, depth: usize) Error!u16 {
        if (depth > 24) return error.LimitExceeded;
        if (!eq(environment, "matrix") and !eq(environment, "bmatrix") and !eq(environment, "pmatrix") and !eq(environment, "Bmatrix") and !eq(environment, "vmatrix") and !eq(environment, "Vmatrix") and !eq(environment, "cases")) return error.UnsupportedSyntax;
        const result = try self.add(.{ .kind = .matrix, .text = environment, .size = size });
        var rows: [16]u16 = undefined;
        var row_count: usize = 0;
        var widths: [16]f64 = .{0} ** 16;
        var columns: usize = 0;
        while (true) {
            if (row_count == 16) return error.LimitExceeded;
            const row_id = try self.add(.{ .kind = .row, .size = size, .h = size * 1.3, .base = size });
            rows[row_count] = row_id;
            row_count += 1;
            var count: usize = 0;
            var last: u16 = nil;
            while (true) {
                if (count == 16) return error.LimitExceeded;
                const cell = try self.row(size, depth + 1);
                if (last == nil) self.boxes[row_id].a = cell else self.boxes[last].next = cell;
                last = cell;
                widths[count] = @max(widths[count], self.boxes[cell].w);
                count += 1;
                self.boxes[row_id].base = @max(self.boxes[row_id].base, self.boxes[cell].base);
                self.skip();
                if (self.at < self.source.len and self.source[self.at] == '&') {
                    self.at += 1;
                    continue;
                }
                break;
            }
            columns = @max(columns, count);
            if (std.mem.startsWith(u8, self.source[self.at..], "\\\\")) {
                self.at += 2;
                continue;
            }
            if (!std.mem.startsWith(u8, self.source[self.at..], "\\end{")) return error.InvalidSyntax;
            self.at += 4;
            if (!eq(try self.literalGroup(), environment)) return error.InvalidSyntax;
            break;
        }
        const side: f64 = if (eq(environment, "matrix")) 0 else 10;
        var y: f64 = 2;
        var total_width: f64 = 2 * side;
        for (widths[0..columns]) |w| total_width += w + 12;
        total_width -= 12;
        for (rows[0..row_count], 0..) |row_id, r| {
            var child = self.boxes[row_id].a;
            var column: usize = 0;
            var x = side;
            var height = self.boxes[row_id].h;
            while (child != nil) : (child = self.boxes[child].next) {
                self.boxes[child].x = x + (if (eq(environment, "cases")) 0 else (widths[column] - self.boxes[child].w) / 2);
                self.boxes[child].y = self.boxes[row_id].base - self.boxes[child].base;
                height = @max(height, self.boxes[child].y + self.boxes[child].h);
                x += widths[column] + 12;
                column += 1;
            }
            self.boxes[row_id].y = y;
            self.boxes[row_id].h = height;
            self.boxes[row_id].w = total_width;
            if (r == 0) self.boxes[result].a = row_id else self.boxes[rows[r - 1]].next = row_id;
            y += height + 5;
        }
        self.boxes[result].w = total_width;
        self.boxes[result].h = y;
        self.boxes[result].base = y / 2 + size * 0.3;
        return result;
    }
    pub fn init(raw: []const u8) Error!Layout {
        if (raw.len > 512) return error.LimitExceeded;
        if (token(raw) != raw.len) return error.InvalidSyntax;
        var self: Layout = .{ .source = raw[2 .. raw.len - 2] };
        self.root = try self.row(14, 0);
        self.skip();
        if (self.at != self.source.len) return error.InvalidSyntax;
        return self;
    }
    pub fn pixelWidth(self: *const Layout) usize {
        return @intFromFloat(@ceil(self.boxes[self.root].w));
    }
    pub fn pixelHeight(self: *const Layout) usize {
        return @intFromFloat(@ceil(self.boxes[self.root].h));
    }
    pub fn draw(self: *const Layout, out: *svg.Svg, x: f64, y: f64, fg: []const u8) Error!void {
        try out.add("<g data-math=\"true\" aria-label=\"");
        try out.escape(self.source);
        try out.add("\">");
        try self.drawBox(out, self.root, x, y, fg);
        try out.add("</g>");
    }
    fn drawBox(self: *const Layout, out: *svg.Svg, index: u16, px: f64, py: f64, fg: []const u8) Error!void {
        if (index == nil) return;
        const box = self.boxes[index];
        const x = px + box.x;
        const y = py + box.y;
        if (box.kind == .text) {
            try out.fmt("<text x=\"{d:.2}\" y=\"{d:.2}\" font-family=\"Cambria Math,Times New Roman,serif\" font-size=\"{d:.2}\" text-anchor=\"start\" dominant-baseline=\"alphabetic\" fill=\"{s}\" stroke=\"none\">", .{ x, y + box.base, box.size, fg });
            try out.escape(box.text);
            try out.add("</text>");
        }
        if (box.kind == .fraction) try out.fmt("<path data-math-fraction=\"true\" d=\"M {d:.2} {d:.2} H {d:.2}\" stroke=\"{s}\" stroke-width=\"1\" fill=\"none\"/>", .{ x, y + self.boxes[box.a].h + 3, x + box.w, fg });
        if (box.kind == .radical) try out.fmt("<path data-math-radical=\"true\" d=\"M {d:.2} {d:.2} l 3 -2 l 3 6 L {d:.2} {d:.2} H {d:.2}\" stroke=\"{s}\" stroke-width=\"1\" fill=\"none\"/>", .{ x, y + box.h * 0.55, x + 10, y + 2, x + box.w, fg });
        if (box.kind == .accent and eq(box.text, "overbrace")) {
            try out.fmt("<path data-math-accent=\"overbrace\" transform=\"translate({d:.2} {d:.2}) scale({d:.4} 1)\" vector-effect=\"non-scaling-stroke\" stroke=\"{s}\" stroke-width=\"1\" fill=\"none\" d=\"M 0 6 Q 0 3 5 3 H 45 Q 50 3 50 0 Q 50 3 55 3 H 95 Q 100 3 100 6\"/>", .{ x, y, box.w / 100, fg });
        }
        if (box.kind == .accent and !eq(box.text, "overbrace")) {
            try out.fmt("<path data-math-accent=\"{s}\" stroke=\"{s}\" stroke-width=\"1\" fill=\"none\" d=\"", .{ box.text, fg });
            if (eq(box.text, "phase")) try out.fmt("M {d:.2} {d:.2} L {d:.2} {d:.2} H {d:.2}", .{ x + 8, y, x, y + box.h - 1, x + box.w }) else if (eq(box.text, "hat") or eq(box.text, "widehat")) try out.fmt("M {d:.2} {d:.2} L {d:.2} {d:.2} L {d:.2} {d:.2}", .{ x, y + 5, x + box.w / 2, y + 1, x + box.w, y + 5 }) else if (eq(box.text, "bar") or eq(box.text, "overline")) try out.fmt("M {d:.2} {d:.2} H {d:.2}", .{ x, y + 3, x + box.w }) else if (eq(box.text, "vec")) try out.fmt("M {d:.2} {d:.2} H {d:.2} l -4 -2 m 4 2 l -4 2", .{ x, y + 3, x + box.w }) else try out.fmt("M {d:.2} {d:.2} Q {d:.2} {d:.2} {d:.2} {d:.2} T {d:.2} {d:.2}", .{ x, y + 4, x + box.w / 4, y - 1, x + box.w / 2, y + 3, x + box.w, y + 2 });
            try out.add("\"/>");
        }
        if (box.kind == .matrix and !eq(box.text, "matrix")) {
            try out.fmt("<g data-math-matrix=\"{s}\" stroke=\"{s}\" stroke-width=\"1\" fill=\"none\">", .{ box.text, fg });
            const path = if (eq(box.text, "cases") or eq(box.text, "Bmatrix")) "M 8 0 Q 3 0 3 .1 V .4 Q 3 .5 0 .5 Q 3 .5 3 .6 V .9 Q 3 1 8 1" else if (eq(box.text, "pmatrix")) "M 8 0 Q -3 .5 8 1" else if (eq(box.text, "vmatrix")) "M 5 0 V 1" else if (eq(box.text, "Vmatrix")) "M 3 0 V 1 M 7 0 V 1" else "M 8 0 H 3 V 1 H 8";
            try out.fmt("<path transform=\"translate({d:.2} {d:.2}) scale(1 {d:.2})\" vector-effect=\"non-scaling-stroke\" d=\"{s}\"/>", .{ x, y, box.h, path });
            if (!eq(box.text, "cases")) try out.fmt("<path transform=\"translate({d:.2} {d:.2}) scale(-1 {d:.2})\" vector-effect=\"non-scaling-stroke\" d=\"{s}\"/>", .{ x + box.w, y, box.h, path });
            try out.add("</g>");
        }
        if (box.kind == .row or box.kind == .matrix) {
            var child = box.a;
            while (child != nil) : (child = self.boxes[child].next) try self.drawBox(out, child, x, y, fg);
        } else {
            try self.drawBox(out, box.a, x, y, fg);
            try self.drawBox(out, box.b, x, y, fg);
            try self.drawBox(out, box.c, x, y, fg);
        }
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn symbols(name: []const u8) ?[]const u8 {
    const pairs = [_][2][]const u8{
        .{ "alpha", "α" },
        .{ "beta", "β" },
        .{ "gamma", "γ" },
        .{ "delta", "δ" },
        .{ "epsilon", "ϵ" },
        .{ "varepsilon", "ε" },
        .{ "zeta", "ζ" },
        .{ "eta", "η" },
        .{ "theta", "θ" },
        .{ "iota", "ι" },
        .{ "kappa", "κ" },
        .{ "lambda", "λ" },
        .{ "mu", "μ" },
        .{ "nu", "ν" },
        .{ "xi", "ξ" },
        .{ "omicron", "ο" },
        .{ "pi", "π" },
        .{ "rho", "ρ" },
        .{ "sigma", "σ" },
        .{ "tau", "τ" },
        .{ "upsilon", "υ" },
        .{ "phi", "ϕ" },
        .{ "varphi", "φ" },
        .{ "chi", "χ" },
        .{ "psi", "ψ" },
        .{ "omega", "ω" },
        .{ "Alpha", "Α" },
        .{ "Beta", "Β" },
        .{ "Gamma", "Γ" },
        .{ "Delta", "Δ" },
        .{ "Epsilon", "Ε" },
        .{ "Zeta", "Ζ" },
        .{ "Eta", "Η" },
        .{ "Theta", "Θ" },
        .{ "Iota", "Ι" },
        .{ "Kappa", "Κ" },
        .{ "Lambda", "Λ" },
        .{ "Mu", "Μ" },
        .{ "Nu", "Ν" },
        .{ "Xi", "Ξ" },
        .{ "Omicron", "Ο" },
        .{ "Pi", "Π" },
        .{ "Rho", "Ρ" },
        .{ "Sigma", "Σ" },
        .{ "Tau", "Τ" },
        .{ "Upsilon", "Υ" },
        .{ "Phi", "Φ" },
        .{ "Chi", "Χ" },
        .{ "Psi", "Ψ" },
        .{ "Omega", "Ω" },
        .{ "int", "∫" },
        .{ "sum", "∑" },
        .{ "prod", "∏" },
        .{ "infty", "∞" },
        .{ "pm", "±" },
        .{ "mp", "∓" },
        .{ "times", "×" },
        .{ "cdot", "·" },
        .{ "cdots", "⋯" },
        .{ "ldots", "…" },
        .{ "circ", "∘" },
        .{ "le", "≤" },
        .{ "leq", "≤" },
        .{ "ge", "≥" },
        .{ "geq", "≥" },
        .{ "ne", "≠" },
        .{ "neq", "≠" },
        .{ "approx", "≈" },
        .{ "forall", "∀" },
        .{ "complement", "∁" },
        .{ "therefore", "∴" },
        .{ "emptyset", "∅" },
        .{ "empty", "∅" },
        .{ "varnothing", "∅" },
        .{ "exists", "∃" },
        .{ "exist", "∃" },
        .{ "nexists", "∄" },
        .{ "subset", "⊂" },
        .{ "supset", "⊃" },
        .{ "because", "∵" },
        .{ "mapsto", "↦" },
        .{ "mid", "∣" },
        .{ "to", "→" },
        .{ "implies", "⟹" },
        .{ "in", "∈" },
        .{ "isin", "∈" },
        .{ "land", "∧" },
        .{ "gets", "←" },
        .{ "impliedby", "⟸" },
        .{ "lor", "∨" },
        .{ "leftrightarrow", "↔" },
        .{ "iff", "⟺" },
        .{ "notin", "∉" },
        .{ "ni", "∋" },
        .{ "notni", "∌" },
        .{ "lnot", "¬" },
        .{ "nabla", "∇" },
        .{ "Im", "ℑ" },
        .{ "Reals", "ℝ" },
        .{ "jmath", "ȷ" },
        .{ "partial", "∂" },
        .{ "image", "ℑ" },
        .{ "wp", "℘" },
        .{ "aleph", "ℵ" },
        .{ "Game", "⅁" },
        .{ "weierp", "℘" },
        .{ "alef", "ℵ" },
        .{ "Finv", "Ⅎ" },
        .{ "N", "ℕ" },
        .{ "Z", "ℤ" },
        .{ "alefsym", "ℵ" },
        .{ "cnums", "ℂ" },
        .{ "natnums", "ℕ" },
        .{ "beth", "ℶ" },
        .{ "Complex", "ℂ" },
        .{ "R", "ℝ" },
        .{ "gimel", "ℷ" },
        .{ "ell", "ℓ" },
        .{ "Re", "ℜ" },
        .{ "daleth", "ℸ" },
        .{ "hbar", "ℏ" },
        .{ "real", "ℜ" },
        .{ "eth", "ð" },
        .{ "hslash", "ℏ" },
        .{ "reals", "ℝ" },
    };
    for (pairs) |pair| if (eq(name, pair[0])) return pair[1];
    return null;
}
test "math fractions and scripts have bounded geometry" {
    const layout = try Layout.init("$$x_1^2+\\frac{a}{\\sqrt{b}}$$");
    try std.testing.expect(layout.pixelWidth() > 20);
    try std.testing.expect(layout.pixelHeight() > 25);
    try std.testing.expectError(error.UnsupportedSyntax, Layout.init("$$\\unknown{x}$$"));
    try std.testing.expectError(error.InvalidSyntax, Layout.init("$$x^{2$$"));
}
test "math children fit their measured parents" {
    for ([_][]const u8{ "$$x_1^2+\\frac{a}{\\sqrt{b}}$$", "$$\\begin{cases}a & \\frac{x^2}{y_3} \\\\ b & c\\end{cases}$$", "$$\\hat{x} + \\phase{2^3}$$" }) |source| {
        const layout = try Layout.init(source);
        for (layout.boxes[0..layout.count]) |box| {
            var children: [3]u16 = .{ box.a, box.b, box.c };
            if (box.kind == .row or box.kind == .matrix) children = .{ box.a, nil, nil };
            for (children) |first| {
                var id = first;
                while (id != nil) {
                    const child = layout.boxes[id];
                    try std.testing.expect(child.x >= 0 and child.y >= 0);
                    try std.testing.expect(child.x + child.w <= box.w + 0.001);
                    try std.testing.expect(child.y + child.h <= box.h + 0.001);
                    id = if (box.kind == .row or box.kind == .matrix) child.next else nil;
                }
            }
        }
    }
}
