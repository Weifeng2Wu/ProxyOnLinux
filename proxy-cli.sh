#!/bin/bash

#================================================================
# Proxy CLI - 代理快捷管理工具
# 用法: proxy [on|off|shutdown|status]
#================================================================

PROXY_DIR="/home/user/project/proxy"
SINGBOX_BIN="$PROXY_DIR/sing-box/sing-box"
CONFIG_FILE="$PROXY_DIR/config/config.json"
PID_FILE="$PROXY_DIR/singbox.pid"
ENV_FILE="$PROXY_DIR/proxy_env.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

proxy_on() {
    echo -e "${BLUE}[INFO]${NC} 启用代理环境变量..."

    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}[ERROR]${NC} 代理未部署，请先运行部署脚本"
        exit 1
    fi

    # 导出环境变量
    export http_proxy="http://127.0.0.1:10809"
    export https_proxy="http://127.0.0.1:10809"
    export HTTP_PROXY="http://127.0.0.1:10809"
    export HTTPS_PROXY="http://127.0.0.1:10809"
    export all_proxy="socks5://127.0.0.1:10808"
    export ALL_PROXY="socks5://127.0.0.1:10808"
    export no_proxy="localhost,127.0.0.1,::1"
    export NO_PROXY="localhost,127.0.0.1,::1"

    # 检查 sing-box 是否运行
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p $pid > /dev/null 2>&1; then
            echo -e "${GREEN}[SUCCESS]${NC} 代理环境变量已设置"
            echo -e "${BLUE}提示:${NC} 在当前shell会话中生效"
            echo -e "${BLUE}提示:${NC} 使用 ${YELLOW}source <(proxy on)${NC} 或将此命令添加到 ~/.bashrc"
            return 0
        fi
    fi

    echo -e "${YELLOW}[WARN]${NC} sing-box 服务未运行，请先运行部署脚本"
}

proxy_off() {
    echo -e "${BLUE}[INFO]${NC} 禁用代理环境变量..."

    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    unset all_proxy ALL_PROXY no_proxy NO_PROXY

    echo -e "${GREEN}[SUCCESS]${NC} 代理环境变量已清除"
    echo -e "${BLUE}提示:${NC} sing-box 服务仍在运行，使用 ${YELLOW}proxy shutdown${NC} 关闭服务"
}

proxy_shutdown() {
    echo -e "${BLUE}[INFO]${NC} 关闭并清理代理..."

    # 清除环境变量
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    unset all_proxy ALL_PROXY no_proxy NO_PROXY

    # 停止 sing-box 服务
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p $pid > /dev/null 2>&1; then
            kill $pid
            echo -e "${GREEN}[SUCCESS]${NC} sing-box 已停止 (PID: $pid)"
        fi
        rm -f "$PID_FILE"
    else
        pkill -f "sing-box run" 2>/dev/null && echo -e "${GREEN}[SUCCESS]${NC} sing-box 已停止"
    fi

    # 清理配置文件
    rm -f "$CONFIG_FILE"
    rm -f "$PROXY_DIR"/config/temp_node_*.json
    rm -f "$PROXY_DIR"/config/result_*.txt

    echo -e "${GREEN}[SUCCESS]${NC} 代理已关闭并清理"
}

proxy_status() {
    echo -e "${BLUE}========== 代理状态 ==========${NC}"

    # 检查 sing-box 服务
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p $pid > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} sing-box 服务: ${GREEN}运行中${NC} (PID: $pid)"
        else
            echo -e "${RED}✗${NC} sing-box 服务: ${RED}已停止${NC}"
        fi
    else
        echo -e "${RED}✗${NC} sing-box 服务: ${RED}未启动${NC}"
    fi

    # 检查环境变量
    if [ -n "$http_proxy" ] || [ -n "$HTTP_PROXY" ]; then
        echo -e "${GREEN}✓${NC} 环境变量: ${GREEN}已设置${NC}"
        echo -e "  HTTP代理: ${http_proxy:-$HTTP_PROXY}"
        echo -e "  SOCKS5代理: ${all_proxy:-$ALL_PROXY}"
    else
        echo -e "${RED}✗${NC} 环境变量: ${RED}未设置${NC}"
    fi

    # 检查配置文件
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${GREEN}✓${NC} 配置文件: 存在"
    else
        echo -e "${RED}✗${NC} 配置文件: 不存在"
    fi

    # 测试连接
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p $pid > /dev/null 2>&1; then
            echo ""
            echo -e "${BLUE}[测试]${NC} 检测代理IP..."
            local proxy_ip=$(curl -x http://127.0.0.1:10809 -s --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null)
            if [ -n "$proxy_ip" ]; then
                echo -e "${GREEN}✓${NC} 代理IP: ${GREEN}$proxy_ip${NC}"
            else
                echo -e "${RED}✗${NC} 代理连接: ${RED}失败${NC}"
            fi
        fi
    fi

    echo -e "${BLUE}=============================${NC}"
}

show_help() {
    cat <<EOF
Proxy CLI - 代理快捷管理工具

用法:
  proxy on          启用代理环境变量
  proxy off         禁用代理环境变量
  proxy shutdown    关闭服务并清理配置
  proxy status      查看代理状态

示例:
  # 启用代理（需要在当前shell生效）
  source <(proxy on)
  # 或
  eval "\$(proxy on)"

  # 查看状态
  proxy status

  # 禁用代理（保持服务运行）
  proxy off

  # 完全关闭并清理
  proxy shutdown

EOF
}

# 主逻辑
case "$1" in
    on)
        proxy_on
        ;;
    off)
        proxy_off
        ;;
    shutdown)
        proxy_shutdown
        ;;
    status)
        proxy_status
        ;;
    *)
        show_help
        exit 1
        ;;
esac
