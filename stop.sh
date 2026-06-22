#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/singbox.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null; then
        kill $PID
        echo "sing-box 已停止 (PID: $PID)"
    else
        echo "sing-box 进程不存在"
    fi
    rm -f "$PID_FILE"
else
    pkill -f "sing-box run" && echo "sing-box 已停止" || echo "未找到运行中的 sing-box 进程"
fi

# 清理环境变量
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
echo "代理环境变量已清除"
