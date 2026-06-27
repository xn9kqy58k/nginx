#!/usr/bin/env bash
# =============================================================================
# VPS 安全加固脚本（v2node增强稳定版）
# 适配：Ubuntu 20.04+ / Debian 10+
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
danger() { echo -e "${RED}[✗]${NC} $*"; }
sec()    { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

[[ $EUID -ne 0 ]] && echo "root required" && exit 1

# =============================================================================
# 清理旧配置
# =============================================================================
sec "清理旧配置"

rm -f /etc/sysctl.d/99-harden.conf || true
rm -f /etc/fail2ban/jail.local /etc/fail2ban/filter.d/portscan.conf || true

ufw --force reset >/dev/null 2>&1 || true
info "已重置UFW"

# =============================================================================
# 安装依赖
# =============================================================================
sec "安装依赖"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq ufw fail2ban

# =============================================================================
# 端口检测（v2node增强核心）
# =============================================================================
sec "检测代理 / v2node端口"

PROXY_PORTS=""

# -------------------------
# 1. ss监听端口（基础）
# -------------------------
SS_PORTS=$(ss -H -tulnp 2>/dev/null | awk '
/LISTEN|UNCONN/ {
  if (match($0, /:([0-9]{2,5})/, m)) print m[1]
}' | sort -u)

# -------------------------
# 2. 进程识别补充
# -------------------------
PROC_PORTS=$(ss -tulnp 2>/dev/null | grep -E "v2node|v2bx|xray|nginx|hysteria" \
  | awk '{print $4}' | awk -F: '{print $NF}' | awk -F% '{print $1}' \
  | grep -E '^[0-9]+$' || true)

# -------------------------
# 3. v2node JSON配置解析（关键）
# -------------------------
CFG_PORTS=""
for f in /etc/v2node/config.json /root/v2node/config.json /opt/v2node/config.json; do
  if [[ -f "$f" ]]; then
    CFG_PORTS+=" $(grep -Eo '"port"[[:space:]]*:[[:space:]]*[0-9]{2,5}' "$f" \
      | grep -Eo '[0-9]{2,5}' || true)"
  fi
done

# -------------------------
# 合并去重
# -------------------------
PROXY_PORTS=$(echo -e "$SS_PORTS\n$PROC_PORTS\n$CFG_PORTS" \
  | grep -E '^[0-9]{2,5}$' \
  | sort -u)

# 去掉SSH端口避免误操作
PROXY_PORTS=$(echo "$PROXY_PORTS" | grep -v "^22$" || true)

if [[ -z "$PROXY_PORTS" ]]; then
  warn "未检测到代理/v2node端口，仅放行SSH"
else
  info "检测端口：$PROXY_PORTS"
fi

# =============================================================================
# UFW防火墙
# =============================================================================
sec "配置UFW"

ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp comment "SSH"

for p in $PROXY_PORTS; do
  ufw allow ${p}/tcp comment "proxy"
done

echo "y" | ufw enable
info "UFW已启用"

# =============================================================================
# Fail2ban（优化版）
# =============================================================================
sec "Fail2ban配置"

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 8

[sshd]
enabled = true
port = 22

[portscan]
enabled = true
filter = portscan
logpath = /var/log/ufw.log
findtime = 300
maxretry = 10
bantime = 24h
EOF

cat > /etc/fail2ban/filter.d/portscan.conf <<EOF
[Definition]
failregex = .*UFW BLOCK.*SRC=<HOST>.*
ignoreregex =
EOF

systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

# =============================================================================
# 内核优化（修复版）
# =============================================================================
sec "sysctl优化"

cat > /etc/sysctl.d/99-harden.conf <<EOF
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2

net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

net.ipv4.tcp_fin_timeout = 15

fs.file-max = 1000000
EOF

sysctl --system >/dev/null 2>&1 || true
info "sysctl已应用"

# =============================================================================
# 自动更新
# =============================================================================
sec "自动更新"

cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# =============================================================================
# 完成输出
# =============================================================================
sec "完成"

echo "开放端口："
echo "  SSH: 22/tcp"

for p in $PROXY_PORTS; do
  echo "  PROXY: $p/tcp"
done

echo ""
info "加固完成"
