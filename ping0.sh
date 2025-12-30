#!/bin/bash
set -euo pipefail

echo "======================================================"
echo "🚀 Ping0 原生 IP 终极反代 + DNS SSL 自动化脚本"
echo "======================================================"

# ========= 基础变量 =========
ACME_HOME="/root/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"

NGINX_SSL="/etc/nginx/ssl"
CERT_FILE="$NGINX_SSL/fullchain.pem"
KEY_FILE="$NGINX_SSL/privkey.pem"

UPSTREAM_HOST="ping0.ipyard.com"
UPSTREAM_URL="https://ping0.ipyard.com"

# ========= 用户输入 =========
read -rp "请输入你的域名 (如 ping0.cc): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_EMAIL
read -rsp "请输入 Cloudflare Global API Key: " CF_KEY
echo

if [[ -z "$DOMAIN" || -z "$CF_EMAIL" || -z "$CF_KEY" ]]; then
    echo "❌ 参数不能为空"
    exit 1
fi

export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# ========= 安装依赖 =========
echo "⚙️ 安装依赖..."
apt update -y
apt install -y nginx curl cron ca-certificates

# ========= 初始 Nginx HTTP =========
cat >/etc/nginx/conf.d/ping0.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass $UPSTREAM_URL;
        proxy_set_header Host $UPSTREAM_HOST;
        proxy_set_header Accept-Encoding "";
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# ========= 安装 acme.sh =========
if [ ! -x "$ACME_BIN" ]; then
    echo "⬇️ 安装 acme.sh..."
    curl -sS https://get.acme.sh | sh
fi

# ========= DNS 申请证书 =========
echo "🔐 通过 Cloudflare DNS 申请证书..."
mkdir -p "$NGINX_SSL"

"$ACME_BIN" --register-account -m "$CF_EMAIL" || true

"$ACME_BIN" --issue \
    --dns dns_cf \
    -d "$DOMAIN" \
    --server letsencrypt

"$ACME_BIN" --install-cert -d "$DOMAIN" \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd "systemctl reload nginx"

# ========= 终极 HTTPS 配置 =========
cat >/etc/nginx/conf.d/ping0.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    server_tokens off;

    location / {
        proxy_pass $UPSTREAM_URL;
        proxy_set_header Host $UPSTREAM_HOST;

        # ===== 核心：IP 纯净 =====
        proxy_set_header X-Real-IP "";
        proxy_set_header X-Forwarded-For "";
        proxy_set_header X-Forwarded-Proto "";
        proxy_set_header REMOTE-HOST "";

        proxy_http_version 1.1;

        # 禁用压缩（sub_filter 生效关键）
        proxy_set_header Accept-Encoding "";

        # ===== 内容层彻底伪装 =====
        sub_filter_once off;
        sub_filter '<span class="label orange" style="background: rgb(255, 170, 0);">广播 IP</span>' \
                   '<span class="label orange" style="background: limegreen;">原生 IP</span>';
        sub_filter '广播 IP' '原生 IP';
        sub_filter '$UPSTREAM_HOST' '$DOMAIN';

        # ===== 去指纹 =====
        proxy_hide_header Server;
        proxy_hide_header X-Powered-By;
        proxy_hide_header Via;
        proxy_hide_header X-Cache;
    }
}
EOF

nginx -t && systemctl restart nginx

# ========= 自动续签 =========
(crontab -l 2>/dev/null | grep -v acme.sh || true; \
echo "0 3 * * * $ACME_BIN --cron --home $ACME_HOME > /dev/null 2>&1") | crontab -

echo "======================================================"
echo "✅ 部署完成"
echo "🌐 https://$DOMAIN"
echo "📌 ping0 显示：100% 原生 IP"
echo "🔁 DNS SSL 自动续签已启用"
echo "======================================================"
