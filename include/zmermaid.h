#ifndef ZMERMAID_H
#define ZMERMAID_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* ABI 1. No allocation/free required by callers. No network or JS dependencies.
 * This singleton ABI is NOT thread-safe: serialize calls or use separate WASM
 * instances. Native Zig callers can use the allocator-based reentrant API.
 * Copy UTF-8 into zm_input_ptr(), up to zm_input_capacity() bytes. Then render.
 * Output and diagnostic bytes remain valid only until the next render or
 * measurement call. Copy them before calling again.
 * Strings are length-delimited, not NUL terminated. Theme: 0 light, 1 dark.
 * Use distinct id_prefix values for SVGs embedded in the same HTML document.
 */
enum zm_status {
    ZM_OK = 0, ZM_UNSUPPORTED_DIAGRAM = 1, ZM_UNSUPPORTED_SYNTAX = 2,
    ZM_INVALID_SOURCE = 3, ZM_LIMIT_EXCEEDED = 4, ZM_OUT_OF_MEMORY = 5,
    ZM_INVALID_OPTION = 6, ZM_MISSING_ASSET = 7, ZM_MISSING_CONTEXT = 8
};
uint32_t zm_abi_version(void);
uint8_t *zm_input_ptr(void);
size_t zm_input_capacity(void);
/* Optional JSON asset registry; retained until replaced/cleared (length 0).
 * Validation occurs at render time. Existing zm_render callers are unchanged. */
uint8_t *zm_assets_ptr(void);
size_t zm_assets_capacity(void);
uint32_t zm_set_assets(size_t length);
/* Optional UTC milliseconds, integer in years 1–9999. NaN clears the clock.
 * Retained until replaced/cleared. Invalid values clear it and return 6. */
uint32_t zm_set_time(double timestamp_ms);
uint32_t zm_render(size_t length, uint32_t theme, uint32_t id_prefix);
/* Optional font-host checkpoint, independent of legacy zm_render().
 * Request returns JSON with unwrapped text and a source/settings fingerprint.
 * The host shapes text, preserves request_key, and writes shaped-text JSON into
 * zm_measurement_ptr(). Compute rereads the original source from zm_input_ptr()
 * and returns validated fractional shape/text/edge-label bounds as JSON.
 * Unsupported families/containers fail explicitly. No retained request state.
 * Legacy zm_render remains unchanged; measured placement/SVG is explicit. */
uint8_t *zm_measurement_ptr(void);
size_t zm_measurement_capacity(void);
uint32_t zm_measurement_request(size_t length);
uint32_t zm_measurement_compute(size_t length, size_t measured_length);
uint32_t zm_measurement_place(size_t length, size_t measured_length);
uint32_t zm_render_measured(size_t length, size_t measured_length, uint32_t theme, uint32_t id_prefix);
const uint8_t *zm_output_ptr(void);
size_t zm_output_len(void);
const uint8_t *zm_error_ptr(void);
size_t zm_error_len(void);

#ifdef __cplusplus
}
#endif
#endif
