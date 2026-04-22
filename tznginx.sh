#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 0. 基础工具预装 ---
echo -e "${YELLOW}正在检查并补齐基础工具 (curl, unzip...)${PLAIN}"
apt-get update
apt-get install -y curl wget sudo unzip xz-utils

echo -e "${CYAN}======================================================${PLAIN}"
echo -e "${CYAN}        哪吒监控 (V1) CDN 优化版全自动化脚本           ${PLAIN}"
echo -e "${CYAN}======================================================${PLAIN}"

# --- 1. 系统更新 ---
echo -e "\n${YELLOW}[1/6] 正在静默更新系统包...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive
apt-get -o Dpkg::Options::="--force-confold" upgrade -y
apt-get install -y vim git socat tar net-tools ufw nginx

# --- 2. 安装 Docker 环境 ---
echo -e "\n${YELLOW}[2/6] 正在安装 Docker & Docker Compose...${PLAIN}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | bash -s docker
    systemctl enable docker
    systemctl start docker
else
    echo -e "${BLUE}Docker 已存在，跳过安装。${PLAIN}"
fi

if ! docker compose version &> /dev/null; then
    apt-get install -y docker-compose-plugin
fi

# --- 3. 参数采集 ---
echo -e "\n${YELLOW}[3/6] 配置信息采集${PLAIN}"
read -p "请输入要绑定的域名 (例: tz.example.com): " DOMAIN
read -p "请输入面板内部运行端口 (默认 8868): " NZ_PORT
NZ_PORT=${NZ_PORT:-8868}
read -p "请输入你的邮箱 (用于 SSL 证书申请): " EMAIL

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    echo -e "${RED}错误: 域名和邮箱不能为空${PLAIN}"
    exit 1
fi

# --- 4. SSL 证书申请 (Acme.sh) ---
echo -e "\n${YELLOW}[4/6] 正在通过 Acme.sh 申请证书...${PLAIN}"
rm -rf ~/.acme.sh
curl https://get.acme.sh | sh -s email=$EMAIL
export PATH="$HOME/.acme.sh:$PATH"
~/.acme.sh/acme.sh --upgrade --auto-upgrade
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

systemctl stop nginx
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force

mkdir -p /etc/nginx/certs/$DOMAIN
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
    --key-file       /etc/nginx/certs/$DOMAIN/key.pem  \
    --fullchain-file /etc/nginx/certs/$DOMAIN/fullchain.pem

# --- 5. Nginx 反代配置 (CDN & WebSocket 优化版) ---
echo -e "\n${YELLOW}[5/6] 正在配置 Nginx 反向代理 (含超时优化)...${PLAIN}"
NGINX_CONF="/etc/nginx/conf.d/nezha.conf"

cat > $NGINX_CONF <<EOF
upstream dashboard_backend {
    server 127.0.0.1:$NZ_PORT;
    keepalive 512;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/certs/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/$DOMAIN/key.pem;

    ssl_stapling on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    underscores_in_headers on;

    # gRPC 通信 (探针与面板通信)
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$remote_addr;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        grpc_pass grpc://dashboard_backend;
    }

    # WebSocket 优化 (解决 CDN 环境下网页频繁刷新问题)
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 延长超时时间，适配 CDN 心跳
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        
        # 禁用缓存，确保实时推送
        proxy_buffering off;
        proxy_cache_bypass \$http_upgrade;
        
        proxy_pass http://dashboard_backend;
    }

    # Web 界面主体
    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_pass http://dashboard_backend;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

nginx -t && systemctl restart nginx

# --- 6. 安全加固 ---
echo -e "\n${YELLOW}[6/6] 正在配置防火墙...${PLAIN}"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny $NZ_PORT/tcp
echo "y" | ufw enable

# --- 7. 信息输出 ---
echo -e "\n${GREEN}======================================================${PLAIN}"
echo -e "${GREEN}           ✅ 哪吒面板环境修复版部署完成！             ${PLAIN}"
echo -e "${GREEN}======================================================${PLAIN}"
echo -e "${BLUE}访问域名:${PLAIN} ${CYAN}https://$DOMAIN${PLAIN}"
echo -e "${BLUE}CDN 状态:${PLAIN} ${YELLOW}已适配 (请确保 CF 后台 SSL 为 Full Strict)${PLAIN}"
echo -e "${BLUE}刷新修复:${PLAIN} ${GREEN}WebSocket 超时已延长至 3600s${PLAIN}"
echo -e "------------------------------------------------------"
echo -e "${YELLOW}👉 如果尚未安装面板，请执行：${PLAIN}"
echo -e "curl -L https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh -o nezha.sh && chmod +x nezha.sh && sudo ./nezha.sh"
echo -e "${GREEN}======================================================${PLAIN}"
