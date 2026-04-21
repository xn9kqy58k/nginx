#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 0. 基础工具预装 ---
# 解决你遇到的 curl command not found 问题
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}检测到缺少 curl，正在安装基础工具...${PLAIN}"
    apt-get update && apt-get install -y curl wget sudo
fi

echo -e "${GREEN}=== 哪吒监控 (V1) 全环境部署助手 ===${PLAIN}"

# --- 1. 系统更新 (解决 SSH 配置弹窗问题) ---
echo -e "\n${YELLOW}[1/5] 正在静默更新系统包...${PLAIN}"
# 使用 -o Dpkg::Options::="--force-confold" 自动保留旧配置，防止 SSH 弹窗中断
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -o Dpkg::Options::="--force-confold" upgrade -y
apt-get install -y vim git socat tar net-tools ufw nginx

# --- 2. Docker 环境安装 ---
echo -e "\n${YELLOW}[2/5] 正在安装 Docker & Compose...${PLAIN}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | bash -s docker
    systemctl enable docker
    systemctl start docker
fi
if ! docker compose version &> /dev/null; then
    apt-get install -y docker-compose-plugin
fi

# --- 3. 参数采集 ---
echo -e "\n${YELLOW}[3/5] 配置信息采集${PLAIN}"
read -p "请输入要绑定的域名 (例: dashboard.example.com): " DOMAIN
read -p "请输入面板内部运行端口 (默认 8008): " NZ_PORT
NZ_PORT=${NZ_PORT:-8008}
read -p "请输入你的邮箱 (用于 SSL 证书申请): " EMAIL

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    echo -e "${RED}错误: 域名和邮箱不能为空${PLAIN}"
    exit 1
fi

# --- 4. SSL 证书申请 (Acme.sh) ---
echo -e "\n${YELLOW}[4/5] 正在通过 Acme.sh 申请证书...${PLAIN}"
# 强制清理可能存在的旧安装
rm -rf ~/.acme.sh
curl https://get.acme.sh | sh -s email=$EMAIL
# 重新加载环境路径以确保 acme.sh 命令可用
export PATH="$HOME/.acme.sh:$PATH"
~/.acme.sh/acme.sh --upgrade --auto-upgrade
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 停止 nginx 以便 standalone 模式占用 80 端口申请证书
systemctl stop nginx
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force

mkdir -p /etc/nginx/certs/$DOMAIN
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
    --key-file       /etc/nginx/certs/$DOMAIN/key.pem  \
    --fullchain-file /etc/nginx/certs/$DOMAIN/fullchain.pem

# --- 5. Nginx 反代配置 (基于官方 V1 模板) ---
echo -e "\n${YELLOW}[5/5] 正在生成 Nginx 配置文件...${PLAIN}"
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

    # gRPC 通信 (Agent 上线核心)
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$remote_addr;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        grpc_pass grpc://dashboard_backend;
    }

    # WebSocket (实时数据/终端)
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://dashboard_backend;
    }

    # Web 界面
    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://dashboard_backend;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

# 检查语法并重启 Nginx
nginx -t && systemctl restart nginx

# --- 安全加固：屏蔽 IP 直连 ---
echo -e "\n${YELLOW}[安全加固] 正在通过 UFW 屏蔽后端端口外部访问...${PLAIN}"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny $NZ_PORT/tcp
echo "y" | ufw enable

# --- 6. 面板安装提示 ---
echo -e "\n${GREEN}===============================================${PLAIN}"
echo -e "1. 系统更新: ${GREEN}完成 (静默模式)${PLAIN}"
echo -e "2. Docker 环境: ${GREEN}已就绪${PLAIN}"
echo -e "3. Nginx 反代: ${GREEN}已启动 (HTTPS)${PLAIN}"
echo -e "4. 安全状态: ${YELLOW}已屏蔽端口 $NZ_PORT，禁止外部直连${PLAIN}"
echo -e "-----------------------------------------------"
echo -e "接下来请运行哪吒官方安装脚本，并设置端口为: ${CYAN}$NZ_PORT${PLAIN}"
echo -e "安装完成后，请通过以下域名访问:"
echo -e "${GREEN}https://$DOMAIN${PLAIN}"
echo -e "==============================================="
