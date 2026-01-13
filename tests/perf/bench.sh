#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"

BUILD_DIR="${BUILD_DIR:-build}"
CONF_PATH="${CONF_PATH:-$ROOT_DIR/zaver.conf}"

THREADS="${THREADS:-4}"
CONNS="${CONNS:-500}"
DURATION="${DURATION:-30s}"
WARMUP="${WARMUP:-3s}"

# Repeat each measured case N times and report mean values.
RUNS="${RUNS:-1}"
PAUSE_BETWEEN_RUNS="${PAUSE_BETWEEN_RUNS:-1}"

# wrk defaults can be too aggressive for slow endpoints like CGI; expose timeout.
WRK_TIMEOUT="${WRK_TIMEOUT:-10s}"

# Benchmark modes:
# - suite: run core cases (static small, static big, CGI, 404)
# - scan_conns: scan CONN_LIST for static small
# - scan_threads: scan THREAD_LIST for static small
# - scale_workers: scan WORKER_LIST, restarting server each time, for static small
# - full: suite + scan_conns + scan_threads + scale_workers
MODE="${MODE:-full}"
CONN_LIST="${CONN_LIST:-50 100 200 500 1000}"
WORKER_LIST="${WORKER_LIST:-1 2 4}"
THREAD_LIST="${THREAD_LIST:-1 2 4 8}"

BIG_FILE_MB="${BIG_FILE_MB:-256}"
BIG_FILE_PATH_REL="${BIG_FILE_PATH_REL:-big.bin}"

LOG_FILE="${ROOT_DIR}/tests/perf/bench.server.log"
OUT_MD="${OUT_MD:-$ROOT_DIR/tests/perf/results.md}"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: missing dependency: $1" >&2
        exit 1
    fi
}

need_cmd curl
need_cmd awk
need_cmd grep
need_cmd sed
need_cmd tr
need_cmd date
need_cmd ss
need_cmd setsid
need_cmd wrk

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
    echo "Error: RUNS must be a positive integer, got: $RUNS" >&2
    exit 1
fi

PORT=3000
if [[ -f "$CONF_PATH" ]]; then
    P=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$CONF_PATH" | tail -n 1 | cut -d= -f2 | tr -d ' \t\r')
    if [[ -n "${P:-}" ]]; then
        PORT="$P"
    fi
fi

WORKERS_CONF=""
if [[ -f "$CONF_PATH" ]]; then
    W=$(grep -E '^[[:space:]]*workers[[:space:]]*=' "$CONF_PATH" | tail -n 1 | cut -d= -f2 | tr -d ' \t\r')
    if [[ -n "${W:-}" ]]; then
        WORKERS_CONF="$W"
    fi
fi

BIN_PATH=""
if [[ -f "./${BUILD_DIR}/zaver" ]]; then
    BIN_PATH="./${BUILD_DIR}/zaver"
elif [[ -f "./${BUILD_DIR}/src/zaver" ]]; then
    BIN_PATH="./${BUILD_DIR}/src/zaver"
else
    echo "Error: Could not find 'zaver' under BUILD_DIR=${BUILD_DIR}" >&2
    echo "Hint: build with: cmake -S . -B build && cmake --build build" >&2
    exit 1
fi

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill -TERM -- "-${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

stop_server() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill -TERM -- "-${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
        SERVER_PID=""
    fi
}

ensure_port_free() {
    local line
    line=$(ss -ltnp 2>/dev/null | grep -E "LISTEN\\s+.*[:.]${PORT}\\b" || true)
    if [[ -z "$line" ]]; then
        return 0
    fi

    if echo "$line" | grep -q "\"zaver\""; then
        echo "Port $PORT already has zaver; killing it for a clean benchmark run." >&2
        local pids
        pids=$(echo "$line" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' ')
        if [[ -n "${pids:-}" ]]; then
            kill -KILL $pids 2>/dev/null || true
            for _ in $(seq 1 50); do
                if ! ss -ltnp 2>/dev/null | grep -E "LISTEN\\s+.*[:.]${PORT}\\b" | grep -q "\"zaver\""; then
                    return 0
                fi
                sleep 0.1
            done
        fi
        return 0
    fi

    echo "Error: port $PORT is already in use by another process:" >&2
    echo "$line" >&2
    exit 1
}

wait_ready() {
    local url="$1"
    local ready=0
    for _ in $(seq 1 80); do
        local code
        code=$(curl --max-time 1 -o /dev/null -s -w "%{http_code}" "$url" || true)
        if [[ "$code" != "000" ]]; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "Server did not become ready." >&2
        tail -n 200 "$LOG_FILE" || true
        exit 1
    fi
}

