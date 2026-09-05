#!/usr/bin/env bash
# Slate M0 — test harness for the v0.1 test plan.
#
# Every command writes its evidence into tools/evidence/<timestamp>/ so a test
# run leaves a reviewable trail rather than scrollback. See
# specification/roadmap/implementation/v0.1-test-plan.md for the cases these
# support.
#
#   ./tools/m0test.sh serve            start the M0 server (foreground)
#   ./tools/m0test.sh host             the host suite: pytest + fake device
#   ./tools/m0test.sh flash            build and flash the Tab5
#   ./tools/m0test.sh monitor [secs]   capture the device log (default 30)
#   ./tools/m0test.sh ledger [file]    extract SLATE_LEDGER lines
#   ./tools/m0test.sh count            ask the server what the counter is
#   ./tools/m0test.sh reset            reset the server's counter (restart it)
#   ./tools/m0test.sh doctor           check the environment before testing

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="$REPO_ROOT/tools/evidence"
PYTHON="$REPO_ROOT/.venv/bin/python"
FIRMWARE_DIR="$REPO_ROOT/m0/firmware"
SERVER="$REPO_ROOT/m0/server/server.py"

: "${IDF_EXPORT:=$HOME/esp/esp-idf/export.sh}"
: "${SLATE_PORT:=}"
: "${SLATE_SERVER_HOST:=127.0.0.1}"
: "${SLATE_SERVER_PORT:=8000}"

log()  { printf '\033[0;36m==\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32mOK\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; }

# The Tab5's USB-Serial-JTAG. Detected rather than hard-coded, because the
# device number changes between plug-ins.
detect_port() {
    if [ -n "$SLATE_PORT" ]; then
        echo "$SLATE_PORT"
        return 0
    fi
    local found
    found="$(ls /dev 2>/dev/null | grep -E '^cu\.usbmodem' | head -1)"
    if [ -z "$found" ]; then
        return 1
    fi
    echo "/dev/$found"
}

new_evidence_dir() {
    local dir="$EVIDENCE_DIR/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dir"
    echo "$dir"
}

cmd_doctor() {
    local problems=0

    if [ -x "$PYTHON" ]; then ok "python venv"; else fail "no .venv — run: python3 -m venv .venv && .venv/bin/pip install -r codegen/requirements.txt websockets pytest pytest-asyncio"; problems=1; fi

    if [ -f "$IDF_EXPORT" ]; then ok "ESP-IDF at $IDF_EXPORT"; else fail "no ESP-IDF export.sh at $IDF_EXPORT (set IDF_EXPORT=)"; problems=1; fi

    local port
    if port="$(detect_port)"; then ok "Tab5 on $port"; else fail "no /dev/cu.usbmodem* — check the cable, and that it is in the Tab5's DATA USB-C port, not the power-only one"; problems=1; fi

    if [ -f "$FIRMWARE_DIR/sdkconfig.defaults.local" ]; then
        ok "sdkconfig.defaults.local present"
        if grep -q 'CONFIG_SLATE_WIFI_SSID=""' "$FIRMWARE_DIR/sdkconfig.defaults.local" 2>/dev/null; then
            fail "SLATE_WIFI_SSID is still empty"
            problems=1
        fi
    else
        fail "no m0/firmware/sdkconfig.defaults.local — copy sdkconfig.defaults.local.example and fill it in"
        problems=1
    fi

    if "$PYTHON" -c "import websockets" 2>/dev/null; then ok "websockets"; else fail "pip install websockets"; problems=1; fi

    return $problems
}

cmd_serve() {
    log "M0 server on 0.0.0.0:8000 — Ctrl-C to stop"
    log "the device must be able to reach this host; check the firewall if it cannot"
    exec "$PYTHON" "$SERVER"
}

cmd_host() {
    local dir; dir="$(new_evidence_dir)"
    log "host suite -> $dir/pytest.log"
    ( cd "$REPO_ROOT" && "$PYTHON" -m pytest -q ) 2>&1 | tee "$dir/pytest.log"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 0 ]; then ok "host suite green"; else fail "host suite red (rc=$rc)"; fi
    return $rc
}

