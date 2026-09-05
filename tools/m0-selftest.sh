#!/usr/bin/env bash
# Slate M0 — інтерактивний тест-прогін v0.1.
#
# Запусти один раз:   ./tools/m0-selftest.sh
#
# Скрипт сам виконує все, що можна виконати без людини, а те, що видно лише на
# екрані пристрою, питає в тебе. Наприкінці складає один звіт — віддай його
# Клоду для аналізу.
#
# Нічого руйнівного не робить: збирає, прошиває, читає логи, ставить запитання.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO_ROOT/tools/evidence/selftest-$RUN_ID"
mkdir -p "$OUT"
REPORT="$OUT/report.md"
PYTHON="$REPO_ROOT/.venv/bin/python"
FIRMWARE_DIR="$REPO_ROOT/m0/firmware"
: "${IDF_EXPORT:=$HOME/esp/esp-idf/export.sh}"

SERVER_PID=""
PASS=0; FAIL=0; SKIP=0; ASKED=0

C_HEAD=$'\033[1;36m'; C_OK=$'\033[0;32m'; C_BAD=$'\033[0;31m'
C_ASK=$'\033[1;33m'; C_DIM=$'\033[0;90m'; C_OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$C_HEAD" "$*" "$C_OFF"; }
note() { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_OFF"; }

rec() { printf '%s\n' "$*" >> "$REPORT"; }

pass() { PASS=$((PASS+1)); printf '%s  PASS%s  %s\n' "$C_OK" "$C_OFF" "$1"; rec "- **PASS** — $1"; }
fail() { FAIL=$((FAIL+1)); printf '%s  FAIL%s  %s\n' "$C_BAD" "$C_OFF" "$1"; rec "- **FAIL** — $1"; }
skip() { SKIP=$((SKIP+1)); printf '%s  SKIP  %s%s\n' "$C_DIM" "$1" "$C_OFF"; rec "- **SKIP** — $1"; }

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    pkill -f idf_monitor 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

# Читає з термінала, якщо він справді відкривається; інакше зі stdin.
#
# `[ -r /dev/tty ]` тут брехало: файл існує, але читання падає з "Device not
# configured", коли скрипт запущено не з термінала. Тому пробуємо відкрити його
# один раз на старті і далі довіряємо результату — інакше цикл питань крутився б
# вічно, не отримуючи відповіді.
# Обгортка в групу обов'язкова: `exec 3</dev/tty 2>/dev/null` зробило б
# перенаправлення stderr ПОСТІЙНИМ для всього скрипта, і всі подальші помилки
# зникли б безслідно.
if { exec 3</dev/tty; } 2>/dev/null; then
    HAVE_TTY=1
else
    HAVE_TTY=0
fi

read_tty() {
    local __var="$1"
    if [ "$HAVE_TTY" = "1" ]; then
        read -r "$__var" <&3
    else
        read -r "$__var"
    fi
}

# --- питання -----------------------------------------------------------------
# ask_choice "<питання>" "варіант1" "варіант2" ...
# Записує і номер, і текст обраного варіанта — Клод читає текст, не номер.
ask_choice() {
    local question="$1"; shift
    local options=("$@")
    ASKED=$((ASKED+1))

    printf '\n%s? %s%s\n' "$C_ASK" "$question" "$C_OFF"
    local i=1
    for opt in "${options[@]}"; do
        printf '    %d) %s\n' "$i" "$opt"
        i=$((i+1))
    done
    printf '    0) інше / не знаю — впишу словами\n'

    local answer="" tries=0
    while true; do
        tries=$((tries+1))
        if [ "$tries" -gt 5 ]; then
            rec ""; rec "**Q$ASKED.** $question"; rec ""
            rec "> **Відповідь:** (немає вводу — питання пропущено)"
            ANSWER="NO_INPUT"
            printf '  %sбез відповіді — пропускаю%s\n' "$C_DIM" "$C_OFF"
            return 0
        fi
        printf '  твій вибір: '
        if ! read_tty answer; then
            answer=""
        fi
        if [ "$answer" = "0" ]; then
            printf '  опиши словами: '
            local free=""
            read_tty free
            rec ""
            rec "**Q$ASKED.** $question"
            rec ""
            rec "> **Відповідь (вільна):** $free"
            ANSWER="OTHER: $free"
            return 0
        fi
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
            local chosen="${options[$((answer-1))]}"
            rec ""
            rec "**Q$ASKED.** $question"
            rec ""
            rec "> **Відповідь:** $chosen"
            ANSWER="$chosen"
            return 0
        fi
        printf '  %sне зрозумів — введи число%s\n' "$C_BAD" "$C_OFF"
    done
}

wait_enter() {
    printf '\n%s>> %s%s' "$C_ASK" "$1" "$C_OFF"
    read_tty _ignored
}

detect_port() {
    local f; f="$(ls /dev 2>/dev/null | grep -E '^cu\.usbmodem' | head -1)"
    [ -z "$f" ] && return 1
    echo "/dev/$f"
}

# Рахує збіги у файлі. Обгортка потрібна, бо `grep -c` друкує 0 І повертає
# ненульовий код, коли збігів немає — тому `grep -c ... || echo 0` дописував
# ДРУГИЙ нуль. Значення на кшталт "0\n0" ламали і числові порівняння
# (справний пристрій отримував FAIL), і сам звіт.
count_matches() {
    local pattern="$1" file="$2" n
    [ -f "$file" ] || { echo 0; return 0; }
    n="$(grep -aEc "$pattern" "$file" 2>/dev/null)"
    [ -z "$n" ] && n=0
    echo "$n"
}

# Знімає лог із пристрою у файл протягом N секунд.
capture() {
    local secs="$1" outfile="$2" port
    port="$(detect_port)" || return 1
    # shellcheck disable=SC1090
    ( . "$IDF_EXPORT" >/dev/null 2>&1 && cd "$FIRMWARE_DIR" \
        && idf.py -p "$port" monitor > "$outfile" 2>&1 ) &
    local pid=$!
    local i=0
    while [ "$i" -lt "$secs" ]; do
        sleep 1; i=$((i+1))
        printf '\r%s   запис логу %ds/%ds%s' "$C_DIM" "$i" "$secs" "$C_OFF"
    done
    printf '\r%s   запис логу завершено (%ds)      %s\n' "$C_DIM" "$secs" "$C_OFF"
    pkill -f idf_monitor 2>/dev/null
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    # Прибрати ANSI, щоб лог був придатний для grep і читання
    sed -i '' 's/\x1b\[[0-9;]*m//g' "$outfile" 2>/dev/null
    return 0
}

led() { grep -aoE "SLATE_LEDGER .*" "$1" 2>/dev/null | sed 's/ *$//' | sort -u; }

# =============================================================================
say ""
say "${C_HEAD}Slate M0 — тест-прогін v0.1${C_OFF}"
say "докази: $OUT"
say ""
note "Скрипт ставитиме запитання про те, що видно на екрані Tab5."
note "Тримай пристрій перед собою. Перервати будь-коли — Ctrl-C."

rec "# Slate M0 — звіт тест-прогону"
rec ""
rec "**Запущено:** $(date '+%Y-%m-%d %H:%M:%S')  "
rec "**Комміт:** \`$(git rev-parse --short HEAD 2>/dev/null || echo '?')\`  "
rec "**Гілка:** $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
rec ""
rec "> Згенеровано \`tools/m0-selftest.sh\`. Віддай цей файл Клоду для аналізу."

# --- 0. Середовище -----------------------------------------------------------
head_ "0. Середовище"
rec ""; rec "## 0. Середовище"; rec ""

ENV_OK=1
if [ -x "$PYTHON" ]; then pass "python venv на місці"; else fail "немає .venv"; ENV_OK=0; fi
if [ -f "$IDF_EXPORT" ]; then pass "ESP-IDF знайдено"; else fail "немає ESP-IDF ($IDF_EXPORT)"; ENV_OK=0; fi
if PORT="$(detect_port)"; then
    pass "Tab5 на $PORT"
else
    fail "Tab5 не видно на USB — перевір кабель і що він у ДАНОМУ порту Tab5, не в тому, що лише живлення"
    ENV_OK=0
fi
if [ -f "$FIRMWARE_DIR/sdkconfig.defaults.local" ]; then pass "sdkconfig.defaults.local є"; else fail "немає sdkconfig.defaults.local"; ENV_OK=0; fi

if [ "$ENV_OK" -eq 0 ]; then
    say ""
    say "${C_BAD}Середовище не готове — далі немає сенсу.${C_OFF}"
    say "Звіт: $REPORT"
    exit 1
fi

# --- A. Хост -----------------------------------------------------------------
head_ "A. Хостові тести (без пристрою)"
rec ""; rec "## A. Хостові тести"; rec ""

say "  A1 — тричі ганяю сюїту, шукаю нестабільність..."
A1_RESULTS=""
for i in 1 2 3; do
    r="$("$PYTHON" -m pytest -q -p no:warnings 2>&1 | tail -1)"
    A1_RESULTS="$A1_RESULTS$r"$'\n'
done
echo "$A1_RESULTS" > "$OUT/a1-pytest.txt"
A1_COUNTS="$(echo "$A1_RESULTS" | grep -oE '^[0-9]+ passed' | sort -u | wc -l | tr -d ' ')"
if echo "$A1_RESULTS" | grep -q "passed" && [ "$A1_COUNTS" = "1" ] && ! echo "$A1_RESULTS" | grep -q "failed"; then
    pass "A1 сюїта стабільна: $(echo "$A1_RESULTS" | head -1)"
else
    fail "A1 сюїта нестабільна або червона — див. a1-pytest.txt"
fi
rec "\`\`\`"; rec "$A1_RESULTS"; rec "\`\`\`"

say "  A2 — перевіряю, що продуктова і codegen сюїти не змішались..."
A2_PROD="$("$PYTHON" -m pytest -q -p no:warnings 2>&1 | tail -1)"
A2_CG="$( (cd codegen && ../.venv/bin/python -m pytest tests -p no:warnings 2>&1 | tail -1) )"
{ echo "product: $A2_PROD"; echo "codegen: $A2_CG"; } > "$OUT/a2-suites.txt"
if echo "$A2_PROD" | grep -qE "^9[0-9] passed" && echo "$A2_CG" | grep -q "546 passed"; then
    pass "A2 сюїти роздільні (продукт: $A2_PROD / codegen: $A2_CG)"
else
    fail "A2 сюїти змішались або впали (продукт: $A2_PROD / codegen: $A2_CG)"
fi

say "  A3 — лічильник живе на сервері..."
pkill -f "m0/server/server.py" 2>/dev/null; sleep 1
"$PYTHON" m0/server/server.py > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
sleep 2

count_now() {
    "$PYTHON" - <<'PY' 2>/dev/null
import asyncio, sys
sys.path.insert(0, "tools")
from fake_device import FakeDevice
async def main():
    async with FakeDevice("ws://127.0.0.1:8000/ws") as d:
        r = await d.subscribe("/apps/m0", ["count"])
        f = await d.recv_data(r)
        print(f["updates"][0]["text"])
asyncio.run(main())
PY
}

A3_BEFORE="$(count_now)"
"$PYTHON" tools/fake_device.py --increments 3 --watch 0 > "$OUT/a3-increments.txt" 2>&1
A3_AFTER="$(count_now)"
if [ -n "$A3_BEFORE" ] && [ -n "$A3_AFTER" ] && [ "$A3_AFTER" = "$((A3_BEFORE + 3))" ]; then
    pass "A3 лічильник на сервері: $A3_BEFORE -> $A3_AFTER (нова сесія бачить те саме)"
else
    fail "A3 лічильник не пережив нову сесію: '$A3_BEFORE' -> '$A3_AFTER'"
fi

say "  A4 — непроханий пуш годинника..."
"$PYTHON" tools/fake_device.py --increments 0 --watch 4 > "$OUT/a4-clock.txt" 2>&1
A4_PUSHES="$(count_matches "push" "$OUT/a4-clock.txt")"
if [ "$A4_PUSHES" -ge 2 ] && ! grep -q "req_id" "$OUT/a4-clock.txt"; then
    pass "A4 годинник пушить сам ($A4_PUSHES кадрів за 4с, без req_id)"
else
    fail "A4 пуш годинника не той: $A4_PUSHES кадрів, req_id присутній=$(grep -c req_id "$OUT/a4-clock.txt")"
fi

say "  A5 — документ одним кадром..."
"$PYTHON" tools/fake_device.py --increments 0 --watch 0 > "$OUT/a5-doc.txt" 2>&1
A5_BLOCKS="$(grep -oE "doc: [0-9]+ blocks" "$OUT/a5-doc.txt" | grep -oE "[0-9]+" | head -1)"
if [ -n "$A5_BLOCKS" ] && [ "$A5_BLOCKS" -ge 50 ]; then
    pass "A5 документ: $A5_BLOCKS блоків одним кадром"
else
    fail "A5 документ не прийшов як слід (blocks='$A5_BLOCKS')"
fi

# --- B. Пристрій -------------------------------------------------------------
head_ "B. Пристрій"
rec ""; rec "## B. Пристрій"; rec ""

say "  Збираю і прошиваю (це займе ~1-2 хв)..."
# shellcheck disable=SC1090
( . "$IDF_EXPORT" >/dev/null 2>&1 && cd "$FIRMWARE_DIR" && idf.py -p "$PORT" flash ) \
    > "$OUT/b0-flash.log" 2>&1
if [ $? -eq 0 ]; then pass "B0 прошито"; else fail "B0 прошивка впала — див. b0-flash.log"; fi

say ""
say "  B1 — знімаю лог завантаження (25с). Пристрій щойно перезавантажився."
capture 25 "$OUT/b1-boot.log"
led "$OUT/b1-boot.log" > "$OUT/b1-ledger.txt"

B1_BOOTS="$(count_matches "walking skeleton" "$OUT/b1-boot.log")"
B1_PANEL="$(grep -aoE "panel_revision=[A-Za-z0-9]+" "$OUT/b1-boot.log" | head -1)"
B1_BSP="$(grep -aoE "Discovered board version [0-9] \([^)]*\)" "$OUT/b1-boot.log" | head -1)"
B1_XML="$(grep -aoE "lv_xml=[A-Z_]+" "$OUT/b1-boot.log" | head -1)"
B1_DISP="$(grep -aoE "display [0-9]+x[0-9]+, touch [a-zA-Z]+" "$OUT/b1-boot.log" | head -1)"

