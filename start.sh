#!/bin/bash

#================================================================
# V2Ray 自动部署脚本 - 中国GPU云服务器优化版
# 用法: ./start.sh <订阅链接>
# 功能: 自动安装依赖、解析订阅、测速选择最优节点、启动代理
#================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2RAY_DIR="${SCRIPT_DIR}/v2ray"
CONFIG_DIR="${SCRIPT_DIR}/config"
LOG_DIR="${SCRIPT_DIR}/logs"
SOCKS_PORT=10808
HTTP_PORT=10809
SUBSCRIBE_URL="$1"

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查参数
check_arguments() {
    if [ -z "$SUBSCRIBE_URL" ]; then
        log_error "缺少订阅链接参数"
        echo "用法: $0 <订阅链接>"
        exit 1
    fi
    log_info "订阅链接: $SUBSCRIBE_URL"
}

# 创建必要目录
create_directories() {
    log_info "创建工作目录..."
    mkdir -p "$V2RAY_DIR" "$CONFIG_DIR" "$LOG_DIR"
}

# 检测系统信息
detect_system() {
    log_info "检测系统信息..."

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
        log_info "操作系统: $OS $VER"
    else
        log_error "无法检测操作系统"
        exit 1
    fi

    # 检测架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            V2RAY_ARCH="linux-64"
            ;;
        aarch64)
            V2RAY_ARCH="linux-arm64-v8a"
            ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    log_info "系统架构: $ARCH ($V2RAY_ARCH)"
}

# 配置国内镜像源
setup_mirrors() {
    log_info "配置国内镜像源..."

    case $OS in
        ubuntu|debian)
            # 检查 sources.list 是否存在（新版 Debian/Ubuntu 可能使用 sources.list.d）
            if [ -f /etc/apt/sources.list ]; then
                # 备份原始源
                if [ ! -f /etc/apt/sources.list.bak ]; then
                    sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
                fi

                # 使用阿里云镜像
                sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb http://mirrors.aliyun.com/ubuntu/ $(lsb_release -cs) main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $(lsb_release -cs)-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $(lsb_release -cs)-backports main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ $(lsb_release -cs)-security main restricted universe multiverse
EOF
                log_success "已配置阿里云Ubuntu镜像源"
            else
                log_warn "未找到 /etc/apt/sources.list，跳过镜像源配置（新版系统使用 sources.list.d）"
            fi
            ;;
        centos)
            # 使用阿里云CentOS镜像
            sudo sed -e 's|^mirrorlist=|#mirrorlist=|g' \
                     -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' \
                     -i.bak /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
            log_success "已配置阿里云CentOS镜像源"
            ;;
    esac
}

# 安装系统依赖
install_dependencies() {
    log_info "安装系统依赖..."

    case $OS in
        ubuntu|debian)
            sudo apt-get update -y
            sudo apt-get install -y curl wget jq unzip net-tools ca-certificates
            ;;
        centos)
            sudo yum install -y curl wget jq unzip net-tools ca-certificates
            ;;
        *)
            log_warn "未知系统，尝试通用安装..."
            ;;
    esac

    log_success "系统依赖安装完成"
}

