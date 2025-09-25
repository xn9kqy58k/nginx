#!/bin/bash
# =============================
# 稳妥版 Trojan-gRPC 部署脚本
# 半自动化：先启动默认 Nginx，再申请证书
# =============================

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 权限运行"
    exit 1
fi

# 交互输入
read -p "请输入域名（例如: example.com）: " DOMAIN
read -p "请输入邮箱（用于证书通知）: " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "❌ 域名和邮箱不能为空"
    exit 1
fi

echo "📦 安装依赖：Nginx + Certbot"
apt update -y
apt install -y nginx certbot python3-certbot-nginx curl wget cron

# 创建伪装页
WWW_DIR="/var/www/html"
mkdir -p "$WWW_DIR"
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# 启动默认 Nginx，确保 80 端口可访问
systemctl enable nginx
systemctl restart nginx

# 测试 80 端口是否可访问
echo "🌐 测试域名是否解析到本 VPS..."
sleep 2
if ! curl -sI "http://$DOMAIN" | grep -q "200\|301\|302"; then
    echo "⚠️ 域名 $DOMAIN 可能没有正确解析到当前 VPS 或 80 端口被阻挡"
    echo "请先确保域名解析到本 VPS，并开放 80 端口"
    read -p "确认后按回车继续，或 Ctrl+C 退出"
fi

# 申请证书（webroot 模式，先启动默认页面保证申请成功）
echo "🔑 正在申请 SSL 证书..."
certbot certonly --webroot -w "$WWW_DIR" -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive
if [ $? -ne 0 ]; then
    echo "❌ 证书申请失败，请检查域名解析和 80 端口"
    exit 1
fi

# 写完整 Nginx 配置
CONF_FILE="/etc/nginx/conf.d/trojan-grpc.conf"
cat > "$CONF_FILE" <<EOF
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

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        listen 443 ssl default_server;
        listen [::]:443 ssl default_server;
        server_name _;

        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

        return 444;
    }
}
EOF

# 检查并重启 Nginx
echo "🔍 检查 Nginx 配置..."
nginx -t && systemctl restart nginx

# 设置证书自动续签
cat > /etc/cron.d/certbot-renew <<CRON
0 3 * * * root certbot renew --quiet && systemctl reload nginx
CRON
systemctl enable cron
systemctl restart cron

echo "🎉 部署完成！Trojan-gRPC 已启用"
echo "👉 域名: $DOMAIN"
echo "👉 配置文件: $CONF_FILE"
echo "👉 伪装页面: $WWW_DIR/index.html"
echo "🔄 证书每天凌晨 3 点自动续签"


echo "🎉 部署完成！Trojan-gRPC 已启用"
echo "👉 域名: $DOMAIN"
echo "👉 配置文件: $CONF_FILE"
echo "👉 伪装页面: $WWW_DIR/index.html"
