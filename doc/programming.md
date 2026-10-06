# Programming Notes

## Units and include files

**C:** Include `include/zmermaid.h` and link the static library in `zig-out/lib/`.
The header supports C++ through `extern "C"`.

**Zig:** Import `src/root.zig` as the `zmermaid` module. Requires Zig 0.16.0.

**JavaScript:** Import `web/zmermaid.mjs`. For browser text shaping, also import
`web/text-measurement.mjs`. These modules need no package installation.

## Building

```powershell
zig build -Doptimize=ReleaseSmall
zig build test
```

The build emits `zig-out/zmermaid.wasm` and a native static library. The filename
of the latter depends on the target (`zmermaid.lib` on Windows). The WASM module
has no imports and needs neither WASI nor a JavaScript diagram engine.

## Source and result

Pass one UTF-8 diagram source, without Markdown fences. Configuration frontmatter
is accepted where implemented. A successful render returns UTF-8 SVG, not a
bitmap. Not all Mermaid syntax or options are supported.

The ordinary renderer does not call the system clock, fetch assets or measure
browser fonts. Measured rendering is a separate, explicit interface; it does
not silently replace ordinary rendering or fall back after failure.

## Memory ownership

| Interface | Ownership |
|---|---|
| C and raw WASM | Buffers belong to the library. Never free them. |
| Zig | Returned `[]u8` belongs to the caller. Free with the supplied allocator. |
| JavaScript wrapper | Returned strings and parsed objects are copied out of WASM. |

C output and diagnostics must be copied before the next rendering or measurement
operation. They are byte spans, not NUL-terminated strings. Check status before
reading output. A failing render clears output; a successful render clears its
diagnostic. Asset/time setters return status directly, not a new rendered result.

## Limits and concurrency

The source and asset buffers each hold 1 MiB; the shaped-text buffer holds 4 MiB.
The C/WASM implementation has a resettable 32 MiB workspace. Additional node,
edge, nesting and label limits depend on the diagram family.

The singleton C API is neither reentrant nor thread-safe. Serialize the entire
write/call/read transaction, including asset and clock updates. Use separate
WASM instances for independent work. The allocator-based Zig API permits
independent calls, provided the allocator and host data are safe for concurrent use.

Give SVGs in the same document distinct ID prefixes. Automatic prefixes in the
JavaScript wrapper are local to that renderer, not global across instances.

## Host responsibilities

Provide any required assets, time and font measurements. Apply your navigation
policy to SVG links. Callback metadata is inert until the host binds callbacks.
Fonts should be loaded before text is shaped.

This project has not had a security audit. Do not treat its SVG or asset parser
as a general-purpose sanitizer. Bound execution time when processing untrusted
inputs; a worker is one option in a browser.

**See also:** [C buffers](c-buffers.md), [Zig interface](zig.md),
[Errors](errors.md), [Text measurement](text-measurement.md).
