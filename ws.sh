#!/bin/bash
set -e

# ===============================
# VLESS WS CDN Nginx 入口脚本
# ===============================

if [ "$(id -u)" -ne 0 ]; then
    echo "必须 root 运行"
    exit 1
fi

read -rp "VLESS SNI 域名（如 tw01.api6666666.top）: " VLESS_DOMAIN
read -rp "XrayR 实际监听端口（如 10000）: " XRAYR_PORT

if [ -z "$VLESS_DOMAIN" ] || [ -z "$XRAYR_PORT" ]; then
    echo "参数不能为空"
    exit 1
fi

# 安装 nginx
if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y nginx
elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx
else
    echo "不支持的系统"
    exit 1
fi

systemctl stop nginx || true

# 写 nginx.conf
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 1024;
}

stream {
    map \$ssl_preread_server_name \$backend {
        $VLESS_DOMAIN   vless_backend;
        default         reject_backend;
    }

    upstream vless_backend {
        server 127.0.0.1:$XRAYR_PORT;
    }

    upstream reject_backend {
        server 127.0.0.1:1;
    }

    server {
        listen 443 reuseport;
        ssl_preread on;
        proxy_pass \$backend;
        proxy_timeout 8s;
        proxy_connect_timeout 2s;
    }
}
EOF

nginx -t
systemctl restart nginx
systemctl enable nginx

echo
echo "======================================"
echo "完成"
echo "VLESS SNI: $VLESS_DOMAIN"
echo "转发端口: 127.0.0.1:$XRAYR_PORT"
echo "非 VLESS 流量：直接断"
echo "======================================"
