#!/usr/bin/env bash
# Slate M0 — автоматична частина тест-прогону v0.1.
#
# Тут лише те, що машина перевіряє сама. Нічого не питає і нічого не чекає від
# людини — це навмисно: усе, що вимагає очей, пальців або вух, живе в
# tools/m0-hands-on.sh і тільки там.
#
#   ./tools/m0-auto.sh            все
#   ./tools/m0-auto.sh host       лише хостові тести (без пристрою)
#   ./tools/m0-auto.sh device     лише пристрій (прошивка + аналіз логів)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

MODE="${1:-all}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO_ROOT/tools/evidence/auto-$RUN_ID"
mkdir -p "$OUT"
REPORT="$OUT/report.md"
PYTHON="$REPO_ROOT/.venv/bin/python"
FIRMWARE_DIR="$REPO_ROOT/m0/firmware"
: "${IDF_EXPORT:=$HOME/esp/esp-idf/export.sh}"

SERVER_PID=""
PASS=0; FAIL=0; SKIP=0

C_HEAD=$'\033[1;36m'; C_OK=$'\033[0;32m'; C_BAD=$'\033[0;31m'; C_DIM=$'\033[0;90m'; C_OFF=$'\033[0m'
say()   { printf '%s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$C_HEAD" "$*" "$C_OFF"; }
rec()   { printf '%s\n' "$*" >> "$REPORT"; }
pass()  { PASS=$((PASS+1)); printf '%s  PASS%s  %s\n' "$C_OK" "$C_OFF" "$1"; rec "- **PASS** — $1"; }
fail()  { FAIL=$((FAIL+1)); printf '%s  FAIL%s  %s\n' "$C_BAD" "$C_OFF" "$1"; rec "- **FAIL** — $1"; }
skip()  { SKIP=$((SKIP+1)); printf '%s  SKIP  %s%s\n' "$C_DIM" "$1" "$C_OFF"; rec "- **SKIP** — $1"; }

cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; pkill -f idf_monitor 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM

# `grep -c` друкує 0 І повертає ненульовий код, коли збігів немає, тож
# `grep -c ... || echo 0` дописував би другий нуль і ламав порівняння.
count_matches() {
    local pattern="$1" file="$2" n
    [ -f "$file" ] || { echo 0; return 0; }
    n="$(grep -aEc "$pattern" "$file" 2>/dev/null)"
    [ -z "$n" ] && n=0
    echo "$n"
}

detect_port() {
    local f; f="$(ls /dev 2>/dev/null | grep -E '^cu\.usbmodem' | head -1)"
    [ -z "$f" ] && return 1
    echo "/dev/$f"
}

capture() {
    local secs="$1" outfile="$2" port
    port="$(detect_port)" || return 1
    # shellcheck disable=SC1090
    ( . "$IDF_EXPORT" >/dev/null 2>&1 && cd "$FIRMWARE_DIR" \
        && idf.py -p "$port" monitor > "$outfile" 2>&1 ) &
    local pid=$! i=0
    while [ "$i" -lt "$secs" ]; do sleep 1; i=$((i+1)); printf '\r%s   лог %ds/%ds%s' "$C_DIM" "$i" "$secs" "$C_OFF"; done
    printf '\r%s   лог знято (%ds)        %s\n' "$C_DIM" "$secs" "$C_OFF"
    pkill -f idf_monitor 2>/dev/null
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    sed -i '' 's/\x1b\[[0-9;]*m//g' "$outfile" 2>/dev/null
    return 0
}

count_now() {
    "$PYTHON" - <<'PY' 2>/dev/null
import asyncio, sys
sys.path.insert(0, "tools")
from fake_device import FakeDevice
async def main():
    async with FakeDevice("ws://127.0.0.1:8000/ws") as d:
        r = await d.subscribe("/apps/m0", ["count"])
        print((await d.recv_data(r))["updates"][0]["text"])
asyncio.run(main())
PY
}

rec "# Slate M0 — автоматичний прогін"
rec ""
rec "**Запущено:** $(date '+%Y-%m-%d %H:%M:%S') · **Комміт:** \`$(git rev-parse --short HEAD 2>/dev/null)\`"
rec ""
rec "> Лише машинні перевірки. Те, що вимагає людини, — у \`tools/m0-hands-on.sh\`."

say ""
say "${C_HEAD}Slate M0 — автоматичний прогін${C_OFF}   ($MODE)"
say "докази: $OUT"

# =============================== ХОСТ =========================================
if [ "$MODE" = "all" ] || [ "$MODE" = "host" ]; then
head_ "A. Хост"
rec ""; rec "## A. Хост"; rec ""

say "  A1 сюїта × 3..."
A1=""
for _ in 1 2 3; do A1="$A1$("$PYTHON" -m pytest -q -p no:warnings 2>&1 | tail -1)"$'\n'; done
echo "$A1" > "$OUT/a1-pytest.txt"
if [ "$(echo "$A1" | grep -oE '^[0-9]+ passed' | sort -u | wc -l | tr -d ' ')" = "1" ] && ! echo "$A1" | grep -q failed; then
    pass "A1 сюїта стабільна: $(echo "$A1" | head -1)"
else
    fail "A1 нестабільна/червона: $(echo "$A1" | tr '\n' ' ')"
fi

say "  A2 сюїти роздільні..."
A2P="$("$PYTHON" -m pytest -q -p no:warnings 2>&1 | tail -1)"
A2C="$( (cd codegen && ../.venv/bin/python -m pytest tests -p no:warnings 2>&1 | tail -1) )"
{ echo "product: $A2P"; echo "codegen: $A2C"; } > "$OUT/a2-suites.txt"
if echo "$A2P" | grep -qE "^[0-9]+ passed" && echo "$A2C" | grep -q "546 passed"; then
    pass "A2 роздільні (продукт $A2P / codegen $A2C)"
else
    fail "A2 змішались (продукт $A2P / codegen $A2C)"
fi

say "  A3-A5 дріт..."
pkill -f "m0/server/server.py" 2>/dev/null; sleep 1
"$PYTHON" m0/server/server.py > "$OUT/server.log" 2>&1 & SERVER_PID=$!
sleep 2

B="$(count_now)"
"$PYTHON" tools/fake_device.py --increments 3 --watch 0 > "$OUT/a3.txt" 2>&1
A="$(count_now)"
if [ -n "$B" ] && [ "$A" = "$((B+3))" ]; then
    pass "A3 лічильник на сервері: $B -> $A (нова сесія)"
else
    fail "A3 лічильник не пережив нову сесію: '$B' -> '$A'"
fi

"$PYTHON" tools/fake_device.py --increments 0 --watch 4 > "$OUT/a4.txt" 2>&1
P="$(count_matches "push" "$OUT/a4.txt")"
if [ "$P" -ge 2 ] && [ "$(count_matches "req_id" "$OUT/a4.txt")" = "0" ]; then
    pass "A4 годинник пушить сам ($P кадрів/4с, без req_id)"
else
    fail "A4 пуш не той ($P кадрів, req_id=$(count_matches "req_id" "$OUT/a4.txt"))"
fi

"$PYTHON" tools/fake_device.py --increments 0 --watch 0 > "$OUT/a5.txt" 2>&1
BL="$(grep -oE "doc: [0-9]+ blocks" "$OUT/a5.txt" | grep -oE "[0-9]+" | head -1)"
if [ -n "$BL" ] && [ "$BL" -ge 50 ]; then pass "A5 документ: $BL блоків одним кадром"; else fail "A5 документ: blocks='$BL'"; fi
fi

# ============================== ПРИСТРІЙ ======================================
if [ "$MODE" = "all" ] || [ "$MODE" = "device" ]; then
head_ "B. Пристрій (машинна частина)"
rec ""; rec "## B. Пристрій"; rec ""

if ! PORT="$(detect_port)"; then
    fail "Tab5 не видно на USB"
else
    pass "Tab5 на $PORT"

    say "  B0 збірка + прошивка..."
    # shellcheck disable=SC1090
    ( . "$IDF_EXPORT" >/dev/null 2>&1 && cd "$FIRMWARE_DIR" && idf.py -p "$PORT" flash ) > "$OUT/b0-flash.log" 2>&1
    if [ $? -eq 0 ]; then pass "B0 прошито"; else fail "B0 прошивка впала"; fi

    say "  B1 лог завантаження..."
    capture 25 "$OUT/b1-boot.log"
    grep -aoE "SLATE_LEDGER .*" "$OUT/b1-boot.log" | sed 's/ *$//' | sort -u > "$OUT/b1-ledger.txt"

    BOOTS="$(count_matches "walking skeleton" "$OUT/b1-boot.log")"
    PANIC="$(count_matches "abort\\(\\) was called|Guru Meditation" "$OUT/b1-boot.log")"
    DISP="$(grep -aoE "display [0-9]+x[0-9]+, touch [a-z]+" "$OUT/b1-boot.log" | head -1)"
    XML="$(grep -aoE "lv_xml=[A-Z_]+" "$OUT/b1-boot.log" | head -1)"
    PANEL="$(grep -aoE "panel_revision=[A-Za-z0-9]+" "$OUT/b1-boot.log" | head -1)"
    BSP="$(grep -aoE "Discovered board version [0-9] \([^)]*\)" "$OUT/b1-boot.log" | head -1)"

    rec ""; rec "### Ledger"; rec ""; rec '```'
    cat "$OUT/b1-ledger.txt" >> "$REPORT"
    rec "$DISP"; rec "$BSP"; rec '```'

    [ "$BOOTS" = "1" ] && pass "B1 одне завантаження за 25с" || fail "B1 завантажень: $BOOTS (reboot-loop)"
    [ "$PANIC" = "0" ] && pass "B1 без паніки" || fail "B1 паніки: $PANIC"
    [ -n "$DISP" ] && pass "B1 $DISP" || fail "B1 дисплей не піднявся"
    [ "$XML" = "lv_xml=GO" ] && pass "B1 $XML" || fail "B1 вердикт XML: '$XML'"
    if [ -n "$PANEL" ] && [ -n "$BSP" ]; then
        pass "B1 плата: $PANEL · BSP: $BSP"
    else
        fail "B1 плата не визначилась"
    fi

    say "  B2 поведінка без сервера..."
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
    sleep 1
    capture 20 "$OUT/b2-noserver.log"
    NB="$(count_matches "walking skeleton" "$OUT/b2-noserver.log")"
    NP="$(count_matches "abort\\(\\) was called|Guru Meditation" "$OUT/b2-noserver.log")"
    if [ "$NB" -le 1 ] && [ "$NP" = "0" ]; then
        pass "B2 без сервера стабільний ($NB завантажень, $NP паніки)"
    else
        fail "B2 без сервера нестабільний ($NB завантажень, $NP паніки)"
    fi

    SDIO="$(count_matches "sdmmc_card_init failed|ensure_slave_bus_ready failed" "$OUT/b1-boot.log")"
    IP="$(grep -aoE "wifi_ip=[0-9.]+" "$OUT/b1-boot.log" | head -1)"
    rec ""; rec "### Мережа"; rec ""
    if [ -n "$IP" ]; then
        pass "B3 WiFi піднявся: $IP"
        rec "WiFi: **$IP** — блок C у hands-on можна проходити."
    else
        skip "B3 WiFi не піднявся (помилок SDIO: $SDIO) — C6 без прошивки esp_hosted"
        rec "WiFi **не піднявся**; помилок SDIO: **$SDIO**. C6 не має прошивки esp_hosted."
    fi
fi
fi

head_ "Підсумок"
rec ""; rec "## Підсумок"; rec ""
rec "| PASS | FAIL | SKIP |"; rec "|---|---|---|"; rec "| $PASS | $FAIL | $SKIP |"
printf '  %sPASS %d%s  %sFAIL %d%s  %sSKIP %d%s\n\n' "$C_OK" "$PASS" "$C_OFF" "$C_BAD" "$FAIL" "$C_OFF" "$C_DIM" "$SKIP" "$C_OFF"
say "  звіт: $REPORT"
say ""
[ "$FAIL" -eq 0 ]