ensure_big_file() {
    local path="$ROOT_DIR/html/${BIG_FILE_PATH_REL}"
    if [[ -f "$path" ]]; then
        return 0
    fi
    echo "Creating big file: $path (${BIG_FILE_MB} MiB)" >&2
    dd if=/dev/zero of="$path" bs=1M count="$BIG_FILE_MB" status=none
}

make_conf_with_workers() {
    local workers="$1"
    local out_path="$2"

    if [[ ! -f "$CONF_PATH" ]]; then
        echo "Error: CONF_PATH not found: $CONF_PATH" >&2
        exit 1
    fi

    if grep -Eq '^[[:space:]]*workers[[:space:]]*=' "$CONF_PATH"; then
        sed -E "s/^[[:space:]]*workers[[:space:]]*=.*/workers=${workers}/" "$CONF_PATH" >"$out_path"
    else
        cat "$CONF_PATH" >"$out_path"
        echo "workers=${workers}" >>"$out_path"
    fi
}

start_server() {
    local conf="$1"
    ensure_port_free
    rm -f "$LOG_FILE"
    setsid "$BIN_PATH" -c "$conf" >"$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    wait_ready "http://127.0.0.1:${PORT}/index.html"
}

run_wrk_case() {
    local name="$1"
    local url="$2"

    # Warmup
    wrk --latency --timeout "$WRK_TIMEOUT" -t"$THREADS" -c"$CONNS" -d"$WARMUP" "$url" >/dev/null 2>&1 || true

    # Helpers: parse and normalize wrk units for aggregation.
    to_ms() {
        local v="$1"
        awk -v t="$v" 'BEGIN {
            if (t=="" || t=="N/A") { print ""; exit }
            if (t ~ /us$/) { sub(/us$/, "", t); printf "%.6f", t/1000; exit }
            if (t ~ /ms$/) { sub(/ms$/, "", t); printf "%.6f", t; exit }
            if (t ~ /s$/)  { sub(/s$/,  "", t); printf "%.6f", t*1000; exit }
            printf "";
        }'
    }

    to_mib_per_sec() {
        local v="$1"
        awk -v t="$v" 'BEGIN {
            if (t=="" || t=="N/A") { print ""; exit }
            if (t ~ /KB$/) { sub(/KB$/, "", t); printf "%.6f", t/1024; exit }
            if (t ~ /MB$/) { sub(/MB$/, "", t); printf "%.6f", t; exit }
            if (t ~ /GB$/) { sub(/GB$/, "", t); printf "%.6f", t*1024; exit }
            if (t ~ /B$/)  { sub(/B$/,  "", t); printf "%.6f", t/1024/1024; exit }
            printf "";
        }'
    }

    mean_of() {
        awk '{s+=$1; n+=1} END { if(n==0) print ""; else printf "%.6f", s/n }'
    }

    fmt_ms() {
        local v="$1"
        awk -v x="$v" 'BEGIN { if (x=="" || x=="N/A") print "N/A"; else printf "%.3fms", x }'
    }

    fmt_mibps() {
        local v="$1"
        awk -v x="$v" 'BEGIN { if (x=="" || x=="N/A") print "N/A"; else printf "%.2fMB", x }'
    }

    local rps_list=""
    local lat_avg_ms_list=""
    local lat_stdev_ms_list=""
    local lat_max_ms_list=""
    local p50_ms_list=""
    local p90_ms_list=""
    local p99_ms_list=""
    local xfer_mibps_list=""
    local non2xx_sum=0
    local sockerr_text=""

    for run_i in $(seq 1 "$RUNS"); do
        local out
        out=$(wrk --latency --timeout "$WRK_TIMEOUT" -t"$THREADS" -c"$CONNS" -d"$DURATION" "$url" 2>/dev/null || true)

        local rps
        local latency_avg
        local latency_stdev
        local latency_max
        local transfer
        local non2xx
        local socket_errors

        rps=$(echo "$out" | awk '/Requests\/sec/ {print $2; exit}')
        latency_avg=$(echo "$out" | awk '/Latency/ {print $2; exit}')
        latency_stdev=$(echo "$out" | awk '/Latency/ {print $3; exit}')
        latency_max=$(echo "$out" | awk '/Latency/ {print $4; exit}')
        transfer=$(echo "$out" | awk '/Transfer\/sec/ {print $2; exit}')

        local p50
        local p90
        local p99
        p50=$(echo "$out" | awk 'BEGIN{f=0} /Latency Distribution/ {f=1; next} f && $1=="50%" {print $2; exit}')
        p90=$(echo "$out" | awk 'BEGIN{f=0} /Latency Distribution/ {f=1; next} f && $1=="90%" {print $2; exit}')
        p99=$(echo "$out" | awk 'BEGIN{f=0} /Latency Distribution/ {f=1; next} f && $1=="99%" {print $2; exit}')

        non2xx=$(echo "$out" | awk -F': ' '/Non-2xx or 3xx responses/ {print $2; exit}')
        socket_errors=$(echo "$out" | awk -F': ' '/Socket errors/ {print $2; exit}')

        if [[ -n "${non2xx:-}" ]]; then
            non2xx_sum=$((non2xx_sum + non2xx))
        fi
        if [[ -n "${socket_errors:-}" ]]; then
            sockerr_text="$socket_errors"
        fi

        rps_list+="$(echo "${rps:-0}" | awk '{printf "%.6f", $1}')\n"
        lat_avg_ms_list+="$(to_ms "${latency_avg:-N/A}")\n"
        lat_stdev_ms_list+="$(to_ms "${latency_stdev:-N/A}")\n"
        lat_max_ms_list+="$(to_ms "${latency_max:-N/A}")\n"
        p50_ms_list+="$(to_ms "${p50:-N/A}")\n"
        p90_ms_list+="$(to_ms "${p90:-N/A}")\n"
        p99_ms_list+="$(to_ms "${p99:-N/A}")\n"
        xfer_mibps_list+="$(to_mib_per_sec "${transfer:-N/A}")\n"

        if [[ "$run_i" -lt "$RUNS" ]]; then
            sleep "$PAUSE_BETWEEN_RUNS"
        fi
    done

    local rps_mean
    local lat_avg_ms_mean
    local lat_stdev_ms_mean
    local lat_max_ms_mean
    local p50_ms_mean
    local p90_ms_mean
    local p99_ms_mean
    local xfer_mibps_mean

    rps_mean=$(echo -e "$rps_list" | awk 'NF{print}' | mean_of)
    lat_avg_ms_mean=$(echo -e "$lat_avg_ms_list" | awk 'NF{print}' | mean_of)
    lat_stdev_ms_mean=$(echo -e "$lat_stdev_ms_list" | awk 'NF{print}' | mean_of)
    lat_max_ms_mean=$(echo -e "$lat_max_ms_list" | awk 'NF{print}' | mean_of)
    p50_ms_mean=$(echo -e "$p50_ms_list" | awk 'NF{print}' | mean_of)
    p90_ms_mean=$(echo -e "$p90_ms_list" | awk 'NF{print}' | mean_of)
    p99_ms_mean=$(echo -e "$p99_ms_list" | awk 'NF{print}' | mean_of)
    xfer_mibps_mean=$(echo -e "$xfer_mibps_list" | awk 'NF{print}' | mean_of)

    LAST_RPS_MEAN="$rps_mean"
    LAST_P99_MS_MEAN="$p99_ms_mean"
    LAST_XFER_MIBPS_MEAN="$xfer_mibps_mean"

    local notes=""
    if [[ "$non2xx_sum" -ne 0 ]]; then
        notes="non2xx_sum=${non2xx_sum}"
    fi
    if [[ -n "${sockerr_text:-}" ]]; then
        if [[ -n "$notes" ]]; then
            notes+="; "
        fi
        notes+="sockerr(${sockerr_text})"
    fi
    if [[ -z "$notes" ]]; then
        notes="-"
    fi

    echo "| ${name} | ${url} | ${WORKERS_LABEL:-${WORKERS_CONF:-N/A}} | ${THREADS} | ${CONNS} | ${DURATION} | ${RUNS} | ${rps_mean:-N/A} | $(fmt_ms "$lat_avg_ms_mean") | $(fmt_ms "$lat_stdev_ms_mean") | $(fmt_ms "$lat_max_ms_mean") | $(fmt_ms "$p50_ms_mean") | $(fmt_ms "$p90_ms_mean") | $(fmt_ms "$p99_ms_mean") | $(fmt_mibps "$xfer_mibps_mean") | ${non2xx_sum} | ${sockerr_text:-0} | ${notes} |"
}

