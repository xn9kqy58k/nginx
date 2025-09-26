#!/bin/bash
# 自动化部署 Nginx + ssl)

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 权限运行"
    exit 1
fi

# 输入域名和邮箱
read -p "请输入域名（例如: example.com）: " DOMAIN
read -p "请输入邮箱（用于证书通知）: " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "❌ 域名和邮箱不能为空"
    exit 1
fi

# 安装组件
echo "📦 安装 Nginx 和 Certbot..."
apt update -y
apt install -y nginx certbot python3-certbot-nginx curl wget

# 停止 Nginx，避免端口占用
systemctl stop nginx

# 申请证书（standalone 模式）
echo "🔑 正在申请 SSL 证书 (Standalone 模式)..."
certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --non-interactive
if [ $? -ne 0 ]; then
    echo "❌ 证书申请失败，请检查域名解析和 80 端口"
    exit 1
fi

# 创建伪装页
WWW_DIR="/var/www/html"
mkdir -p "$WWW_DIR"
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# 写 Nginx 配置
CONF_FILE="/etc/nginx/conf.d/trojan-grpc.conf"
cat > "$CONF_FILE" <<EOF
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
        grpc_connect_timeout 120s;
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
EOF

# 去掉不可见字符
sed -i 's/[\r]//g' "$CONF_FILE"

# 启动 Nginx
nginx -t && systemctl restart nginx && systemctl enable nginx

# 自动续签
echo "0 3 * * * root certbot renew --quiet && systemctl reload nginx" > /etc/cron.d/certbot-renew
systemctl restart cron || systemctl restart crond

echo "🎉 部署完成！Trojan-gRPC 已启用"
echo "👉 域名: $DOMAIN"
echo "👉 配置文件: $CONF_FILE"
echo "👉 伪装页面: $WWW_DIR/index.html"
echo "🔄 证书每天凌晨 3 点自动续签"
