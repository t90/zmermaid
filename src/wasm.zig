const std = @import("std");
const renderer = @import("root.zig");
const capacity = 1024 * 1024;
var input: [capacity]u8 = undefined;
var assets: [capacity]u8 = undefined;
var shaped_text: [4 * capacity]u8 = undefined;
var assets_length: usize = 0;
var now_ms: ?i64 = null;
var heap: [32 * 1024 * 1024]u8 = undefined;
var output: []const u8 = "";
var diagnostic: []const u8 = "";
export fn zm_abi_version() u32 {
    return 1;
}
export fn zm_input_ptr() [*]u8 {
    return &input;
}
export fn zm_input_capacity() usize {
    return input.len;
}
export fn zm_assets_ptr() [*]u8 {
    return &assets;
}
export fn zm_assets_capacity() usize {
    return assets.len;
}
export fn zm_set_assets(length: usize) u32 {
    assets_length = 0;
    if (length > assets.len) return 4;
    assets_length = length;
    return 0;
}
// NaN clears the optional host clock; rejected values also clear stale state.
export fn zm_set_time(timestamp_ms: f64) u32 {
    now_ms = null;
    if (std.math.isNan(timestamp_ms)) return 0;
    if (!std.math.isFinite(timestamp_ms) or timestamp_ms != @floor(timestamp_ms) or timestamp_ms < -62135596800000 or timestamp_ms > 253402300799999) return 6;
    now_ms = @intFromFloat(timestamp_ms);
    return 0;
}
export fn zm_output_ptr() [*]const u8 {
    return output.ptr;
}
export fn zm_output_len() usize {
    return output.len;
}
export fn zm_error_ptr() [*]const u8 {
    return diagnostic.ptr;
}
export fn zm_error_len() usize {
    return diagnostic.len;
}
// Stateless two-step host font handoff. Every compute rechecks the source;
// no request, source or measurement survives in a hidden registration slot.
export fn zm_measurement_ptr() [*]u8 {
    return &shaped_text;
}
export fn zm_measurement_capacity() usize {
    return shaped_text.len;
}
export fn zm_measurement_request(length: usize) u32 {
    output = "";
    diagnostic = "";
    if (length > input.len) {
        diagnostic = "Input exceeds 1 MiB.";
        return 4;
    }
    var fixed = std.heap.FixedBufferAllocator.init(&heap);
    output = @import("flowchart.zig").measurementRequest(fixed.allocator(), input[0..length]) catch |err| return measurementError(err);
    return 0;
}
export fn zm_measurement_compute(length: usize, measured_length: usize) u32 {
    output = "";
    diagnostic = "";
    if (length > input.len or measured_length > shaped_text.len) {
        diagnostic = "Source or measurement exceeds capacity.";
        return 4;
    }
    var fixed = std.heap.FixedBufferAllocator.init(&heap);
    output = @import("flowchart.zig").measuredGraph(fixed.allocator(), input[0..length], shaped_text[0..measured_length]) catch |err| return measurementError(err);
    return 0;
}
export fn zm_measurement_place(length: usize, measured_length: usize) u32 {
    output = "";
    diagnostic = "";
    if (length > input.len or measured_length > shaped_text.len) {
        diagnostic = "Source or measurement exceeds capacity.";
        return 4;
    }
    var fixed = std.heap.FixedBufferAllocator.init(&heap);
    output = @import("flowchart.zig").measuredPlacement(fixed.allocator(), input[0..length], shaped_text[0..measured_length]) catch |err| return measurementError(err);
    return 0;
}
fn measurementError(err: @import("flowchart.zig").Error) u32 {
    return switch (err) {
        error.OutOfMemory => blk: {
            diagnostic = "Measurement workspace exhausted.";
            break :blk 5;
        },
        error.LimitExceeded => blk: {
            diagnostic = "Measurement exceeds current limits.";
            break :blk 4;
        },
        error.UnsupportedSyntax => blk: {
            diagnostic = "Measured layout currently supports flat SVG-label flowcharts only.";
            break :blk 2;
        },
        else => blk: {
            diagnostic = "Invalid source or host measurements; measurements must match the original request.";
            break :blk 3;
        },
    };
}
export fn zm_render(length: usize, theme: u32, id_prefix: u32) u32 {
    output = "";
    diagnostic = "";
    if (length > input.len) {
        diagnostic = "Input exceeds 1 MiB.";
        return 4;
    }
    if (theme > 1) {
        diagnostic = "Theme must be 0 (light) or 1 (dark).";
        return 6;
    }
    var fixed = std.heap.FixedBufferAllocator.init(&heap);
    output = renderer.render(fixed.allocator(), input[0..length], .{ .theme = @enumFromInt(theme), .id_prefix = id_prefix, .assets = assets[0..assets_length], .now_ms = now_ms }) catch |err| {
        switch (err) {
            error.MissingContext => {
                diagnostic = "This diagram needs a caller-supplied current time (nowMs); the renderer does not read the system clock.";
                return 8;
            },
            error.MissingAsset => {
                diagnostic = "A referenced icon or image must be supplied by the host; rendering never downloads assets.";
                return 7;
            },
            error.UnsupportedDiagram => {
                diagnostic = "This diagram family is not implemented yet.";
                return 1;
            },
            error.UnsupportedSyntax => {
                diagnostic = "This syntax is not implemented yet; the diagram was not approximated.";
                return 2;
            },
            error.InvalidSyntax, error.InvalidUtf8 => {
                diagnostic = "Invalid or incomplete diagram source.";
                return 3;
            },
            error.LimitExceeded => {
                diagnostic = "Diagram exceeds the current input, node, edge, or label limits.";
                return 4;
            },
            error.OutOfMemory => {
                diagnostic = "Renderer workspace exhausted.";
                return 5;
            },
        }
    };
    return 0;
}
export fn zm_render_measured(length: usize, measured_length: usize, theme: u32, id_prefix: u32) u32 {
    output = "";
    diagnostic = "";
    if (length > input.len or measured_length > shaped_text.len) {
        diagnostic = "Input or measurements exceed capacity.";
        return 4;
    }
    if (theme > 1) {
        diagnostic = "Invalid theme.";
        return 6;
    }
    var fixed = std.heap.FixedBufferAllocator.init(&heap);
    output = @import("flowchart.zig").renderMeasured(fixed.allocator(), input[0..length], shaped_text[0..measured_length], @enumFromInt(theme), id_prefix) catch |err| return measurementError(err);
    return 0;
}
