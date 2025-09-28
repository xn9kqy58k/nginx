#!/bin/bash
# ===============================================================
# 自动化部署 Nginx + TLS + Stream + Certbot 
# Debian 系统 VPS 批量部署
# 自动处理端口占用
# 域名和邮箱运行时输入
# ===============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行脚本"
    exit 1
fi

# -----------------------------
# 用户输入域名和邮箱
# -----------------------------
read -p "请输入要申请证书的域名（例如: example.com）: " DOMAIN
read -p "请输入邮箱（用于证书通知）: " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "❌ 域名和邮箱不能为空"
    exit 1
fi

# -----------------------------
# 更新系统并安装基础软件
# -----------------------------
echo "📦 更新 apt 并安装基础软件..."
apt update -y
apt install -y curl wget git lsb-release gnupg2 software-properties-common unzip

# -----------------------------
# 添加 Nginx 官方仓库并安装 Nginx
# -----------------------------
echo "🏗️ 添加 Nginx 官方仓库并安装最新稳定版 Nginx..."
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list
apt update -y
apt install -y nginx

# -----------------------------
# 安装 Certbot
# -----------------------------
echo "🔑 安装 Certbot..."
apt install -y certbot python3-certbot-nginx

# -----------------------------
# 检查 80/443 端口是否被占用
# -----------------------------
echo "🔍 检查 80/443 端口占用..."
OCCUPIED_SERVICES=()
for PORT in 80 443; do
    PID=$(lsof -ti tcp:$PORT)
    if [ -n "$PID" ]; then
        SERVICE=$(ps -p $PID -o comm=)
        echo "⚠️ 端口 $PORT 被 $SERVICE 占用，已停止"
        systemctl stop $SERVICE 2>/dev/null
        OCCUPIED_SERVICES+=($SERVICE)
    fi
done

# -----------------------------
# 停止 Nginx，避免端口冲突
# -----------------------------
systemctl stop nginx

# -----------------------------
# 申请 SSL 证书（standalone 模式）
# -----------------------------
echo "🔑 正在申请 SSL 证书..."
certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --non-interactive
if [ $? -ne 0 ]; then
    echo "❌ 证书申请失败，请检查域名解析和 80 端口"
    # 恢复占用服务
    for S in "${OCCUPIED_SERVICES[@]}"; do
        systemctl start $S
    done
    exit 1
fi

# 恢复原本占用服务
for S in "${OCCUPIED_SERVICES[@]}"; do
    systemctl start $S
done

# -----------------------------
# 创建伪装网页
# -----------------------------
WWW_DIR="/var/www/html"
mkdir -p "$WWW_DIR"
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"
echo "🌐 伪装页已创建：$WWW_DIR/index.html"

# -----------------------------
# 写入 Nginx 配置
# -----------------------------
CONF_FILE="/etc/nginx/conf.d/trojan-grpc.conf"
cat > "$CONF_FILE" <<EOF
# -----------------------------
# Stream 模块：TLS 443 转发到 XrayR/Trojan
# -----------------------------
stream {
    server {
        listen 443 ssl;
        proxy_timeout 300s;

        ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;

        proxy_protocol on;

        proxy_pass 127.0.0.1:1024;
    }
}

# -----------------------------
# HTTP 模块：回落网页
# -----------------------------
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    keepalive_timeout 65;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    server {
        listen 8443;  # 内部回落端口
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

# -----------------------------
# 测试并启动 Nginx
# -----------------------------
sed -i 's/[\r]//g' "$CONF_FILE"
nginx -t && systemctl restart nginx && systemctl enable nginx
echo "✅ Nginx 配置已生效"

# -----------------------------
# 设置证书自动续签
# -----------------------------
echo "0 3 * * * root certbot renew --quiet && systemctl reload nginx" > /etc/cron.d/certbot-renew
systemctl restart cron || systemctl restart crond

# -----------------------------
# 部署完成提示
# -----------------------------
echo "🎉 部署完成！"
echo "👉 域名: $DOMAIN"
echo "👉 配置文件: $CONF_FILE"
echo "👉 伪装页面: $WWW_DIR/index.html"
echo "🔄 证书每天凌晨 3 点自动续签"
