#!/usr/bin/env bash
# =============================================================================
#  VPS 安全加固脚本（配合 V2bX 使用）
#  功能：UFW防火墙 / Fail2ban爆破防护 / 内核参数 / 清理残留服务
#  放行：SSH 22 + V2bX 自动检测端口
#  不动：SSH登录方式 / V2bX / 节点配置
#  系统：Ubuntu 20.04+ / Debian 10+
#  用法：bash harden.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
danger()  { echo -e "${RED}[✗]${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

[[ $EUID -ne 0 ]] && echo "请以 root 运行" && exit 1

# =============================================================================
# 检测 V2bX 端口
# =============================================================================
section "检测 V2bX 端口"

V2BX_PORTS=$(ss -tlnp | grep -i v2bx | awk '{print $4}' | awk -F: '{print $NF}' | sort -u || true)
V2BX_UDP_PORTS=$(ss -ulnp | grep -i v2bx | awk '{print $4}' | awk -F: '{print $NF}' | sort -u || true)

if [[ -z "$V2BX_PORTS" && -z "$V2BX_UDP_PORTS" ]]; then
    warn "未检测到 V2bX 监听端口，请确认 V2bX 已在运行"
    warn "仅放行 SSH 22，V2bX 端口请事后手动添加：ufw allow <端口>"
else
    [[ -n "$V2BX_PORTS" ]]     && info "V2bX TCP 端口：$V2BX_PORTS"
    [[ -n "$V2BX_UDP_PORTS" ]] && info "V2bX UDP 端口：$V2BX_UDP_PORTS"
fi

# =============================================================================
# 安装依赖
# =============================================================================
section "安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y -qq ufw fail2ban unattended-upgrades
info "安装完成"

# =============================================================================
# 清理残留 nginx
# =============================================================================
section "检查残留服务"

if systemctl is-active --quiet nginx 2>/dev/null || false; then
    warn "检测到 nginx 正在运行，正在停止并禁用..."
    systemctl stop nginx
    systemctl disable nginx --quiet
    info "nginx 已停止"
else
    info "无残留服务"
fi

# =============================================================================
# UFW 防火墙
# =============================================================================
section "配置 UFW 防火墙"

# 确保 IPv6 支持开启
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH 22
ufw allow 22/tcp comment 'SSH'
info "放行 22/tcp (SSH)"

# V2bX TCP 端口
for port in $V2BX_PORTS; do
    ufw allow "${port}/tcp" comment "V2bX"
    info "放行 ${port}/tcp (V2bX)"
done

# V2bX UDP 端口（hysteria2 等）
for port in $V2BX_UDP_PORTS; do
    ufw allow "${port}/udp" comment "V2bX-UDP"
    info "放行 ${port}/udp (V2bX)"
done

echo "y" | ufw enable
info "防火墙已启用（IPv4 + IPv6）"
echo ""
ufw status numbered

# =============================================================================
# Fail2ban —— SSH 爆破 / 端口扫描防护
# =============================================================================
section "配置 Fail2ban"

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 10
ignoreip = 127.0.0.1/8

# SSH 爆破防护：10次失败封禁24小时
[sshd]
enabled  = true
port     = 22
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 10
bantime  = 24h

# 端口扫描防护：快速连接多个端口触发封禁
[portscan]
enabled   = true
filter    = portscan
logpath   = /var/log/ufw.log
maxretry  = 5
findtime  = 30s
bantime   = 24h
EOF

# 端口扫描过滤规则
cat > /etc/fail2ban/filter.d/portscan.conf << 'EOF'
[Definition]
failregex = .*UFW BLOCK.* SRC=<HOST> .*
ignoreregex =
EOF

# 确保 UFW 日志开启（供 portscan jail 使用）
ufw logging on

systemctl enable fail2ban --quiet
systemctl restart fail2ban
info "Fail2ban 已启动"
info "SSH：10次失败封禁24小时"
info "端口扫描：30秒内触发5次 UFW BLOCK 封禁24小时"

# =============================================================================
# 内核参数加固
# =============================================================================
section "内核参数加固"

cat > /etc/sysctl.d/99-harden.conf << 'EOF'
# 防 IP 欺骗
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
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
# 完成 & 汇总
# =============================================================================
section "加固完成"
echo ""
echo -e "${BOLD}防火墙放行端口：${NC}"
echo -e "  ${GREEN}22/tcp${NC}      SSH"
for port in $V2BX_PORTS;     do echo -e "  ${GREEN}${port}/tcp${NC}     V2bX"; done
for port in $V2BX_UDP_PORTS; do echo -e "  ${GREEN}${port}/udp${NC}     V2bX (UDP)"; done
echo ""
echo -e "${BOLD}已完成项目：${NC}"
echo "  [✓] UFW 防火墙（IPv4 + IPv6，白名单模式）"
echo "  [✓] SSH 爆破防护（10次失败封禁24小时）"
echo "  [✓] 端口扫描封禁（30秒内5次触发即封禁）"
echo "  [✓] 内核 SYN flood / IP欺骗 / Smurf 防护"
echo "  [✓] 自动安全更新"
echo ""
if [[ -z "$V2BX_PORTS" && -z "$V2BX_UDP_PORTS" ]]; then
    danger "V2bX 端口未检测到，请手动补充："
    echo "    ufw allow <端口>/tcp && ufw reload"
fi
echo ""
