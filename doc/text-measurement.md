# Text Measurement

## shapeTextRequest

**Module:** `web/text-measurement.mjs`.

**Declaration**

```js
shapeTextRequest(request, document)
```

**Purpose:** Shapes requested text using the browser's SVG font engine.

**Parameters:** `request` is an object from `renderer.measurementRequest`.
`document` is a browser document with a body and working SVG text measurement.

**Return value:** A `zmermaid-shaped-text-v1` object containing node/edge bounds,
wrapped lines, styled word runs and the matching request key. Throws on failure.

**Remarks:** Creates temporary offscreen SVG elements and removes them before
returning. It uses `getBBox`, `getComputedTextLength` and `Intl.Segmenter`, not
character-count approximations. A DOM mock without real text geometry is not
sufficient. Load the selected fonts before calling. No Mermaid/ELK runtime is
imported. Measured layouts require SVG labels, not HTML labels.

**Example**

```js
import { createRenderer } from './web/zmermaid.mjs';
import { shapeTextRequest } from './web/text-measurement.mjs';

const renderer = await createRenderer(wasmBytes);
const source = 'flowchart LR; A[Input] --> B{Ready?}';
const svg = await renderer.renderMeasured(source, async request => {
  await document.fonts.load(`16px ${request.font_family}`);
  await document.fonts.ready;
  return shapeTextRequest(request, document);
});
```

**See also:** [JavaScript measurement methods](javascript.md#measurement-methods).

## Host handoff

**Purpose:** Allows native, WASM and browser hosts to share the same measured
rendering interface without linking a font engine into zmermaid.

1. Obtain request JSON for the exact source.
2. Copy/parse it before another engine operation overwrites the output.
3. Shape every requested node label, title section and edge label with the
   requested font family, font size, wrapping width and styles.
4. Preserve source identities, settings and `request_key` in the shaped response.
5. Restore the original source if other calls have reused its buffer.
6. Supply the shaped response to bounds, placement or SVG generation.

**Remarks:** A source/settings fingerprint binds measurements to the request.
Do not edit labels, reorder identities or reuse measurements after changing
source/settings. Geometry uses fractional units. Hosts should not replace real
font shaping with guessed sizes when matching text layout matters.

The shipped browser adapter is the practical reference for response fields.
Requests use `zmermaid-measurement-request-v1`; responses use
`zmermaid-shaped-text-v1`. These experimental JSON formats are not a promise
that every internal layout structure remains unchanged under ABI 1.

**See also:** [C measured interface](c-measurement.md),
[Zig measured functions](zig.md#measured-functions).
