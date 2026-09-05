/* The device half of v0.1's trimmed wire.
 *
 * WiFi, one HTTP GET for the page, and a WebSocket speaking `subscribe`,
 * `data` and `event` — nothing else. No cache, no revalidation, no session
 * registry, no reconnection: v0.1 implements a strict *subset* of the protocol,
 * never a variant of it. Cache honesty is v1.1, sessions and reconnect are v1.2.
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Called on the LVGL side for each update in a `data` frame. `json_update` is
 * one element of the `updates` array, still as JSON, because the applicator is
 * the only thing that knows which properties a widget understands.
 */
typedef void (*slate_update_cb_t)(const char *widget_id, const char *json_update);

/* Join the network configured in Kconfig. Blocks until associated or timed out. */
bool slate_wifi_connect(void);

/* Fetch the page XML into a caller-owned buffer. Returns the byte count, or 0.
 * The buffer is NUL-terminated on success.
 */
size_t slate_http_fetch_page(char *out, size_t out_size);

/* Open the WebSocket and start the wire. `on_update` is invoked for every
 * update in every `data` frame, from the websocket task.
 */
bool slate_wire_start(slate_update_cb_t on_update);

/* Send `subscribe` for the named widgets. */
void slate_wire_subscribe(const char *page, const char *const *widgets, size_t count);

/* Send a fire-and-forget `event`. */
void slate_wire_event(const char *action, const char *source);

/* True once the socket is open. */
bool slate_wire_connected(void);

/* The device-minted session id, for logging. */
const char *slate_session_id(void);

#ifdef __cplusplus
}
#endif
