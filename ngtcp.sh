#!/bin/bash
# ==============================================================================
# V2bX + Nginx + Cloudflare DNS 一键部署脚本（终结版 v3）
#
# 架构：
#   客户端 :443
#     └─ Nginx stream ssl 终结 TLS（Chrome 对齐 cipher 顺序）
#          └─ proxy_protocol → V2bX :1024（明文 Trojan）
#               └─ EnableFallback → 反代真实网站 :8080（V2bX 处理回落）
#
# 本版新增优化：
#   ✅ ssl_ciphers 顺序对齐 Chrome，被动 TLS 指纹更难命中
#   ✅ 伪装站改为反代真实网站（响应体/header/时序与真实站一致）
#   ✅ 反代目标可自定义，默认 www.example.com
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── 权限检查 ──────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 权限运行" >&2
  exit 1
fi

# ── 常量定义 ──────────────────────────────────────────────────────────────────
CERT_DIR="/etc/V2bX"
ACME_HOME="$HOME/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"
TROJAN_PORT=1024    # V2bX 监听（仅 127.0.0.1，接收 Nginx 转发的明文）
FALLBACK_PORT=8080  # 伪装站 HTTP 端口（仅 127.0.0.1，由 V2bX 回落触达）
NGINX_CONF="/etc/nginx/nginx.conf"

echo "=== V2bX + Nginx + Cloudflare DNS 一键部署（终结版 v3）==="

# ── 交互输入 ──────────────────────────────────────────────────────────────────
read -rp "请输入域名 (example.com): "                   DOMAIN
read -rp "请输入 Cloudflare 邮箱: "                     CF_EMAIL
read -rp "请输入 Cloudflare Global API Key: "            CF_KEY
read -rp "请输入伪装反代目标域名 (如 www.bing.com): "    CAMOUFLAGE_HOST

if [ -z "$DOMAIN" ] || [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ] || [ -z "$CAMOUFLAGE_HOST" ]; then
  echo "❌ 输入不能为空" >&2
  exit 1
fi

# ── 端口占用检测 ───────────────────────────────────────────────────────────────
for PORT in 443 "$TROJAN_PORT" "$FALLBACK_PORT"; do
  if ss -tlnp | awk '{print $4}' | grep -q ":${PORT}$"; then
    echo "❌ 端口 $PORT 已被占用，请先释放后再运行" >&2
    exit 1
  fi
done

# ── 证书路径冲突检测 ───────────────────────────────────────────────────────────
SKIP_CERT=false
if [ -f "$CERT_FILE" ] || [ -f "$KEY_FILE" ]; then
  echo "⚠️  检测到已有证书文件："
  [ -f "$CERT_FILE" ] && echo "    $CERT_FILE"
  [ -f "$KEY_FILE"  ] && echo "    $KEY_FILE"
  read -rp "是否覆盖重新申请？[y/N]: " OVERWRITE
  [[ "${OVERWRITE,,}" == "y" ]] && SKIP_CERT=false || SKIP_CERT=true
  [ "$SKIP_CERT" = true ] && echo "ℹ️  跳过证书申请，使用现有证书继续部署。"
fi

# ── 安装依赖 ──────────────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y curl wget gnupg2 lsb-release \
  software-properties-common apt-transport-https ca-certificates

# ── 安装 acme.sh ──────────────────────────────────────────────────────────────
if [ ! -f "$ACME_BIN" ]; then
  echo "📦 正在安装 acme.sh ..."
  curl -fsSL https://get.acme.sh | sh -s -- install --home "$ACME_HOME"
fi
echo "✅ acme.sh: $ACME_BIN"

# ── 申请证书 ──────────────────────────────────────────────────────────────────
if [ "$SKIP_CERT" = false ]; then
  echo "📜 正在申请证书（Let's Encrypt）..."
  export CF_Email="$CF_EMAIL"
  export CF_Key="$CF_KEY"

  "$ACME_BIN" --issue \
    -d "$DOMAIN" \
    --dns dns_cf \
    --server letsencrypt \
    --home "$ACME_HOME" \
    --log

  unset CF_Email CF_Key   # 申请完立即清除

  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"

  "$ACME_BIN" --install-cert -d "$DOMAIN" \
    --home "$ACME_HOME" \
    --key-file       "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd      "nginx -s reload || true"

  chmod 600 "$KEY_FILE" "$CERT_FILE"
else
  unset CF_Email CF_Key 2>/dev/null || true
fi

# ── 安装官方 Nginx（含 stream_ssl 模块）──────────────────────────────────────
install_nginx_official() {
  local CODENAME
  CODENAME=$(lsb_release -cs)
  curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor > /usr/share/keyrings/nginx-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/debian $CODENAME nginx" \
    > /etc/apt/sources.list.d/nginx.list
  apt-get update -y
  apt-get install -y nginx
}

NGINX_OK=true
command -v nginx &>/dev/null || NGINX_OK=false
if [ "$NGINX_OK" = true ]; then
  nginx -V 2>&1 | grep -q -- '--with-stream_ssl_module' || NGINX_OK=false
