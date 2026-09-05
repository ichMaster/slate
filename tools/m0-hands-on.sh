#!/usr/bin/env bash
# Slate M0 — те, що може підтвердити тільки людина.
#
# Тут НЕМАЄ жодної перевірки, яку машина здатна зробити сама: збірка, прошивка,
# pytest, розбір логів, підрахунок завантажень — усе це в tools/m0-auto.sh і
# запускається без тебе. Лишилось рівно те, для чого потрібні очі й пальці:
# подивитись на екран, торкнутись його, оцінити відчуття, вимкнути живлення.
#
#   ./tools/m0-hands-on.sh
#
# Пристрій має бути вже прошитий (це робить m0-auto.sh). Тривалість ~2 хв.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO_ROOT/tools/evidence/hands-on-$RUN_ID"
mkdir -p "$OUT"
REPORT="$OUT/report.md"
PYTHON="$REPO_ROOT/.venv/bin/python"
FIRMWARE_DIR="$REPO_ROOT/m0/firmware"
: "${IDF_EXPORT:=$HOME/esp/esp-idf/export.sh}"

ASKED=0
NETWORK=0

C_HEAD=$'\033[1;36m'; C_ASK=$'\033[1;33m'; C_DIM=$'\033[0;90m'; C_BAD=$'\033[0;31m'; C_OFF=$'\033[0m'
say()   { printf '%s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$C_HEAD" "$*" "$C_OFF"; }
note()  { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
rec()   { printf '%s\n' "$*" >> "$REPORT"; }

cleanup() { pkill -f idf_monitor 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM

# Термінал відкриваємо один раз: `[ -r /dev/tty ]` буває істинним навіть коли
# читання падає з "Device not configured". Обгортка в групу обов'язкова, інакше
# перенаправлення stderr стало б постійним для всього скрипта.
if { exec 3</dev/tty; } 2>/dev/null; then HAVE_TTY=1; else HAVE_TTY=0; fi
read_tty() {
    if [ "$HAVE_TTY" = "1" ]; then read -r "$1" <&3; else read -r "$1"; fi
}

ask() {
    local question="$1"; shift
    local options=("$@")
    ASKED=$((ASKED+1))
    printf '\n%s? %s%s\n' "$C_ASK" "$question" "$C_OFF"
    local i=1
    for o in "${options[@]}"; do printf '    %d) %s\n' "$i" "$o"; i=$((i+1)); done
    printf '    0) інше — впишу словами\n'

    local a="" tries=0
    while true; do
        tries=$((tries+1))
        if [ "$tries" -gt 5 ]; then
            rec ""; rec "**Q$ASKED.** $question"; rec ""; rec "> _(без відповіді)_"
            ANSWER="NO_INPUT"; return 0
        fi
        printf '  > '
        read_tty a || a=""
        if [ "$a" = "0" ]; then
            printf '  опиши: '; local free=""; read_tty free || free=""
            rec ""; rec "**Q$ASKED.** $question"; rec ""; rec "> **$free**  _(вільна відповідь)_"
            ANSWER="$free"; return 0
        fi
        if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#options[@]}" ]; then
            rec ""; rec "**Q$ASKED.** $question"; rec ""; rec "> **${options[$((a-1))]}**"
            ANSWER="${options[$((a-1))]}"; return 0
        fi
        printf '  %sчисло, будь ласка%s\n' "$C_BAD" "$C_OFF"
    done
}

step() { printf '\n%s>> %s%s' "$C_ASK" "$1" "$C_OFF"; read_tty _x; }

detect_port() {
    local f; f="$(ls /dev 2>/dev/null | grep -E '^cu\.usbmodem' | head -1)"
    [ -z "$f" ] && return 1
    echo "/dev/$f"
}

# Пише лог, поки ти щось робиш руками. Єдина причина, чому запис узагалі тут:
# він має збігтися в часі з твоїми дотиками.
#
# --no-reset обов'язковий. Без нього приєднання монітора перезавантажує пристрій
# рівно в ту мить, коли скрипт каже починати тикати — це виглядає як падіння від
# дотику, з'їдає перші секунди запису на завантаження, і зробило б доказ
# перезавантаження нечитабельним, бо незрозуміло, хто саме перезавантажив.
capture() {
    local secs="$1" outfile="$2" port
    port="$(detect_port)" || return 1
    # shellcheck disable=SC1090
    ( . "$IDF_EXPORT" >/dev/null 2>&1 && cd "$FIRMWARE_DIR" \
        && idf.py -p "$port" monitor --no-reset > "$outfile" 2>&1 ) &
    local pid=$! i=0
    while [ "$i" -lt "$secs" ]; do sleep 1; i=$((i+1)); printf '\r%s   пишу лог %ds/%ds%s' "$C_DIM" "$i" "$secs" "$C_OFF"; done
    printf '\r%s   готово (%ds)          %s\n' "$C_DIM" "$secs" "$C_OFF"
    pkill -f idf_monitor 2>/dev/null
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    sed -i '' 's/\x1b\[[0-9;]*m//g' "$outfile" 2>/dev/null
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

# =============================================================================
rec "# Slate M0 — підтвердження людиною"
rec ""
rec "**Запущено:** $(date '+%Y-%m-%d %H:%M:%S') · **Комміт:** \`$(git rev-parse --short HEAD 2>/dev/null)\`"
rec ""
rec "> Тільки те, що не перевіряється машиною. Решта — у звіті \`m0-auto.sh\`."

say ""
say "${C_HEAD}Slate M0 — те, що можеш підтвердити тільки ти${C_OFF}"
note "Пристрій має бути прошитий. Дивись на екран Tab5."
note "Перервати — Ctrl-C. Питань: 4 без мережі, ще 6 якщо мережа є."

if ! detect_port >/dev/null; then
    say ""
    say "${C_BAD}Tab5 не видно на USB. Перевір кабель — на Tab5 один порт лише живить.${C_OFF}"
    exit 1
fi

# Чи є мережа — вирішує лог, не людина.
say ""
note "Дивлюсь, чи піднялась мережа (25с)..."
capture 25 "$OUT/boot.log"
if grep -aq "wifi_ip=" "$OUT/boot.log" 2>/dev/null; then
    NETWORK=1
    note "Мережа є — буде повний набір питань."
else
    note "Мережі немає — питання про сторінку/кнопку/документ пропущу."
fi
rec ""
rec "Мережа на момент запуску: **$([ "$NETWORK" = 1 ] && echo "є" || echo "немає")**"

# ------------------------------------------------------------------ ЕКРАН ----
head_ "1. Екран"

ask "Що зараз на екрані Tab5?" \
    "сірий фон, чорний текст 'server unreachable' по центру" \
    "сірий фон, чорний текст 'connecting…' по центру" \
    "сторінка: заголовок, велике число, кнопка +1, годинник, білa панель" \
    "чорний / нічого не видно" \
    "блимає або перезавантажується" \
    "щось є, але виглядає поламано"

ask "Екран виглядає НАВМИСНО грубим — сірий фон, системний шрифт, без рамок, тіней і заокруглень?" \
    "так, як неоформлений демо-тулкіт — саме так і має бути" \
    "ні, виглядає надто оформлено" \
    "не можу оцінити"

# -------------------------------------------------------------------- ТАЧ ----
head_ "2. Тач"
note "Зараз 15 секунд писатиму лог, поки ти тикаєш."
step "Готовий? Enter — і одразу тикай у РІЗНІ місця екрана..."
say ""
say "  ${C_ASK}ТИКАЙ ЗАРАЗ${C_OFF} — кути і центр"
say ""
capture 15 "$OUT/touch.log"

TOUCHES="$(grep -aEc "touch x=" "$OUT/touch.log" 2>/dev/null)"; [ -z "$TOUCHES" ] && TOUCHES=0
grep -aoE "touch x=[0-9-]+ y=[0-9-]+" "$OUT/touch.log" 2>/dev/null | head -10 > "$OUT/coords.txt"
rec ""; rec "### Тач"; rec ""; rec "Подій зафіксовано: **$TOUCHES**"; rec ""; rec '```'
cat "$OUT/coords.txt" >> "$REPORT" 2>/dev/null
rec '```'
note "зафіксовано подій: $TOUCHES"

# Про візуальну реакцію не питаємо: на екрані з простим написом її за задумом і
# немає, тож відповідь "жодної реакції" правдива й нічого не означає. Питаємо
# лише те, чого немає в лозі — чи ти справді торкався. Це відрізняє "тач
# зламаний" від "ніхто не тикав", а вердикт виносить лічильник подій.
ask "Ти справді торкався екрана протягом цих 15 секунд?" \
    "так, тикав кілька разів у різні місця" \
    "торкнувся один-два рази" \
    "ні, не встиг / пропустив"
TOUCHED="$ANSWER"

case "$TOUCHED" in
    "ні"*)
        rec ""; rec "> Вердикт: **не перевірено** — записів немає, бо не торкались."
        note "тач не перевірено — не торкались" ;;
    *)
        if [ "$TOUCHES" -ge 3 ]; then
            rec ""; rec "> Вердикт: **PASS** — торкання зафіксовані ($TOUCHES подій)."
            note "тач працює"
        else
            rec ""; rec "> Вердикт: **FAIL** — торкались, але прошивка зафіксувала лише $TOUCHES подій."
            note "ТАЧ НЕ ПРАЦЮЄ: торкались, а подій $TOUCHES"
        fi ;;
esac

# ------------------------------------------------------------------ МЕРЕЖА ---
if [ "$NETWORK" = "1" ]; then
    head_ "3. Сторінка від сервера"

    ask "Годинник на екрані рухається щосекунди?" "так, тікає" "ні, стоїть" "не бачу годинника"

    step "Натисни кнопку +1 на екрані 5 разів, потім Enter..."
    capture 12 "$OUT/increment.log"

    ask "Коли тиснув +1 — кнопка відповіла МИТТЄВО, а число змінилось трохи ПІЗНІШЕ?" \
        "так: кнопка миттєво, число з невеликою затримкою" \
        "число мінялось миттєво разом з кнопкою" \
        "число взагалі не мінялось" \
        "кнопка не реагувала"

    ask "Прокрути документ пальцем. Як воно?" \
        "плавно" "ривками" "не прокручується" "документ порожній"

    ask "У документі є рядок, який виглядає як порожні квадратики?" \
        "так, є квадратики" "ні, весь текст читабельний" "не помітив"

    head_ "4. Доказ перезавантаження — головне"
    BEFORE="$(count_now)"
    say ""
    note "Сервер каже, що лічильник зараз = ${BEFORE:-?}"
    rec ""; rec "### Доказ перезавантаження"; rec ""; rec "До: **${BEFORE:-?}**"
    step "ВИМКНИ І УВІМКНИ Tab5 (повністю, живленням). Сервер не чіпай. Потім Enter..."
    capture 25 "$OUT/reboot.log"
    AFTER="$(count_now)"
    rec "Після: **${AFTER:-?}**"
    note "після перезавантаження сервер каже = ${AFTER:-?}"

    ask "Яке число показує Tab5 ПІСЛЯ перезавантаження?" \
        "те саме, що й до перезавантаження" \
        "0 — скинулось" \
        "інше число" \
        "сторінка не завантажилась"
else
    rec ""
    rec "### Мережеві питання пропущено"
    rec ""
    rec "WiFi не піднявся, тому сторінка, кнопка, документ і доказ перезавантаження не перевірялись."
fi

# ---------------------------------------------------------------- ПІДСУМОК ---
rec ""; rec "### Логи"; rec ""
for f in "$OUT"/*.log "$OUT"/*.txt; do
    [ -f "$f" ] && rec "- \`$(basename "$f")\` ($(wc -l < "$f" | tr -d ' ') рядків)"
done

head_ "Готово"
say "  відповідей: $ASKED"
say "  звіт: $REPORT"
say ""
say "  Віддай Клоду:"
say "     ${C_ASK}проаналізуй $REPORT${C_OFF}"
say ""
