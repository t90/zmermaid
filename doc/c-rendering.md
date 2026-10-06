# C Interface: Rendering

**Include file:** `zmermaid.h`

## zm_render

**Declaration**

```c
uint32_t zm_render(size_t length, uint32_t theme, uint32_t id_prefix);
```

**Purpose:** Renders the diagram in the input buffer as SVG.

Use this routine when you already have the diagram source and want a finished
SVG without supplying font measurements. It performs parsing, layout and SVG
generation in one call. A failure is a failed transaction, not a partly usable
picture: examine the status and diagnostic instead of reading an old result.

**Parameters**

| Name | Meaning |
|---|---|
| `length` | Number of UTF-8 source bytes already copied to `zm_input_ptr()`. |
| `theme` | `0` for light; `1` for dark. |
| `id_prefix` | Unsigned SVG identifier prefix; use distinct values per document. |

**Return value:** `ZM_OK` on success; otherwise a [status code](errors.md#c-status-codes).

**Remarks:** Uses the retained asset registry and caller-supplied clock. The
output span contains SVG only on success. Unsupported syntax fails explicitly.
Ordinary rendering uses built-in text estimates, not host-shaped measurements.

**Example**

```c
/* Source is already in the input buffer. */
uint32_t status = zm_render(length, 1, 42);
```

**See also:** [Result functions](c-buffers.md#result-functions),
[zm_render_measured](c-measurement.md#zm_render_measured).

## Asset functions

**Declaration**

```c
uint8_t *zm_assets_ptr(void);
size_t zm_assets_capacity(void);
uint32_t zm_set_assets(size_t length);
```

**Purpose:** Supplies icons and images referenced by a diagram.

**Parameters:** `length` is the byte count of asset JSON copied to the asset
buffer. Pass zero to clear the registry.

**Return value:** The accessors return buffer address/capacity. `zm_set_assets`
returns `ZM_OK`, or `ZM_LIMIT_EXCEEDED` if the length exceeds capacity. An
oversized registration also clears the previous registration.

**Remarks:** Capacity is 1 MiB. Registration retains bytes until replaced or
cleared; JSON/content validation occurs during ordinary rendering, not during
registration. Do not alter registered bytes without re-registering them.

The JSON object maps exact icon names or image references to asset objects:

```json
{"app:ok":{"width":24,"height":24,"svg":"<path d='M4 12 L10 18 L20 6'/>"}}
```

At most 256 assets are supported. Dimensions default to 24; values must be
positive and no greater than 16,384. Each asset supplies either an SVG fragment
or a `data` image URI such as `data:image/png;base64,...`, not both. PNG, JPEG,
GIF and WebP are accepted. The SVG fragment subset
excludes scripts, event attributes, CSS, external references, XML entities and
`foreignObject`. Local reference IDs are rewritten. No assets are downloaded.

**Example**

```c
const char assets[] = "{\"app:ok\":{\"svg\":\"<circle cx='12' cy='12' r='8'/>\"}}";
size_t length = sizeof(assets) - 1;
if (length > zm_assets_capacity()) return 1;
memcpy(zm_assets_ptr(), assets, length);
if (zm_set_assets(length) != ZM_OK) return 1;
/* Requires <string.h>. */
```

**See also:** [Zig Options](zig.md#types-and-constants),
[JavaScript setAssets](javascript.md#setassets).

## zm_set_time

**Declaration**

```c
uint32_t zm_set_time(double timestamp_ms);
```

**Purpose:** Supplies the current UTC time for ordinary rendering.

**Parameters:** Integral milliseconds since the Unix epoch, from
`-62135596800000` through `253402300799999` (years 1–9999). `NaN` clears the clock.

**Return value:** `ZM_OK`, or `ZM_INVALID_OPTION` for a fractional, infinite or
out-of-range value. Invalid values also clear the retained clock.

**Remarks:** Time persists until replaced or cleared. The renderer never reads
the system clock. Gantt `todayMarker` features may require it; `todayMarker off`
does not. Host timezone conversion is the caller's responsibility. The measured
interface does not accept a clock or use this setting.

**Example**

```c
zm_set_time(NAN); /* Requires <math.h>; remove a retained clock. */
```

**See also:** [ZM_MISSING_CONTEXT](errors.md#c-status-codes),
[Zig Options](zig.md#types-and-constants).
