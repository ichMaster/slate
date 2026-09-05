/* Panel-revision probe — one of v0.1's recorded verdicts.
 *
 * The Tab5 shipped with two different display stacks and the board does not say
 * which one it has. ROADMAP §v0.1 asks for the revision to be probed and
 * recorded because every later phase that touches the panel needs to know
 * whether the fleet is uniform.
 *
 * The BSP at 1.3.0 carries drivers for both (esp_lcd_ili9881c and
 * esp_lcd_st7123, with matching touch controllers), so the answer exists at
 * runtime; this probe reads it rather than guessing at build time.
 */

#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The three display stacks the Tab5 has shipped with. ST7123 and ST7121 share
 * an I2C address and are told apart only by the touch firmware version byte,
 * which is why they are separate values here rather than one "ST712x".
 */
typedef enum {
    SLATE_PANEL_UNKNOWN = 0,
    SLATE_PANEL_ILI9881C, /* board version 1: LCD ILI9881C, touch GT911 */
    SLATE_PANEL_ST7123,   /* board version 2: LCD ST7123,  touch ST712x FW 3 */
    SLATE_PANEL_ST7121,   /* board version 3: LCD ST7121,  touch ST712x FW 1 */
} slate_panel_revision_t;

/* Probe the panel over I2C and log the verdict in a greppable form:
 *
 *     SLATE_LEDGER panel_revision=ILI9881C touch=GT911
 *
 * Must run after the BSP's I2C bus is up. Never fails the boot: an
 * indeterminate answer is itself a result worth recording.
 */
slate_panel_revision_t slate_panel_probe(void);

/* Human-readable name for the ledger and the log line. */
const char *slate_panel_name(slate_panel_revision_t revision);

#ifdef __cplusplus
}
#endif
