#!/bin/bash
# 自动化部署 Nginx + TLS 前置 + 内部回落网页
# 支持 Debian/Ubuntu 系统
# 用于 Trojan/XrayR 架构

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 权限运行"
    exit 1
fi

read -p "请输入域名（例: example.com）: " DOMAIN
read -p "请输入邮箱（用于证书通知）: " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "❌ 域名和邮箱不能为空"
    exit 1
fi

echo "📦 更新 apt 并安装基础软件..."
apt update -y
apt install -y curl wget gnupg2 lsb-release software-properties-common

echo "📦 安装 Nginx 和 Certbot..."
apt install -y nginx certbot python3-certbot-nginx

# 停止 Nginx，避免端口占用
systemctl stop nginx

# 申请证书（standalone 模式）
echo "🔑 申请 TLS 证书..."
certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --non-interactive

# 创建伪装页
WWW_DIR="/var/www/html"
mkdir -p "$WWW_DIR"
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# 备份原 nginx.conf
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

# 写入 nginx.conf
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

# -----------------------------
# Stream 模块：TLS 443 转发到 XrayR
# -----------------------------
stream {
    server {
        listen 443 ssl;
        proxy_timeout 300s;

        # 使用 Certbot 证书
        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;

        # 保留原始客户端 IP
        proxy_protocol on;

        # 转发到 XrayR 本地端口（明文）
        proxy_pass 127.0.0.1:1024;
    }
}

# -----------------------------
# HTTP 模块：内部回落网页
# -----------------------------
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    keepalive_timeout 65;

    # 日志
    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    # 回落网页配置
    server {
        listen 8443;  # 内部回落，不暴露公网
        server_name localhost;

        root /var/www/html;
        index index.html;

        location / {
            try_files \$uri \$uri/ =404;
        }

        access_log /var/log/nginx/fallback.access.log;
        error_log  /var/log/nginx/fallback.error.log info;
    }
}
EOF

# 去掉不可见字符
sed -i 's/[\r]//g' /etc/nginx/nginx.conf

# 启动 Nginx
nginx -t && systemctl restart nginx && systemctl enable nginx

# 自动续签
echo "0 3 * * * root certbot renew --quiet && systemctl reload nginx" > /etc/cron.d/certbot-renew
systemctl restart cron || systemctl restart crond

echo "🎉 部署完成！"
echo "👉 域名: $DOMAIN"
echo "👉 伪装网页: $WWW_DIR/index.html"
echo "🔄 TLS 证书每天凌晨 3 点自动续签"
