/* `doc-view` v0 — the platform's heaviest renderer, proven first.
 *
 * The device turns a list of typed blocks into a scrollable column of plain
 * labels. It does **not** parse Markdown, and never will: the server sends
 * `{kind, text}` and the renderer only ever switches on `kind`. That invariant
 * is the reason doc-view is in the walking skeleton at all — every later
 * document surface (the Markdown browser at v2.4, Wikipedia at v2.5) reaches
 * the device through this same shape.
 *
 * Throwaway in every other respect: no component, no tokens, no links. Headings
 * are merely larger, bullets are prefixed, code sits on a shaded strip.
 */

#pragma once

#include "cJSON.h"
#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Replace the contents of `container` with the given blocks.
 *
 * `items` is the `items` array from a `data` frame. The previous column is
 * freed first, so repeated updates must not grow the heap — the DoD asks for
 * that to be measured rather than assumed.
 *
 * Caller holds the LVGL lock.
 */
void slate_doc_view_set_items(lv_obj_t *container, const cJSON *items);

/* Microseconds spent in the last rebuild, for the SLATE-008 ledger. */
int64_t slate_doc_view_last_render_us(void);

#ifdef __cplusplus
}
#endif
