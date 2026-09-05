# Slate M0 firmware — quarry, not foundation

v0.1's device half. The kept `firmware/` tree begins at v1.1 and is **not**
seeded from this code ([ARCHITECTURE.md](../../specification/ARCHITECTURE.md)
§Stack and repository layout).

## Build and flash

```bash
. ~/esp/esp-idf/export.sh
idf.py build
idf.py -p /dev/cu.usbmodem1101 flash monitor
```

## Versions used

Pinned for v0.1's own reproducibility, **not** for the project — ARCHITECTURE
§Stack defers the real pinning to v1.1.

| | |
|---|---|
| ESP-IDF | v5.5.5 |
| LVGL | 9.5.0 (via `espressif/esp_lvgl_port ^2`) |
| Tab5 BSP | `espressif/m5stack_tab5 ^1.3.0` |

## The board on this desk

Recorded here because both facts change how the firmware must be built, and
neither is discoverable without the hardware in hand.

**ESP32-P4 revision v1.3, so this is a pre-v3 build.** ESP-IDF treats P4
revisions `<3.0` and `>=3.0` as mutually exclusive targets — "huge hardware
difference", in its own Kconfig — and 5.5 defaults to v3.1. Without
`CONFIG_ESP32P4_SELECTS_REV_LESS_V3=y` and `CONFIG_ESP32P4_REV_MIN_100=y` the
bootloader refuses to flash:

```
bootloader.bin requires chip revision in range [v3.1 - v3.99]
(this chip is revision v1.3)
```

A binary built this way runs on 0.x/1.x boards and **not** on 3.x ones. A second
Tab5 with 3.x silicon needs its own build, not an edit to this one.

**Board version 3: LCD ST7121, touch ST712x (FW 1).** Not the ILI9881C+GT911 of
the original board, and not ST7123 either — ST7123 and ST7121 share I2C address
`0x55` and are separated only by the touch firmware version byte (3 vs 1).

## The BSP bug this milestone hit

`bsp_display_start()` calls a private `bsp_get_board_version()` that enables
**only** `BSP_FEATURE_TOUCH` before probing I2C for a touch controller. On this
board the touch controller does not appear on the bus until the **LCD rail** is
also up, so that probe finds nothing and the BSP `assert`s:

```
E M5Stack Tab5: Unsupported board version!
```

which is a boot loop, not a diagnosable error. `slate_panel_probe()` therefore
enables `BSP_FEATURE_LCD` as well as `BSP_FEATURE_TOUCH` before the BSP runs,
and the board is then detected correctly by both. The I2C scan shows the
difference plainly — `0x28` and `0x55` are absent until the LCD rail is enabled:

```
touch only : i2c_devices=7  0x10 0x32 0x40 0x41 0x43 0x44 0x68
LCD + touch: i2c_devices=9  0x10 0x28 0x32 0x40 0x41 0x43 0x44 0x55 0x68
```

Any later phase that touches bring-up will meet this again. It is a BSP 1.3.0
defect against board version 3, not something Slate chose.

## What this project does (SLATE-001 scope only)

Boots, identifies the board, brings up display and touch, and draws the first of
M0's three firmware-drawn states — a plain `connecting…` label on the `#e0e0e0`
ground. Nothing here fetches, parses, or connects: the XML renderer arrives with
SLATE-002, the wire with SLATE-006.

The screen is deliberately crude ([ui-m0-brief.md](../../specification/ui-m0-brief.md),
[ui-implementation.md §6](../../specification/ui-implementation.md)). If it
starts looking designed, the milestone has drifted.

## Ledger lines

Every fact SLATE-008 needs is logged at boot with a `SLATE_LEDGER` prefix, so the
ledger is transcribed from a boot log rather than reconstructed:

```
SLATE_LEDGER i2c_devices=9 addrs=0x10 0x28 0x32 0x40 0x41 0x43 0x44 0x55 0x68
SLATE_LEDGER panel_revision=ST7121 touch=ST712x st712x_fw=1
SLATE_LEDGER lvgl_version=9.5.0
SLATE_LEDGER idf_version=v5.5.5
SLATE_LEDGER free_heap_internal=128895 free_heap_psram=31082736
```