fi
if [ "$NGINX_OK" = false ]; then
  echo "⚙️  安装官方 Nginx（含 stream_ssl 模块）..."
  install_nginx_official
fi

# ── 生成 Nginx 配置 ────────────────────────────────────────────────────────────
cat > "$NGINX_CONF" <<NGINX
# ── 顶层 ──────────────────────────────────────────────────────────────────────
user www-data;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 65536;

events {
    worker_connections 4096;
    multi_accept on;
}

# ── HTTP 层：反代伪装站（仅本地，由 V2bX fallback 触达）──────────────────────
#
# [优化] 改为反代真实网站，而非本地静态页：
#   - 响应体、header、时序完全来自真实站，GFW 主动探测无法与真实网站区分
#   - proxy_set_header Host 设为目标域名，确保反代请求正常响应
#   - 仅监听 127.0.0.1，外部无法绕过 stream 层直连
#
http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile     on;
    tcp_nopush   on;
    tcp_nodelay  on;
    keepalive_timeout 65;
    server_tokens off;

    server {
        listen 127.0.0.1:${FALLBACK_PORT};
        server_name ${DOMAIN};

        location / {
            proxy_pass         https://${CAMOUFLAGE_HOST};
            proxy_set_header   Host ${CAMOUFLAGE_HOST};
            proxy_set_header   X-Real-IP \$remote_addr;
            proxy_ssl_server_name on;      # SNI 传目标域名，避免证书校验失败

            # HTTP/1.1（Trojan 回落要求，h2 会导致回落失败）
            proxy_http_version 1.1;
            proxy_set_header   Connection "";

            # 超时配置
            proxy_connect_timeout 10s;
            proxy_read_timeout    60s;
        }
    }
}

# ── Stream 层：TLS 终结 → proxy_protocol → V2bX ──────────────────────────────
#
# [优化] ssl_ciphers 顺序对齐 Chrome ClientHello：
#   TLS 1.3 suite 优先，TLS 1.2 顺序与 Chrome 保持一致
#   被动流量指纹分析更难命中 "非浏览器" 特征
#
stream {
    log_format stream_log '\$remote_addr [\$time_local] \$protocol '
                          '\$status \$bytes_sent \$bytes_received \$session_time';
    access_log /var/log/nginx/stream.log stream_log;

    server {
        listen 443 ssl reuseport;

        ssl_certificate     ${CERT_FILE};
        ssl_certificate_key ${KEY_FILE};

        # Chrome 对齐 cipher 顺序
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers off;   # 关闭！让客户端顺序优先，更接近真实浏览器行为

        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;
        ssl_session_tickets off;

        ssl_stapling        on;
        ssl_stapling_verify on;
        resolver            1.1.1.1 8.8.8.8 valid=300s;
        resolver_timeout    5s;

        proxy_timeout         300s;
        proxy_connect_timeout 10s;

        # proxy_protocol：将真实客户端 IP 传给 V2bX（V2bX 需 EnableProxyProtocol: true）
        proxy_protocol on;

        proxy_pass 127.0.0.1:${TROJAN_PORT};
    }
}
NGINX

# ── 验证并启动 Nginx ──────────────────────────────────────────────────────────
nginx -t
systemctl enable nginx
systemctl restart nginx

# ── 自动续签（systemd timer）─────────────────────────────────────────────────
cat > /etc/systemd/system/acme-renew.service <<SERVICE
[Unit]
Description=acme.sh certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=${ACME_BIN} --cron --home ${ACME_HOME} --reloadcmd "nginx -s reload"
SERVICE

cat > /etc/systemd/system/acme-renew.timer <<TIMER
[Unit]
Description=Daily acme.sh renewal at 03:00

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now acme-renew.timer

# ── 完成提示 ──────────────────────────────────────────────────────────────────
echo ""
echo "✅ Nginx 部署完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  域名          : $DOMAIN"
echo "  证书          : $CERT_FILE"
echo "  私钥          : $KEY_FILE"
echo "  伪装反代目标  : $CAMOUFLAGE_HOST"
echo "  Nginx 配置    : $NGINX_CONF"
echo "  自动续签      : 每天 03:00（systemd timer）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  📋 V2bX ControllerConfig 关键配置（请对照修改）："
echo ""
echo "    ListenIP: 127.0.0.1"
echo "    EnableProxyProtocol: true"
echo "    EnableFallback: true"
echo "    FallBackConfigs:"
echo "      - SNI: $DOMAIN"
echo "        Dest: 127.0.0.1:$FALLBACK_PORT"
echo "        ProxyProtocolVer: 0"
echo "    CertConfig:"
echo "      CertMode: none"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ⚠️  回落站点已强制 HTTP/1.1，勿在 http 块开启 h2"
echo "  ⚠️  伪装反代目标建议选知名网站（bing/apple/cloudflare）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
