#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 权限运行"
  exit 1
fi

CERT_DIR="/etc/V2bX"
ACME_HOME="$HOME/.acme.sh"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"
FALLBACK_PORT=8443
TROJAN_PORT=1024

echo "=== V2bX + Nginx + Cloudflare DNS 一键部署 ==="

read -p "请输入域名 (example.com): " DOMAIN
read -p "请输入 Cloudflare 邮箱: " CF_EMAIL
read -p "请输入 Cloudflare Global API Key: " CF_KEY

if [ -z "$DOMAIN" ] || [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
  echo "❌ 输入不能为空"
  exit 1
fi

# 安装依赖
apt update -y
apt install -y curl wget gnupg2 lsb-release software-properties-common apt-transport-https ca-certificates

# --- 检查并安装 acme.sh ---
ACME_BIN=$(command -v acme.sh 2>/dev/null || echo "$ACME_HOME/acme.sh")
if [ ! -f "$ACME_BIN" ]; then
  echo "📦 正在安装 acme.sh ..."
  curl -sS https://get.acme.sh | sh -s -- install
  source ~/.bashrc >/dev/null 2>&1 || true
  ACME_BIN="$ACME_HOME/acme.sh"
fi
echo "✅ acme.sh 路径: $ACME_BIN"

# --- 环境变量 ---
export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# --- 使用 Cloudflare DNS 验证申请正式证书 ---
echo "📜 正在申请证书（Let's Encrypt 正式环境）..."
"$ACME_BIN" --issue -d "$DOMAIN" --dns dns_cf --server letsencrypt --log

mkdir -p "$CERT_DIR"
"$ACME_BIN" --install-cert -d "$DOMAIN" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "nginx -s reload || true"

unset CF_Email; unset CF_Key

# --- 安装 Nginx 官方版本 ---
if ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
  echo "⚙️ 当前 Nginx 不支持 stream，切换官方源安装..."
  codename=$(lsb_release -cs)
  echo "deb http://nginx.org/packages/debian $codename nginx" > /etc/apt/sources.list.d/nginx.list
  curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add -
  apt update -y
  apt install -y nginx
fi

# --- 伪装页 ---
WWW_DIR="/var/www/$DOMAIN"
mkdir -p "$WWW_DIR"
if ! curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"; then
  echo "<h1>Hello from internal fallback on $DOMAIN</h1>" > "$WWW_DIR/index.html"
fi
chown -R www-data:www-data "$WWW_DIR"

# --- Nginx 配置 ---
NGINX_CONF="/etc/nginx/nginx.conf"
cat > "$NGINX_CONF" <<NGINX
user  www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
}

worker_rlimit_nofile 65536;

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 65;

    server_tokens off;

    server {
        listen 127.0.0.1:${FALLBACK_PORT};
        server_name localhost;
        root ${WWW_DIR};
        index index.html;
        location / {
            try_files \$uri /index.html;
            allow 127.0.0.1;
            deny all;
        }
    }
}

stream {
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'EECDH+AESGCM:EECDH+CHACHA20:!aNULL:!MD5:!DSS';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    server {
        listen 443 ssl reuseport proxy_protocol;
        proxy_timeout 300s;

        ssl_certificate ${CERT_FILE};
        ssl_certificate_key ${KEY_FILE};

        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 1.1.1.1 8.8.8.8 valid=300s;
        resolver_timeout 5s;

        proxy_pass 127.0.0.1:${TROJAN_PORT};
    }
}
NGINX

# --- 启动 nginx ---
nginx -t
systemctl enable nginx
systemctl restart nginx

# --- 自动续签 ---
cat > /etc/systemd/system/acme-renew.service <<SERVICE
[Unit]
Description=acme.sh Renew Certificates and Reload Nginx
After=network-online.target

[Service]
Type=oneshot
ExecStart=${ACME_BIN} --cron --home ${ACME_HOME} --reloadcmd "nginx -s reload"
SERVICE

cat > /etc/systemd/system/acme-renew.timer <<TIMER
[Unit]
Description=Run acme.sh renew daily

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now acme-renew.timer

# --- 总结 ---
echo "✅ 部署完成！"
echo "域名: $DOMAIN"
echo "证书路径: $CERT_FILE"
echo "私钥路径: $KEY_FILE"
echo "伪装页路径: $WWW_DIR/index.html"
echo "Nginx 配置: $NGINX_CONF"
echo "自动续签: 每天凌晨 3 点"
echo "Trojan 服务请监听 127.0.0.1:${TROJAN_PORT}"
echo "本地回落端口: ${FALLBACK_PORT}"
