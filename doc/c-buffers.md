# C Interface: Buffers

**Include file:** `zmermaid.h`

**Library:** Native zmermaid; the same names are exported by WASM.

## zm_abi_version

**Declaration**

```c
uint32_t zm_abi_version(void);
```

**Purpose:** Returns the interface version.

**Parameters:** None.

**Return value:** `1` for this release.

**Remarks:** Check this before using a separately distributed library or WASM
module. This is the ABI version, not the Mermaid compatibility version.

**Example**

```c
if (zm_abi_version() != 1) return 1;
```

**See also:** [Programming notes](programming.md).

## Input functions

**Declaration**

```c
uint8_t *zm_input_ptr(void);
size_t zm_input_capacity(void);
```

**Purpose:** Obtains the writable source buffer and its capacity in bytes.

**Parameters:** None.

**Return value:** The buffer address, or the capacity (currently 1 MiB).

**Remarks:** Copy UTF-8 bytes into this buffer before a rendering or measurement
call. Pass their exact byte count. A terminating zero is neither required nor
included in the length. Never write beyond capacity. The library owns the buffer.

**Example**

```c
const char source[] = "flowchart LR; A --> B";
size_t length = sizeof(source) - 1;
if (length > zm_input_capacity()) return 1;
memcpy(zm_input_ptr(), source, length); /* Requires <string.h>. */
```

**See also:** [zm_render](c-rendering.md#zm_render),
[Measurement functions](c-measurement.md#measurement-functions).

## Result functions

**Declaration**

```c
const uint8_t *zm_output_ptr(void);
size_t zm_output_len(void);
const uint8_t *zm_error_ptr(void);
size_t zm_error_len(void);
```

**Purpose:** Obtains the result or diagnostic from the last rendering or
measurement operation.

**Parameters:** None.

**Return value:** The corresponding byte-span address or byte count.

**Remarks:** A rendering result is SVG. Measurement calls produce JSON instead.
Neither result nor diagnostic is NUL-terminated. Do not use `strlen` or `%s` on
these pointers. Copy or consume the bytes before the next render/measurement
call; never free the pointers. An empty span must not be dereferenced.

**Example**

```c
uint32_t status = zm_render(length, 0, 1);
if (status == ZM_OK)
    fwrite(zm_output_ptr(), 1, zm_output_len(), stdout);
else
    fwrite(zm_error_ptr(), 1, zm_error_len(), stderr);
/* Requires <stdio.h>; length denotes source bytes already copied. */
```

**See also:** [Errors and constants](errors.md), [Programming notes](programming.md).
