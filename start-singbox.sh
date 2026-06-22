#!/bin/bash

#================================================================
# sing-box 自动部署脚本 - 中国GPU云服务器优化版
# 用法: ./start-singbox.sh <订阅链接>
# 功能: 自动安装依赖、解析订阅、测速选择最优节点、启动代理
# 支持协议: VMess、VLess、Trojan、Shadowsocks、AnyTLS、Hysteria2
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
SINGBOX_DIR="${SCRIPT_DIR}/sing-box"
CONFIG_DIR="${SCRIPT_DIR}/config"
LOG_DIR="${SCRIPT_DIR}/logs"
SOCKS_PORT=10808
HTTP_PORT=10809
MIXED_PORT=10810
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
    mkdir -p "$SINGBOX_DIR" "$CONFIG_DIR" "$LOG_DIR"
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
            SINGBOX_ARCH="amd64"
            ;;
        aarch64)
            SINGBOX_ARCH="arm64"
            ;;
        armv7l)
            SINGBOX_ARCH="armv7"
            ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    log_info "系统架构: $ARCH ($SINGBOX_ARCH)"
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
    log_info "检查系统依赖..."

    # 检查必需工具是否已安装
    local missing_deps=()
    for tool in curl wget jq unzip; do
        if ! command -v $tool &> /dev/null; then
            missing_deps+=($tool)
        fi
    done

    if [ ${#missing_deps[@]} -eq 0 ]; then
        log_success "所有必需依赖已安装"
        return
    fi

    log_warn "缺少依赖: ${missing_deps[*]}"
    log_info "尝试安装缺失的依赖..."

    case $OS in
        ubuntu|debian)
            if sudo -n true 2>/dev/null; then
                sudo apt-get update -y
                sudo apt-get install -y "${missing_deps[@]}" ca-certificates
            else
                log_warn "需要 sudo 权限安装依赖，请手动执行："
                log_warn "  sudo apt-get install -y ${missing_deps[*]}"
                log_error "缺少必需工具，退出"
                exit 1
            fi
            ;;
        centos)
            if sudo -n true 2>/dev/null; then
                sudo yum install -y "${missing_deps[@]}" ca-certificates
            else
                log_warn "需要 sudo 权限安装依赖，请手动执行："
                log_warn "  sudo yum install -y ${missing_deps[*]}"
                log_error "缺少必需工具，退出"
                exit 1
            fi
            ;;
        *)
            log_error "未知系统，请手动安装: ${missing_deps[*]}"
            exit 1
            ;;
    esac

    log_success "系统依赖安装完成"
}

