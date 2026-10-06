# Errors and Constants

## C status codes

**Declaration:** `enum zm_status` in `zmermaid.h`.

| Constant | Value | Meaning |
|---|---:|---|
| `ZM_OK` | 0 | Operation succeeded. |
| `ZM_UNSUPPORTED_DIAGRAM` | 1 | Diagram family is not implemented. |
| `ZM_UNSUPPORTED_SYNTAX` | 2 | Requested syntax/configuration is not supported. |
| `ZM_INVALID_SOURCE` | 3 | Invalid source, UTF-8 or host-measurement response. |
| `ZM_LIMIT_EXCEEDED` | 4 | Input, assets, measurement or diagram limit exceeded. |
| `ZM_OUT_OF_MEMORY` | 5 | Fixed workspace exhausted. |
| `ZM_INVALID_OPTION` | 6 | Invalid theme or clock value. |
| `ZM_MISSING_ASSET` | 7 | Referenced icon/image was not supplied. |
| `ZM_MISSING_CONTEXT` | 8 | Required caller context, such as current time, is missing. |

**Remarks:** Render and measurement failures supply a category diagnostic,
currently without source locations. Setters return status directly and do not
replace that diagnostic. Measured calls use a narrower mapping: invalid/mismatched
host data generally yields `ZM_INVALID_SOURCE`; unsupported measured cases yield
`ZM_UNSUPPORTED_SYNTAX`. Do not assume identical error categories across paths.

**Example**

```c
if (status == ZM_UNSUPPORTED_SYNTAX) {
    /* Report unsupported syntax; do not display stale output. */
}
```

**See also:** [Result functions](c-buffers.md#result-functions).

## Themes

**Declaration:** C/WASM integer `0` (light) or `1` (dark); Zig `Theme.light` or
`Theme.dark`; JavaScript `'light'` or `'dark'`.

**Remarks:** Other values are rejected. ID prefixes are unsigned 32-bit values
and should be distinct for diagrams sharing a document.

**See also:** [C rendering](c-rendering.md), [Zig Options](zig.md#types-and-constants).

## Zig errors

**Declaration:** `zmermaid.Error`.

**Members:** `OutOfMemory`, `InvalidSyntax`, `LimitExceeded`, `UnsupportedSyntax`,
`MissingAsset`, `MissingContext`, `UnsupportedDiagram`, `InvalidUtf8`.

**Remarks:** Zig returns an error union rather than C status numbers. Invalid
time in ordinary Zig rendering returns `InvalidSyntax`. Measured validation may
map invalid host data to `InvalidSyntax`. Use `try` or catch errors explicitly;
free an output slice only after a successful return.

**Example**

```zig
const svg = zmermaid.render(allocator, source, .{}) catch |err| {
    std.debug.print("Render failed: {s}\n", .{@errorName(err)});
    return err;
};
defer allocator.free(svg);
```

**See also:** [Zig interface](zig.md).

## JavaScript errors

**Declaration**

```js
new RenderError(code, message)
```

**Purpose:** Represents an engine status or a wrapper resource-limit failure.

**Parameters:** `code` is the numeric status; `message` describes the failure.

**Return value:** An `Error` instance with `name === 'RenderError'` and `code`.

**Remarks:** Wrong argument types can throw `TypeError`; invalid numeric options
can throw `RangeError`. Module loading, font shaping and JSON encoding can throw
other errors. Not every failure is a `RenderError`. Asynchronous measured calls
reject their promises.

**Example**

```js
import { RenderError } from './web/zmermaid.mjs';
try {
  renderer.render(source);
} catch (error) {
  if (error instanceof RenderError) console.error(error.code, error.message);
  else throw error;
}
```

**See also:** [JavaScript interface](javascript.md).
