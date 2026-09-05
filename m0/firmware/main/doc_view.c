#include "doc_view.h"

#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"

static const char *TAG = "slate.doc";

/* The one shaded ground in M0, for code blocks (ui-implementation.md §6).
 * Literal hex is correct here and nowhere after v1.3 — M0 exists partly to make
 * that difference visible.
 */
#define CODE_BG_COLOR 0xebebeb

/* Headings are "merely larger" — the brief's words. Two stock LVGL faces are
 * all M0 gets; the real type ladder arrives with the token layer at v1.3.
 */
#define BULLET_PREFIX "• "

static int64_t s_last_render_us;

int64_t slate_doc_view_last_render_us(void)
{
    return s_last_render_us;
}

static bool kind_is(const char *kind, const char *name)
{
    return kind != NULL && strcmp(kind, name) == 0;
}

/* One block, one widget. A divider is the only kind that is not a label, since
 * it has no text to carry.
 */
static void add_block(lv_obj_t *container, const char *kind, const char *text, lv_coord_t width)
{
    if (kind_is(kind, "divider")) {
        lv_obj_t *rule = lv_obj_create(container);
        lv_obj_set_size(rule, width, 1);
        lv_obj_set_style_bg_color(rule, lv_color_hex(0xc0c0c0), LV_PART_MAIN);
        lv_obj_set_style_bg_opa(rule, LV_OPA_COVER, LV_PART_MAIN);
        lv_obj_set_style_border_width(rule, 0, LV_PART_MAIN);
        lv_obj_set_style_pad_all(rule, 0, LV_PART_MAIN);
        lv_obj_remove_flag(rule, LV_OBJ_FLAG_SCROLLABLE);
        return;
    }

    lv_obj_t *label = lv_label_create(container);
    lv_obj_set_width(label, width);
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);

    if (kind_is(kind, "bullet")) {
        /* Prefixed, not laid out with a hanging indent — that refinement belongs
         * to the real doc-view component at v2.4.
         */
        lv_label_set_text_fmt(label, BULLET_PREFIX "%s", text);
    } else {
        lv_label_set_text(label, text);
    }

    if (kind_is(kind, "h1") || kind_is(kind, "h2") || kind_is(kind, "h3")) {
        lv_obj_set_style_text_font(label, &lv_font_montserrat_24, LV_PART_MAIN);
        lv_obj_set_style_pad_top(label, 8, LV_PART_MAIN);
    } else if (kind_is(kind, "code")) {
        lv_obj_set_style_bg_color(label, lv_color_hex(CODE_BG_COLOR), LV_PART_MAIN);
        lv_obj_set_style_bg_opa(label, LV_OPA_COVER, LV_PART_MAIN);
        lv_obj_set_style_pad_all(label, 6, LV_PART_MAIN);
        /* No wrapping for code: the brief says a strip, and folding a code line
         * mid-token reads worse than clipping it.
         */
        lv_label_set_long_mode(label, LV_LABEL_LONG_CLIP);
    } else if (kind_is(kind, "quote")) {
        /* No accent rule in M0 — the token layer owns colour from v1.3. An
         * indent is enough to read as a quotation.
         */
        lv_obj_set_style_pad_left(label, 16, LV_PART_MAIN);
        lv_obj_set_style_text_color(label, lv_color_hex(0x606060), LV_PART_MAIN);
    }
}

void slate_doc_view_set_items(lv_obj_t *container, const cJSON *items)
{
    if (container == NULL || !cJSON_IsArray(items)) {
        return;
    }

    const uint32_t heap_before = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    const int64_t t0 = esp_timer_get_time();

    /* Rebuild from scratch. `items` has set semantics — there is no append
     * operation in the protocol, and the property set stays closed — so the
     * previous column is freed rather than diffed.
     */
    lv_obj_clean(container);

    lv_obj_set_flex_flow(container, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(container, 6, LV_PART_MAIN);
    lv_obj_set_scroll_dir(container, LV_DIR_VER);
    /* A visible scrollbar, so scrollability reads without a gesture. */
    lv_obj_set_scrollbar_mode(container, LV_SCROLLBAR_MODE_ON);
    lv_obj_set_style_width(container, 6, LV_PART_SCROLLBAR);

    /* Leave room for the scrollbar and the container's own padding, so text
     * wraps inside the panel rather than under the bar.
     */
    const lv_coord_t width = lv_obj_get_content_width(container) - 12;

    int count = 0;
    const cJSON *block = NULL;
    cJSON_ArrayForEach(block, items)
    {
        const cJSON *kind = cJSON_GetObjectItem(block, "kind");
        const cJSON *text = cJSON_GetObjectItem(block, "text");
        add_block(container, cJSON_IsString(kind) ? kind->valuestring : "p",
                  cJSON_IsString(text) ? text->valuestring : "", width);
        count++;
    }

    const int64_t t1 = esp_timer_get_time();
    s_last_render_us = t1 - t0;

    const uint32_t heap_after = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    ESP_LOGI(TAG, "SLATE_LEDGER doc_blocks=%d doc_render_us=%lld doc_heap_free=%lu", count,
             (long long)s_last_render_us, (unsigned long)heap_after);
    ESP_LOGD(TAG, "heap before rebuild %lu, after %lu", (unsigned long)heap_before,
             (unsigned long)heap_after);
}
