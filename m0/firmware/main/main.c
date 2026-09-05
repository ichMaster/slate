/* Slate M0 — the walking skeleton, device half.
 *
 * Power on, fetch one page from the server, render it, and let the server own
 * everything on it. The number the button increments lives on the server and
 * only ever arrives in a `data` frame — which is why rebooting this device does
 * not reset it, and why that is the whole milestone.
 *
 * The screen is deliberately crude (ui-m0-brief.md, ui-implementation.md §6):
 * raw LVGL widgets, stock theme, default font, #e0e0e0 ground, Cyrillic as tofu
 * on purpose. If it starts looking designed, the milestone has drifted.
 */

#include "applicator.h"
#include "bsp/display.h"
#include "bsp/m5stack_tab5.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"
#include "net.h"
#include "panel_probe.h"
#include "xml_poc.h"

static const char *TAG = "slate.m0";

#define M0_BG_COLOR 0xe0e0e0

/* The page's dynamic ids, and the widgets the device subscribes to. The page
 * declares them as `name=` attributes; the applicator finds them by that name.
 */
static const char *const M0_WIDGETS[] = {"count", "clock", "doc"};
#define M0_WIDGET_COUNT (sizeof(M0_WIDGETS) / sizeof(M0_WIDGETS[0]))

#define M0_PAGE_ID   "m0"
#define M0_PAGE_NAME "/apps/m0"

/* Generous: the page is ~1.9 KB today and there is 32 MB of PSRAM. */
#define PAGE_BUFFER_BYTES 8192

#define TOUCH_LOG_INTERVAL_US 250000

static lv_obj_t *s_page_root;

/* -- the three firmware-drawn states --------------------------------------- */

/* Touch logging belongs on **every** screen, not just the rendered page.
 *
 * lv_obj_clean() drops the callbacks along with the widgets, so each state has
 * to re-attach them. Attaching only on the page meant touch was unobservable in
 * exactly the situations where it most needs checking — the two states the
 * device shows when the server is out of reach.
 */
static void log_touch_cb(lv_event_t *event);

