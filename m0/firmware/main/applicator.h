/* The receiving end of `data`: an id -> widget lookup and a switch over the
 * properties this milestone uses.
 *
 * Hard-coded to `count`, `clock` and `doc` on purpose — the general applicator
 * over the full closed eight-property set arrives at v1.2. What is *not*
 * throwaway is the rule it establishes: an update naming an id the page does
 * not have is **dropped and debug-logged, never a crash**
 * (ARCHITECTURE.md §Error handling). A server that has drifted ahead of a
 * cached page is a normal condition on a device that caches pages.
 */

#pragma once

#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Bind the applicator to a rendered page. Widgets are found by name, so the
 * page's `name=` attributes are the contract.
 */
void slate_applicator_bind(lv_obj_t *page_root);

/* Apply one update, given as the JSON object from a `data` frame's `updates`
 * array. Safe to call from any task: it takes the LVGL lock itself.
 */
void slate_applicator_apply(const char *widget_id, const char *json_update);

/* How many updates have been dropped for naming an unknown id. The DoD asks for
 * this to be observable rather than merely logged.
 */
uint32_t slate_applicator_dropped(void);

#ifdef __cplusplus
}
#endif