cmd_flash() {
    local port; port="$(detect_port)" || { fail "no device"; return 1; }
    local dir; dir="$(new_evidence_dir)"
    log "build + flash on $port -> $dir/flash.log"
    # shellcheck disable=SC1090
    ( . "$IDF_EXPORT" >/dev/null 2>&1 && cd "$FIRMWARE_DIR" && idf.py -p "$port" flash ) \
        > "$dir/flash.log" 2>&1
    local rc=$?
    tail -5 "$dir/flash.log"
    if [ "$rc" -eq 0 ]; then ok "flashed"; else fail "flash failed — see $dir/flash.log"; fi
    return $rc
}

cmd_monitor() {
    local secs="${1:-30}"
    local port; port="$(detect_port)" || { fail "no device"; return 1; }
    local dir; dir="$(new_evidence_dir)"
    local logfile="$dir/device.log"

    log "capturing $secs s from $port -> $logfile"
    log "interact with the device now (touch, press +1, scroll the document)"

    # shellcheck disable=SC1090
    ( . "$IDF_EXPORT" >/dev/null 2>&1 && cd "$FIRMWARE_DIR" \
        && idf.py -p "$port" monitor > "$logfile" 2>&1 ) &
    local monitor_pid=$!

    local elapsed=0
    while [ "$elapsed" -lt "$secs" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
        printf '\r  %ds/%ds' "$elapsed" "$secs"
    done
    printf '\n'

    pkill -f idf_monitor 2>/dev/null
    kill "$monitor_pid" 2>/dev/null
    wait "$monitor_pid" 2>/dev/null

    ok "captured $(wc -l < "$logfile" | tr -d ' ') lines"
    echo "$logfile" > "$EVIDENCE_DIR/.last"
    cmd_ledger "$logfile"
}

cmd_ledger() {
    local logfile="${1:-}"
    if [ -z "$logfile" ] && [ -f "$EVIDENCE_DIR/.last" ]; then
        logfile="$(cat "$EVIDENCE_DIR/.last")"
    fi
    if [ ! -f "$logfile" ]; then
        fail "no log file — run 'monitor' first, or pass a path"
        return 1
    fi

    log "ledger lines from $logfile"
    # Strip ANSI colour so the ledger is greppable and pasteable.
    sed 's/\x1b\[[0-9;]*m//g' "$logfile" \
        | grep -aoE 'SLATE_LEDGER .*' | sort -u | tee "${logfile%.log}-ledger.txt"

    echo
    log "touch events: $(grep -ac 'touch x=' "$logfile" 2>/dev/null || echo 0)"
    log "errors:"
    sed 's/\x1b\[[0-9;]*m//g' "$logfile" | grep -aE '^E \(' | sort -u | head -10
}

cmd_count() {
    "$PYTHON" - "$SLATE_SERVER_HOST" "$SLATE_SERVER_PORT" <<'PY'
import asyncio, json, sys
sys.path.insert(0, "tools")
from fake_device import FakeDevice

host, port = sys.argv[1], sys.argv[2]

async def main():
    async with FakeDevice(f"ws://{host}:{port}/ws") as device:
        req = await device.subscribe("/apps/m0", ["count", "clock"])
        frame = await device.recv_data(req)
        for update in frame["updates"]:
            print(f"{update['id']}: {update.get('text')}")

asyncio.run(main())
PY
}

cmd_reset() {
    log "the counter lives in the server process, so restarting it resets the count"
    log "stop 'm0test.sh serve' and start it again"
}

case "${1:-}" in
    doctor)  shift; cmd_doctor "$@" ;;
    serve)   shift; cmd_serve "$@" ;;
    host)    shift; cmd_host "$@" ;;
    flash)   shift; cmd_flash "$@" ;;
    monitor) shift; cmd_monitor "$@" ;;
    ledger)  shift; cmd_ledger "$@" ;;
    count)   shift; cmd_count "$@" ;;
    reset)   shift; cmd_reset "$@" ;;
    *)
        sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
