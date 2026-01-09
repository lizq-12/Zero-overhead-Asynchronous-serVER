#!/bin/bash

# 颜色定义，好看一点
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== Starting Functional Test ==="

# 1. 启动服务器
# 注意：在 CI 环境里，编译好的程序在上一级目录的 build/ 下
# 我们让它在后台运行 (&)
../build/zaver &
SERVER_PID=$!
echo "Server started with PID $SERVER_PID"

# 2. 等待几秒让服务器初始化
sleep 3

# 3. 发送测试请求
# 访问 index.html，检查 HTTP 状态码是否为 200
echo "Sending request to http://127.0.0.1:3000/index.html ..."
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" http://127.0.0.1:3000/index.html)

# 4. 验证结果
if [ "$HTTP_CODE" -eq 200 ]; then
    echo -e "${GREEN}Test Passed! Server returned HTTP 200.${NC}"
    RESULT=0
else
    echo -e "${RED}Test Failed! Server returned HTTP $HTTP_CODE${NC}"
    RESULT=1
fi

# 5. 清理战场：杀掉服务器进程
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null

# 6. 告诉 CI 是成功还是失败
exit $RESULT
