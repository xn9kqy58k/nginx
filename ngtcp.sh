#!/bin/bash
# 自动化部署 Nginx 
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 权限运行"
    exit 1
fi

# -----------------------------
# 输入关键信息
# -----------------------------
read -p "申请证书域名 : " DOMAIN
read -p "证书提醒邮箱: " EMAIL
read -p "请输入对接面板网址 : " API_DOMAIN
read -p "请输入对接面板密钥 : " APIKEY
read -p "请输入节点 NodeID: " NODEID


# -----------------------------
# 安装依赖
# -----------------------------
echo "📦 更新 apt 并安装基础软件..."
apt update -y
apt install -y curl wget gnupg2 lsb-release software-properties-common

echo "📦 安装 Nginx 和 Certbot..."
apt install -y nginx certbot python3-certbot-nginx

# 停止 Nginx，避免端口占用
systemctl stop nginx

# -----------------------------
# 申请证书
# -----------------------------
echo "🔑 申请 TLS 证书..."
certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --non-interactive

# -----------------------------
# 伪装页
# -----------------------------
WWW_DIR="/var/www/html"
mkdir -p "$WWW_DIR"
curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# -----------------------------
# 写入 nginx.conf
# -----------------------------
echo "⚙️ 写入 nginx.conf ..."
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

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
# HTTP 模块：内部回落网页
# -----------------------------
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    keepalive_timeout 65;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    server {
        listen 8443;
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
sed -i 's/\r//' /etc/nginx/nginx.conf

# 启动 Nginx
nginx -t && systemctl restart nginx && systemctl enable nginx

# -----------------------------
# 写入 V2bX 配置
# -----------------------------
echo "⚙️ 写入 V2bX 配置 ..."
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
          "Dest": "127.0.0.1:8443",
          "ProxyProtocolVer": 0
        }
      ]
    }
  ]
}
EOF

# -----------------------------
# 自动续签
# -----------------------------
echo "0 3 * * * root certbot renew --quiet && systemctl reload nginx" > /etc/cron.d/certbot-renew
systemctl restart cron || systemctl restart crond

# -----------------------------
# 完成
# -----------------------------
echo "🎉 部署完成！"
echo "👉 节点域名: $DOMAIN"
echo "👉 面板地址: $API_DOMAIN"
echo "👉 节点 ID: $NODEID"
echo "👉 回落伪装页: $WWW_DIR/index.html"
echo "🔄 TLS 证书每天凌晨 3 点自动续签"
