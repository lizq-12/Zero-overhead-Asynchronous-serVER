#!/usr/bin/env bash
set -uo pipefail

# === 0. 配置区域 ===
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="${ROOT_DIR}/build"
CONF_PATH="${ROOT_DIR}/zaver.conf"
OUT_MD="${ROOT_DIR}/tests/perf/ultimate_report.md"
RAW_LOG="${ROOT_DIR}/tests/perf/wrk_raw.log"
SERVER_LOG="${ROOT_DIR}/tests/perf/server.log"

# 测试目标
URL_SMALL="http://127.0.0.1:3000/index.html"
URL_BIG="http://127.0.0.1:3000/big.bin"
URL_CGI="http://127.0.0.1:3000/cgi-bin/hello.sh"

# 准备测试文件
if [ ! -f "${ROOT_DIR}/html/big.bin" ]; then
    echo "Creating 256MB dummy file..."
    dd if=/dev/zero of="${ROOT_DIR}/html/big.bin" bs=1M count=256 status=none
fi

# 检查依赖
for cmd in wrk curl pidstat ss awk grep; do
    if ! command -v $cmd &> /dev/null; then echo "Error: $cmd missing."; exit 1; fi
done

# === 1. 辅助函数 ===

start_server() {
    # 尝试设置 ulimit
    ulimit -n 65535 2>/dev/null || true
    
    # 找可执行文件
    if [[ -f "${BUILD_DIR}/zaver" ]]; then BIN="${BUILD_DIR}/zaver"; else BIN="${BUILD_DIR}/src/zaver"; fi
    
    echo "Starting server from $BIN ..."
    
    # 启动服务器 (关键修改：使用 disown 让脚本不再追踪这个后台进程)
    "$BIN" -c "$CONF_PATH" >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    # 【关键修复】告诉 shell 不要等待这个 PID
    disown $SERVER_PID 
    
    echo "Server PID: $SERVER_PID"
    sleep 2
    
    # 检查服务器是否真的活着
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "Error: Server failed to start! Check log at $SERVER_LOG"
        cat "$SERVER_LOG"
        exit 1
    fi
}

stop_server() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill -9 "$SERVER_PID" 2>/dev/null || true
    fi
}
# 注意：因为 disown 了，trap 可能抓不到，所以要在脚本退出前手动调用 stop_server

run_test() {
    local name="$1"
    local url="$2"
    local threads="$3"
    local conns="$4"
    local duration="$5"
    local extra_args="${6:-}"

    echo "Running: $name (Conns: $conns)..." >&2
    
    # 启动资源监控 (后台运行)
    # 我们把监控进程的 PID 记下来，专门只等它
    local pidstat_pid=""
    if [[ -n "$SERVER_PID" ]]; then
        # 监控 5 秒
        (sleep 2; pidstat -u -r -p "$SERVER_PID" 1 5 | awk '
            /Average/ && $8 ~ /[0-9]/ {cpu=$8} 
            /Average/ && $13 ~ /[0-9]/ {mem=$13} 
            END {print cpu, mem}' > /tmp/perf_stats) &
        pidstat_pid=$!
    fi

    # 运行 wrk (同步运行，不会卡住)
    local output
    output=$(wrk -t"$threads" -c"$conns" -d"$duration" --latency $extra_args "$url")
    echo "$output" >> "$RAW_LOG"
    
    # 【关键修复】只等待资源监控结束，而不是 wait 所有
    if [[ -n "$pidstat_pid" ]]; then
        wait "$pidstat_pid" 2>/dev/null || true
    fi

    # 解析数据
    local qps=$(echo "$output" | awk '/Requests\/sec/ {print $2}')
    local tput=$(echo "$output" | awk '/Transfer\/sec/ {print $2}')
    local lat_p99=$(echo "$output" | grep "99%" | awk '{print $2}')
    local lat_avg=$(echo "$output" | awk '/Latency/ && /ms|us|s/ {print $2; exit}')
    
    # 读取监控数据
    local cpu_usage="N/A"
    local mem_usage="N/A"
    if [ -f /tmp/perf_stats ]; then
        read cpu_usage mem_usage < /tmp/perf_stats || true
    fi

    # 输出结果
    echo "| $name | **$qps** | $tput | $lat_avg | **$lat_p99** | ${cpu_usage}% | ${mem_usage}MB |"
}

# === 2. 主流程 ===

# 确保清理旧进程
pkill -f "zaver" || true

echo "" > "$RAW_LOG"
start_server

# 注册退出时的清理
trap stop_server EXIT

# 生成报告头
echo "# Zaver Ultimate Benchmark Report" > "$OUT_MD"
echo "Date: $(date)" >> "$OUT_MD"
echo "| Scenario | QPS | Throughput | Latency (Avg) | P99 | CPU% | Mem |" >> "$OUT_MD"
echo "|---|---|---|---|---|---|---|" >> "$OUT_MD"

# 开始测试
run_test "Baseline (Small)" "$URL_SMALL" 4 500 20s
run_test "Throughput (Big)" "$URL_BIG" 4 100 20s
run_test "C10K Scalability" "$URL_SMALL" 4 5000 20s
run_test "Short Connection" "$URL_SMALL" 4 500 20s "-H Connection:close"
run_test "CGI Dynamic" "$URL_CGI" 4 50 20s

echo "" >> "$OUT_MD"
echo "Done! Report: $OUT_MD"
cat "$OUT_MD"