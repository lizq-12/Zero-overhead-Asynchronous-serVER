#!/bin/bash

set -euo pipefail

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== Starting Functional Test ==="

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

LOG_FILE="${ROOT_DIR}/tests/functional_test.server.log"

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        # Kill the whole process group (master + workers)
        kill -TERM -- "-${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

BUILD_DIR="${BUILD_DIR:-build}"

# 1. 智能查找可执行文件位置
# 既然我们在根目录运行，通常 build 就在 ./build；Sanitizer 可能是 ./build-asan
if [ -f "./${BUILD_DIR}/zaver" ]; then
    BIN_PATH="./${BUILD_DIR}/zaver"
elif [ -f "./${BUILD_DIR}/src/zaver" ]; then
    BIN_PATH="./${BUILD_DIR}/src/zaver"
else
    echo -e "${RED}Error: Could not find 'zaver' executable!${NC}"
    echo "Hint: set BUILD_DIR=build or BUILD_DIR=build-asan"
    echo "Searching under common build directories:"
    find . -maxdepth 3 -type f -name zaver -print || true
    exit 1
fi

echo "Found server binary at: $BIN_PATH"

# 2. 启动服务器
rm -f "$LOG_FILE"
setsid "$BIN_PATH" -c "$ROOT_DIR/zaver.conf" >"$LOG_FILE" 2>&1 &
SERVER_PID=$!
echo "Server started with PID $SERVER_PID"

# 3. 等待服务器就绪（避免固定 sleep 的偶发失败）
READY=0
for i in $(seq 1 50); do
    CODE=$(curl --max-time 1 -o /dev/null -s -w "%{http_code}" http://127.0.0.1:3000/index.html || true)
    if [[ "$CODE" != "000" ]]; then
        READY=1
        break
    fi
    sleep 0.1
done

if [[ "$READY" -ne 1 ]]; then
    echo -e "${RED}Server did not become ready in time.${NC}"
    echo "--- server log (tail) ---"
    tail -n 200 "$LOG_FILE" || true
    exit 1
fi

RESULT=0

# 4.1 基本可用性：index.html 应该 200
echo "Request: http://127.0.0.1:3000/index.html (expect 200)"
HTTP_CODE=$(curl --max-time 3 -o /dev/null -s -w "%{http_code}" http://127.0.0.1:3000/index.html || true)
if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo -e "${RED}FAILED: expected 200, got $HTTP_CODE${NC}"
    RESULT=1
fi

# 4.2 负例：不存在资源应该 404
echo "Request: http://127.0.0.1:3000/__ci_not_found__ (expect 404)"
HTTP_CODE=$(curl --max-time 3 -o /dev/null -s -w "%{http_code}" http://127.0.0.1:3000/__ci_not_found__ || true)
if [[ "$HTTP_CODE" -ne 404 ]]; then
    echo -e "${RED}FAILED: expected 404, got $HTTP_CODE${NC}"
    RESULT=1
fi

if [[ "$RESULT" -eq 0 ]]; then
    echo -e "${GREEN}Functional tests passed.${NC}"
else
    echo "--- server log (tail) ---"
    tail -n 200 "$LOG_FILE" || true
fi

# 4.3 安全回归：路径穿越应被拒绝（400/403），不能读到仓库文件
echo "Request: http://127.0.0.1:3000/../CMakeLists.txt (expect 400/403)"
HTTP_CODE=$(curl --path-as-is --max-time 3 -o /dev/null -s -w "%{http_code}" http://127.0.0.1:3000/../CMakeLists.txt || true)
if [[ "$HTTP_CODE" != "400" && "$HTTP_CODE" != "403" ]]; then
    echo -e "${RED}FAILED: traversal should be blocked, got $HTTP_CODE${NC}"
    RESULT=1
fi

echo "Request: http://127.0.0.1:3000/%2e%2e/CMakeLists.txt (expect 400/403)"
HTTP_CODE=$(curl --path-as-is --max-time 3 -o /dev/null -s -w "%{http_code}" http://127.0.0.1:3000/%2e%2e/CMakeLists.txt || true)
if [[ "$HTTP_CODE" != "400" && "$HTTP_CODE" != "403" ]]; then
    echo -e "${RED}FAILED: encoded traversal should be blocked, got $HTTP_CODE${NC}"
    RESULT=1
fi

# 4.4 安全回归：软链接逃逸应被拒绝（403）
DOCROOT="$ROOT_DIR/html"
OUTSIDE_DIR="$ROOT_DIR/tests/_tmp_outside"
LINK_NAME="$DOCROOT/__ci_symlink_escape__.txt"

mkdir -p "$OUTSIDE_DIR"
echo "ci" >"$OUTSIDE_DIR/outside.txt"

rm -f "$LINK_NAME"
ln -s "$OUTSIDE_DIR/outside.txt" "$LINK_NAME"

echo "Request: http://127.0.0.1:3000/__ci_symlink_escape__.txt (expect 403)"
HTTP_CODE=$(curl --max-time 3 -o /dev/null -s -w "%{http_code}" http://127.0.0.1:3000/__ci_symlink_escape__.txt || true)
rm -f "$LINK_NAME"

if [[ "$HTTP_CODE" != "403" ]]; then
    echo -e "${RED}FAILED: symlink escape should be blocked, got $HTTP_CODE${NC}"
    RESULT=1
fi

if [[ "$RESULT" -eq 0 ]]; then
    echo -e "${GREEN}All functional + security tests passed.${NC}"
else
    echo "--- server log (tail) ---"
    tail -n 200 "$LOG_FILE" || true
fi

exit $RESULT
