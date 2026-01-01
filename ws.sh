#!/bin/bash
set -euo pipefail

echo "========================================================="
echo "🔐 TLS-only 诱饵证书 + WS 原样转发（XrayR）最终部署脚本"
echo "========================================================="

# -----------------------------
# 基础路径
# -----------------------------
ACME_HOME="/root/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"

CERT_BASE="/etc/V2bX/tls-only"
NGINX_CONF_DIR="/etc/nginx/conf.d"

mkdir -p "$CERT_BASE" "$NGINX_CONF_DIR"

# -----------------------------
# 输入参数
# -----------------------------
read -rp "TLS-only 诱饵域名（仅用于握手）: " TLS_DOMAIN
read -rp "VLESS WS 域名（由 XrayR 管证书）: " VLESS_DOMAIN
read -rp "WS 路径（如 /api/stream）: " WS_PATH
read -rp "XrayR 监听端口（如 10000）: " XRAYR_PORT
read -rp "Cloudflare 邮箱: " CF_EMAIL
read -rsp "Cloudflare Global API Key: " CF_KEY
echo

if [[ -z "$TLS_DOMAIN" || -z "$VLESS_DOMAIN" || -z "$WS_PATH" || -z "$XRAYR_PORT" ]]; then
    echo "❌ 参数不完整，退出"
    exit 1
fi

export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# -----------------------------
# 安装 acme.sh
# -----------------------------
if [ ! -x "$ACME_BIN" ]; then
    echo "--- ⬇️ 安装 acme.sh ---"
    curl -sS https://get.acme.sh | sh
fi

# -----------------------------
# 申请 TLS-only 证书（唯一一个）
# -----------------------------
echo "--- 🌐 申请 TLS-only 诱饵证书 ---"

"$ACME_BIN" --register-account -m "$CF_EMAIL" --server letsencrypt || true

"$ACME_BIN" --issue \
    -d "$TLS_DOMAIN" \
    --dns dns_cf \
    --server letsencrypt

"$ACME_BIN" --install-cert \
    -d "$TLS_DOMAIN" \
    --key-file       "$CERT_BASE/key.pem" \
    --fullchain-file "$CERT_BASE/fullchain.pem"

# -----------------------------
# 生成 Nginx 配置
# -----------------------------
echo "--- 🧩 生成 Nginx 配置 ---"

# TLS-only 探测吸收
cat > "$NGINX_CONF_DIR/00-tls-only.conf" <<EOF
server {
    listen 443 ssl;
    server_name $TLS_DOMAIN;

    ssl_certificate     $CERT_BASE/fullchain.pem;
    ssl_certificate_key $CERT_BASE/key.pem;

    return 444;
}
EOF

# WS 原样转发（TLS 在 XrayR 终止）
cat > "$NGINX_CONF_DIR/10-vless-ws.conf" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443;
    server_name $VLESS_DOMAIN;

    location $WS_PATH {
        proxy_pass http://127.0.0.1:$XRAYR_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_buffering off;
    }

    location / {
        return 444;
    }
}
EOF

# -----------------------------
# 检查并重载 Nginx
# -----------------------------
echo "--- 🔍 检查 Nginx 配置 ---"
nginx -t

echo "--- 🔄 重载 Nginx ---"
systemctl reload nginx

unset CF_Email CF_Key

echo "========================================================="
echo "✅ 部署完成（正式上线状态）"
echo
echo "🔹 TLS-only 诱饵域名：$TLS_DOMAIN"
echo "   行为：TLS 成功 → 立即断开"
echo
echo "🔹 VLESS WS 域名：$VLESS_DOMAIN"
echo "   路径：$WS_PATH"
echo "   转发：127.0.0.1:$XRAYR_PORT"
echo "   证书：由 XrayR 自行管理"
echo
echo "👉 Nginx 仅负责吸收与转发，不参与代理证书"
echo "========================================================="