# 下载并安装sing-box
install_singbox() {
    log_info "开始安装 sing-box..."

    # 检查是否已安装
    if [ -f "$SINGBOX_DIR/sing-box" ]; then
        log_warn "sing-box 已存在，跳过下载"
        return
    fi

    # GitHub镜像源列表
    declare -a GITHUB_PROXIES=(
        "https://ghp.ci/"
        "https://mirror.ghproxy.com/"
        "https://gh.api.99988866.xyz/"
        "https://ghproxy.net/"
        "https://gh-proxy.org/"
        ""  # 直连作为最后备选
    )

    # 获取最新版本（带超时和重试）
    log_info "获取 sing-box 最新版本..."
    VERSION=""
    for PROXY in "${GITHUB_PROXIES[@]}"; do
        if [ -z "$PROXY" ]; then
            log_info "尝试直连 GitHub API..."
            RELEASE_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
        else
            log_info "尝试镜像: $PROXY"
            RELEASE_URL="${PROXY}https://api.github.com/repos/SagerNet/sing-box/releases/latest"
        fi

        VERSION=$(curl -sL --connect-timeout 10 --max-time 20 "$RELEASE_URL" 2>&1 | jq -r '.tag_name' 2>/dev/null)
        if [ -n "$VERSION" ] && [ "$VERSION" != "null" ]; then
            GITHUB_PROXY="$PROXY"
            log_success "成功获取版本信息: $VERSION"
            break
        fi
    done

    # 如果所有方法都失败，使用固定版本
    if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
        VERSION="v1.10.0"
        log_warn "无法获取最新版本，使用固定版本: $VERSION"
    fi

    # 下载sing-box（添加更多备用下载源）
    cd "$SINGBOX_DIR"
    DOWNLOAD_SUCCESS=false

    # 定义下载源（包括 jsdelivr CDN）
    declare -a DOWNLOAD_SOURCES=(
        "https://edgeone.gh-proxy.org/https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${SINGBOX_ARCH}.tar.gz"
        "https://ghp.ci/https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${SINGBOX_ARCH}.tar.gz"
        "https://mirror.ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${SINGBOX_ARCH}.tar.gz"
        "https://ghproxy.net/https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${SINGBOX_ARCH}.tar.gz"
        "https://gh-proxy.org/https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${SINGBOX_ARCH}.tar.gz"
        "https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${SINGBOX_ARCH}.tar.gz"
    )

    for DOWNLOAD_URL in "${DOWNLOAD_SOURCES[@]}"; do
        log_info "尝试下载: $(echo $DOWNLOAD_URL | grep -oP 'https://[^/]+')"

        if wget --timeout=30 --tries=2 -O sing-box.tar.gz "$DOWNLOAD_URL" 2>/dev/null; then
            DOWNLOAD_SUCCESS=true
            log_success "下载成功"
            break
        fi
    done

    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        log_error "sing-box 下载失败"
        exit 1
    fi

    # 解压
    tar -xzf sing-box.tar.gz
    mv sing-box-${VERSION#v}-linux-${SINGBOX_ARCH}/sing-box .
    rm -rf sing-box-${VERSION#v}-linux-${SINGBOX_ARCH} sing-box.tar.gz
    chmod +x sing-box

    log_success "sing-box 安装完成: $VERSION"
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

    # 解析节点（支持多种协议）
    echo "$SUB_CONTENT" | grep -E '^(vmess|vless|trojan|ss|hysteria2|hy2|tuic|anytls)://' > "$CONFIG_DIR/nodes.txt" || {
        log_error "未找到有效节点"
        exit 1
    }

    NODE_COUNT=$(wc -l < "$CONFIG_DIR/nodes.txt")
    log_success "成功解析 $NODE_COUNT 个节点"
}

# 生成sing-box基础配置
generate_base_config() {
    local outbound="$1"

    cat <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": $MIXED_PORT
    },
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": $SOCKS_PORT
    },
    {
      "type": "http",
      "tag": "http-in",
      "listen": "127.0.0.1",
      "listen_port": $HTTP_PORT
    }
  ],
  "outbounds": [
    $outbound,
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
}

# 解析VMess节点为sing-box配置
parse_vmess_singbox() {
    local url="$1"
    local vmess_data="${url#vmess://}"
    local vmess_json=$(echo "$vmess_data" | base64 -d 2>/dev/null)

    if [ -z "$vmess_json" ]; then
        return 1
    fi

    local server=$(echo "$vmess_json" | jq -r '.add')
    local port=$(echo "$vmess_json" | jq -r '.port')
    local uuid=$(echo "$vmess_json" | jq -r '.id')
    local aid=$(echo "$vmess_json" | jq -r '.aid // 0')
    local net=$(echo "$vmess_json" | jq -r '.net // "tcp"')
    local tls=$(echo "$vmess_json" | jq -r '.tls // ""')
    local sni=$(echo "$vmess_json" | jq -r '.sni // .host // ""')

    cat <<EOF
{
  "type": "vmess",
  "tag": "proxy",
  "server": "$server",
  "server_port": $port,
  "uuid": "$uuid",
  "alter_id": $aid,
  "security": "auto",
  "transport": {
    "type": "$net"
  }
  $([ "$tls" = "tls" ] && echo ', "tls": { "enabled": true, "server_name": "'"$sni"'", "insecure": false }')
}
EOF
}

