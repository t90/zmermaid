/** No fetch, DOM, package dependencies, or runtime imports. Supply WASM bytes. */
export class RenderError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'RenderError';
    this.code = code;
  }
}

/** Optional host opt-in. Only explicitly registered callbacks may run; no eval or globals. */
export function bindInteractions(container, { callbacks = {}, navigate } = {}) {
  if (!container?.addEventListener || !container?.contains) throw new TypeError('Expected a diagram container');
  if (navigate !== undefined && typeof navigate !== 'function') throw new TypeError('navigate must be a function');
  const handlers = new Map(Object.entries(callbacks));
  for (const callback of handlers.values()) if (typeof callback !== 'function') throw new TypeError('Callbacks must be functions');
  const listener = event => {
    if (event.type === 'keydown' && event.key !== 'Enter' && event.key !== ' ') return;
    const node = event.target?.closest?.('[data-zm-callback],a[href]');
    if (!node || !container.contains(node)) return;
    if (node.hasAttribute('data-zm-callback')) {
      const callback = handlers.get(node.getAttribute('data-zm-callback'));
      if (!callback) return;
      const raw = node.getAttribute('data-zm-args');
      let args;
      try { args = raw === null ? [node.getAttribute('data-mermaid-id')] : JSON.parse(raw); } catch { return; }
      if (!Array.isArray(args) || args.length > 32 || args.some(x => typeof x !== 'string')) return;
      event.preventDefault(); callback(...args);
    } else if (navigate && event.type === 'click') {
      const href = node.getAttribute('href');
      if (!href || href.length>2048 || /[\x00-\x1f\x7f]/.test(href)) return;
      if (!/^(https?:\/\/|#)/i.test(href) && (/\\/.test(href) || href.startsWith('//') || /^[^/?#]*:/.test(href))) return;
      event.preventDefault(); navigate(href, { target: node.getAttribute('target') || '_self', event });
    }
  };
  container.addEventListener('click', listener);
  container.addEventListener('keydown', listener);
  return () => {
    container.removeEventListener('click', listener);
    container.removeEventListener('keydown', listener);
  };
}

export async function createRenderer(wasmBytes, { assets } = {}) {
  if (!(wasmBytes instanceof WebAssembly.Module)) {
    const bytes = ArrayBuffer.isView(wasmBytes)
      ? new Uint8Array(wasmBytes.buffer, wasmBytes.byteOffset, wasmBytes.byteLength)
      : new Uint8Array(wasmBytes);
    if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
      if (typeof DecompressionStream !== 'function') throw new Error('This browser needs gzip DecompressionStream support. Update the browser/WebView2 Runtime or supply uncompressed WASM.');
      wasmBytes = await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
    }
  }
  const module = wasmBytes instanceof WebAssembly.Module
    ? wasmBytes : await WebAssembly.compile(wasmBytes);
  if (WebAssembly.Module.imports(module).length) throw new Error('Unexpected WASM imports');
  const instance = await WebAssembly.instantiate(module, {});
  const api = instance.exports;
  if (api.zm_abi_version() !== 1) throw new Error('Unsupported zmermaid ABI');
  const encoder = new TextEncoder();
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const setAssets = assets => {
    if (typeof api.zm_set_assets !== 'function') throw new Error('This WASM build does not support assets');
    if (assets !== undefined && assets !== null && (typeof assets !== 'object' || Array.isArray(assets))) throw new TypeError('Assets must be a name-to-asset object');
    const bytes = assets === undefined || assets === null ? new Uint8Array() : encoder.encode(JSON.stringify(assets));
    if (bytes.length > api.zm_assets_capacity()) throw new RenderError(4, 'Assets exceed 1 MiB');
    new Uint8Array(api.memory.buffer, api.zm_assets_ptr(), bytes.length).set(bytes);
    const status = api.zm_set_assets(bytes.length);
    if (status) throw new RenderError(status, 'Unable to register assets');
  };
  if (assets !== undefined) setAssets(assets);
  let nextId = 1;
  const read = (ptr, len) => decoder.decode(new Uint8Array(api.memory.buffer, ptr, len));
  const writeSource = source => {
    if (typeof source !== 'string') throw new TypeError('Source must be a string');
    if (source.length > api.zm_input_capacity()) throw new RenderError(4, 'Input exceeds 1 MiB');
    const bytes = encoder.encode(source);
    if (bytes.length > api.zm_input_capacity()) throw new RenderError(4, 'Input exceeds 1 MiB');
    new Uint8Array(api.memory.buffer, api.zm_input_ptr(), bytes.length).set(bytes);
    return bytes.length;
  };
  const measurementRequest = source => {
    if (typeof api.zm_measurement_request !== 'function') throw new Error('This WASM build does not support host measurements');
    const status = api.zm_measurement_request(writeSource(source));
    if (status) throw new RenderError(status, read(api.zm_error_ptr(), api.zm_error_len()));
    return JSON.parse(read(api.zm_output_ptr(), api.zm_output_len()));
  };
  return Object.freeze({
    abiVersion: 1,
    capacity: api.zm_input_capacity(),
    setAssets,
    measurementRequest,
    /** Explicit asynchronous font-host checkpoint. It does not change render().
     * The host may await loaded fonts and use shapeTextRequest(request, document).
     * Rewrite the source after await so concurrent calls cannot mix diagrams. */
    async measureFlowchart(source, measureText, {placement = false, svg = false, theme = 'light', idPrefix} = {}) {
      if (typeof measureText !== 'function') throw new TypeError('measureText must be a font-host function');
      if (theme !== 'light' && theme !== 'dark') throw new TypeError('Theme must be light or dark');
      if (idPrefix === undefined) idPrefix = nextId++;
      if (!Number.isInteger(idPrefix) || idPrefix < 0 || idPrefix > 0xffffffff) throw new RangeError('idPrefix must be an unsigned 32-bit integer');
      const request = measurementRequest(source);
      const shaped = await measureText(request);
      if (svg) return this.renderShaped(source, shaped, {theme, idPrefix});
      const encoded = JSON.stringify(shaped);
      if (typeof encoded !== 'string') throw new TypeError('The font host must return a shaped-text object');
      if (encoded.length > api.zm_measurement_capacity()) throw new RenderError(4, 'Measurements exceed 4 MiB');
      const bytes = encoder.encode(encoded);
      if (bytes.length > api.zm_measurement_capacity()) throw new RenderError(4, 'Measurements exceed 4 MiB');
      const length = writeSource(source);
      new Uint8Array(api.memory.buffer, api.zm_measurement_ptr(), bytes.length).set(bytes);
      const status = placement ? api.zm_measurement_place(length, bytes.length) : api.zm_measurement_compute(length, bytes.length);
      if (status) throw new RenderError(status, read(api.zm_error_ptr(), api.zm_error_len()));
      const result = read(api.zm_output_ptr(), api.zm_output_len());
      return JSON.parse(result);
    },
    /** Synchronous repaint of already-shaped text. Native source binding still
     * rejects stale caches. Useful for theme changes and beforeprint events. */
    renderShaped(source, shaped, {theme = 'light', idPrefix} = {}) {
      if (theme !== 'light' && theme !== 'dark') throw new TypeError('Theme must be light or dark');
      if (idPrefix === undefined) idPrefix = nextId++;
      if (!Number.isInteger(idPrefix) || idPrefix < 0 || idPrefix > 0xffffffff) throw new RangeError('idPrefix must be an unsigned 32-bit integer');
      const encoded = JSON.stringify(shaped);
      if (typeof encoded !== 'string') throw new TypeError('Expected a shaped-text object');
      if (encoded.length > api.zm_measurement_capacity()) throw new RenderError(4, 'Measurements exceed 4 MiB');
      const bytes = encoder.encode(encoded);
      if (bytes.length > api.zm_measurement_capacity()) throw new RenderError(4, 'Measurements exceed 4 MiB');
      const length = writeSource(source);
      new Uint8Array(api.memory.buffer, api.zm_measurement_ptr(), bytes.length).set(bytes);
      const status = api.zm_render_measured(length, bytes.length, theme === 'dark' ? 1 : 0, idPrefix);
      if (status) throw new RenderError(status, read(api.zm_error_ptr(), api.zm_error_len()));
      return read(api.zm_output_ptr(), api.zm_output_len());
    },
    async renderMeasured(source, measureText, options = {}) {
      return this.measureFlowchart(source, measureText, {...options, svg: true});
    },
    render(source, { theme = 'light', idPrefix, nowMs = null } = {}) {
      if (typeof source !== 'string') throw new TypeError('Source must be a string');
      if (theme !== 'light' && theme !== 'dark') throw new TypeError('Theme must be light or dark');
      if (nowMs !== null && (!Number.isInteger(nowMs) || nowMs < -62135596800000 || nowMs > 253402300799999))
        throw new RangeError('nowMs must be an integer UTC timestamp in years 1–9999, or null');
      if (typeof api.zm_set_time === 'function') {
        const status = api.zm_set_time(nowMs === null ? NaN : nowMs);
        if (status) throw new RenderError(status, 'Invalid current time');
      } else if (nowMs !== null) throw new Error('This WASM build does not support a host clock');
      if (idPrefix === undefined) idPrefix = nextId++;
      if (!Number.isInteger(idPrefix) || idPrefix < 0 || idPrefix > 0xffffffff)
        throw new RangeError('idPrefix must be an unsigned 32-bit integer');
      // Avoid an unbounded temporary allocation before checking encoded length.
      if (source.length > api.zm_input_capacity()) throw new RenderError(4, 'Input exceeds 1 MiB');
      const bytes = encoder.encode(source);
      if (bytes.length > api.zm_input_capacity()) throw new RenderError(4, 'Input exceeds 1 MiB');
      new Uint8Array(api.memory.buffer, api.zm_input_ptr(), bytes.length).set(bytes);
      const status = api.zm_render(bytes.length, theme === 'dark' ? 1 : 0, idPrefix);
      if (status) throw new RenderError(status, read(api.zm_error_ptr(), api.zm_error_len()));
      // Copy before the next render invalidates the WASM-owned output buffer.
      return read(api.zm_output_ptr(), api.zm_output_len());
    },
  });
}
