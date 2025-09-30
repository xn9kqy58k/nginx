#!/bin/bash
# 更安全、更高性能、伪装更强的 Nginx + Certbot + V2bX 自动部署脚本
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
read -p "请输入对接面板网址 (http(s)://panel.example) : " API_DOMAIN
read -p "请输入对接面板密钥 : " APIKEY
read -p "请输入节点 NodeID (数字) : " NODEID

FALLBACK_PORT=$(shuf -i 20000-60000 -n 1)

# -----------------------------
# 基本依赖安装
# -----------------------------
echo "📦 清理无效源并更新 apt..."
sed -i '/bullseye-backports/d' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y --no-install-recommends curl wget gnupg2 lsb-release software-properties-common nginx certbot python3-certbot-nginx openssl systemd

# 备份 nginx.conf
if [ -f /etc/nginx/nginx.conf ]; then
  mkdir -p /root/nginx-backups
  cp -a /etc/nginx/nginx.conf "/root/nginx-backups/nginx.conf.$(date +%s)"
fi

systemctl stop nginx || true

# -----------------------------
# 申请证书
# -----------------------------
echo "🔑 申请 TLS 证书..."
if ! certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --non-interactive; then
  echo "❌ 证书申请失败，请检查域名解析和防火墙"
  exit 1
fi

# -----------------------------
# 伪装页
# -----------------------------
WWW_DIR="/var/www/$DOMAIN"
mkdir -p "$WWW_DIR"
if curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"; then
  echo "✅ 已下载伪装页到 $WWW_DIR/index.html"
else
  echo "❌ 下载伪装页失败"
  exit 1
fi
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# -----------------------------
# Nginx 配置
# -----------------------------
NGINX_CONF="/etc/nginx/nginx.conf"
cat > "$NGINX_CONF" <<'NGINX'
user www-data;
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
    types_hash_max_size 2048;
    server_tokens off;

    gzip on;
    gzip_min_length 256;
    gzip_comp_level 4;
    gzip_proxied any;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;

    access_log /var/log/nginx/access.log main buffer=16k;

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

        access_log /var/log/nginx/fallback.access.log;
        error_log /var/log/nginx/fallback.error.log info;
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
sed -i 's/\r//' "$NGINX_CONF"

nginx -t
systemctl restart nginx
systemctl enable nginx

# -----------------------------
# 安装 V2bX
# -----------------------------
echo "📦 安装 V2bX ..."
wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh -O /tmp/v2bx-install.sh
chmod +x /tmp/v2bx-install.sh
yes n | bash /tmp/v2bx-install.sh
systemctl stop v2bx || true

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
      "DeviceOnlineMinTraffic": 200,
      "MinReportTraffic": 0,
      "EnableProxyProtocol": true,
      "EnableUot": true,
      "EnableTFO": true,
      "DNSType": "UseIPv4",
      "CertConfig": {
        "CertMode": "none",
        "RejectUnknownSni": false,
        "CertDomain": "$DOMAIN",
        "CertFile": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
        "KeyFile": "/etc/letsencrypt/live/$DOMAIN/privkey.pem",
        "Email": "$EMAIL",
        "Provider": "cloudflare",
        "DNSEnv": {
          "EnvName": "env1"
        }
      },
      "EnableFallback": true,
      "FallBackConfigs": [
        {
          "SNI": "",
          "Alpn": "",
          "Path": "",
          "Dest": "127.0.0.1:$FALLBACK_PORT",
          "ProxyProtocolVer": 0
        }
      ]
    }
  ]
}
EOF

chown -R root:root /etc/V2bX
chmod -R 600 /etc/V2bX/config.json || true

systemctl daemon-reexec
systemctl enable v2bx
systemctl restart v2bx

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
👉 面板地址: $API_DOMAIN
👉 节点 ID: $NODEID
👉 本地回落端口: $FALLBACK_PORT
👉 伪装页路径: $WWW_DIR/index.html
👉 nginx 配置: $NGINX_CONF
👉 V2bX 配置: /etc/V2bX/config.json
👉 自动续签: systemd timer 每日 03:00

V2bX 已安装并运行： systemctl status v2bx
Nginx 已配置 TLS 回落和透传： systemctl status nginx
SUMMARY
