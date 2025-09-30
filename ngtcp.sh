#!/bin/bash
# 更安全、更高性能、伪装更强的 Nginx + Certbot + V2bX 自动部署脚本
# 自动检测并安装支持 stream 的 Nginx 版本
set -euo pipefail
IFS=$'\n\t'

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 权限运行"
  exit 1
fi

# -----------------------------
# 用户输入（保持简单交互）
# -----------------------------
read -p "申请证书域名  : " DOMAIN
read -p "证书提醒邮箱: " EMAIL
read -p "请输入对接面板网址 (https://) : " API_DOMAIN
read -p "请输入对接面板密钥 : " APIKEY
read -p "请输入节点 NodeID: " NODEID

# 随机化回落端口
FALLBACK_PORT=$(shuf -i 20000-60000 -n 1)

# -----------------------------
# 基本依赖安装
# -----------------------------
echo "📦 更新 apt 并安装必要包..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y --no-install-recommends curl wget gnupg2 lsb-release software-properties-common apt-transport-https ca-certificates

# -----------------------------
# 检查 Nginx 是否支持 stream
# -----------------------------
install_official_nginx() {
  echo "⚠️ 检测到当前 Nginx 不支持 stream，切换到官方版本..."
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

# 继续安装 Certbot
apt install -y certbot python3-certbot-nginx openssl systemd

# -----------------------------
# 备份现有 nginx 配置
# -----------------------------
if [ -f /etc/nginx/nginx.conf ]; then
  mkdir -p /root/nginx-backups
  cp -a /etc/nginx/nginx.conf "/root/nginx-backups/nginx.conf.$(date +%s)"
  echo "📦 已备份 /etc/nginx/nginx.conf 到 /root/nginx-backups/"
fi

systemctl stop nginx || true

# -----------------------------
# 申请证书
# -----------------------------
echo "🔑 申请 TLS 证书（standalone 模式）..."
if ! certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --non-interactive; then
  echo "❌ 证书申请失败，请检查域名解析与防火墙。"
  exit 1
fi

# -----------------------------
# 伪装页
# -----------------------------
WWW_DIR="/var/www/$DOMAIN"
mkdir -p "$WWW_DIR"
if curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"; then
  echo "✅ 已从 GitHub 下载伪装页到 $WWW_DIR/index.html"
else
  echo "❌ 下载伪装页失败"
  exit 1
fi
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

    # 本地回落网页
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
    ssl_ciphers TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256;
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
# 安装 V2bX（手动选择 n）
# -----------------------------
echo "📦 安装 V2bX..."
wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh -O /tmp/v2bx-install.sh
bash /tmp/v2bx-install.sh <<EOF
n
EOF

# -----------------------------
# 写入 V2bX 配置
# -----------------------------
mkdir -p /etc/V2bX
cat > /etc/V2bX/config.json <<EOF
{
  "Log": {
    "Level": "error",
    "Output": ""
  },
  "Cores": [
    {
      "Type": "xray",
      "Log": {
        "Level": "error",
        "ErrorPath": "/etc/V2bX/error.log"
      },
      "OutboundConfigPath": "/etc/V2bX/custom_outbound.json",
      "RouteConfigPath": "/etc/V2bX/route.json"
    }
  ],
  "Nodes": [
    {
      "Core": "xray",
      "ApiHost": "$API_DOMAIN",
      "ApiKey": "$APIKEY",
      "NodeID": $NODEID,
      "NodeType": "trojan",
      "Timeout": 30,
      "ListenIP": "127.0.0.1",
      "SendIP": "0.0.0.0",
      "EnableProxyProtocol": true,
      "EnableFallback": true,
      "FallBackConfigs": [
        {
          "Dest": "127.0.0.1:$FALLBACK_PORT",
          "ProxyProtocolVer": 0
        }
      ]
    }
  ]
}
EOF

chmod 600 /etc/V2bX/config.json

echo "🎉 部署完成，Nginx 已支持 stream，V2bX 配置已生成！"
