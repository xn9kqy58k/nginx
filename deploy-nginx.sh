#!/usr/bin/env bash
# =============================================================================
#  Nginx 伪装站部署脚本（配合 XrayR + V2Board 面板使用）
#
#  只处理 Nginx / 证书 / 防火墙部分，XrayR 节点配置由面板管理。
#
#  模式A  WS+TLS  ：Nginx 前置，终止 TLS，反代到 XrayR 本地端口
#  模式B  Reality ：XrayR 直接监听 443，Nginx 仅作内部蜜罐 fallback 接收
#
#  系统：Ubuntu 20.04/22.04/24.04  |  Debian 10/11/12
#  用法：bash deploy-nginx.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

[[ $EUID -ne 0 ]] && error "请以 root 身份运行：sudo bash deploy-nginx.sh"
command -v apt &>/dev/null || error "仅支持 Debian/Ubuntu 系统"

# =============================================================================
# 配置收集
# =============================================================================
section "配置信息"
echo ""

echo -e "${BOLD}节点传输模式：${NC}"
echo "  1) VLESS + Reality（XrayR 直接监听 443，Nginx 仅做内部 fallback）"
echo "  2) VLESS/VMess + WebSocket + TLS（Nginx 前置终止 TLS）"
read -rp "请输入 1-2 [默认 1]: " MODE
MODE=${MODE:-1}
echo ""

read -rp "$(echo -e "${BOLD}蜜罐 Worker 域名${NC}（如 trap.yourdomain.com）: ")" HONEYPOT_DOMAIN
[[ -z "$HONEYPOT_DOMAIN" ]] && error "蜜罐域名不能为空"

DOMAIN=""
EMAIL=""
XRAYR_PORT=8080   # XrayR 本地监听端口（WS 模式，在面板节点配置里填写）
WS_PATH="/$(openssl rand -hex 6)"

if [[ "$MODE" == "2" ]]; then
    read -rp "$(echo -e "${BOLD}节点域名${NC}（已解析到本机，如 node.example.com）: ")" DOMAIN
    [[ -z "$DOMAIN" ]] && error "域名不能为空"
    read -rp "$(echo -e "${BOLD}邮箱${NC}（Let's Encrypt 证书通知）: ")" EMAIL
    [[ -z "$EMAIL" ]] && error "邮箱不能为空"
    read -rp "$(echo -e "${BOLD}XrayR 本地端口${NC}（面板节点配置的服务端口，默认 8080）: ")" INPUT_PORT
    XRAYR_PORT=${INPUT_PORT:-8080}
    read -rp "$(echo -e "${BOLD}WS 路径${NC}（默认随机，如需指定请输入）: ")" INPUT_PATH
    [[ -n "$INPUT_PATH" ]] && WS_PATH="$INPUT_PATH"
fi

read -rp "$(echo -e "${BOLD}SSH 端口${NC}（留空不修改，建议改成非 22）: ")" NEW_SSH_PORT

echo ""
echo -e "${BOLD}确认配置：${NC}"
[[ "$MODE" == "1" ]] && echo "  模式：Reality（Nginx 内部 fallback）" || echo "  模式：WS+TLS（Nginx 前置）"
echo "  蜜罐域名：$HONEYPOT_DOMAIN"
[[ "$MODE" == "2" ]] && echo "  节点域名：$DOMAIN" && echo "  XrayR 本地端口：$XRAYR_PORT" && echo "  WS 路径：$WS_PATH"
echo ""
read -rp "开始部署？[y/N] " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "已取消" && exit 0

# =============================================================================
# 安装依赖
# =============================================================================
section "安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y -qq nginx certbot python3-certbot-nginx ufw fail2ban curl openssl
info "依赖安装完成"

# =============================================================================
# SSH 端口
# =============================================================================
SSH_PORT=22
if [[ -n "$NEW_SSH_PORT" && "$NEW_SSH_PORT" =~ ^[0-9]+$ ]]; then
    section "修改 SSH 端口 → $NEW_SSH_PORT"
    sed -i "s/^#*Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
    systemctl reload sshd
    SSH_PORT=$NEW_SSH_PORT
    info "SSH 端口已改为 $NEW_SSH_PORT"
