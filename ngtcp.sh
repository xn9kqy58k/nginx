#!/bin/bash
# 更安全、更高性能、伪装更强的 Nginx + Certbot + V2bX 自动部署脚本
# 说明：以 root 运行(e.g. sudo -i)。脚本会备份现有 nginx 配置与伪装页。
set -euo pipefail
IFS=$'\n\t'

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 权限运行"
  exit 1
fi

# -----------------------------
# 用户输入（保持简单交互）
# -----------------------------
read -p "申请证书域名 (example.com) : " DOMAIN
read -p "证书提醒邮箱: " EMAIL
read -p "请输入对接面板网址 (http(s)://panel.example) : " API_DOMAIN
read -p "请输入对接面板密钥 : " APIKEY
read -p "请输入节点 NodeID (数字) : " NODEID

# 随机化回落端口（绑定 localhost，更难被外网探测）
FALLBACK_PORT=$(shuf -i 20000-60000 -n 1)

# -----------------------------
# 基本依赖安装
# -----------------------------
echo "📦 更新 apt 并安装必要包..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y --no-install-recommends curl wget gnupg2 lsb-release software-properties-common nginx certbot python3-certbot-nginx openssl systemd

# 备份现有 nginx 配置
if [ -f /etc/nginx/nginx.conf ]; then
  mkdir -p /root/nginx-backups
  cp -a /etc/nginx/nginx.conf "/root/nginx-backups/nginx.conf.$(date +%s)"
  echo "📦 已备份 /etc/nginx/nginx.conf 到 /root/nginx-backups/"
fi

# 关闭 nginx 以便 certbot standalone 使用 80/443
systemctl stop nginx || true

# -----------------------------
# 申请证书（带重试）
# -----------------------------
echo "🔑 申请 TLS 证书（standalone 模式）..."
max_retry=3
n=0
until [ $n -ge $max_retry ]
do
  if certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --non-interactive; then
    echo "✅ 证书申请成功"
    break
  else
    n=$((n+1))
    echo "⚠️ 证书申请失败，重试 ($n/$max_retry)..."
    sleep 3
  fi
done
if [ $n -ge $max_retry ]; then
  echo "❌ 多次尝试申请证书失败，退出。请检查域名解析与防火墙。"
  exit 1
fi

# -----------------------------
# 伪装页（从 GitHub 下载原始伪装页，遵循你的要求不改动）
# -----------------------------
WWW_DIR="/var/www/$DOMAIN"
mkdir -p "$WWW_DIR"

# 从指定 GitHub 仓库下载 index.html（与你最初脚本一致）
if curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"; then
  echo "✅ 已从 GitHub 下载伪装页到 $WWW_DIR/index.html"
else
  echo "❌ 下载伪装页失败，请检查网络或 URL。"
  exit 1
fi

chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# -----------------------------
# 生成更安全的 nginx.conf（stream + http）
# 注意：stream 用于 TLS 转发到 Xray, http 提供本地回落页面
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

# 全局优化
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

    # Gzip for fallback assets
    gzip on;
    gzip_min_length 256;
    gzip_comp_level 4;
    gzip_proxied any;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;

    # 缓冲日志以减少磁盘 I/O
    access_log /var/log/nginx/access.log main buffer=16k;

    # 本地回落网页（仅绑定 localhost）
    server {
        listen 127.0.0.1:%FALLBACK_PORT%;
        server_name localhost;

        root %WWW_DIR%;
        index index.html;

        location / {
            try_files $uri /index.html;
            # 只允许本地访问，避免被外网直接请求
            allow 127.0.0.1;
            deny all;
        }

        access_log /var/log/nginx/fallback.access.log;
        error_log /var/log/nginx/fallback.error.log info;
    }
}

# stream 模块用于 TLS 透传到 Xray/V2bX
stream {
    # SSL/TLS 优化
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

        # 将 TLS 流量传给本地 Xray(1024)
        proxy_pass 127.0.0.1:1024;
    }
}
NGINX

# 使用占位替换将动态变量写入 nginx.conf
sed -i "s|%FALLBACK_PORT%|$FALLBACK_PORT|g" "$NGINX_CONF"
sed -i "s|%WWW_DIR%|$WWW_DIR|g" "$NGINX_CONF"
sed -i "s|%DOMAIN%|$DOMAIN|g" "$NGINX_CONF"

# 去掉 Windows 不可见字符（若有）
sed -i 's/\r//' "$NGINX_CONF"

# 测试并启动 nginx
nginx -t
systemctl restart nginx
systemctl enable nginx

# -----------------------------
# 写入 V2bX 配置（/etc/V2bX/config.json）
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

# -----------------------------
# 自动续签（使用 systemd timer，较 cron 更可靠）
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
# 小提示（防火墙/安全）
# -----------------------------
echo "\n注意：如果使用 UFW/iptables，请确保允许 443 端口并限制不必要的入站。"

# -----------------------------
# 完成
# -----------------------------
cat <<SUMMARY
🎉 部署完成！
👉 域名: $DOMAIN
👉 面板地址: $API_DOMAIN
👉 节点 ID: $NODEID
👉 本地回落端口 (仅绑定 localhost): $FALLBACK_PORT
👉 伪装页路径: $WWW_DIR/index.html
👉 nginx 配置: $NGINX_CONF
👉 V2bX 配置: /etc/V2bX/config.json
👉 自动续签: systemd timer (certbot-renew.timer) 每日 03:00

安全/伪装要点：
 - 回落服务绑定 localhost，减少被外网扫描到的概率
 - 随机化回落端口
 - 关闭 server_tokens、启用 HTTP gzip 与日志缓冲，减小 I/O 压力
 - TLS: 强推荐 TLSv1.2/1.3、禁用 session tickets、启用 stapling

下一步建议：
 - 若使用 Cloudflare 或其他 CDN，请在面板中配置并确认 DNS 已正确解析到当前服务器
 - 如需把伪装页做得更像真实站点，可替换 $WWW_DIR 的文件

SUMMARY