rec ""; rec "### B1 — завантаження"; rec ""; rec "\`\`\`"
cat "$OUT/b1-ledger.txt" >> "$REPORT" 2>/dev/null
rec "$B1_DISP"; rec "$B1_BSP"; rec "\`\`\`"

if [ "$B1_BOOTS" = "1" ]; then
    pass "B1 одне завантаження за 25с (немає reboot-loop)"
else
    fail "B1 пристрій перезавантажувався $B1_BOOTS разів за 25с"
fi
[ -n "$B1_DISP" ] && pass "B1 $B1_DISP" || fail "B1 дисплей не піднявся"
[ -n "$B1_XML" ] && pass "B1 $B1_XML" || fail "B1 немає вердикту lv_xml"
if [ -n "$B1_PANEL" ] && [ -n "$B1_BSP" ]; then
    pass "B1 плата: $B1_PANEL / BSP каже: $B1_BSP"
else
    fail "B1 плата не визначилась ($B1_PANEL / $B1_BSP)"
fi

ask_choice "Що зараз на екрані Tab5?" \
    "сірий фон, чорний текст 'server unreachable' по центру" \
    "сірий фон, чорний текст 'connecting…' по центру" \
    "сірий фон і сторінка: заголовок, велике число, кнопка +1, годинник, білa панель" \
    "екран чорний / нічого не видно" \
    "екран блимає або постійно перезавантажується" \
    "щось є, але виглядає поламано"
