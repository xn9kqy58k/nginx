#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}=== 哪吒监控 (V1) 环境全自动化部署脚本 ===${PLAIN}"

# --- 1. 系统更新与基础工具安装 ---
echo -e "\n${YELLOW}[1/5] 正在更新系统包并安装基础工具...${PLAIN}"
apt update && apt upgrade -y
apt install -y curl wget sudo vim git socat tar net-tools ufw

# --- 2. 安装 Docker 运行环境 ---
echo -e "\n${YELLOW}[2/5] 正在安装 Docker & Docker Compose...${PLAIN}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | bash -s docker
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}Docker 安装成功！${PLAIN}"
else
    echo -e "${BLUE}Docker 已存在，跳过安装。${PLAIN}"
fi

# 安装 Docker Compose V2
if ! docker compose version &> /dev/null; then
    apt install -y docker-compose-plugin
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

# --- 4. 申请 SSL 证书 (Acme.sh) ---
echo -e "\n${YELLOW}[4/5] 正在通过 Acme.sh 申请证书...${PLAIN}"
curl https://get.acme.sh | sh -s email=$EMAIL
source ~/.bashrc
# 如果是第一次安装，需要重新载入路径
/root/.acme.sh/acme.sh --upgrade --auto-upgrade
/root/.acme.sh/acme.sh --issue -d $DOMAIN --standalone

mkdir -p /etc/nginx/certs/$DOMAIN
/root/.acme.sh/acme.sh --install-cert -d $DOMAIN \
    --key-file       /etc/nginx/certs/$DOMAIN/key.pem  \
    --fullchain-file /etc/nginx/certs/$DOMAIN/fullchain.pem

# --- 5. Nginx 反代配置 ---
echo -e "\n${YELLOW}[5/5] 正在配置 Nginx 反向代理...${PLAIN}"
apt install -y nginx

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

    # gRPC 相关 (哪吒 V1 核心通信)
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$remote_addr;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        grpc_pass grpc://dashboard_backend;
    }

    # WebSocket 相关
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://dashboard_backend;
    }

    # 网页主体
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

# 检查 Nginx 语法并重启
nginx -t && systemctl restart nginx

# --- 安全加固：屏蔽后端端口直连 ---
echo -e "\n${YELLOW}[安全加固] 正在屏蔽外部对 $NZ_PORT 端口的访问...${PLAIN}"
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp
# 拒绝外部访问面板后端端口
ufw deny $NZ_PORT/tcp
ufw --force enable

# --- 结尾提示 ---
echo -e "\n${GREEN}===============================================${PLAIN}"
echo -e "${GREEN}系统环境与 Nginx 反代配置完成！${PLAIN}"
echo -e "1. Docker 状态: $(systemctl is-active docker)"
echo -e "2. 域名: ${YELLOW}https://$DOMAIN${PLAIN}"
echo -e "3. 面板后端端口: ${YELLOW}$NZ_PORT (已防火墙屏蔽，仅限本地反代访问)${PLAIN}"
echo -e "4. 现在你可以运行哪吒面板的 Docker 安装命令了。"
echo -e "${GREEN}===============================================${PLAIN}"
