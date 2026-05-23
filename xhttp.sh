#!/bin/bash
set -e

# ============================================================
#  VLESS XHTTP + Nginx + V2BX 一体化部署脚本
#  链路: 客户端 → CF CDN (TLS) → Nginx (TLS终止) → V2BX (裸XHTTP)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ── Root 检查 ──────────────────────────────────────────────
[ "$(id -u)" != "0" ] && error "必须使用 root 运行"

section "VLESS XHTTP CDN 一体化部署"

# ── 参数收集 ───────────────────────────────────────────────
echo ""
read -rp "① VLESS SNI 域名（已解析到 CF / CF 橙云）: " DOMAIN
read -rp "② Cloudflare 邮箱: " CF_EMAIL
read -rsp "③ Cloudflare Global API Key: " CF_KEY
echo
read -rp "④ 伪装路径（例如 /xhttp，必须以 / 开头）: " PATH_VAL
read -rp "⑤ V2BX 本地监听端口（推荐 1024-60000 内未占用端口）: " BACKEND_PORT
echo ""
echo -e "${YELLOW}── 面板对接信息 ──${NC}"
read -rp "⑥ 面板 API 地址（例如 https://panel.example.com）: " PANEL_URL
read -rsp "⑦ 面板 API Key（节点通信密钥）: " PANEL_KEY
echo
read -rp "⑧ 节点 ID（面板后台节点列表中的 ID）: " NODE_ID

# ── 参数校验 ───────────────────────────────────────────────
[[ -z "$DOMAIN" || -z "$CF_EMAIL" || -z "$CF_KEY" || -z "$PATH_VAL" \
   || -z "$BACKEND_PORT" || -z "$PANEL_URL" || -z "$PANEL_KEY" || -z "$NODE_ID" ]] \
   && error "所有参数不能为空"