B1_SCREEN="$ANSWER"

ask_choice "Чи виглядає екран НАВМИСНО простим — сірий фон, стандартний шрифт, жодних рамок і тіней?" \
    "так, виглядає як неоформлений демо-тулкіт" \
    "ні, виглядає надто оформлено/красиво" \
    "не можу оцінити"

# --- B2 тач ------------------------------------------------------------------
say ""
say "  B2 — тач."
wait_enter "Приготуйся торкатись екрана. Натисни Enter, і після цього 15 секунд тикай у РІЗНІ місця екрана..."

say ""
say "  ${C_ASK}ТИКАЙ В ЕКРАН ЗАРАЗ${C_OFF} — у різні кути і в центр, поки йде запис"
say ""
capture 15 "$OUT/b2-touch.log"

B2_TOUCHES="$(count_matches "touch x=" "$OUT/b2-touch.log")"
grep -aoE "touch x=[0-9-]+ y=[0-9-]+ \([a-z]+\)" "$OUT/b2-touch.log" 2>/dev/null | head -12 > "$OUT/b2-coords.txt"

rec ""; rec "### B2 — тач"; rec ""
rec "Подій: **$B2_TOUCHES**"; rec ""; rec "\`\`\`"
cat "$OUT/b2-coords.txt" >> "$REPORT" 2>/dev/null
rec "\`\`\`"

