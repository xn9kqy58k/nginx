#!/bin/bash
# Trojan-gRPC 一键部署脚本（webroot方式申请证书，支持命令行传入域名和邮箱）

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 权限运行此脚本"
    exit 1
fi

# 获取命令行参数
DOMAIN=$1
EMAIL=$2

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "❌ 使用方法: bash $0 <域名> <邮箱>"
    echo "例如: bash $0 example.com you@example.com"
    exit 1
fi

echo "✅ 使用域名: $DOMAIN"
echo "✅ 使用邮箱: $EMAIL"

# 安装依赖
apt update -y
apt install -y nginx certbot python3-certbot-nginx curl wget cron

# 创建伪装页目录
WWW_DIR="/var/www/html"
mkdir -p "$WWW_DIR"
cd "$WWW_DIR" || exit 1

# 下载伪装页面
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o index.html
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# 启动 Nginx 默认站点，确保 80 端口可访问
systemctl enable nginx
systemctl restart nginx

# 先用 webroot 模式申请证书
echo "🔑 正在申请 SSL 证书（webroot 模式）..."
certbot certonly --webroot -w "$WWW_DIR" -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive
if [ $? -ne 0 ]; then
    echo "❌ 证书申请失败，请检查域名解析和端口"
    exit 1
fi

# 写完整 Nginx 配置
CONF_FILE="/etc/nginx/conf.d/trojan-grpc.conf"
cat > $CONF_FILE <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log combined;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 3600s;
    server_tokens off;

    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy no-referrer-when-downgrade;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' data:;";

    upstream grpc_backend {
        server 127.0.0.1:1024;
        keepalive 100;
    }

    server {
        listen 80;
        listen [::]:80;
        server_name $DOMAIN;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name $DOMAIN;

        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers 'ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-GCM-SHA256:!aNULL:!MD5:!3DES';
        ssl_prefer_server_ciphers on;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;

        location /grpc {
            grpc_pass grpc://grpc_backend;
            grpc_set_header Host \$host;
            grpc_set_header X-Real-IP \$remote_addr;
            grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            grpc_set_header X-Forwarded-Proto https;
            grpc_set_header TE trailers;
            grpc_connect_timeout 60s;
            grpc_send_timeout 3600s;
            grpc_read_timeout 3600s;
        }

        location / {
            root /var/www/html;
            index index.html;
            try_files \$uri /index.html;
            default_type text/html;
            add_header Cache-Control "no-cache";
        }
    }
}
EOF

# 检查配置并重载 Nginx
nginx -t && systemctl reload nginx

# 自动续签
cat > /etc/cron.d/certbot-renew <<CRON
0 3 * * * root certbot renew --quiet && systemctl reload nginx
CRON
systemctl enable cron
systemctl restart cron

echo "🎉 部署完成！Trojan-gRPC 已启用"
echo "👉 域名: $DOMAIN"
echo "👉 配置文件: $CONF_FILE"
echo "👉 伪装页面: /var/www/html/index.html"
echo "🔄 证书每天凌晨 3 点自动检查续签"
