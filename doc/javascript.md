# JavaScript Interface

**Module:** `web/zmermaid.mjs`. No Node.js or package installation is required.

## createRenderer

**Declaration**

```js
await createRenderer(wasmBytes, { assets } = {})
```

**Purpose:** Creates an independent renderer backed by a WASM instance.

**Parameters:** `wasmBytes` is a byte buffer/view or compiled `WebAssembly.Module`.
`assets` optionally supplies the [asset registry](c-rendering.md#asset-functions).

**Return value:** A promise for a renderer object.

**Remarks:** The loader requires ABI 1 and rejects WASM imports. Gzip bytes are
accepted when the browser supports `DecompressionStream`. The loader does not
fetch the module; the host supplies bytes. Each renderer has its own state.

**Example**

```js
import { createRenderer } from './web/zmermaid.mjs';
const renderer = await createRenderer(wasmBytes);
```

**See also:** [render](#render), [Renderer properties](#renderer-properties).

## Renderer properties

**Declaration:** `renderer.abiVersion`, `renderer.capacity`.

**Purpose:** Reports ABI version (`1`) and source capacity in UTF-8 bytes.

**Parameters:** None. **Return value:** Numbers.

**Remarks:** The returned renderer object is frozen. Its internal assets and
ID counter can still change through methods.

**Example:** `console.log(renderer.abiVersion, renderer.capacity);`

**See also:** [createRenderer](#createrenderer).

## render

**Declaration**

```js
renderer.render(source, { theme = 'light', idPrefix, nowMs = null } = {})
```

**Purpose:** Renders a source string synchronously as SVG.

Once the module has loaded, this method needs no promise or font callback.
The returned value is an ordinary string, so your application can retain it
while rendering other diagrams. For real font-based wrapping, use the separate
measured methods rather than expecting this method to consult the browser.

**Parameters:** `theme` is `'light'` or `'dark'`. `idPrefix` is an unsigned 32-bit
integer; omission takes the next instance-local ID, starting at 1. `nowMs` is
an integral UTC timestamp in the supported range, or null.

**Return value:** An owned JavaScript SVG string; throws on failure.

**Remarks:** The wrapper sets or clears the clock on every ordinary render.
Assets remain registered until replaced. Explicit prefixes do not advance the
automatic counter; avoid collisions when mixing them. Time is not accepted by
the measured methods. Returned strings survive later calls.

**Example**

```js
const svg = renderer.render('flowchart LR; A --> B', { theme: 'dark' });
```

**See also:** [Errors](errors.md#javascript-errors), [setAssets](#setassets).

## setAssets

**Declaration:** `renderer.setAssets(assets)`.

**Purpose:** Replaces the retained registry of supplied icons and images.

**Parameters:** A name-to-asset object, or null/undefined to clear it.

**Return value:** None; throws on failure.

**Remarks:** Encoding is limited to 1 MiB. Content validation is deferred to
ordinary rendering. No external icon packs are fetched or bundled.

**Example**

```js
renderer.setAssets({ 'app:ok': { svg: "<circle cx='12' cy='12' r='8'/>" } });
renderer.setAssets(null);
```

**See also:** [Asset format](c-rendering.md#asset-functions).

## Measurement methods

**Declaration**

```js
renderer.measurementRequest(source)
await renderer.measureFlowchart(source, measureText,
    { placement = false, svg = false, theme = 'light', idPrefix } = {})
await renderer.renderMeasured(source, measureText, options = {})
renderer.renderShaped(source, shaped, { theme = 'light', idPrefix } = {})
```

**Purpose:** Obtains a text request, computes measured geometry, renders using
a font-host callback, or synchronously repaints a matching shaped-text object.

**Parameters:** `measureText(request)` returns a shaped-text object or a promise
for it. `shaped` is that already-produced object. `placement` requests a final
scene instead of bounds. `svg` requests SVG and takes precedence over placement.
Theme/prefix have the same meaning as ordinary rendering.

**Return value:** `measurementRequest` returns a parsed request object.
`measureFlowchart` returns a promise for a parsed bounds/placement object, or SVG
when `svg` is true. `renderMeasured` always requests SVG. `renderShaped` returns
SVG synchronously. All may throw/reject.

**Remarks:** Shaped JSON is limited to 4 MiB. The wrapper rewrites source after
awaiting the host, so interleaved callbacks do not accidentally use another
source. Native validation still rejects stale measurements. Unsupported features
fail explicitly. Use [shapeTextRequest](text-measurement.md#shapetextrequest) as
the browser font host. See that chapter for a complete example.

**Example**

```js
const shaped = await measureText(renderer.measurementRequest(source));
const svg = renderer.renderShaped(source, shaped, { theme: 'dark' });
```

**See also:** [C measured interface](c-measurement.md), [Text measurement](text-measurement.md).

## bindInteractions

**Declaration**

```js
bindInteractions(container, { callbacks = {}, navigate } = {})
```

**Purpose:** Binds inert diagram callback metadata and optional link handling.

**Parameters:** `container` holds the rendered SVG. `callbacks` maps names to
host functions. Optional `navigate(href, { target, event })` intercepts links.

**Return value:** A cleanup function that removes the click and keyboard listeners.

**Remarks:** Only explicitly supplied functions are called; no globals are
resolved and no strings evaluated. Callback arguments are string arrays; without
explicit arguments the diagram node ID is supplied. Click, Enter and Space are
handled. Without this helper callbacks stay inert and ordinary anchors retain
browser behavior. The host remains responsible for navigation policy.

**Example**

```js
import { bindInteractions } from './web/zmermaid.mjs';
const cleanup = bindInteractions(container, {
  callbacks: { inspect: id => console.log(id) },
  navigate: href => console.log('Requested navigation:', href),
});
// When removing the view:
cleanup();
```

**See also:** [Programming notes](programming.md#host-responsibilities).