fi

# =============================================================================
# 防火墙
# =============================================================================
section "配置 UFW 防火墙"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'SSH'
ufw allow 80/tcp   comment 'HTTP'
ufw allow 443/tcp  comment 'HTTPS'
echo "y" | ufw enable
info "防火墙已启用：$SSH_PORT / 80 / 443"

# =============================================================================
# Fail2ban
# =============================================================================
section "配置 Fail2ban"
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 7d
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port    = $SSH_PORT
EOF
systemctl enable fail2ban --quiet
systemctl restart fail2ban
info "Fail2ban 已启动"

# =============================================================================
# 内核参数加固
# =============================================================================
section "加固内核参数"
cat > /etc/sysctl.d/99-hardening.conf << EOF
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1000000
EOF
sysctl -p /etc/sysctl.d/99-hardening.conf -q
info "内核参数已应用"

# =============================================================================
# 兜底页（Worker 不可达时用）
# =============================================================================
mkdir -p /var/www/html
cat > /var/www/html/50x.html << 'EOF'
<!DOCTYPE html><html><head><title>503</title></head>
<body><h1>503 Service Unavailable</h1></body></html>
EOF

# =============================================================================
# Nginx 配置（根据模式分支）
# =============================================================================

# ── 公共 TLS 参数片段 ─────────────────────────────────────────────────────────
make_ssl_block() {
    local cert_domain=$1
    cat << EOF
    ssl_certificate     /etc/letsencrypt/live/${cert_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${cert_domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF
}

# ── 蜜罐反代 location 片段（两种模式共用）─────────────────────────────────────
make_honeypot_proxy() {
    local upstream_domain=$1
    cat << EOF
        proxy_pass          https://${upstream_domain};
        proxy_ssl_server_name on;
        proxy_ssl_name      ${upstream_domain};
        proxy_set_header    Host ${upstream_domain};
        proxy_set_header    X-Real-IP \$remote_addr;
        proxy_set_header    X-Forwarded-For \$remote_addr;
        proxy_set_header    X-Forwarded-Proto https;
        proxy_http_version  1.1;
        proxy_read_timeout  30s;
        proxy_connect_timeout 10s;
        error_page 502 503 504 /50x.html;
EOF
}

if [[ "$MODE" == "1" ]]; then
    # ──────────────────────────────────────────────────────────────────────────
    # 模式 A：Reality
    # XrayR 监听 443，非认证流量经 PROXY Protocol 转到本机 8443
    # Nginx 在 8443 接收，解析真实 IP，反代蜜罐 Worker
    # ──────────────────────────────────────────────────────────────────────────
    FALLBACK_PORT=8443
    section "配置 Nginx（Reality 内部 fallback，端口 $FALLBACK_PORT）"

    rm -f /etc/nginx/sites-enabled/default

    cat > /etc/nginx/sites-available/honeypot-fallback << NGINXEOF
# Reality 模式内部 fallback
# 只监听本机，不对外暴露
server {
    listen 127.0.0.1:${FALLBACK_PORT} proxy_protocol;

    # 从 PROXY Protocol 提取原始客户端 IP
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
$(make_honeypot_proxy "$HONEYPOT_DOMAIN")
        location = /50x.html {
            root /var/www/html;
            internal;
        }
    }

    access_log /var/log/nginx/fallback-access.log;
    error_log  /var/log/nginx/fallback-error.log warn;
}
NGINXEOF

    ln -sf /etc/nginx/sites-available/honeypot-fallback /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx
    info "Nginx 内部 fallback 已配置（127.0.0.1:$FALLBACK_PORT）"

else
    # ──────────────────────────────────────────────────────────────────────────
    # 模式 B：WS + TLS
    # Nginx 前置，终止 TLS，非代理流量反代蜜罐 Worker，代理流量转发 XrayR
    # ──────────────────────────────────────────────────────────────────────────
    section "申请 Let's Encrypt 证书（$DOMAIN）"
    systemctl stop nginx 2>/dev/null || true
    certbot certonly \
        --standalone --non-interactive --agree-tos \
        --email "$EMAIL" -d "$DOMAIN" --quiet
    # 自动续期
    cat > /etc/cron.d/certbot-renew << EOF
0 3 * * * root certbot renew --quiet --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
EOF
    info "证书申请成功"

    section "配置 Nginx（WS+TLS 前置）"

    rm -f /etc/nginx/sites-enabled/default

    cat > /etc/nginx/sites-available/node << NGINXEOF
server_tokens off;

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

$(make_ssl_block "$DOMAIN")

    # ── WS 代理流量入口（转发给 XrayR）──────────────────────────────
    # 非 WebSocket 升级请求访问此路径返回 404，探测器看不到入口
    location ${WS_PATH} {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_pass          http://127.0.0.1:${XRAYR_PORT};
        proxy_http_version  1.1;
        proxy_set_header    Upgrade \$http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_set_header    Host \$host;
        proxy_set_header    X-Real-IP \$remote_addr;
        proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
        proxy_buffering     off;
    }

    # ── 其余所有流量 → 蜜罐 Worker ───────────────────────────────────
    location / {
$(make_honeypot_proxy "$HONEYPOT_DOMAIN")
        location = /50x.html {
            root /var/www/html;
            internal;
        }
    }

    access_log /var/log/nginx/node-access.log;
    error_log  /var/log/nginx/node-error.log warn;
}
NGINXEOF

    ln -sf /etc/nginx/sites-available/node /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx
    info "Nginx 前置已配置"
