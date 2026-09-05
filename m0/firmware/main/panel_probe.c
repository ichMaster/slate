#include "panel_probe.h"

#include "bsp/m5stack_tab5.h"
#include "driver/i2c_master.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_touch_gt911.h"
#include "esp_lcd_touch_st7123.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "slate.panel";

/* The Tab5 does not report its display stack anywhere readable, so the revision
 * is inferred from which touch controller answers on I2C — the same signal the
 * BSP uses (managed_components/espressif__m5stack_tab5/src/bsp_display.c).
 *
 * Two things this probe does that the BSP's does not, both learned the hard way
 * on the board on this desk:
 *
 *   1. It scans the whole bus and logs it. When detection fails, "nothing
 *      answered" and "something answered at an address nobody checks" look
 *      identical from a single failed probe, and they need opposite fixes.
 *   2. It probes GT911 at its **primary** address 0x5D as well as the backup
 *      0x14. The BSP checks only 0x14, so a GT911 strapped to its primary
 *      address reads as an unsupported board.
 *
 * Touch is held in reset until the IO expander enables it, so the enable and
 * its settling delay have to happen here too — a probe before that finds an
 * empty bus no matter what is soldered to it.
 */

#define ST712X_FW_VERSION_REG 0x0000
#define ST712X_FW_ST7121      1
#define ST712X_FW_ST7123      3

#define I2C_PROBE_TIMEOUT_MS 50
#define TOUCH_SETTLE_MS      500

/* Standard 7-bit I2C address range, excluding the reserved ends. */
#define I2C_SCAN_FIRST 0x08
#define I2C_SCAN_LAST  0x77

const char *slate_panel_name(slate_panel_revision_t revision)
{
    switch (revision) {
    case SLATE_PANEL_ILI9881C:
        return "ILI9881C";
    case SLATE_PANEL_ST7123:
        return "ST7123";
    case SLATE_PANEL_ST7121:
        return "ST7121";
    default:
        return "UNKNOWN";
    }
}

static const char *touch_name(slate_panel_revision_t revision)
{
    return revision == SLATE_PANEL_ILI9881C ? "GT911"
         : revision == SLATE_PANEL_UNKNOWN  ? "unknown"
                                            : "ST712x";
}

/* Log every address that acknowledges, as one line. Cheap, and it turns a
 * detection failure from a mystery into a fact worth writing in the ledger.
 */
static void scan_bus(i2c_master_bus_handle_t bus)
{
    char found[128];
    size_t used = 0;
    int count = 0;

    for (uint16_t addr = I2C_SCAN_FIRST; addr <= I2C_SCAN_LAST; addr++) {
        if (i2c_master_probe(bus, addr, I2C_PROBE_TIMEOUT_MS) != ESP_OK) {
            continue;
        }
        count++;
        if (used < sizeof(found) - 8) {
            used += snprintf(found + used, sizeof(found) - used, "0x%02X ", addr);
        }
    }
    if (count == 0) {
        snprintf(found, sizeof(found), "(none)");
    }
    ESP_LOGI(TAG, "SLATE_LEDGER i2c_devices=%d addrs=%s", count, found);
}

slate_panel_revision_t slate_panel_probe(void)
{
    i2c_master_bus_handle_t bus = bsp_i2c_get_handle();
    if (bus == NULL) {
        ESP_LOGE(TAG, "I2C bus not initialised; call bsp_i2c_init() first");
        ESP_LOGI(TAG, "SLATE_LEDGER panel_revision=UNKNOWN reason=no_i2c_bus");
        return SLATE_PANEL_UNKNOWN;
    }

    /* Release touch from reset through the IO expander, then let it boot.
     *
     * The LCD rail is enabled alongside it: on this board the touch controller
     * does not appear on the bus with BSP_FEATURE_TOUCH alone, and the BSP's own
     * detection — which enables only touch — misidentifies the board as a
     * result. Enabling both is harmless where touch is independent.
     */
    esp_err_t ret = bsp_feature_enable(BSP_FEATURE_LCD, true);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "could not enable the LCD rail: %s", esp_err_to_name(ret));
    }
    ret = bsp_feature_enable(BSP_FEATURE_TOUCH, true);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "could not enable the touch feature: %s", esp_err_to_name(ret));
    }
    vTaskDelay(pdMS_TO_TICKS(TOUCH_SETTLE_MS));

    scan_bus(bus);

    slate_panel_revision_t revision = SLATE_PANEL_UNKNOWN;
    uint8_t fw_version = 0;

    if (i2c_master_probe(bus, ESP_LCD_TOUCH_IO_I2C_ST7123_ADDRESS, I2C_PROBE_TIMEOUT_MS)
        == ESP_OK) {
        /* ST7123 and ST7121 answer at the same address; only the touch firmware
         * version byte separates them, so an unreadable version leaves the
         * revision genuinely unknown rather than guessed.
         */
        esp_lcd_panel_io_handle_t io = NULL;
        esp_lcd_panel_io_i2c_config_t io_config = ESP_LCD_TOUCH_IO_I2C_ST7123_CONFIG();
        if (esp_lcd_new_panel_io_i2c(bus, &io_config, &io) == ESP_OK) {
            if (esp_lcd_panel_io_rx_param(io, ST712X_FW_VERSION_REG, &fw_version,
                                          sizeof(fw_version))
                == ESP_OK) {
                if (fw_version == ST712X_FW_ST7121) {
                    revision = SLATE_PANEL_ST7121;
                } else if (fw_version == ST712X_FW_ST7123) {
                    revision = SLATE_PANEL_ST7123;
                } else {
                    ESP_LOGW(TAG, "ST712x present with unrecognised firmware version %u",
                             fw_version);
                }
            } else {
                ESP_LOGW(TAG, "ST712x present but firmware version unreadable");
            }
            esp_lcd_panel_io_del(io);
        }
    } else if (i2c_master_probe(bus, ESP_LCD_TOUCH_IO_I2C_GT911_ADDRESS, I2C_PROBE_TIMEOUT_MS)
                   == ESP_OK
               || i2c_master_probe(bus, ESP_LCD_TOUCH_IO_I2C_GT911_ADDRESS_BACKUP,
                                   I2C_PROBE_TIMEOUT_MS)
                      == ESP_OK) {
        revision = SLATE_PANEL_ILI9881C;
    } else {
        ESP_LOGE(TAG, "no touch controller answered: ST712x 0x%02X, GT911 0x%02X/0x%02X",
                 ESP_LCD_TOUCH_IO_I2C_ST7123_ADDRESS, ESP_LCD_TOUCH_IO_I2C_GT911_ADDRESS,
                 ESP_LCD_TOUCH_IO_I2C_GT911_ADDRESS_BACKUP);
    }

    ESP_LOGI(TAG, "SLATE_LEDGER panel_revision=%s touch=%s st712x_fw=%u",
             slate_panel_name(revision), touch_name(revision), fw_version);

    return revision;
}
