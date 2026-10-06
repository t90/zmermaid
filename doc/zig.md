# Zig Interface

**Module:** `src/root.zig`, imported as `zmermaid`.

**Compiler:** Zig 0.16.0.

## Types and constants

**Declaration**

```zig
pub const Theme = enum(u32) { light = 0, dark = 1 };
pub const Options = struct {
    theme: Theme = .light,
    id_prefix: u32 = 1,
    assets: []const u8 = "",
    now_ms: ?i64 = null,
};
pub const compatibility_version = "11.17.1";
```

**Purpose:** Selects presentation, asset JSON and optional UTC time.

**Remarks:** `assets` is encoded JSON, not a map of native Zig objects. Empty
means no registry. `now_ms` follows the range given for [zm_set_time](c-rendering.md#zm_set_time);
null means no clock. Options apply to one ordinary `render` call; they are not
retained. The compatibility constant is a syntax target, not a conformance claim.

`Error` is the error set returned by the renderer. See [Errors](errors.md#zig-errors).
`FlowMeasurement` exposes measurement types through `flow_measurement.zig`;
its lower-level geometry helpers are implementation details rather than a stable
application interface. Prefer the JSON handoff below.

**Example**

```zig
const options: zmermaid.Options = .{ .theme = .dark, .id_prefix = 12 };
```

**See also:** [render](#render), [Programming notes](programming.md).

## render

**Declaration**

```zig
pub fn render(allocator: std.mem.Allocator, input: []const u8,
              options: Options) Error![]u8;
```

**Purpose:** Converts one UTF-8 diagram source to SVG.

This is the simplest entry point for a Zig application. Unlike the C interface,
it does not require copying source into a shared buffer. You decide which
allocator to use and where to store, display or transmit the resulting SVG.

**Parameters:** `allocator` supplies temporary and output memory; `input` is
source without Markdown fences; `options` configures this call.

**Return value:** An owned SVG slice, or an error.

**Remarks:** Free the returned slice with the same allocator. Input remains
caller-owned. No output slice is returned on failure. Calls do not use singleton
C buffers. Independent calls are reentrant with suitable allocators.

**Example**

```zig
const svg = try zmermaid.render(allocator, "flowchart LR; A --> B", .{});
defer allocator.free(svg);
```

**See also:** [README usage example](../README.md#zig-api), [Errors](errors.md).

## Measured functions

**Declaration**

```zig
pub fn measurementRequest(allocator: std.mem.Allocator,
                          input: []const u8) Error![]u8;
pub fn measuredGraph(allocator: std.mem.Allocator, input: []const u8,
                     shaped_text: []const u8) Error![]u8;
pub fn measuredPlacement(allocator: std.mem.Allocator, input: []const u8,
                         shaped_text: []const u8) Error![]u8;
pub fn renderMeasured(allocator: std.mem.Allocator, input: []const u8,
                      shaped_text: []const u8, theme: Theme,
                      prefix: u32) Error![]u8;
```

**Purpose:** Requests host font shaping, validates shape bounds, computes a
measured scene, or renders that scene as SVG, respectively.

**Parameters:** Allocator and source as for `render`; `shaped_text` is UTF-8 JSON
matching the source's measurement request. `theme` and `prefix` select the
measured SVG presentation.

**Return value:** Owned UTF-8 JSON for the first three routines, or owned SVG
for `renderMeasured`. All return errors on failure.

**Remarks:** Free each returned slice with its allocator. These functions do not
take `Options`; they do not consume its assets or clock. The supported subset and
source fingerprint requirements are the same as the [C measured interface](c-measurement.md).
The source and shaped text need only remain valid during the call. The module
exports these routines as aliases of the flowchart implementation.

**Example**

```zig
const request = try zmermaid.measurementRequest(allocator, source);
defer allocator.free(request);
// Give request to a font host. shaped_json below is its matching response.
const svg = try zmermaid.renderMeasured(allocator, source, shaped_json, .light, 1);
defer allocator.free(svg);
```

**See also:** [Text measurement protocol](text-measurement.md#host-handoff).