# 下载并安装V2Ray
install_v2ray() {
    log_info "开始安装V2Ray..."

    # 检查是否已安装
    if [ -f "$V2RAY_DIR/v2ray" ]; then
        log_warn "V2Ray已存在，跳过下载"
        return
    fi

    # 获取最新版本（使用多个GitHub镜像源）
    log_info "获取V2Ray最新版本..."

    # GitHub镜像源列表（按优先级排序）
    declare -a GITHUB_PROXIES=(
        "https://ghp.ci/"
        "https://mirror.ghproxy.com/"
        "https://gh-proxy.org/"
        "https://ghproxy.net/"
        ""  # 直连作为最后备选
    )

    VERSION=""
    GITHUB_PROXY=""
    for PROXY in "${GITHUB_PROXIES[@]}"; do
        if [ -z "$PROXY" ]; then
            log_info "尝试直连 GitHub..."
            RELEASE_URL="https://github.com/v2fly/v2ray-core/releases/latest"
        else
            log_info "尝试镜像: $PROXY"
            RELEASE_URL="${PROXY}https://github.com/v2fly/v2ray-core/releases/latest"
        fi

        VERSION=$(curl -sL --connect-timeout 10 --max-time 20 "$RELEASE_URL" | grep -oP 'v\d+\.\d+\.\d+' | head -n 1)
        if [ -n "$VERSION" ]; then
            GITHUB_PROXY="$PROXY"
            log_success "成功获取版本信息: $VERSION"
            break
        fi
    done

    if [ -z "$VERSION" ]; then
        log_error "无法获取V2Ray版本信息，所有镜像源均失败"
        exit 1
    fi

    # 下载V2Ray（带重试机制）
    cd "$V2RAY_DIR"

    DOWNLOAD_SUCCESS=false
    for PROXY in "${GITHUB_PROXIES[@]}"; do
        if [ -z "$PROXY" ]; then
            log_info "尝试直连下载..."
            DOWNLOAD_URL="https://github.com/v2fly/v2ray-core/releases/download/${VERSION}/v2ray-${V2RAY_ARCH}.zip"
        else
            log_info "尝试下载: $PROXY"
            DOWNLOAD_URL="${PROXY}https://github.com/v2fly/v2ray-core/releases/download/${VERSION}/v2ray-${V2RAY_ARCH}.zip"
        fi

        if wget --timeout=30 --tries=2 -O v2ray.zip "$DOWNLOAD_URL" 2>/dev/null; then
            DOWNLOAD_SUCCESS=true
            log_success "下载成功"
            break
        fi
    done

    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        log_error "V2Ray下载失败，所有镜像源均不可用"
        exit 1
    fi

    # 解压
    unzip -o v2ray.zip
    rm v2ray.zip
    chmod +x v2ray v2ctl 2>/dev/null || chmod +x v2ray

    log_success "V2Ray安装完成: $VERSION"
}

# 解析订阅链接
parse_subscription() {
    log_info "解析订阅链接..."

    # 下载订阅内容
    SUB_CONTENT=$(curl -sL "$SUBSCRIBE_URL" | base64 -d 2>/dev/null || curl -sL "$SUBSCRIBE_URL")

    if [ -z "$SUB_CONTENT" ]; then
        log_error "订阅链接无效或无法访问"
        exit 1
    fi

    # 保存原始订阅内容
    echo "$SUB_CONTENT" > "$CONFIG_DIR/subscription.txt"

    # 解析节点（支持vmess、vless、trojan、ss）
    echo "$SUB_CONTENT" | grep -E '^(vmess|vless|trojan|ss)://' > "$CONFIG_DIR/nodes.txt" || {
        log_error "未找到有效节点"
        exit 1
    }

    NODE_COUNT=$(wc -l < "$CONFIG_DIR/nodes.txt")
    log_success "成功解析 $NODE_COUNT 个节点"
}

# 将节点转换为V2Ray配置
node_to_config() {
    local node_url="$1"
    local config_file="$2"
    local protocol="${node_url%%://*}"

    case $protocol in
        vmess)
            parse_vmess "$node_url" "$config_file"
            ;;
        vless)
            parse_vless "$node_url" "$config_file"
            ;;
        trojan)
            parse_trojan "$node_url" "$config_file"
            ;;
        ss)
            parse_shadowsocks "$node_url" "$config_file"
            ;;
        *)
            log_warn "不支持的协议: $protocol"
            return 1
            ;;
    esac
}

# 解析VMess节点
parse_vmess() {
    local url="$1"
    local config_file="$2"
    local vmess_data="${url#vmess://}"
    local vmess_json=$(echo "$vmess_data" | base64 -d 2>/dev/null)

    if [ -z "$vmess_json" ]; then
        log_warn "VMess节点解析失败"
        return 1
    fi

    # 提取配置信息
    local address=$(echo "$vmess_json" | jq -r '.add')
    local port=$(echo "$vmess_json" | jq -r '.port')
    local uuid=$(echo "$vmess_json" | jq -r '.id')
    local aid=$(echo "$vmess_json" | jq -r '.aid // 0')
    local net=$(echo "$vmess_json" | jq -r '.net // "tcp"')
    local tls=$(echo "$vmess_json" | jq -r '.tls // ""')
    local sni=$(echo "$vmess_json" | jq -r '.sni // .host // ""')
    local path=$(echo "$vmess_json" | jq -r '.path // ""')

    # 生成V2Ray配置
    cat > "$config_file" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    },
    {
      "port": $HTTP_PORT,
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "$address",
            "port": $port,
            "users": [
              {
                "id": "$uuid",
                "alterId": $aid,
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$net",
        "security": "$([ "$tls" = "tls" ] && echo "tls" || echo "none")",
        $([ "$tls" = "tls" ] && echo "\"tlsSettings\": { \"serverName\": \"$sni\", \"allowInsecure\": false },")
        $([ "$net" = "ws" ] && echo "\"wsSettings\": { \"path\": \"$path\" },")
        $([ "$net" = "h2" ] && echo "\"httpSettings\": { \"path\": \"$path\" },")
        "sockopt": {}
      }
    }
  ]
}
EOF
}