if [ "$B2_TOUCHES" -ge 3 ]; then
    pass "B2 тач працює: $B2_TOUCHES подій"
    B2_BAD="$("$PYTHON" - "$OUT/b2-coords.txt" <<'PY'
import re, sys
bad = 0
for line in open(sys.argv[1], encoding="utf-8", errors="ignore"):
    m = re.search(r"touch x=(-?\d+) y=(-?\d+)", line)
    if m:
        x, y = int(m.group(1)), int(m.group(2))
        if not (0 <= x <= 1280 and 0 <= y <= 720):
            bad += 1
print(bad)
PY
)"
    if [ "$B2_BAD" = "0" ]; then
        pass "B2 усі координати в межах 1280x720"
    else
        fail "B2 $B2_BAD координат поза межами екрана"
    fi
else
    fail "B2 тач не дав подій ($B2_TOUCHES) — або не торкались, або тач не працює"
fi

# --- B4 стан "недоступний сервер" --------------------------------------------
say ""
say "  B3 — стан 'сервер недоступний'."
note "Зупиняю сервер і перезавантажую пристрій."
[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
sleep 1
# Підключення монітора саме по собі ресетить пристрій (rst:0x17
# CHIP_USB_UART_RESET), тож окрема команда скидання не потрібна — її в idf.py і
# немає.
capture 20 "$OUT/b3-unreachable.log"

B3_BOOTS="$(count_matches "walking skeleton" "$OUT/b3-unreachable.log")"
B3_PANIC="$(count_matches "abort\\(\\) was called|Guru Meditation" "$OUT/b3-unreachable.log")"
rec ""; rec "### B3 — сервер недоступний"; rec ""
rec "Завантажень за 20с: **$B3_BOOTS** · паніка: **$B3_PANIC**"

if [ "$B3_BOOTS" -le 1 ] && [ "$B3_PANIC" = "0" ]; then
    pass "B3 пристрій не падає без сервера ($B3_BOOTS завантажень, 0 паніки)"
else
    fail "B3 пристрій нестабільний без сервера ($B3_BOOTS завантажень, $B3_PANIC паніки)"
fi

ask_choice "Що на екрані ЗАРАЗ (сервер вимкнено)?" \
    "'server unreachable' простим текстом на сірому" \
    "'connecting…' і так і залишилось" \
    "сторінка з числом і кнопкою (стара, з пам'яті)" \
    "чорний екран" \
    "блимає / перезавантажується"
B3_SCREEN="$ANSWER"

# --- C. Мережа ---------------------------------------------------------------
head_ "C. Мережа (DoD)"
rec ""; rec "## C. Мережа"; rec ""

C6_FAIL="$(count_matches "sdmmc_card_init failed|ensure_slave_bus_ready failed" "$OUT/b1-boot.log")"
WIFI_IP="$(grep -aoE "wifi_ip=[0-9.]+" "$OUT/b1-boot.log" | head -1)"

if [ -n "$WIFI_IP" ]; then
    pass "C0 WiFi піднявся: $WIFI_IP"
    say ""
    note "Мережа працює — запускаю сервер і перевіряю DoD."
    "$PYTHON" m0/server/server.py > "$OUT/server-c.log" 2>&1 &
    SERVER_PID=$!
    sleep 2
    # Підключення монітора ресетить пристрій само по собі.
    capture 30 "$OUT/c1-page.log"
    led "$OUT/c1-page.log" >> "$OUT/c-ledger.txt"

    C1_FETCH="$(grep -aoE "page_fetch_bytes=[0-9]+" "$OUT/c1-page.log" | head -1)"
    C1_SUB="$(count_matches "subscribed as" "$OUT/c1-page.log")"
    C1_DOC="$(grep -aoE "doc_blocks=[0-9]+ doc_render_us=[0-9]+" "$OUT/c1-page.log" | head -1)"

    rec "\`\`\`"; rec "$C1_FETCH"; rec "$C1_DOC"; rec "\`\`\`"
    [ -n "$C1_FETCH" ] && pass "C1 сторінку отримано: $C1_FETCH" || fail "C1 сторінку не отримано"
    [ "$C1_SUB" -ge 1 ] && pass "C1 підписка пройшла" || fail "C1 підписки немає"
    [ -n "$C1_DOC" ] && pass "C4 документ відрендерено: $C1_DOC" || fail "C4 документ не відрендерено"

    ask_choice "Що на екрані?" \
        "сторінка: заголовок, велике число, кнопка +1, годинник, білa панель з текстом" \
        "сторінка є, але документ порожній" \
        "'server unreachable'" \
        "щось інше"

    ask_choice "Годинник унизу цифр рухається щосекунди?" "так, тікає" "ні, стоїть" "не бачу годинника"

    wait_enter "Натисни кнопку +1 на екрані 5 разів, потім Enter..."
    capture 12 "$OUT/c3-increment.log"
    C3_EVENTS="$(count_matches "increment pressed" "$OUT/c3-increment.log")"
    [ "$C3_EVENTS" -ge 3 ] && pass "C3 натискання дійшли: $C3_EVENTS" || fail "C3 натискань не видно ($C3_EVENTS)"

    ask_choice "Коли ти тиснув +1 — кнопка відповідала МИТТЄВО, а число мінялось трохи ПІЗНІШЕ?" \
        "так: кнопка миттєво, число з невеликою затримкою" \
        "число мінялось миттєво разом з кнопкою" \
        "число взагалі не мінялось" \
        "кнопка не реагувала"

    ask_choice "Прокрути документ пальцем. Як воно?" \
        "прокручується плавно" \
        "прокручується, але ривками" \
        "не прокручується" \
        "документ порожній"

    ask_choice "У документі є рядок, який виглядає як порожні квадратики (тофу)?" \
        "так, є квадратики — це очікувано" \
        "ні, весь текст читабельний" \
        "не помітив"

    # C6 — доказ перезавантаження
    say ""
    say "  ${C_ASK}C6 — головний тест милістоуна.${C_OFF}"
    C6_BEFORE="$(count_now)"
    say "  Сервер зараз каже, що лічильник = $C6_BEFORE"
    wait_enter "ВИМКНИ І УВІМКНИ Tab5 (повне перезавантаження живленням). Сервер НЕ чіпай. Потім Enter..."
    capture 25 "$OUT/c6-reboot.log"
    C6_AFTER="$(count_now)"

    rec ""; rec "### C6 — доказ перезавантаження"; rec ""
    rec "До перезавантаження: **$C6_BEFORE** · після: **$C6_AFTER**"

    if [ -n "$C6_BEFORE" ] && [ "$C6_BEFORE" = "$C6_AFTER" ]; then
        pass "C6 лічильник пережив перезавантаження пристрою: $C6_BEFORE"
    else
        fail "C6 лічильник змінився при перезавантаженні: $C6_BEFORE -> $C6_AFTER"
    fi

    ask_choice "Яке число показує Tab5 ПІСЛЯ перезавантаження?" \
        "те саме, що й до перезавантаження" \
        "0 — скинулось" \
        "інше число" \
        "сторінка не завантажилась"
else
    skip "C — мережа недоступна, DoD не перевірявся"
    rec ""
    rec "**Мережа не піднялась.** C6-копроцесор не відповідає по SDIO:"
    rec ""
    rec "\`\`\`"
    grep -aoE "(sdmmc_init_ocr[^\"]*|ensure_slave_bus_ready failed[^\"]*|esp_wifi_init[^\"]*)" "$OUT/b1-boot.log" 2>/dev/null | sort -u | head -4 >> "$REPORT"
    rec "\`\`\`"
    rec ""
    rec "Помилок SDIO у логу: **$C6_FAIL**"
    say ""
    say "  ${C_DIM}WiFi не піднявся — блок C пропущено. Це відомий блокер:${C_OFF}"
    say "  ${C_DIM}на ESP32-C6 немає прошивки esp_hosted.${C_OFF}"
fi

# --- Підсумок ----------------------------------------------------------------
head_ "Підсумок"
rec ""; rec "## Підсумок"; rec ""
rec "| | |"; rec "|---|---|"
rec "| PASS | $PASS |"; rec "| FAIL | $FAIL |"; rec "| SKIP | $SKIP |"
rec ""
rec "### Сирі логи"; rec ""
for f in "$OUT"/*.log "$OUT"/*.txt; do
    [ -f "$f" ] && rec "- \`$(basename "$f")\` ($(wc -l < "$f" | tr -d ' ') рядків)"
done

printf '  %sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
    "$C_OK" "$PASS" "$C_OFF" "$C_BAD" "$FAIL" "$C_OFF" "$C_DIM" "$SKIP" "$C_OFF"
say ""
say "${C_HEAD}Готово.${C_OFF}"
say ""
say "  Звіт:  ${C_OK}$REPORT${C_OFF}"
say "  Логи:  $OUT"
say ""
say "  Віддай Клоду одним рядком:"
say "     ${C_ASK}проаналізуй $REPORT${C_OFF}"
say ""
