# ProxyOnLinux

🚀 一键部署 sing-box 代理服务 - 支持订阅解析、自动测速、智能选节点

## ✨ 特性

- ✅ 支持多种协议：VMess、VLess、Trojan、Shadowsocks、**AnyTLS**、Hysteria2
- ✅ 自动解析订阅链接
- ✅ 自动测速并选择最优节点
- ✅ 简单的快捷命令管理
- ✅ 一键启动/关闭代理
- ✅ 适配国内网络环境（镜像源加速）

## 📦 快速开始

### 1. 部署代理

```bash
./start-singbox.sh <订阅链接>
```

### 2. 使用代理

```bash
# 启用代理环境变量
source proxy_env.sh

# 或使用快捷命令（推荐）
proxy on

# 测试代理
curl ip.sb
```

### 3. 管理代理

```bash
# 查看状态
proxy status

# 禁用代理（保持服务运行）
proxy off

# 完全关闭并清理
proxy shutdown
```

## 📝 快捷命令

部署完成后会自动安装 `proxy` 命令：

| 命令 | 说明 |
|------|------|
| `proxy status` | 查看代理状态和IP |
| `proxy on` | 启用代理环境变量 |
| `proxy off` | 禁用代理环境变量 |
| `proxy shutdown` | 关闭服务并清理配置 |

## 🔧 代理端口

- **HTTP**: 127.0.0.1:10809
- **SOCKS5**: 127.0.0.1:10808
- **Mixed**: 127.0.0.1:10810 (推荐)

## 🌍 使用场景

设置环境变量后，所有支持代理的工具都会自动使用：

```bash
# Git 克隆
git clone https://github.com/user/repo.git

# pip 安装
pip install torch

# wget 下载
wget https://example.com/file.zip

# curl 访问
curl https://www.google.com
```

## 📋 系统要求

- Linux (Debian/Ubuntu/CentOS)
- curl, wget, jq, unzip

## 🛠️ 文件说明

- `start-singbox.sh` - 主部署脚本
- `proxy-cli.sh` - 快捷命令工具
- `stop.sh` - 停止脚本（自动生成）
- `proxy_env.sh` - 环境变量配置（自动生成）

## 🎯 工作原理

1. 下载订阅链接内容
2. 解析所有节点配置
3. 自动测速（串行测试前3个节点）
4. 选择延迟最低的节点
5. 启动 sing-box 代理服务
6. 验证连接并生成配置

## 📖 常见问题

### Q: ping google.com 不通？

A: **这是正常的**。ping 使用 ICMP 协议，代理只支持 TCP/UDP。使用 `curl` 测试即可。

### Q: IP 地址没有改变？

A: 需要先设置环境变量：
```bash
source proxy_env.sh
# 或
proxy on
```

### Q: 如何在新的终端窗口使用代理？

A: 每个新终端需要重新执行：
```bash
source /path/to/proxy_env.sh
```

或将此命令添加到 `~/.bashrc` 中自动加载。

### Q: 如何更换节点？

A: 重新运行部署脚本即可：
```bash
./stop.sh
./start-singbox.sh <订阅链接>
```

## 🔄 更新日志

### v1.0.0
- 首次发布
- 支持 AnyTLS 协议
- 自动测速选择最优节点
- 快捷命令管理

## 📄 许可证

MIT License

## 🙏 鸣谢

- [sing-box](https://github.com/SagerNet/sing-box) - 核心代理工具