fi

# =============================================================================
# 输出后续操作提示
# =============================================================================
MY_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo 'YOUR_VPS_IP')

section "部署完成"
echo ""

if [[ "$MODE" == "1" ]]; then
    echo -e "${BOLD}模式：${NC}Reality（Nginx 内部 fallback）"
    echo ""
    echo -e "${CYAN}${BOLD}── 在 XrayR 配置中添加以下 fallback（/etc/XrayR/config.yml）──${NC}"
    echo ""
    cat << XRAYREOF
InboundConfigList:
  - ListenIP: 0.0.0.0
    InboundTag: 你的节点Tag
    # ... 其他面板自动生成的配置 ...
    # 在 Reality 节点的额外配置里加入：
    EnableFallback: true
    FallbackList:
      - Dest: 127.0.0.1:8443   # 本机 Nginx fallback 端口
        Xver: 1                  # 启用 PROXY Protocol，传递真实 IP
XRAYREOF
    echo ""
    echo -e "${YELLOW}注：XrayR 的 Reality fallback 配置语法以实际版本文档为准${NC}"
    echo "    XrayR 文档：https://crackair.gitbook.io/xrayr-project"
else
    echo -e "${BOLD}模式：${NC}WS + TLS（Nginx 前置）"
    echo ""
    echo -e "${CYAN}${BOLD}── 面板节点配置填写参考 ──${NC}"
    echo "  传输协议：WebSocket"
    echo "  监听地址：127.0.0.1"
    echo "  监听端口：$XRAYR_PORT"
    echo "  WS 路径：$WS_PATH"
    echo "  TLS：关闭（由 Nginx 处理）"
    echo "  域名/SNI：$DOMAIN（面板 Node Host 字段）"
    echo ""
    echo "  客户端连接配置："
    echo "  地址：$DOMAIN  端口：443  传输：WS  路径：$WS_PATH  TLS：开启"
fi

echo ""
echo -e "${CYAN}${BOLD}── 蜜罐 Worker 联动（需手动完成）──${NC}"
echo "  在蜜罐 Worker 环境变量中添加："
echo -e "  ${BOLD}TRUSTED_NODE_IPS${NC} = $MY_IP"
echo "  让蜜罐信任本节点透传的 X-Real-IP，记录探测器真实 IP"
echo ""
echo -e "${YELLOW}${BOLD}注意事项：${NC}"
echo "  1. SSH 端口：$SSH_PORT"
echo "  2. Nginx 日志：/var/log/nginx/"
echo "  3. 服务状态：systemctl status nginx"
[[ "$MODE" == "2" ]] && echo "  4. 证书自动续期：已配置 cron（每天 03:00 检查）"
echo ""
