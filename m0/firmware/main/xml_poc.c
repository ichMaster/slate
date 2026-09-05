#include "xml_poc.h"

#include <stdlib.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"

#if LV_USE_XML
#include "others/xml/lv_xml.h"
#include "others/xml/lv_xml_component.h"
#endif

static const char *TAG = "slate.xml";

/* The page XML, embedded from m0/apps/m0.xml at build time (see
 * main/CMakeLists.txt). It is the same file the server serves, so the verdict is
 * taken against the real page — but from the binary, so a network failure
 * cannot erase the one measurement this milestone exists to produce.
 */
extern const uint8_t m0_xml_start[] asm("_binary_m0_xml_start");
extern const uint8_t m0_xml_end[] asm("_binary_m0_xml_end");

static bool s_initialised;

static uint32_t free_internal(void)
{
    return (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
}

static uint32_t free_psram(void)
{
    return (uint32_t)heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
}

/* LVGL's own pool. Reports 0 when LVGL is built against clib malloc, in which
 * case the system-heap figures are the meaningful ones instead.
 */
static uint32_t lv_pool_free(uint32_t *total_out)
{
    lv_mem_monitor_t mon;
    lv_mem_monitor(&mon);
    if (total_out != NULL) {
        *total_out = (uint32_t)mon.total_size;
    }
    return (uint32_t)mon.free_size;
}

void slate_xml_init(void)
{
#if LV_USE_XML
    if (!s_initialised) {
        lv_xml_init();
        s_initialised = true;
    }
#endif
}

void slate_xml_log_verdict(const slate_xml_verdict_t *verdict)
{
    if (!verdict->available) {
        ESP_LOGE(TAG, "SLATE_LEDGER lv_xml=UNAVAILABLE reason=built_without_LV_USE_XML");
        return;
    }
    ESP_LOGI(TAG, "SLATE_LEDGER xml_bytes=%lu", (unsigned long)verdict->xml_bytes);
    if (!verdict->registered) {
        ESP_LOGE(TAG, "SLATE_LEDGER lv_xml=NO_GO stage=register");
        return;
    }
    if (!verdict->created) {
        ESP_LOGE(TAG, "SLATE_LEDGER lv_xml=NO_GO stage=create");
        return;
    }

    /* Deltas are reported as costs (positive = memory consumed), because that is
     * the number v1.3 needs when deciding how much a page may carry.
     */
    const int32_t register_cost = (int32_t)verdict->heap_before - (int32_t)verdict->heap_after_reg;
    const int32_t create_cost =
        (int32_t)verdict->heap_after_reg - (int32_t)verdict->heap_after_create;
    const int32_t psram_cost =
        (int32_t)verdict->psram_before - (int32_t)verdict->psram_after_create;
    const int32_t lv_register_cost =
        (int32_t)verdict->lv_free_before - (int32_t)verdict->lv_free_after_reg;
    const int32_t lv_create_cost =
        (int32_t)verdict->lv_free_after_reg - (int32_t)verdict->lv_free_after_create;

    ESP_LOGI(TAG, "SLATE_LEDGER lv_xml=GO lvgl=%d.%d.%d", LVGL_VERSION_MAJOR, LVGL_VERSION_MINOR,
             LVGL_VERSION_PATCH);
    ESP_LOGI(TAG, "SLATE_LEDGER xml_register_us=%lld xml_create_us=%lld",
             (long long)verdict->register_us, (long long)verdict->create_us);
    ESP_LOGI(TAG, "SLATE_LEDGER xml_register_heap_cost=%ld xml_create_heap_cost=%ld",
             (long)register_cost, (long)create_cost);
    ESP_LOGI(TAG, "SLATE_LEDGER xml_psram_cost=%ld heap_free_after=%lu psram_free_after=%lu",
             (long)psram_cost, (unsigned long)verdict->heap_after_create,
             (unsigned long)verdict->psram_after_create);
    ESP_LOGI(TAG,
             "SLATE_LEDGER lv_pool_total=%lu lv_register_cost=%ld lv_widget_tree_cost=%ld "
             "lv_pool_free_after=%lu",
             (unsigned long)verdict->lv_total, (long)lv_register_cost, (long)lv_create_cost,
             (unsigned long)verdict->lv_free_after_create);
}

slate_xml_verdict_t slate_xml_render(lv_obj_t *parent, const char *name, const char *xml,
                                     lv_obj_t **out_root)
{
    slate_xml_verdict_t verdict = {0};
    if (out_root != NULL) {
        *out_root = NULL;
    }

#if !LV_USE_XML
    (void)parent;
    (void)name;
    (void)xml;
    ESP_LOGE(TAG, "built without LV_USE_XML; nothing to render");
    return verdict;
#else
    verdict.available = true;
    verdict.xml_bytes = (uint32_t)strlen(xml);

    slate_xml_init();

    verdict.heap_before = free_internal();
    verdict.psram_before = free_psram();
    verdict.lv_free_before = lv_pool_free(&verdict.lv_total);

    const int64_t t0 = esp_timer_get_time();
    const lv_result_t reg = lv_xml_register_component_from_data(name, xml);
    const int64_t t1 = esp_timer_get_time();

    verdict.register_us = t1 - t0;
    verdict.heap_after_reg = free_internal();
    verdict.lv_free_after_reg = lv_pool_free(NULL);
    verdict.registered = (reg == LV_RESULT_OK);

    if (!verdict.registered) {
        ESP_LOGE(TAG, "lv_xml_register_component_from_data failed for %s", name);
        return verdict;
    }

    const int64_t t2 = esp_timer_get_time();
    lv_obj_t *root = lv_xml_create(parent, name, NULL);
    const int64_t t3 = esp_timer_get_time();

    verdict.create_us = t3 - t2;
    verdict.heap_after_create = free_internal();
    verdict.psram_after_create = free_psram();
    verdict.lv_free_after_create = lv_pool_free(NULL);
    verdict.created = (root != NULL);

    if (!verdict.created) {
        ESP_LOGE(TAG, "lv_xml_create returned NULL for %s", name);
    } else if (out_root != NULL) {
        *out_root = root;
    }
    return verdict;
#endif
}

slate_xml_verdict_t slate_xml_measure_embedded(lv_obj_t *parent)
{
    slate_xml_verdict_t verdict = {0};

#if !LV_USE_XML
    (void)parent;
    ESP_LOGE(TAG, "built without LV_USE_XML; nothing to measure");
    return verdict;
#else
    /* EMBED_TXTFILES does not NUL-terminate in every IDF version, so copy into a
     * terminated buffer rather than trusting it.
     */
    const size_t xml_len = (size_t)(m0_xml_end - m0_xml_start);
    char *xml = malloc(xml_len + 1);
    if (xml == NULL) {
        ESP_LOGE(TAG, "out of memory copying the %u-byte page", (unsigned)xml_len);
        return verdict;
    }
    memcpy(xml, m0_xml_start, xml_len);
    xml[xml_len] = '\0';

    /* Registered under its own name so it cannot collide with the live page
     * fetched over HTTP, and torn down immediately: this is a measurement, not
     * the screen the user gets.
     */
    lv_obj_t *root = NULL;
    verdict = slate_xml_render(parent, "m0_poc", xml, &root);
    if (root != NULL) {
        lv_obj_delete(root);
    }
    free(xml);
    return verdict;
#endif
}