run_wrk_case_with_conns() {
    local name="$1"
    local url="$2"
    local conns="$3"

    local old_conns="$CONNS"
    CONNS="$conns"
    run_wrk_case "$name" "$url"
    CONNS="$old_conns"
}

main() {
    ensure_big_file
    BASE_URL="http://127.0.0.1:${PORT}"

    local ts
    ts=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    {
        echo "# Zaver Performance Results"
        echo
        echo "- Time: ${ts}"
        echo "- Binary: ${BIN_PATH}"
        echo "- Config: ${CONF_PATH}"
        echo "- Mode: ${MODE}"
        echo "- Threads: ${THREADS}"
        echo "- Base Conns: ${CONNS}"
        echo "- Duration: ${DURATION} (warmup ${WARMUP})"
        echo "- Runs per case: ${RUNS}"
        echo "- wrk timeout: ${WRK_TIMEOUT}"
        if [[ -n "${WORKERS_CONF:-}" ]]; then
            echo "- workers (from conf): ${WORKERS_CONF}"
        fi
        echo
        echo "| Case | URL | Workers | Threads | Conns | Duration | Runs | Requests/sec(mean) | Lat(avg) | Lat(stdev) | Lat(max) | p50 | p90 | p99 | Transfer/sec(mean) | Non2xx(sum) | Sockerr | Notes |"
        echo "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|"

        if [[ "$MODE" == "suite" || "$MODE" == "full" ]]; then
            declare -A SUITE_RPS
            declare -A SUITE_P99_MS

            WORKERS_LABEL="${WORKERS_CONF:-N/A}"
            start_server "$CONF_PATH"
            run_wrk_case "Static small" "${BASE_URL}/index.html"
            SUITE_RPS["Static small"]="${LAST_RPS_MEAN:-}"
            SUITE_P99_MS["Static small"]="${LAST_P99_MS_MEAN:-}"

            run_wrk_case "Static big (${BIG_FILE_MB}MiB)" "${BASE_URL}/${BIG_FILE_PATH_REL}"
            SUITE_RPS["Static big"]="${LAST_RPS_MEAN:-}"
            SUITE_P99_MS["Static big"]="${LAST_P99_MS_MEAN:-}"

            run_wrk_case "CGI" "${BASE_URL}/cgi-bin/hello.sh"
            SUITE_RPS["CGI"]="${LAST_RPS_MEAN:-}"
            SUITE_P99_MS["CGI"]="${LAST_P99_MS_MEAN:-}"

            run_wrk_case "404" "${BASE_URL}/no-such-file"
            SUITE_RPS["404"]="${LAST_RPS_MEAN:-}"
            SUITE_P99_MS["404"]="${LAST_P99_MS_MEAN:-}"
            stop_server
            echo

            local base_rps base_p99
            base_rps="${SUITE_RPS["Static small"]:-}"
            base_p99="${SUITE_P99_MS["Static small"]:-}"
            if [[ -n "${base_rps:-}" ]]; then
                echo "## Relative Comparison (vs Static small)"
                echo
                echo "| Case | RPS x | p99 x |"
                echo "|---|---:|---:|"
                for k in "Static small" "Static big" "CGI" "404"; do
                    local rps_k p99_k
                    rps_k="${SUITE_RPS[$k]:-}"
                    p99_k="${SUITE_P99_MS[$k]:-}"

                    local rps_ratio p99_ratio
                    rps_ratio=$(awk -v a="$rps_k" -v b="$base_rps" 'BEGIN { if(a==""||b==""||b==0) print "N/A"; else printf "%.3f", a/b }')
                    p99_ratio=$(awk -v a="$p99_k" -v b="$base_p99" 'BEGIN { if(a==""||b==""||b==0) print "N/A"; else printf "%.3f", a/b }')
                    echo "| ${k} | ${rps_ratio} | ${p99_ratio} |"
                done
                echo
            fi
        fi

        if [[ "$MODE" == "scan_conns" || "$MODE" == "full" ]]; then
            WORKERS_LABEL="${WORKERS_CONF:-N/A}"
            start_server "$CONF_PATH"
            echo "| Conns scan (static small) |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |"
            for c in $CONN_LIST; do
                run_wrk_case_with_conns "Static small" "${BASE_URL}/index.html" "$c"
            done
            stop_server
            echo
        fi

        if [[ "$MODE" == "scan_threads" || "$MODE" == "full" ]]; then
            local old_threads="$THREADS"
            WORKERS_LABEL="${WORKERS_CONF:-N/A}"
            start_server "$CONF_PATH"
            echo "| Threads scan (static small) |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |"
            for t in $THREAD_LIST; do
                THREADS="$t"
                run_wrk_case "Static small" "${BASE_URL}/index.html"
            done
            THREADS="$old_threads"
            stop_server
            echo
        fi

        if [[ "$MODE" == "scale_workers" || "$MODE" == "full" ]]; then
            echo "| Workers scale (static small) |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |"
            local tmp_conf
            tmp_conf="${ROOT_DIR}/tests/perf/_tmp_zaver.conf"
            for w in $WORKER_LIST; do
                make_conf_with_workers "$w" "$tmp_conf"
                WORKERS_LABEL="$w"
                start_server "$tmp_conf"
                run_wrk_case "Static small" "${BASE_URL}/index.html"
                stop_server
            done
            rm -f "$tmp_conf" || true
            echo
        fi

        echo
        echo "> Notes"
        echo "> - This benchmark assumes a single zaver instance owns the port (SO_REUSEPORT allows multiple instances)."
        echo "> - For stable results, run on an idle machine and set RUNS=3 (or higher)." 
    } | tee "$OUT_MD"

    echo
    echo "Saved: $OUT_MD" >&2
}

main "$@"