static void attach_touch_logging(lv_obj_t *screen)
{
    lv_obj_add_flag(screen, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(screen, log_touch_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(screen, log_touch_cb, LV_EVENT_RELEASED, NULL);
}

/* Everything the firmware can draw before a page arrives — and nothing else.
 * Three states is the whole UI budget of this milestone.
 */
static void draw_message_state(const char *message)
{
    bsp_display_lock(0);
    lv_obj_t *screen = lv_screen_active();
    lv_obj_clean(screen);
    lv_obj_set_style_bg_color(screen, lv_color_hex(M0_BG_COLOR), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, LV_PART_MAIN);

    lv_obj_t *label = lv_label_create(screen);
    lv_label_set_text(label, message);
    /* Стоковий шрифт LVGL — 14 px, а панель 1280x720 на п'яти дюймах: напис
     * виходить заввишки близько двох міліметрів і на дошці M0 так не виглядає.
     * 24 px — це все ще стоковий шрифт і жодного оформлення, просто читабельно
     * у масштабі цього екрана. Справжня типографіка приходить із токенами на
     * v1.3.
     */
    lv_obj_set_style_text_font(label, &lv_font_montserrat_24, LV_PART_MAIN);
    lv_obj_center(label);

    attach_touch_logging(screen);
    bsp_display_unlock();
}

static void log_touch_cb(lv_event_t *event)
{
    static int64_t last_log_us;
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

/* -- the button ------------------------------------------------------------ */

/* The philosophy, made visible: LVGL gives the press state instantly and
 * locally, and the number does NOT change here. It changes when the server's
 * `data` frame comes back. Do not be tempted to update the label optimistically
 * — that would make the device hold truth, which is the one thing it must not
 * do.
 */
static void increment_cb(lv_event_t *event)
{
    (void)event;
    ESP_LOGI(TAG, "increment pressed — asking the server");
    slate_wire_event("increment", "increment_btn");
}

static void wire_update_cb(const char *widget_id, const char *json_update)
{
    slate_applicator_apply(widget_id, json_update);
}

/* -- boot ------------------------------------------------------------------ */

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

/* Render the fetched page and wire the button to it. */
static bool render_page(const char *xml)
{
    bsp_display_lock(0);
    lv_obj_t *screen = lv_screen_active();
    lv_obj_clean(screen);

    const slate_xml_verdict_t verdict = slate_xml_render(screen, M0_PAGE_ID, xml, &s_page_root);
    const bool ok = verdict.created;
    if (ok) {
        slate_applicator_bind(s_page_root);

        lv_obj_t *button = lv_obj_find_by_name(s_page_root, "increment_btn");
        if (button != NULL) {
            lv_obj_add_event_cb(button, increment_cb, LV_EVENT_CLICKED, NULL);
        } else {
            ESP_LOGE(TAG, "page has no increment_btn — the button will do nothing");
        }

        attach_touch_logging(screen);
    }
    bsp_display_unlock();
    return ok;
}

void app_main(void)
{
    ESP_LOGI(TAG, "Slate M0 — walking skeleton (v0.1)");

    /* Probe before the display starts: bsp_display_start() asserts outright on a
     * board it cannot identify, so anything learned after it is learned only on
     * boards that already work.
     */
    ESP_ERROR_CHECK(bsp_i2c_init());

    /* Before anything else that takes time: esp_hosted begins probing the SDIO
     * link to the C6 within a couple of seconds of boot, entirely on its own
     * schedule, and an unpowered C6 means it retries and fails forever.
     */
    slate_wifi_power_on();

    const slate_panel_revision_t panel = slate_panel_probe();

    /* Not bsp_display_start(): its defaults put the draw buffers in internal
     * DMA memory, and software rotation needs a further full-screen buffer on
     * top. Once esp_hosted is linked in for WiFi there is no longer enough
     * internal RAM for that, and the display fails to start with
     * "Not enough memory for LVGL buffer (rotation buffer) allocation!".
     *
     * The Tab5 has 32 MB of PSRAM, so the buffers go there instead. The panel is
     * natively portrait (720x1280) and Slate is landscape, so the rotation is
     * not optional — the M0 board is specified at 1280x720.
     */
    bsp_display_cfg_t display_cfg = {
        .lvgl_port_cfg = ESP_LVGL_PORT_INIT_CONFIG(),
        .buffer_size = BSP_LCD_H_RES * 100,
        .double_buffer = false,
        .flags =
            {
                .buff_dma = false,
                .buff_spiram = true,
                .sw_rotate = true,
            },
    };
    lv_display_t *display = bsp_display_start_with_config(&display_cfg);
    if (display == NULL) {
        ESP_LOGE(TAG, "display failed to start");
        return;
    }
    ESP_ERROR_CHECK(bsp_display_backlight_on());

    bsp_display_lock(0);
    lv_display_set_rotation(display, LV_DISPLAY_ROTATION_90);
    bsp_display_unlock();

    ESP_LOGI(TAG, "display %dx%d, touch %s", (int)lv_display_get_horizontal_resolution(display),
             (int)lv_display_get_vertical_resolution(display),
             bsp_display_get_input_dev() != NULL ? "ready" : "MISSING");
    log_boot_ledger(panel);

    /* The go/no-go, taken against the embedded page before the network is even
     * up, so a WiFi failure cannot erase the one measurement v0.1 owes.
     */
    bsp_display_lock(0);
    const slate_xml_verdict_t xml_verdict = slate_xml_measure_embedded(lv_screen_active());
    bsp_display_unlock();
    slate_xml_log_verdict(&xml_verdict);

    /* State 1 of 3. */
    draw_message_state("connecting…");

    if (!slate_wifi_connect()) {
        draw_message_state("server unreachable");
        return;
    }

    char *page = heap_caps_malloc(PAGE_BUFFER_BYTES, MALLOC_CAP_SPIRAM);
    if (page == NULL || slate_http_fetch_page(page, PAGE_BUFFER_BYTES) == 0) {
        /* State 2 of 3. No cache to fall back on: cache honesty is v1.1. */
        draw_message_state("server unreachable");
        free(page);
        return;
    }

    /* State 3 of 3: the page itself. */
    if (!render_page(page)) {
        draw_message_state("server unreachable");
        free(page);
        return;
    }
    free(page);

    if (!slate_wire_start(wire_update_cb)) {
        draw_message_state("server unreachable");
        return;
    }

    /* Wait for the socket, then subscribe. The page is already on screen and
     * every dynamic widget shows its placeholder until the first `data` frame —
     * which is exactly the empty-then-ready progression the component library
     * will formalise at v1.3.
     */
    for (int i = 0; i < 100 && !slate_wire_connected(); i++) {
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    if (!slate_wire_connected()) {
        ESP_LOGE(TAG, "wire never opened");
        draw_message_state("server unreachable");
        return;
    }

    slate_wire_subscribe(M0_PAGE_NAME, M0_WIDGETS, M0_WIDGET_COUNT);
    ESP_LOGI(TAG, "subscribed as %s — the server owns the screen now", slate_session_id());
}