# 解析VLess节点
parse_vless() {
    local url="$1"
    local config_file="$2"

    # VLess URL格式: vless://uuid@server:port?params#name
    local url_body="${url#vless://}"
    local uuid="${url_body%%@*}"
    local rest="${url_body#*@}"
    local server_port="${rest%%\?*}"
    local server="${server_port%:*}"
    local port="${server_port##*:}"
    local params="${rest#*\?}"
    params="${params%%#*}"

    # 解析参数
    local encryption="none"
    local flow=""
    local security="none"
    local sni=""
    local type="tcp"

    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        key="${param%%=*}"
        value="${param#*=}"
        value=$(printf '%b' "${value//%/\\x}")

        case $key in
            encryption) encryption="$value" ;;
            flow) flow="$value" ;;
            security) security="$value" ;;
            sni) sni="$value" ;;
            type) type="$value" ;;
        esac
    done

    cat > "$config_file" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    },
    {
      "port": $HTTP_PORT,
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$server",
            "port": $port,
            "users": [
              {
                "id": "$uuid",
                "encryption": "$encryption"
                $([ -n "$flow" ] && echo ", \"flow\": \"$flow\"")
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$type",
        "security": "$security"
        $([ "$security" = "tls" ] && echo ", \"tlsSettings\": { \"serverName\": \"$sni\", \"allowInsecure\": false }")
      }
    }
  ]
}
EOF
}

# 解析Trojan节点
parse_trojan() {
    local url="$1"
    local config_file="$2"

    # Trojan URL格式: trojan://password@server:port?params#name
    local url_body="${url#trojan://}"
    local password="${url_body%%@*}"
    local rest="${url_body#*@}"
    local server_port="${rest%%\?*}"
    local server="${server_port%:*}"
    local port="${server_port##*:}"

    cat > "$config_file" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    },
    {
      "port": $HTTP_PORT,
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "protocol": "trojan",
      "settings": {
        "servers": [
          {
            "address": "$server",
            "port": $port,
            "password": "$password"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "allowInsecure": false
        }
      }
    }
  ]
}
EOF
}

# 解析Shadowsocks节点
parse_shadowsocks() {
    local url="$1"
    local config_file="$2"

    # SS URL格式: ss://base64(method:password)@server:port#name
    local url_body="${url#ss://}"
    local encoded="${url_body%%@*}"
    local decoded=$(echo "$encoded" | base64 -d 2>/dev/null)
    local method="${decoded%%:*}"
    local password="${decoded#*:}"
    local rest="${url_body#*@}"
    local server_port="${rest%%#*}"
    local server="${server_port%:*}"
    local port="${server_port##*:}"

    cat > "$config_file" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    },
    {
      "port": $HTTP_PORT,
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "protocol": "shadowsocks",
      "settings": {
        "servers": [
          {
            "address": "$server",
            "port": $port,
            "method": "$method",
            "password": "$password"
          }
        ]
      }
    }
  ]
}
EOF
}

