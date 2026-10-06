# zmermaid Library Reference

## How to use this reference

These original reference entries follow the compact handbook style of a classic
programming-library manual. Each entry gives its declaration, purpose,
parameters, result, remarks, example and related entries. Declarations use the
actual C, Zig or JavaScript language; this is not a Pascal binding.

## Contents

| Chapter | Contents |
|---|---|
| [Your first diagram](getting-started.md) | A complete C program and a complete Zig program |
| [Programming notes](programming.md) | Building, ownership, limits and concurrency |
| [C: buffers](c-buffers.md) | Version, source, output and diagnostic buffers |
| [C: rendering](c-rendering.md) | SVG rendering, assets and caller-supplied time |
| [C: measured rendering](c-measurement.md) | Host-shaped text and measured layout |
| [Zig interface](zig.md) | Allocator-based rendering and measured functions |
| [JavaScript interface](javascript.md) | Browser loader, rendering and interactions |
| [Text measurement](text-measurement.md) | Browser font adapter and JSON handoff |
| [Errors and constants](errors.md) | Status codes, themes and error handling |

## Alphabetical entry index

| Name | Chapter |
|---|---|
| `bindInteractions` | [JavaScript](javascript.md#bindinteractions) |
| `capacity`, `abiVersion` | [JavaScript](javascript.md#renderer-properties) |
| `createRenderer` | [JavaScript](javascript.md#createrenderer) |
| `Error`, `Options`, `Theme` | [Zig](zig.md#types-and-constants) |
| `measuredGraph`, `measuredPlacement`, `measurementRequest` | [Zig](zig.md#measured-functions) |
| `measureFlowchart`, `measurementRequest` (renderer methods) | [JavaScript](javascript.md#measurement-methods) |
| `render` (Zig) | [Zig](zig.md#render) |
| `render` (JavaScript) | [JavaScript](javascript.md#render) |
| `renderMeasured` (Zig) | [Zig](zig.md#measured-functions) |
| `renderMeasured`, `renderShaped` (JavaScript) | [JavaScript](javascript.md#measurement-methods) |
| `RenderError` | [Errors](errors.md#javascript-errors) |
| `setAssets` | [JavaScript](javascript.md#setassets) |
| `shapeTextRequest` | [Text measurement](text-measurement.md#shapetextrequest) |
| `zm_abi_version` | [C: buffers](c-buffers.md#zm_abi_version) |
| `zm_assets_capacity`, `zm_assets_ptr`, `zm_set_assets` | [C: rendering](c-rendering.md#asset-functions) |
| `zm_error_len`, `zm_error_ptr`, `zm_output_len`, `zm_output_ptr` | [C: buffers](c-buffers.md#result-functions) |
| `zm_input_capacity`, `zm_input_ptr` | [C: buffers](c-buffers.md#input-functions) |
| `zm_measurement_capacity`, `zm_measurement_ptr` | [C: measured rendering](c-measurement.md#measurement-buffer) |
| `zm_measurement_compute`, `zm_measurement_place`, `zm_measurement_request` | [C: measured rendering](c-measurement.md#measurement-functions) |
| `zm_render` | [C: rendering](c-rendering.md#zm_render) |
| `zm_render_measured` | [C: measured rendering](c-measurement.md#zm_render_measured) |
| `zm_set_time` | [C: rendering](c-rendering.md#zm_set_time) |

Only the documented top-level interfaces are intended for application use.
Internal layout modules and their helper declarations are implementation details.
