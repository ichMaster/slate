/* The lv_xml go/no-go, and the renderer the rest of M0 uses.
 *
 * ROADMAP §v0.1 and the specification's §9 carry exactly one open question:
 * does LVGL's XML module build and run on the ESP32-P4? Everything about the
 * component machinery at v1.3 depends on the answer, and the fallback if it is
 * "no" — a vendored SAX parser with the vocabulary hand-mapped to lv_* calls —
 * costs enough that guessing is not an option.
 *
 * The verdict is taken against an **embedded** copy of the page, so it is
 * network-independent: a WiFi failure must not be able to erase the one
 * measurement this milestone exists to produce.
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool     available;      /* built with LV_USE_XML at all */
    bool     registered;     /* the page XML parsed and registered */
    bool     created;        /* a widget tree was instantiated from it */
    uint32_t xml_bytes;
    int64_t  register_us;    /* parse + register time */
    int64_t  create_us;      /* instantiate time */
    uint32_t heap_before;    /* internal free heap before registering */
    uint32_t heap_after_reg;
    uint32_t heap_after_create;
    uint32_t psram_before;
    uint32_t psram_after_create;
    /* LVGL allocates widgets from its own pool rather than the system heap, so
     * the system figures above can be flat while the real cost is here. Both are
     * recorded because which one moves is itself a finding.
     */
    uint32_t lv_free_before;
    uint32_t lv_free_after_reg;
    uint32_t lv_free_after_create;
    uint32_t lv_total;
} slate_xml_verdict_t;

/* Initialise LVGL's XML module. Idempotent. */
void slate_xml_init(void);

/* Register `xml` under `name` and instantiate it into `parent`, measuring both
 * steps. `out_root` receives the created object. Returns the verdict.
 */
slate_xml_verdict_t slate_xml_render(lv_obj_t *parent, const char *name, const char *xml,
                                     lv_obj_t **out_root);

/* The SLATE-002 verdict, taken against the page embedded in the binary and torn
 * down again. Independent of the network by design.
 */
slate_xml_verdict_t slate_xml_measure_embedded(lv_obj_t *parent);

/* One line summarising the verdict, for the boot log and SLATE-008. */
void slate_xml_log_verdict(const slate_xml_verdict_t *verdict);

#ifdef __cplusplus
}
#endif