# 测试节点延迟
test_node_latency() {
    local config_file="$1"
    local node_name="$2"

    # 启动临时V2Ray实例
    "$V2RAY_DIR/v2ray" -c "$config_file" > /dev/null 2>&1 &
    local v2ray_pid=$!

    # 等待启动
    sleep 2

    # 测试延迟（通过代理访问Google DNS）
    local start_time=$(date +%s%3N)
    local http_code=$(curl -x socks5://127.0.0.1:$SOCKS_PORT \
                           -o /dev/null -s -w '%{http_code}' \
                           --connect-timeout 5 \
                           --max-time 10 \
                           https://www.google.com 2>/dev/null)
    local end_time=$(date +%s%3N)

    # 停止临时实例
    kill $v2ray_pid 2>/dev/null
    wait $v2ray_pid 2>/dev/null

    if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
        local latency=$((end_time - start_time))
        echo "$latency"
        log_info "节点 $node_name 延迟: ${latency}ms"
        return 0
    else
        log_warn "节点 $node_name 测试失败 (HTTP: $http_code)"
        echo "999999"
        return 1
    fi
}

# 测速并选择最优节点
select_best_node() {
    log_info "开始测速选择最优节点..."

    local best_latency=999999
    local best_node=""
    local best_config=""
    local node_index=0

    while IFS= read -r node_url; do
        node_index=$((node_index + 1))
        log_info "测试节点 [$node_index/$NODE_COUNT]"

        local temp_config="$CONFIG_DIR/temp_node_${node_index}.json"

        # 转换节点为配置
        if node_to_config "$node_url" "$temp_config"; then
            # 测试延迟
            local latency=$(test_node_latency "$temp_config" "$node_index")

            if [ "$latency" -lt "$best_latency" ]; then
                best_latency=$latency
                best_node=$node_index
                best_config=$temp_config
                log_success "发现更优节点: #$node_index (${latency}ms)"
            fi
        fi

    done < "$CONFIG_DIR/nodes.txt"

    if [ -z "$best_config" ] || [ "$best_latency" = "999999" ]; then
        log_error "所有节点测试失败，无可用节点"
        exit 1
    fi

    # 复制最优配置
    cp "$best_config" "$CONFIG_DIR/config.json"
    log_success "已选择最优节点: #$best_node (延迟: ${best_latency}ms)"

    # 清理临时配置
    rm -f "$CONFIG_DIR"/temp_node_*.json
}

# 启动V2Ray
start_v2ray() {
    log_info "启动V2Ray代理服务..."

    # 停止已存在的实例
    pkill -f "v2ray.*config.json" 2>/dev/null || true
    sleep 1

    # 启动V2Ray
    cd "$V2RAY_DIR"
    nohup ./v2ray -c "$CONFIG_DIR/config.json" > "$LOG_DIR/v2ray.log" 2>&1 &
    local v2ray_pid=$!

    echo $v2ray_pid > "$SCRIPT_DIR/v2ray.pid"

    # 等待启动
    sleep 3

    if ! ps -p $v2ray_pid > /dev/null; then
        log_error "V2Ray启动失败"
        cat "$LOG_DIR/v2ray.log"
        exit 1
    fi

    log_success "V2Ray已启动 (PID: $v2ray_pid)"
    log_info "SOCKS5代理: 127.0.0.1:$SOCKS_PORT"
    log_info "HTTP代理: 127.0.0.1:$HTTP_PORT"
}

# 验证代理
verify_proxy() {
    log_info "验证代理连接..."

    # 测试1: 访问Google
    log_info "测试1: 访问 Google..."
    if curl -x socks5://127.0.0.1:$SOCKS_PORT \
            -o /dev/null -s -w '%{http_code}\n' \
            --connect-timeout 10 \
            --max-time 15 \
            https://www.google.com | grep -q "200\|301\|302"; then
        log_success "✓ Google 访问成功"
    else
        log_warn "✗ Google 访问失败"
    fi

    # 测试2: 获取IP信息
    log_info "测试2: 检测出口IP..."
    local proxy_ip=$(curl -x socks5://127.0.0.1:$SOCKS_PORT \
                          -s --connect-timeout 10 --max-time 15 \
                          https://api.ipify.org 2>/dev/null)
    if [ -n "$proxy_ip" ]; then
        log_success "✓ 代理IP: $proxy_ip"
    else
        log_warn "✗ 无法获取代理IP"
    fi

    # 测试3: 访问GitHub
    log_info "测试3: 访问 GitHub..."
    if curl -x http://127.0.0.1:$HTTP_PORT \
            -o /dev/null -s -w '%{http_code}\n' \
            --connect-timeout 10 \
            --max-time 15 \
            https://github.com | grep -q "200"; then
        log_success "✓ GitHub 访问成功"
    else
        log_warn "✗ GitHub 访问失败"
    fi

    # 测试4: 访问HuggingFace
    log_info "测试4: 访问 HuggingFace..."
    if curl -x http://127.0.0.1:$HTTP_PORT \
            -o /dev/null -s -w '%{http_code}\n' \
            --connect-timeout 10 \
            --max-time 15 \
            https://huggingface.co | grep -q "200"; then
        log_success "✓ HuggingFace 访问成功"
    else
        log_warn "✗ HuggingFace 访问失败"
    fi
}

# 生成环境变量配置
generate_env_config() {
    log_info "生成环境变量配置..."

    cat > "$SCRIPT_DIR/proxy_env.sh" <<EOF
#!/bin/bash
# V2Ray代理环境变量配置
# 使用方法: source proxy_env.sh

export http_proxy="http://127.0.0.1:$HTTP_PORT"
export https_proxy="http://127.0.0.1:$HTTP_PORT"
export HTTP_PROXY="http://127.0.0.1:$HTTP_PORT"
export HTTPS_PROXY="http://127.0.0.1:$HTTP_PORT"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"

echo "代理环境变量已设置:"
echo "  HTTP/HTTPS代理: 127.0.0.1:$HTTP_PORT"
echo "  SOCKS5代理: 127.0.0.1:$SOCKS_PORT"
EOF

    chmod +x "$SCRIPT_DIR/proxy_env.sh"
    log_success "环境变量配置已生成: proxy_env.sh"
}

# 生成停止脚本
generate_stop_script() {
    cat > "$SCRIPT_DIR/stop.sh" <<'EOF'
#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/v2ray.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null; then
        kill $PID
        echo "V2Ray已停止 (PID: $PID)"
    else
        echo "V2Ray进程不存在"
    fi
    rm -f "$PID_FILE"
else
    pkill -f "v2ray.*config.json" && echo "V2Ray已停止" || echo "未找到运行中的V2Ray进程"
fi

# 清理环境变量
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
echo "代理环境变量已清除"
EOF

    chmod +x "$SCRIPT_DIR/stop.sh"
    log_success "停止脚本已生成: stop.sh"
}

# 显示使用说明
show_usage() {
    cat <<EOF

${GREEN}========================================
🎉 V2Ray代理部署成功！
========================================${NC}

${BLUE}📍 代理地址:${NC}
  SOCKS5: 127.0.0.1:$SOCKS_PORT
  HTTP:   127.0.0.1:$HTTP_PORT

${BLUE}📝 使用方法:${NC}

  设置系统环境变量即可使用代理:
  ${YELLOW}source $SCRIPT_DIR/proxy_env.sh${NC}

  设置后，所有支持 HTTP/HTTPS 代理的工具（git、pip、wget、curl 等）
  都会自动使用代理，无需额外配置。

${BLUE}🔧 管理命令:${NC}
  停止代理: ${YELLOW}$SCRIPT_DIR/stop.sh${NC}
  查看日志: ${YELLOW}tail -f $LOG_DIR/v2ray.log${NC}
  重启代理: ${YELLOW}$SCRIPT_DIR/stop.sh && $0 $SUBSCRIBE_URL${NC}

${BLUE}📊 服务状态:${NC}
  V2Ray PID: $(cat "$SCRIPT_DIR/v2ray.pid" 2>/dev/null || echo "未知")
  配置文件: $CONFIG_DIR/config.json
  日志文件: $LOG_DIR/v2ray.log

${GREEN}========================================${NC}

EOF
}

# 主函数
main() {
    echo -e "${BLUE}"
    cat <<'EOF'
╔═══════════════════════════════════════╗
║   V2Ray 自动部署脚本 - GPU云优化版   ║
║   支持订阅解析 | 自动测速 | 智能选节点   ║
╚═══════════════════════════════════════╝
EOF
    echo -e "${NC}"

    check_arguments
    create_directories
    detect_system
    setup_mirrors
    install_dependencies
    install_v2ray
    parse_subscription
    select_best_node
    start_v2ray
    verify_proxy
    generate_env_config
    generate_stop_script
    show_usage

    log_success "部署完成！代理服务已就绪。"
}

# 执行主函数
main
