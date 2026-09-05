#include "applicator.h"

#include "bsp/m5stack_tab5.h"
#include "cJSON.h"
#include "esp_log.h"

static const char *TAG = "slate.apply";

static lv_obj_t *s_page_root;
static uint32_t s_dropped;

void slate_applicator_bind(lv_obj_t *page_root)
{
    s_page_root = page_root;
    s_dropped = 0;
}

uint32_t slate_applicator_dropped(void)
{
    return s_dropped;
}

/* lv_obj_find_by_name() is why LV_USE_OBJ_NAME is enabled: it turns a `data`
 * update's `id` into the widget the page declared under that name, with no
 * lookup table of our own to keep in step.
 */
static lv_obj_t *find_widget(const char *widget_id)
{
    if (s_page_root == NULL) {
        return NULL;
    }
    return lv_obj_find_by_name(s_page_root, widget_id);
}

void slate_applicator_apply(const char *widget_id, const char *json_update)
{
    cJSON *update = cJSON_Parse(json_update);
    if (update == NULL) {
        return;
    }

    bsp_display_lock(0);

    lv_obj_t *widget = find_widget(widget_id);
    if (widget == NULL) {
        /* Dropped and debug-logged, never a crash. */
        s_dropped++;
        ESP_LOGD(TAG, "dropping update for unknown id \"%s\" (%" PRIu32 " so far)", widget_id,
                 s_dropped);
        bsp_display_unlock();
        cJSON_Delete(update);
        return;
    }

    /* v0.1 uses two of the eight dynamic properties. The rest are page
     * replacements until v1.2 widens the applicator.
     */
    cJSON *text = cJSON_GetObjectItem(update, "text");
    if (cJSON_IsString(text)) {
        lv_label_set_text(widget, text->valuestring);
    }

    cJSON *items = cJSON_GetObjectItem(update, "items");
    if (cJSON_IsArray(items)) {
        /* The structured shape arrives and is counted here; rendering it as a
         * scrollable label column is SLATE-007's deliverable.
         */
        ESP_LOGI(TAG, "SLATE_LEDGER items_received id=%s blocks=%d", widget_id,
                 cJSON_GetArraySize(items));
    }

    bsp_display_unlock();
    cJSON_Delete(update);
}
