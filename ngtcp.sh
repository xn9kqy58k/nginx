#!/bin/bash
# Nginx + Certbot 自动部署脚本（回落端口固定为 8443）
set -euo pipefail
IFS=$'\n\t'

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 权限运行"
  exit 1
fi

# -----------------------------
# 用户输入
# -----------------------------
read -p "申请证书域名 (example.com) : " DOMAIN
read -p "证书提醒邮箱: " EMAIL

# 回落端口固定
FALLBACK_PORT=8443

# -----------------------------
# 基本依赖安装
# -----------------------------
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y --no-install-recommends curl wget gnupg2 lsb-release software-properties-common apt-transport-https ca-certificates

# -----------------------------
# 检查 Nginx 是否支持 stream
# -----------------------------
install_official_nginx() {
  echo "⚠️ 当前 Nginx 不支持 stream，切换到官方版本..."
  apt remove -y nginx nginx-common nginx-core || true

  codename=$(lsb_release -cs)
  echo "deb http://nginx.org/packages/debian $codename nginx" > /etc/apt/sources.list.d/nginx.list
  curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add -

  apt update -y
  apt install -y nginx
}

if ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
  install_official_nginx
else
  echo "✅ 当前 Nginx 已支持 stream"
fi

# 安装 Certbot
apt install -y certbot python3-certbot-nginx openssl systemd

# 备份 nginx 配置
if [ -f /etc/nginx/nginx.conf ]; then
  mkdir -p /root/nginx-backups
  cp -a /etc/nginx/nginx.conf "/root/nginx-backups/nginx.conf.$(date +%s)"
fi

systemctl stop nginx || true

# -----------------------------
# 申请 TLS 证书
# -----------------------------
if ! certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --non-interactive; then
  echo "❌ 证书申请失败，请检查域名解析和防火墙。"
  exit 1
fi

# -----------------------------
# 伪装页
# -----------------------------
WWW_DIR="/var/www/$DOMAIN"
mkdir -p "$WWW_DIR"
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# -----------------------------
# 生成 nginx.conf
# -----------------------------
NGINX_CONF="/etc/nginx/nginx.conf"
cat > "$NGINX_CONF" <<'NGINX'
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

    gzip on;
    gzip_min_length 256;
    gzip_comp_level 4;
    gzip_proxied any;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;

    server {
        listen 127.0.0.1:%FALLBACK_PORT%;
        server_name localhost;

        root %WWW_DIR%;
        index index.html;

        location / {
            try_files $uri /index.html;
            allow 127.0.0.1;
            deny all;
        }
    }
}

stream {
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'EECDH+AESGCM:EECDH+CHACHA20:EECDH+AES256:!aNULL:!MD5:!DSS';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    server {
        listen 443 ssl reuseport;
        proxy_timeout 300s;
        proxy_protocol on;

        ssl_certificate /etc/letsencrypt/live/%DOMAIN%/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/%DOMAIN%/privkey.pem;

        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 1.1.1.1 8.8.8.8 valid=300s;
        resolver_timeout 5s;

        proxy_pass 127.0.0.1:1024;
    }
}
NGINX

sed -i "s|%FALLBACK_PORT%|$FALLBACK_PORT|g" "$NGINX_CONF"
sed -i "s|%WWW_DIR%|$WWW_DIR|g" "$NGINX_CONF"
sed -i "s|%DOMAIN%|$DOMAIN|g" "$NGINX_CONF"

nginx -t
systemctl restart nginx
systemctl enable nginx

# -----------------------------
# 自动续签
# -----------------------------
cat > /etc/systemd/system/certbot-renew.service <<SERVICE
[Unit]
Description=Certbot Renew and reload nginx

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --post-hook "/bin/systemctl reload nginx"
SERVICE

cat > /etc/systemd/system/certbot-renew.timer <<TIMER
[Unit]
Description=Run certbot renew daily

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now certbot-renew.timer

# -----------------------------
# 总结
# -----------------------------
cat <<SUMMARY
🎉 部署完成！
👉 域名: $DOMAIN
👉 本地回落端口: $FALLBACK_PORT
👉 伪装页路径: $WWW_DIR/index.html
👉 nginx 配置: $NGINX_CONF
👉 自动续签: systemd timer 每日 03:00
SUMMARY
