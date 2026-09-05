/* The lv_xml go/no-go — v0.1's reason to exist.
 *
 * ROADMAP §v0.1 and the specification's §9 carry exactly one open question:
 * does LVGL's XML module build and run on the ESP32-P4? Everything about the
 * component machinery at v1.3 depends on the answer, and the fallback if it is
 * "no" — a vendored SAX parser with the vocabulary hand-mapped to lv_* calls —
 * costs enough that guessing is not an option.
 *
 * This module answers it with measurements, not an opinion: register a page
 * from XML, instantiate it, and report parse time, create time, and the heap
 * each step cost.
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
    int64_t  register_us;    /* parse + register time */
    int64_t  create_us;      /* instantiate time */
    uint32_t heap_before;    /* internal free heap before registering */
    uint32_t heap_after_reg; /* after registering */
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

/* Register the embedded M0 page under `name` and instantiate it into `parent`.
 * Logs every measurement with a SLATE_LEDGER prefix. Returns the verdict; the
 * created object, if any, is left on `parent`.
 */
slate_xml_verdict_t slate_xml_poc_run(lv_obj_t *parent, const char *name);

/* One line summarising the verdict, for the boot log and SLATE-008. */
void slate_xml_log_verdict(const slate_xml_verdict_t *verdict);

#ifdef __cplusplus
}
#endif