[[ "$PATH_VAL" != /* ]] && error "伪装路径必须以 / 开头，例如 /xhttp"

# ── 端口占用检查 ───────────────────────────────────────────
section "检查端口占用"
for PORT in 80 443 "$BACKEND_PORT"; do
  if ss -tlnp | grep -q ":${PORT} "; then
    warn "端口 $PORT 已被占用，尝试释放..."
    fuser -k "${PORT}/tcp" 2>/dev/null || true
    sleep 1
  fi
done
info "端口检查通过"

# ── 安装依赖 ───────────────────────────────────────────────
section "安装系统依赖"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y nginx curl socat cron unzip
info "依赖安装完成"

# ── 申请证书 ───────────────────────────────────────────────
section "申请 TLS 证书 (acme.sh + CF DNS)"
export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

CERT_DIR="/etc/v2bx"
CERT="$CERT_DIR/fullchain.cer"
KEY="$CERT_DIR/cert.key"
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

if [ ! -f /root/.acme.sh/acme.sh ]; then
  info "安装 acme.sh..."
  curl -sS https://get.acme.sh | sh
  source /root/.acme.sh/acme.sh.env 2>/dev/null || true
fi

ACME="/root/.acme.sh/acme.sh"

# 强制切换到 Let's Encrypt，避免 ZeroSSL 需要注册邮箱的问题
info "切换 CA 为 Let's Encrypt..."
"$ACME" --set-default-ca --server letsencrypt

# 检查证书是否已存在且未过期，避免触发频率限制
if "$ACME" --list 2>/dev/null | grep -q "$DOMAIN"; then
  info "证书已存在，跳过申请"
else
  info "申请新证书..."
  "$ACME" --issue -d "$DOMAIN" --dns dns_cf --keylength ec-256
fi

"$ACME" --install-cert -d "$DOMAIN" \
  --ecc \
  --key-file "$KEY" \
  --fullchain-file "$CERT" \
  --reloadcmd "systemctl reload nginx 2>/dev/null || true"

chmod 600 "$KEY" "$CERT"
info "证书申请完成"

# ── Nginx 配置 ─────────────────────────────────────────────
section "配置 Nginx"

# Cloudflare IP 段（用于真实 IP 还原）
CF_IPV4_RANGES=(
  "103.21.244.0/22"
  "103.22.200.0/22"
  "103.31.4.0/22"
  "104.16.0.0/13"
  "104.24.0.0/14"
  "108.162.192.0/18"
  "131.0.72.0/22"
  "141.101.64.0/18"
  "162.158.0.0/15"
  "172.64.0.0/13"
  "173.245.48.0/20"
  "188.114.96.0/20"
  "190.93.240.0/20"
  "197.234.240.0/22"
  "198.41.128.0/17"
)

CF_REAL_IP_CONF=""
for cidr in "${CF_IPV4_RANGES[@]}"; do
  CF_REAL_IP_CONF+="        set_real_ip_from ${cidr};\n"
done

cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;

    # ── SSL 全局配置 ──────────────────────────────────────
    ssl_session_cache   shared:SSL:20m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    # ── HTTP → HTTPS 跳转 ────────────────────────────────
    server {
        listen 80;
        server_name $DOMAIN;
        return 301 https://\$host\$request_uri;
    }

    # ── 主服务 ────────────────────────────────────────────
    server {
        listen 443 ssl;
        http2 on;
        server_name $DOMAIN;

        ssl_certificate     $CERT;
        ssl_certificate_key $KEY;

        # HSTS
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

        # ── CF 真实 IP 还原 ───────────────────────────────
$(printf "%b" "$CF_REAL_IP_CONF")
        real_ip_header CF-Connecting-IP;

        # ── XHTTP 代理 ────────────────────────────────────
        location $PATH_VAL {
            proxy_pass          http://127.0.0.1:$BACKEND_PORT;
            proxy_http_version  1.1;

            # XHTTP 流式传输关键配置
            proxy_buffering             off;
            proxy_cache                 off;
            proxy_request_buffering     off;
            chunked_transfer_encoding   on;

            # 长连接超时
            proxy_read_timeout  3600s;
            proxy_send_timeout  3600s;
            keepalive_timeout   3600s;

            proxy_set_header Host              \$http_host;
            proxy_set_header X-Real-IP         \$remote_addr;
            proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        # ── 伪装：非代理路径返回 404 ─────────────────────
        location / {
            return 404;
        }
    }
}
EOF

nginx -t && systemctl restart nginx && systemctl enable nginx
info "Nginx 配置完成并启动"

# ── 安装 V2BX ──────────────────────────────────────────────
section "安装 V2BX (XrayR 核心)"

info "获取 V2BX 最新版本..."
LATEST=$(curl -s https://api.github.com/repos/wyx2685/V2bX/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
[ -z "$LATEST" ] && error "无法获取 V2BX 版本信息，请检查网络"

ARCH=$(uname -m)
case $ARCH in
  x86_64)  ARCH_STR="64" ;;
  aarch64) ARCH_STR="arm64-v8a" ;;
  *)        error "不支持的架构: $ARCH" ;;
esac

DOWNLOAD_URL="https://github.com/wyx2685/V2bX/releases/download/${LATEST}/V2bX-linux-${ARCH_STR}.zip"
info "下载: $DOWNLOAD_URL"
curl -L -o /tmp/v2bx.zip "$DOWNLOAD_URL"

mkdir -p /usr/local/v2bx
unzip -o /tmp/v2bx.zip -d /usr/local/v2bx
chmod +x /usr/local/v2bx/V2bX
ln -sf /usr/local/v2bx/V2bX /usr/local/bin/v2bx
rm -f /tmp/v2bx.zip
info "V2BX 安装完成，版本: $LATEST"

# ── 写入 V2BX config.yml ──────────────────────────────────
section "生成 V2BX 配置"

cat > /etc/v2bx/config.yml <<EOF
Log:
  Level: warning
  AccessPath:
  ErrorPath:

Nodes:
  - PanelType: "NewV2board"
    ApiConfig:
      ApiHost: "$PANEL_URL"
      ApiKey: "$PANEL_KEY"
      NodeID: $NODE_ID
      NodeType: V2ray
      Timeout: 30
      EnableVless: true
      RuleListPath:

    Options:
      ListenIP: 127.0.0.1
      SendIP: 0.0.0.0
      TLSCertConfig:
        CertMode: none
      EnableVless: true
      VlessFlow: ""

    InboundConfig:
      Port: $BACKEND_PORT
      Protocol: vless
      Settings:
        network: xhttp
        xhttpSettings:
          mode: stream-up
          path: "$PATH_VAL"
          host: "$DOMAIN"
EOF

chmod 600 /etc/v2bx/config.yml
info "V2BX 配置写入完成"

# ── 创建 Systemd 服务 ──────────────────────────────────────
section "创建 V2BX 系统服务"

cat > /etc/systemd/system/v2bx.service <<EOF
[Unit]
Description=V2bX Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/v2bx -config /etc/v2bx/config.yml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable v2bx
systemctl start v2bx
sleep 2

# ── 验证服务状态 ───────────────────────────────────────────
section "服务状态验证"
echo ""
if systemctl is-active --quiet nginx; then
  info "✅ Nginx 运行正常"
else
  warn "⚠️  Nginx 未正常运行，请检查: systemctl status nginx"
fi

if systemctl is-active --quiet v2bx; then
  info "✅ V2BX 运行正常"
else
  warn "⚠️  V2BX 未正常运行，请检查: systemctl status v2bx"
fi

if ss -tlnp | grep -q ":$BACKEND_PORT "; then
  info "✅ 后端端口 $BACKEND_PORT 监听正常"
else
  warn "⚠️  后端端口 $BACKEND_PORT 未监听，V2BX 可能启动失败"
  warn "    查看日志: journalctl -u v2bx -n 50"
fi

# ── 输出汇总 ───────────────────────────────────────────────
section "部署完成 🎉"
cat <<SUMMARY

  域名 (SNI/Host):   $DOMAIN
  伪装路径 (Path):   $PATH_VAL
  后端监听端口:       $BACKEND_PORT
  面板地址:          $PANEL_URL
  节点 ID:           $NODE_ID
  证书路径:          $CERT
  V2BX 配置:         /etc/v2bx/config.yml

  ── 客户端配置参考 ──────────────────────────────────────
  协议:     VLESS
  地址:     $DOMAIN
  端口:     443
  传输:     XHTTP  path=$PATH_VAL  mode=stream-up
  TLS:      TLS  SNI=$DOMAIN  FingerPrint=chrome
  加密:     none

  ── 常用命令 ────────────────────────────────────────────
  查看 V2BX 日志:  journalctl -u v2bx -f
  重启 V2BX:       systemctl restart v2bx
  重启 Nginx:      systemctl restart nginx
  重新签发证书:    ~/.acme.sh/acme.sh --renew -d $DOMAIN --ecc --force

  ── 面板节点配置提醒 ────────────────────────────────────
  节点 TLS 类型:   无 (None)
  传输协议:        XHTTP
  path:            $PATH_VAL
  host:            $DOMAIN

SUMMARY
