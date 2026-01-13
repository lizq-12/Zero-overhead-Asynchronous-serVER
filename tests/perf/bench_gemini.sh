#!/usr/bin/env bash
set -euo pipefail

# === 配置区域 ===
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="${ROOT_DIR}/build"
CONF_PATH="${ROOT_DIR}/zaver.conf"
LOG_FILE="${ROOT_DIR}/tests/perf/server.log"
OUT_MD="${ROOT_DIR}/tests/perf/final_report.md"

# 准备测试文件
SMALL_FILE_URL="http://127.0.0.1:3000/index.html"
BIG_FILE_URL="http://127.0.0.1:3000/big.bin"
CGI_URL="http://127.0.0.1:3000/cgi-bin/hello.sh"

# 确保依赖存在
for cmd in wrk curl pidstat ss; do
    if ! command -v $cmd &> /dev/null; then echo "Error: $cmd not found. Install it first."; exit 1; fi
done

# === 辅助函数 ===

# 启动服务器
start_server() {
    echo "Starting Server..."
    # 查找可执行文件
    if [[ -f "${BUILD_DIR}/zaver" ]]; then BIN="${BUILD_DIR}/zaver"; else BIN="${BUILD_DIR}/src/zaver"; fi
    
    # 启动
    setsid "$BIN" -c "$CONF_PATH" >"$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    echo "Server PID: $SERVER_PID"
    sleep 2 # 等待初始化
}

# 停止服务器
stop_server() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill -9 "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap stop_server EXIT

# 资源监控函数 (后台运行)
monitor_resources() {
    local pid=$1
    local duration=$2
    # 每秒采集一次 CPU 和 内存，计算平均值
    pidstat -r -u -p "$pid" 1 "$duration" | awk '
        BEGIN {cpu=0; mem=0; count=0} 
        /Average/ {print "| " $8 "% | " $13 " MB |"; exit}
    ' || echo "| N/A | N/A |"
}

# 运行 wrk 测试用例
run_case() {
    local title=$1
    local url=$2
    local threads=$3
    local conns=$4
    local duration=$5
    local args=${6:-""} # 额外的 wrk 参数

    echo "Running: $title ..." >&2

    # 启动资源监控 (在后台)
    # 注意：这里我们简单睡眠 duration 秒后去拿结果，实际情况可能需要更复杂的同步，
    # 为了简化脚本，这里只做压测，不实时并列显示监控数据，你可以在另一个终端 top 看。
    
    # 运行 wrk
    local output
    output=$(wrk -t"$threads" -c"$conns" -d"$duration" $args "$url" 2>/dev/null)

    # 提取数据
    local qps=$(echo "$output" | awk '/Requests\/sec/ {print $2}')
    local lat=$(echo "$output" | awk '/Latency/ {print $2}')
    local tput=$(echo "$output" | awk '/Transfer\/sec/ {print $2}')
    
    # 格式化输出到表格
    echo "| $title | $conns | $threads | $qps | $lat | $tput |"
}

# === 主流程 ===

# 0. 环境准备
if [ ! -f "${ROOT_DIR}/html/big.bin" ]; then
    echo "Generating 256MB test file..."
    dd if=/dev/zero of="${ROOT_DIR}/html/big.bin" bs=1M count=256 status=none
fi

# 1. 启动服务器
start_server

echo "# Zaver Final Performance Report" > "$OUT_MD"
echo "Date: $(date)" >> "$OUT_MD"
echo "" >> "$OUT_MD"
echo "| Scenario | Conns | Threads | QPS (Req/sec) | Latency (Avg) | Throughput |" >> "$OUT_MD"
echo "|---|---|---|---|---|---|" >> "$OUT_MD" | tee -a "$OUT_MD"

# 2. 执行测试用例

# Case A: 极限 QPS (基准测试)
# 4线程, 500连接, 30秒
run_case "Baseline (Small File)" "$SMALL_FILE_URL" 4 500 30s >> "$OUT_MD"

# Case B: 高吞吐 (零拷贝验证)
# 4线程, 100连接, 30秒
run_case "Throughput (Big File)" "$BIG_FILE_URL" 4 100 30s >> "$OUT_MD"

# Case C: 短连接风暴 (Stress Accept)
# 关键参数: -H 'Connection: close'
run_case "Short Connection" "$SMALL_FILE_URL" 4 500 30s "-H Connection:close" >> "$OUT_MD"

# Case D: C10K 高并发模拟 (需要 ulimit 支持)
# 尝试 5000 连接 (虚拟机上 10k 可能会卡死，先试 5k)
run_case "C5K Scalability" "$SMALL_FILE_URL" 4 5000 30s >> "$OUT_MD"

# Case E: CGI 动态请求
run_case "CGI (Process Fork)" "$CGI_URL" 4 50 30s >> "$OUT_MD"

echo "" >> "$OUT_MD"
echo "Done! Report saved to $OUT_MD"
cat "$OUT_MD"