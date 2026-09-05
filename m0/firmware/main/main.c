/* Slate M0 — walking skeleton, device half.
 *
 * SLATE-001's scope only: bring the Tab5 up, prove display and touch are alive,
 * record the panel revision, and draw the first of the three firmware-drawn
 * states. Nothing here fetches, parses, or connects — the XML renderer arrives
 * with SLATE-002 and the wire with SLATE-006.
 *
 * The screen is deliberately crude (ui-m0-brief.md, ui-implementation.md §6):
 * raw LVGL widgets, stock theme, default font, #e0e0e0 ground. If it starts
 * looking designed, the milestone has drifted.
 */

#include "bsp/display.h"
#include "bsp/m5stack_tab5.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"
#include "panel_probe.h"
#include "xml_poc.h"

static const char *TAG = "slate.m0";

/* The M0 ground. A literal hex value is correct here and nowhere later: tokens
 * arrive at v1.3, and M0 exists partly to make that difference visible.
 */
#define M0_BG_COLOR 0xe0e0e0

/* The Tab5's panel is natively portrait (720x1280); Slate is landscape. */
#define M0_SCREEN_W 1280
#define M0_SCREEN_H 720

/* Log at most one touch per this interval, so a held finger cannot flood the
 * console and hide the ledger lines.
 */
#define TOUCH_LOG_INTERVAL_US 250000

static void log_touch_cb(lv_event_t *event)
{
    static int64_t last_log_us = 0;

    const int64_t now_us = esp_timer_get_time();
    if (now_us - last_log_us < TOUCH_LOG_INTERVAL_US) {
        return;
    }
    last_log_us = now_us;

    lv_indev_t *indev = lv_indev_active();
    if (indev == NULL) {
        return;
    }

    lv_point_t point;
    lv_indev_get_point(indev, &point);
    ESP_LOGI(TAG, "touch x=%d y=%d (%s)", (int)point.x, (int)point.y,
             lv_event_get_code(event) == LV_EVENT_PRESSED ? "pressed" : "released");
}

/* The `connecting…` state: one plain centred label on the grey ground. This is
 * everything the firmware can draw before a page arrives, and two more such
 * states (unreachable, the page) land with SLATE-006.
 */
static void draw_connecting_state(void)
{
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(M0_BG_COLOR), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, LV_PART_MAIN);

    lv_obj_t *label = lv_label_create(screen);
    lv_label_set_text(label, "connecting…");
    lv_obj_center(label);

    /* Touch is proven by logging real coordinates, not by trusting the driver
     * initialised without error.
     */
    lv_obj_add_flag(screen, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(screen, log_touch_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(screen, log_touch_cb, LV_EVENT_RELEASED, NULL);
}

static void log_boot_ledger(slate_panel_revision_t panel)
{
    ESP_LOGI(TAG, "SLATE_LEDGER lvgl_version=%d.%d.%d", LVGL_VERSION_MAJOR, LVGL_VERSION_MINOR,
             LVGL_VERSION_PATCH);
    ESP_LOGI(TAG, "SLATE_LEDGER idf_version=%s", esp_get_idf_version());
    ESP_LOGI(TAG, "SLATE_LEDGER free_heap_internal=%u free_heap_psram=%u",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    ESP_LOGI(TAG, "SLATE_LEDGER panel=%s", slate_panel_name(panel));
}

void app_main(void)
{
    ESP_LOGI(TAG, "Slate M0 — walking skeleton (v0.1)");

    /* Probe before the display starts. bsp_display_start() asserts outright on a
     * board it cannot identify, so anything learned after it is learned only on
     * boards that already work — which is precisely backwards for a diagnostic.
     * The probe does its own touch-enable and settle, so it does not depend on
     * the BSP having got that far.
     */
    ESP_ERROR_CHECK(bsp_i2c_init());
    const slate_panel_revision_t panel = slate_panel_probe();

    lv_display_t *display = bsp_display_start();
    if (display == NULL) {
        ESP_LOGE(TAG, "display failed to start");
        return;
    }
    ESP_ERROR_CHECK(bsp_display_backlight_on());

    bsp_display_lock(0);
    lv_display_set_rotation(display, LV_DISPLAY_ROTATION_90);
    draw_connecting_state();
    bsp_display_unlock();

    /* The go/no-go. Run against a real screen rather than a detached parent, so
     * a page that parses but cannot lay out still counts as a failure.
     */
    bsp_display_lock(0);
    lv_obj_clean(lv_screen_active());
    const slate_xml_verdict_t xml = slate_xml_poc_run(lv_screen_active(), "m0");
    bsp_display_unlock();
    slate_xml_log_verdict(&xml);

    ESP_LOGI(TAG, "display %dx%d, touch %s", (int)lv_display_get_horizontal_resolution(display),
             (int)lv_display_get_vertical_resolution(display),
             bsp_display_get_input_dev() != NULL ? "ready" : "MISSING");
    log_boot_ledger(panel);
    ESP_LOGI(TAG, "boot complete — touch the screen to log coordinates");
}
