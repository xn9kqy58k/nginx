#!/bin/bash
set -e

if [ "$(id -u)" != "0" ]; then
  echo "❌ 必须使用 root 运行"
  exit 1
fi

echo "================ VLESS WS CDN 终极一体部署 ================"

read -rp "VLESS SNI 域名（未解析也可）: " DOMAIN
read -rp "Cloudflare 邮箱: " CF_EMAIL
read -rsp "Cloudflare Global API Key: " CF_KEY
echo
read -rp "XrayR 本地 WS 监听端口（如 10000）: " XRAYR_PORT

if [[ -z "$DOMAIN" || -z "$CF_EMAIL" || -z "$CF_KEY" || -z "$XRAYR_PORT" ]]; then
  echo "❌ 参数不能为空"
  exit 1
fi

export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

CERT_DIR="/etc/V2bX"
CERT="$CERT_DIR/fullchain.cer"
KEY="$CERT_DIR/cert.key"

mkdir -p "$CERT_DIR"

echo "▶ 安装依赖"
apt update -y
apt install -y nginx curl socat cron

echo "▶ 安装 acme.sh"
if [ ! -f /root/.acme.sh/acme.sh ]; then
  curl -sS https://get.acme.sh | sh
fi

echo "▶ 申请 DNS-01 证书（未解析域名可用）"
/root/.acme.sh/acme.sh --issue \
  -d "$DOMAIN" \
  --dns dns_cf \
  --keylength ec-256 \
  --force

/root/.acme.sh/acme.sh --install-cert \
  -d "$DOMAIN" \
  --key-file "$KEY" \
  --fullchain-file "$CERT" \
  --reloadcmd "systemctl reload nginx || true"

echo "▶ 写入 Nginx 配置（WS only + 诱饵断开）"

cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile on;
    tcp_nodelay on;
    keepalive_timeout 60;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    server {
        listen 443 ssl http2;
        server_name $DOMAIN;

        ssl_certificate     $CERT;
        ssl_certificate_key $KEY;
        ssl_protocols TLSv1.2 TLSv1.3;

        # 只允许 WS 命中
        location /ws {
            proxy_pass http://127.0.0.1:$XRAYR_PORT;
            proxy_http_version 1.1;

            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 3600s;
            proxy_buffering off;
        }

        # 所有非 WS：TLS 握手成功后直接断
        location / {
            return 444;
        }
    }

    # 防止 IP 直连
    server {
        listen 443 ssl default_server;
        server_name _;
        ssl_certificate     $CERT;
        ssl_certificate_key $KEY;
        return 444;
    }
}
EOF

echo "▶ 测试并启动 Nginx"
nginx -t
systemctl restart nginx
systemctl enable nginx

echo "▶ 设置证书自动续签"
crontab -l 2>/dev/null | grep -v acme.sh > /tmp/cron.tmp || true
echo "0 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >/dev/null" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm -f /tmp/cron.tmp

unset CF_Email CF_Key

echo "================ 部署完成 ================"
echo "SNI 域名: $DOMAIN"
echo "WS 路径: /ws"
echo "XrayR 本地端口: $XRAYR_PORT"
echo "证书路径: $CERT"
echo "================================================"
