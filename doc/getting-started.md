# Your First Diagram

You do not need a browser to turn diagram source into SVG. The native library
accepts a small text description and gives back the finished picture as text.
A browser or another SVG viewer can display that picture later.

Consider this source:

```text
flowchart LR
    A[Read source] --> B{Ready?}
    B -->|Yes| C[Render SVG]
    B -->|No| D[Revise source]
```

`LR` places the main flow from left to right. Square brackets describe process
boxes; braces describe a decision diamond. The words between vertical bars are
labels on the arrows. Pass the source itself to the library, not a Markdown
document containing it.

## A C program

The C interface uses library-owned buffers. Think of rendering as a three-part
transaction: put source into the input buffer, call the renderer, then read the
result before anyone calls the renderer again.

Save the following as `example.c`:

```c
#include <stdio.h>
#include <string.h>
#include "zmermaid.h"

int main(void) {
    const char source[] =
        "flowchart LR\n"
        "A[Read source] --> B{Ready?}\n"
        "B -->|Yes| C[Render SVG]\n"
        "B -->|No| D[Revise source]\n";
    const size_t length = sizeof(source) - 1;

    if (zm_abi_version() != 1 || length > zm_input_capacity()) {
        fputs("Incompatible library or source too large.\n", stderr);
        return 1;
    }
    memcpy(zm_input_ptr(), source, length);

    const uint32_t status = zm_render(length, 0, 1);
    if (status != ZM_OK) {
        fwrite(zm_error_ptr(), 1, zm_error_len(), stderr);
        fputc('\n', stderr);
        return 1;
    }

    FILE *file = fopen("diagram.svg", "wb");
    if (!file) {
        perror("diagram.svg");
        return 1;
    }
    const size_t size = zm_output_len();
    const int write_failed = fwrite(zm_output_ptr(), 1, size, file) != size;
    const int close_failed = fclose(file) != 0;
    return write_failed || close_failed ? 1 : 0;
}
```

After building the library, compile and run on Windows:

```powershell
zig cc example.c -Iinclude zig-out/lib/zmermaid.lib -o example.exe
./example.exe
```

The program creates `diagram.svg`. Open it with an SVG viewer. Change the second
argument of `zm_render` from `0` to `1` to select the dark theme.

Notice `sizeof(source) - 1`: the library wants the source byte count, without
the C string's terminating zero. Notice also that `fwrite` receives an explicit
length. The returned SVG is not a C string; using `strlen` on it is incorrect.

## A Zig program

The Zig interface has no shared input buffer. It accepts a source slice and
returns a new slice allocated by the allocator you supply. You own that slice.

Save the following as `example.zig`:

```zig
const std = @import("std");
const zmermaid = @import("zmermaid");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const source =
        \\flowchart LR
        \\A[Read source] --> B{Ready?}
        \\B -->|Yes| C[Render SVG]
        \\B -->|No| D[Revise source]
    ;

    const svg = try zmermaid.render(allocator, source, .{});
    defer allocator.free(svg);
    std.debug.print("{s}\n", .{svg});
}
```

Compile and run:

```powershell
zig build-exe --dep zmermaid "-Mroot=example.zig" "-Mzmermaid=src/root.zig"
./example.exe
```

This example prints SVG to the diagnostic stream (stderr). The renderer does
not write files itself; your application decides where the result goes.

`try` propagates a rendering error. `defer allocator.free(svg)` releases the
successful result when the function exits. To select dark presentation, pass
`.{ .theme = .dark }` as the options argument instead of the empty default value.

## When to use measured rendering

Ordinary rendering is convenient when the host has no font engine. If your host
can measure real fonts, the measured interface lets node sizes and wrapping
follow those measurements instead. This can make a substantial difference with
long labels, styled text and unusual fonts.

Measured rendering is a separate workflow, not a switch that silently changes
every diagram. Start with ordinary rendering, then read [Text measurement](text-measurement.md)
when your application needs host-shaped text.

**See also:** [C rendering](c-rendering.md), [Zig render](zig.md#render),
[Programming notes](programming.md).