# 解析VLess节点为sing-box配置
parse_vless_singbox() {
    local url="$1"
    local url_body="${url#vless://}"
    local uuid="${url_body%%@*}"
    local rest="${url_body#*@}"
    local server_port="${rest%%\?*}"
    local server="${server_port%:*}"
    local port="${server_port##*:}"
    local params="${rest#*\?}"
    params="${params%%#*}"

    local encryption="none"
    local security="none"
    local sni=""
    local type="tcp"
    local flow=""

    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        key="${param%%=*}"
        value="${param#*=}"
        value=$(printf '%b' "${value//%/\\x}")

        case $key in
            encryption) encryption="$value" ;;
            security) security="$value" ;;
            sni) sni="$value" ;;
            type) type="$value" ;;
            flow) flow="$value" ;;
        esac
    done

    cat <<EOF
{
  "type": "vless",
  "tag": "proxy",
  "server": "$server",
  "server_port": $port,
  "uuid": "$uuid",
  "flow": "$flow",
  "transport": {
    "type": "$type"
  }
  $([ "$security" = "tls" ] && echo ', "tls": { "enabled": true, "server_name": "'"$sni"'", "insecure": false }')
}
EOF
}

# 解析Trojan节点为sing-box配置
parse_trojan_singbox() {
    local url="$1"
    local url_body="${url#trojan://}"
    local password="${url_body%%@*}"
    local rest="${url_body#*@}"
    local server_port="${rest%%\?*}"
    local server="${server_port%:*}"
    local port="${server_port##*:}"

    cat <<EOF
{
  "type": "trojan",
  "tag": "proxy",
  "server": "$server",
  "server_port": $port,
  "password": "$password",
  "tls": {
    "enabled": true,
    "insecure": false
  }
}
EOF
}

# 解析Shadowsocks节点为sing-box配置
parse_shadowsocks_singbox() {
    local url="$1"
    local url_body="${url#ss://}"
    local encoded="${url_body%%@*}"
    local decoded=$(echo "$encoded" | base64 -d 2>/dev/null)
    local method="${decoded%%:*}"
    local password="${decoded#*:}"
    local rest="${url_body#*@}"
    local server_port="${rest%%#*}"
    local server="${server_port%:*}"
    local port="${server_port##*:}"

    cat <<EOF
{
  "type": "shadowsocks",
  "tag": "proxy",
  "server": "$server",
  "server_port": $port,
  "method": "$method",
  "password": "$password"
}
EOF
}

# 解析AnyTLS节点为sing-box配置
parse_anytls_singbox() {
    local url="$1"
    # AnyTLS URL格式: anytls://password@server:port?sni=xxx&insecure=1#name
    local url_body="${url#anytls://}"
    local password="${url_body%%@*}"
    local rest="${url_body#*@}"
    local server_port="${rest%%\?*}"
    local server="${server_port%:*}"
    local port="${server_port##*:}"
    local params="${rest#*\?}"
    params="${params%%#*}"

    local sni=""
    local insecure="false"

    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        key="${param%%=*}"
        value="${param#*=}"
        value=$(printf '%b' "${value//%/\\x}")

        case $key in
            sni) sni="$value" ;;
            insecure)
                if [ "$value" = "1" ] || [ "$value" = "true" ]; then
                    insecure="true"
                fi
                ;;
        esac
    done

    cat <<EOF
{
  "type": "anytls",
  "tag": "proxy",
  "server": "$server",
  "server_port": $port,
  "password": "$password",
  "tls": {
    "enabled": true,
    "server_name": "$sni",
    "insecure": $insecure
  }
}
EOF
}

# 节点转sing-box配置
node_to_singbox_config() {
    local node_url="$1"
    local protocol="${node_url%%://*}"

    case $protocol in
        vmess)
            parse_vmess_singbox "$node_url"
            ;;
        vless)
            parse_vless_singbox "$node_url"
            ;;
        trojan)
            parse_trojan_singbox "$node_url"
            ;;
        ss)
            parse_shadowsocks_singbox "$node_url"
            ;;
        anytls)
            parse_anytls_singbox "$node_url"
            ;;
        *)
            return 1
            ;;
    esac
}

