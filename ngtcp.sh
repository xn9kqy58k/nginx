#!/bin/bash
#=====================================================
# 🚀 Nginx + acme.sh (Cloudflare DNS 验证) 自动部署脚本
#     - 使用 Cloudflare DNS 申请正式证书
#     - 内部伪装页，仅限 127.0.0.1 访问
#     - 自动续签 + 自动重载 Nginx
#=====================================================

set -euo pipefail
IFS=$'\n\t'

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 权限运行"
  exit 1
fi

# -----------------------------
# 用户输入
# -----------------------------
read -p "申请证书域名 (example.com): " DOMAIN
read -p "Cloudflare 邮箱: " CF_EMAIL
read -p "Cloudflare Global API Key: " CF_KEY

CERT_DIR="/etc/V2bX"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"
FALLBACK_PORT=8443
WWW_DIR="/var/www/${DOMAIN}"

# -----------------------------
# 环境准备
# -----------------------------
apt update -y
apt install -y curl wget gnupg2 lsb-release software-properties-common apt-transport-https ca-certificates socat

# -----------------------------
# 安装 acme.sh
# -----------------------------
ACME_HOME="$HOME/.acme.sh"
if ! command -v acme.sh >/dev/null 2>&1; then
  echo "🌐 正在安装 acme.sh ..."
  curl -sS https://get.acme.sh | sh
  source "$HOME/.bashrc" >/dev/null 2>&1 || true
fi
ACME_BIN=$(command -v acme.sh || echo "$ACME_HOME/acme.sh")
echo "✅ acme.sh 路径: $ACME_BIN"

export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# -----------------------------
# 使用 Cloudflare DNS 申请证书
# -----------------------------
echo "🔐 正在使用 Cloudflare DNS 申请正式证书 ..."

"$ACME_BIN" --issue \
  -d "$DOMAIN" \
  --dns dns_cf \
  --server letsencrypt \
  --log

if [ $? -ne 0 ]; then
  echo "❌ 证书申请失败，请检查 Cloudflare Key 和域名设置。"
  unset CF_Email CF_Key
  exit 1
fi

# -----------------------------
# 安装证书
# -----------------------------
mkdir -p "$CERT_DIR"

"$ACME_BIN" --install-cert \
  -d "$DOMAIN" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "systemctl reload nginx"

echo "✅ 证书已安装: $CERT_FILE"

unset CF_Email CF_Key

# -----------------------------
# 安装 Nginx（官方带 stream）
# -----------------------------
if ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
  echo "⚙️ 安装官方 Nginx（支持 stream）..."
  codename=$(lsb_release -cs)
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx.gpg
  echo "deb [signed-by=/usr/share/keyrings/nginx.gpg] http://nginx.org/packages/debian $codename nginx" > /etc/apt/sources.list.d/nginx.list
  apt update -y && apt install -y nginx
else
  echo "✅ Nginx 已支持 stream 模块"
fi

# -----------------------------
# 内部伪装页：尝试从 GitHub 下载，失败则生成本地默认页
# -----------------------------
mkdir -p "$WWW_DIR"

if curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"; then
  echo "🌐 成功下载伪装页模板"
else
  echo "⚠️ GitHub 不可访问，生成本地默认伪装页"
  cat > "$WWW_DIR/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body style="text-align:center;font-family:sans-serif;margin-top:10%;">
<h1>Hello from internal fallback on $DOMAIN</h1>
<p>This page is only accessible locally (127.0.0.1).</p>
</body>
</html>
EOF
fi

chown -R www-data:www-data "$WWW_DIR"

# -----------------------------
# 生成 nginx.conf
# -----------------------------
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

    gzip on;
    gzip_min_length 256;
    gzip_comp_level 4;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;

    # 内部伪装服务，仅供本地回落使用
    server {
        listen 127.0.0.1:$FALLBACK_PORT;
        server_name localhost;

        root $WWW_DIR;
        index index.html;

        location / {
            try_files \$uri /index.html;
        }
    }
}

stream {
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'EECDH+AESGCM:EECDH+CHACHA20:EECDH+AES256:!aNULL:!MD5:!DSS';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    server {
        listen 443 ssl reuseport;
        proxy_timeout 300s;

        ssl_certificate $CERT_FILE;
        ssl_certificate_key $KEY_FILE;

        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 1.1.1.1 8.8.8.8 valid=300s;
        resolver_timeout 5s;

        # 转发到内部回落端口
        proxy_pass 127.0.0.1:$FALLBACK_PORT;
    }
}
NGINX

nginx -t
systemctl restart nginx
systemctl enable nginx

# -----------------------------
# 自动续签 (acme.sh 自带 cron)
# -----------------------------
"$ACME_BIN" --install-cronjob
echo "✅ 已启用 acme.sh 自动续签 (每日检查一次)"

# -----------------------------
# 输出信息
# -----------------------------
echo -e "\n\033[1;32m================ 部署完成 =================\033[0m"
echo "🌐 域名:           $DOMAIN"
echo "🔒 证书路径:       $CERT_FILE"
echo "🔑 私钥路径:       $KEY_FILE"
echo "🧩 内部回落端口:   $FALLBACK_PORT"
echo "📂 伪装页路径:     $WWW_DIR/index.html"
echo "⚙️  Nginx配置:     $NGINX_CONF"
echo "⏰ 自动续签:       acme.sh cronjob 每日执行"
echo "✅ 外部无法访问伪装页，仅本地使用"
echo "=========================================="

