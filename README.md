# zmermaid

A Mermaid-compatible SVG diagram renderer written in Zig. Available as a
standalone WebAssembly module and native library, with JavaScript and C APIs.

The runtime does not download assets or load Mermaid, ELK, Java, or a server.
An optional host text-measurement adapter improves flowchart and state diagram
layout using shaped text bounds.

## Status

Experimental. Diagram families and configuration options have partial support;
this is not a drop-in replacement or a claim of full Mermaid compatibility.
Mindmaps use an independently designed, FreeMind-inspired presentation.

The measured layout implements source-guided layered graph mechanics, including
fractional geometry, port ordering, labels, self-loops and selected compound
state connections. Unsupported measured cases fall back only when the host
chooses to do so. Known limitations include concurrent regions, grouped
flowcharts, mixed-direction boundary connections, oversized group titles, and
some dense routing arrangements and hierarchical feedback ordering.

## Build and test

Requires Zig 0.16.0. No Node.js, Java or npm dependencies are required.

```powershell
./build.ps1
zig build test
```

Or build directly with `zig build -Doptimize=ReleaseSmall`.

Generated outputs live in `zig-out/` and are not committed. Binary distributions
must include the license, upstream notices and an accessible matching source
version.

## Downloads

GitHub builds and runs the native unit tests on each push to `master`. Tags such
as `v0.1.0` also publish a [release](https://github.com/t90/zmermaid/releases).
Each release includes the raw WASM module, a gzip-compressed module, SHA-256
checksums and a bundle with browser loaders, API documentation and license
notices. `SOURCE.txt` identifies the exact matching source commit.
The WASM gzip asset is compressed with 7-Zip (`-tgzip -mx=9`), has its timestamp
cleared and is checked against the uncompressed module. Consumers do not need
7-Zip; this is a standard gzip stream accepted by the browser loader.

## C API

Save this as `example.c`. Link it against the native library built in `zig-out/lib/`.

```c
#include <stdio.h>
#include <string.h>
#include "zmermaid.h"

int main(void) {
    const char source[] = "flowchart LR; A[Input] --> B[SVG]";
    const size_t length = sizeof(source) - 1;
    if (zm_abi_version() != 1 || length > zm_input_capacity()) return 1;
    memcpy(zm_input_ptr(), source, length);
    const uint32_t status = zm_render(length, 0, 1);
    if (status != ZM_OK) {
        fwrite(zm_error_ptr(), 1, zm_error_len(), stderr);
        return 1;
    }
    const size_t size = zm_output_len();
    return fwrite(zm_output_ptr(), 1, size, stdout) == size ? 0 : 1;
}
```

For example, on Windows:

```powershell
zig cc example.c -Iinclude zig-out/lib/zmermaid.lib -o example.exe
```

The C API owns its buffers. Never free them; copy results before another render
or measurement call. Strings are length-delimited, not NUL-terminated. Serialize
calls because the C API uses shared state.

## Zig API

Save this as `example.zig`. This API returns an owned slice and uses your allocator.

```zig
const std = @import("std");
const zmermaid = @import("zmermaid");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const svg = try zmermaid.render(
        allocator,
        "flowchart LR; A[Input] --> B[SVG]",
        .{ .theme = .dark, .id_prefix = 1 },
    );
    defer allocator.free(svg);
    std.debug.print("{s}\n", .{svg}); // Writes to stderr.
}
```

```powershell
zig build-exe --dep zmermaid "-Mroot=example.zig" "-Mzmermaid=src/root.zig"
```

Independent Zig calls are reentrant when their allocators are safe for the chosen
concurrency model. See the [API reference](doc/index.md) for ownership, errors and
the optional host text-measurement interface.

## JavaScript API

```js
import { createRenderer } from './web/zmermaid.mjs';
const renderer = await createRenderer(wasmBytes);
const svg = renderer.render('flowchart LR; A[Input] --> B[SVG]', {
  theme: 'dark', idPrefix: 1,
});
```

`render` is synchronous after initialization. `renderMeasured` accepts a host
text-measurement callback. Use different ID prefixes within one document.
Native consumers can import `src/root.zig`; C consumers use `include/zmermaid.h`.
See the [API reference](doc/index.md). The JavaScript modules run in browsers;
they do not require Node.js.

## License and acknowledgments

Copyright (c) 2026 Vladimir Vasiltsov, for original zmermaid contributions.

zmermaid is distributed under **EPL-2.0**, with no secondary-license option
declared. See [LICENSE](LICENSE).

Mermaid and RoughJS material retains its MIT copyright and permission notices.
ELK references retain applicable upstream EPL notices. The project license does
not erase third-party rights or establish that every reference is legally a
derivative work.

- [Original upstream license texts](LICENSES/)
- [Third-party notices](THIRD-PARTY-NOTICES.txt)
- [Project and contributor thanks](THANKS.txt)
- [File-level implementation references](PROVENANCE.json)

Thanks to [Mermaid](https://github.com/mermaid-js/mermaid),
[Eclipse Layout Kernel](https://github.com/eclipse-elk/elk), and
[RoughJS](https://github.com/rough-stuff/rough).