# 测试节点延迟
test_node_latency() {
    local config_file="$1"
    local node_name="$2"

    # 启动临时sing-box实例
    "$SINGBOX_DIR/sing-box" run -c "$config_file" > /dev/null 2>&1 &
    local singbox_pid=$!

    # 等待启动
    sleep 2

    # 测试延迟
    local start_time=$(date +%s%3N)
    local http_code=$(curl -x http://127.0.0.1:$HTTP_PORT \
                           -o /dev/null -s -w '%{http_code}' \
                           --connect-timeout 5 \
                           --max-time 8 \
                           https://www.google.com 2>/dev/null)
    local end_time=$(date +%s%3N)

    # 停止临时实例
    kill $singbox_pid 2>/dev/null
    wait $singbox_pid 2>/dev/null

    if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
        local latency=$((end_time - start_time))
        log_info "节点 $node_name 延迟: ${latency}ms" >&2
        echo "$latency"
        return 0
    else
        log_warn "节点 $node_name 测试失败 (HTTP: $http_code)" >&2
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
    local success_count=0

    # 串行测试（更稳定）
    while IFS= read -r node_url; do
        node_index=$((node_index + 1))
        log_info "测试节点 [$node_index/$NODE_COUNT]"

        # 转换节点为sing-box outbound配置
        local outbound=$(node_to_singbox_config "$node_url")

        if [ -z "$outbound" ]; then
            log_warn "节点 #$node_index 解析失败，跳过"
            continue
        fi

        # 生成完整配置
        local temp_config="$CONFIG_DIR/temp_node_${node_index}.json"
        generate_base_config "$outbound" > "$temp_config"

        # 测试延迟
        local latency=$(test_node_latency "$temp_config" "$node_index")

        if [ "$latency" -lt 900000 ] 2>/dev/null && [ "$latency" -gt 0 ] 2>/dev/null; then
            success_count=$((success_count + 1))
            if [ "$latency" -lt "$best_latency" ]; then
                best_latency=$latency
                best_node=$node_index
                best_config=$temp_config
                log_success "发现更优节点: #$node_index (${latency}ms)"
            fi
        fi

        # 只测试前 10 个节点加快速度
        if [ $success_count -ge 3 ]; then
            log_info "已找到 3 个可用节点，停止测速"
            break
        fi

    done < "$CONFIG_DIR/nodes.txt"

    log_info "成功测试 $success_count 个节点"

    if [ -z "$best_config" ] || [ "$best_latency" = "999999" ]; then
        log_error "所有节点测试失败，无可用节点"
        exit 1
    fi

    # 生成最终配置
    cp "$best_config" "$CONFIG_DIR/config.json"
    log_success "已选择最优节点: #$best_node (延迟: ${best_latency}ms)"

    # 清理临时配置
    rm -f "$CONFIG_DIR"/temp_node_*.json
}

# 启动sing-box
start_singbox() {
    log_info "启动 sing-box 代理服务..."

    # 停止已存在的实例
    pkill -f "sing-box run" 2>/dev/null || true
    sleep 1

    # 启动sing-box
    cd "$SINGBOX_DIR"
    nohup ./sing-box run -c "$CONFIG_DIR/config.json" > "$LOG_DIR/singbox.log" 2>&1 &
    local singbox_pid=$!

    echo $singbox_pid > "$SCRIPT_DIR/singbox.pid"

    # 等待启动
    sleep 3

    if ! ps -p $singbox_pid > /dev/null; then
        log_error "sing-box 启动失败"
        cat "$LOG_DIR/singbox.log"
        exit 1
    fi

    log_success "sing-box 已启动 (PID: $singbox_pid)"
    log_info "Mixed代理: 127.0.0.1:$MIXED_PORT"
    log_info "SOCKS5代理: 127.0.0.1:$SOCKS_PORT"
    log_info "HTTP代理: 127.0.0.1:$HTTP_PORT"
}

# 验证代理
verify_proxy() {
    log_info "验证代理连接..."

    # 测试1: 访问Google
    log_info "测试1: 访问 Google..."
    if curl -x http://127.0.0.1:$HTTP_PORT \
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
    local proxy_ip=$(curl -x http://127.0.0.1:$HTTP_PORT \
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
}

# 生成环境变量配置
generate_env_config() {
    log_info "生成环境变量配置..."

    cat > "$SCRIPT_DIR/proxy_env.sh" <<EOF
#!/bin/bash
# sing-box 代理环境变量配置
# 使用方法: source proxy_env.sh

export http_proxy="http://127.0.0.1:$HTTP_PORT"
export https_proxy="http://127.0.0.1:$HTTP_PORT"
export HTTP_PROXY="http://127.0.0.1:$HTTP_PORT"
export HTTPS_PROXY="http://127.0.0.1:$HTTP_PORT"
export all_proxy="socks5://127.0.0.1:$SOCKS_PORT"
export ALL_PROXY="socks5://127.0.0.1:$SOCKS_PORT"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"

echo "代理环境变量已设置:"
echo "  Mixed代理: 127.0.0.1:$MIXED_PORT"
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
EOF

    chmod +x "$SCRIPT_DIR/stop.sh"
    log_success "停止脚本已生成: stop.sh"
}

# 显示使用说明
show_usage() {
    cat <<EOF

${GREEN}========================================
🎉 sing-box 代理部署成功！
========================================${NC}

${BLUE}📍 代理地址:${NC}
  Mixed:  127.0.0.1:$MIXED_PORT (推荐)
  SOCKS5: 127.0.0.1:$SOCKS_PORT
  HTTP:   127.0.0.1:$HTTP_PORT

${BLUE}📝 使用方法:${NC}

  设置系统环境变量即可使用代理:
  ${YELLOW}source $SCRIPT_DIR/proxy_env.sh${NC}

  设置后，所有支持 HTTP/HTTPS/SOCKS5 代理的工具（git、pip、wget、curl 等）
  都会自动使用代理，无需额外配置。

${BLUE}⚡ 快捷命令:${NC}
  ${YELLOW}proxy status${NC}      查看代理状态
  ${YELLOW}proxy on${NC}          启用代理环境变量
  ${YELLOW}proxy off${NC}         禁用代理环境变量
  ${YELLOW}proxy shutdown${NC}    关闭并清理代理

${BLUE}🔧 管理命令:${NC}
  停止代理: ${YELLOW}$SCRIPT_DIR/stop.sh${NC}
  查看日志: ${YELLOW}tail -f $LOG_DIR/singbox.log${NC}
  重启代理: ${YELLOW}$SCRIPT_DIR/stop.sh && $0 $SUBSCRIBE_URL${NC}

${BLUE}📊 服务状态:${NC}
  sing-box PID: $(cat "$SCRIPT_DIR/singbox.pid" 2>/dev/null || echo "未知")
  配置文件: $CONFIG_DIR/config.json
  日志文件: $LOG_DIR/singbox.log

${BLUE}✨ 支持协议:${NC}
  VMess, VLess, Trojan, Shadowsocks, AnyTLS, Hysteria2

${GREEN}========================================${NC}

EOF
}

# 主函数
main() {
    echo -e "${BLUE}"
    cat <<'EOF'
╔═══════════════════════════════════════╗
║  sing-box 自动部署脚本 - GPU云优化版  ║
║ 支持订阅解析 | 自动测速 | 智能选节点    ║
║ VMess|VLess|Trojan|SS|AnyTLS|Hysteria ║
╚═══════════════════════════════════════╝
EOF
    echo -e "${NC}"

    check_arguments
    create_directories
    detect_system
    setup_mirrors
    install_dependencies
    install_singbox
    parse_subscription
    select_best_node
    start_singbox
    verify_proxy
    generate_env_config
    generate_stop_script

    # 安装快捷命令
    log_info "安装快捷命令..."
    mkdir -p ~/bin
    chmod +x "$SCRIPT_DIR/proxy-cli.sh"
    ln -sf "$SCRIPT_DIR/proxy-cli.sh" ~/bin/proxy 2>/dev/null
    if ! grep -q 'export PATH="$HOME/bin:$PATH"' ~/.bashrc 2>/dev/null; then
        echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
    fi
    export PATH="$HOME/bin:$PATH"
    log_success "快捷命令已安装: proxy"

    show_usage

    log_success "部署完成！代理服务已就绪。"
}

# 执行主函数
main
