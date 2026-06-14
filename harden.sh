#!/usr/bin/env bash
# =============================================================================
#  VPS 安全加固脚本（通用版，支持重复执行覆盖旧配置）
#  系统：Ubuntu 20.04+ / Debian 10+
#  用法：bash harden.sh
# =============================================================================

set -eu

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
danger()  { echo -e "${RED}[✗]${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

[[ $EUID -ne 0 ]] && echo "请以 root 运行" && exit 1

# =============================================================================
# 清除旧的加固配置（覆盖模式）
# =============================================================================
section "清除旧配置"

# 清除旧 sysctl
rm -f /etc/sysctl.d/99-harden.conf /etc/sysctl.d/99-hardening.conf
info "旧 sysctl 配置已清除"

# 清除旧 fail2ban jail
rm -f /etc/fail2ban/jail.local /etc/fail2ban/filter.d/portscan.conf
info "旧 Fail2ban 配置已清除"

# 重置 UFW
ufw --force reset >/dev/null 2>&1 || true
info "旧防火墙规则已重置"

# =============================================================================
# 安装依赖
# =============================================================================
section "安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || warn "部分仓库更新失败（不影响安装）"
apt-get install -y -qq ufw fail2ban unattended-upgrades
info "安装完成"

# =============================================================================
# 检测代理进程端口
# =============================================================================
section "检测代理端口"

PROXY_PROCS="v2bx|v2node|nginx|xray|hysteria"
PROXY_TCP=""
PROXY_UDP=""

if ss -tlnp 2>/dev/null | grep -qiE "$PROXY_PROCS"; then
    PROXY_TCP=$(ss -tlnp 2>/dev/null \
        | grep -iE "$PROXY_PROCS" \
        | awk '{print $4}' \
        | awk -F: '{print $NF}' \
        | awk '$1+0 > 0 && $1+0 < 65536' \
        | sort -u | tr '\n' ' ')
fi

if ss -ulnp 2>/dev/null | grep -qiE "$PROXY_PROCS"; then
    PROXY_UDP=$(ss -ulnp 2>/dev/null \
        | grep -iE "$PROXY_PROCS" \
        | awk '{print $4}' \
        | awk -F: '{print $NF}' \
        | awk -F% '{print $1}' \
        | awk '$1+0 > 0 && $1+0 < 65536' \
        | sort -u | tr '\n' ' ')
fi

if [[ -z "$PROXY_TCP" && -z "$PROXY_UDP" ]]; then
    warn "未检测到代理进程端口，仅放行 SSH 22"
    warn "服务启动后重新运行此脚本，或手动执行：ufw allow <端口> && ufw reload"
else
    [[ -n "$PROXY_TCP" ]] && info "检测到 TCP 端口：$PROXY_TCP"
    [[ -n "$PROXY_UDP" ]] && info "检测到 UDP 端口：$PROXY_UDP"
fi

# =============================================================================
# 清理残留 nginx（如果 V2bX 直连模式不需要）
# =============================================================================
section "检查残留服务"

if systemctl is-active --quiet nginx 2>/dev/null; then
    # nginx 在监听端口列表里才保留，否则停掉
    if echo "$PROXY_TCP" | grep -qE '\b80\b|\b443\b'; then
        info "nginx 正在使用中，保留"
    else
        systemctl stop nginx || true
        systemctl disable nginx --quiet || true
        warn "nginx 未被使用，已停止"
    fi
else
    info "无残留服务"
fi

# =============================================================================
# UFW 防火墙
# =============================================================================
section "配置 UFW 防火墙"

[ -f /etc/default/ufw ] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw

ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp comment 'SSH'
info "放行 22/tcp (SSH)"

for port in $PROXY_TCP; do
    ufw allow "${port}/tcp" comment "proxy" && info "放行 ${port}/tcp"
done

for port in $PROXY_UDP; do
    ufw allow "${port}/udp" comment "proxy-udp" && info "放行 ${port}/udp"
done

echo "y" | ufw enable
info "防火墙已启用（IPv4 + IPv6）"
echo ""
ufw status numbered

# =============================================================================
# Fail2ban
# =============================================================================
section "配置 Fail2ban"

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 10
ignoreip = 127.0.0.1/8

[sshd]
enabled  = true
port     = 22
maxretry = 10
bantime  = 24h

[portscan]
enabled   = true
filter    = portscan
logpath   = /var/log/ufw.log
maxretry  = 5
findtime  = 30s
bantime   = 24h
EOF

cat > /etc/fail2ban/filter.d/portscan.conf << 'EOF'
[Definition]
failregex = .*UFW BLOCK.* SRC=<HOST> .*
ignoreregex =
EOF

ufw logging on
systemctl enable fail2ban --quiet
systemctl restart fail2ban
info "Fail2ban 已启动（SSH 10次失败封禁24h / 端口扫描30s触发5次封禁24h）"

# =============================================================================
# 内核参数加固
# =============================================================================
section "内核参数加固"

cat > /etc/sysctl.d/99-harden.conf << 'EOF'
# rp_filter=2 宽松模式，兼容多IP/特殊路由的VPS
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# 禁止接受 ICMP 重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
# SYN flood 防护
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
# 防 Smurf 攻击
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# TIME_WAIT 优化
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
# 文件描述符（高并发节点）
fs.file-max = 1000000
EOF

sysctl -p /etc/sysctl.d/99-harden.conf -q
info "内核参数已应用"

# =============================================================================
# 自动安全更新
# =============================================================================
section "自动安全更新"

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

info "自动安全更新已启用"

# =============================================================================
# 完成
# =============================================================================
section "加固完成"
echo ""
echo -e "${BOLD}防火墙放行：${NC}"
echo -e "  ${GREEN}22/tcp${NC}    SSH"
for port in $PROXY_TCP; do echo -e "  ${GREEN}${port}/tcp${NC}  proxy"; done
for port in $PROXY_UDP; do echo -e "  ${GREEN}${port}/udp${NC}  proxy(UDP)"; done
echo ""
echo -e "${BOLD}已完成：${NC}"
echo "  [✓] 旧配置已清除并重新应用"
echo "  [✓] UFW 防火墙（IPv4 + IPv6）"
echo "  [✓] SSH 爆破防护（10次失败封禁24h）"
echo "  [✓] 端口扫描封禁（30s触发5次封禁24h）"
echo "  [✓] 内核加固（rp_filter=2 兼容模式）"
echo "  [✓] 自动安全更新"
echo ""
if [[ -z "$PROXY_TCP" && -z "$PROXY_UDP" ]]; then
    danger "代理端口未检测到！服务启动后重新运行脚本，或手动执行："
    echo "    ufw allow <端口>/tcp && ufw reload"
fi
echo ""
