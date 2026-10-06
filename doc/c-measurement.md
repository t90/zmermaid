# C Interface: Measured Rendering

**Include file:** `zmermaid.h`

**Purpose:** Explicit host-font measurement for supported flowcharts and state diagrams.

## Measurement buffer

**Declaration**

```c
uint8_t *zm_measurement_ptr(void);
size_t zm_measurement_capacity(void);
```

**Parameters:** None.

**Return value:** Writable shaped-text JSON buffer, or capacity (currently 4 MiB).

**Remarks:** Separate from the source and asset buffers. Copy the host's UTF-8
shaped-text JSON here, without counting a NUL terminator. The library owns it.

**Example**

```c
/* shaped and shaped_length denote host-produced UTF-8 JSON. */
if (shaped_length > zm_measurement_capacity()) return 1;
memcpy(zm_measurement_ptr(), shaped, shaped_length);
```

**See also:** [Text measurement](text-measurement.md).

## Measurement functions

**Declaration**

```c
uint32_t zm_measurement_request(size_t length);
uint32_t zm_measurement_compute(size_t length, size_t measured_length);
uint32_t zm_measurement_place(size_t length, size_t measured_length);
```

**Purpose**

| Routine | Result in the output buffer |
|---|---|
| `zm_measurement_request` | JSON request describing text to shape and source/settings fingerprint. |
| `zm_measurement_compute` | JSON with validated fractional shape, text and edge-label measurements. |
| `zm_measurement_place` | JSON with measured placement, ports, routes and final scene. |

**Parameters:** `length` is the source byte count in the input buffer.
`measured_length` is the shaped-text JSON byte count in the measurement buffer.

**Return value:** `ZM_OK` on success; otherwise a [status code](errors.md).

**Remarks:** Copy the request result before invoking another operation. The host
must preserve `request_key` and the requested text/settings. Each consuming call
rechecks against the source in the input buffer. No hidden request registration
is retained. Stale or mismatched measurements are rejected. Unsupported families
and configurations fail rather than approximate. See the protocol chapter for
the host handoff; measurement functions do not themselves shape fonts.

**Example**

```c
/* Source bytes are already copied. */
uint32_t status = zm_measurement_request(length);
/* On success, copy output JSON and have the host shape the requested text.
   Restore the original source and copy shaped JSON before consuming it. */
```

**See also:** [Result functions](c-buffers.md#result-functions),
[Zig measured functions](zig.md#measured-functions).

## zm_render_measured

**Declaration**

```c
uint32_t zm_render_measured(size_t length, size_t measured_length,
                            uint32_t theme, uint32_t id_prefix);
```

**Purpose:** Produces SVG from source and matching host-shaped text.

**Parameters:** Source/measurement lengths as above; `theme` is `0` (light) or
`1` (dark); `id_prefix` is the SVG identifier prefix.

**Return value:** `ZM_OK`, or a status code. Read SVG or diagnostic using the
result accessors.

**Remarks:** Supports only the implemented measured-layout subset, including
selected compound state connections. HTML labels, sketch mode, assets, links,
callbacks, tooltips and media are not supported by this SVG path. This call does
not use the ordinary renderer's retained asset registry or clock. Do not assume
that ordinary rendering success implies measured rendering success.

**Example**

```c
/* Both buffers contain matching source and shaped-text JSON. */
uint32_t status = zm_render_measured(length, shaped_length, 0, 7);
```

**See also:** [zm_render](c-rendering.md#zm_render),
[JavaScript measurement methods](javascript.md#measurement-methods).
