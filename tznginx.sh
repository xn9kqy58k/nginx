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
# 自动补齐 curl 以便下载脚本，补齐 unzip 以便哪吒面板解压
echo -e "${YELLOW}正在检查并补齐基础工具 (curl, unzip...)${PLAIN}"
apt-get update
apt-get install -y curl wget sudo unzip xz-utils

echo -e "${CYAN}======================================================${PLAIN}"
echo -e "${CYAN}       哪吒监控 (V1) 环境全自动化部署脚本             ${PLAIN}"
echo -e "${CYAN}======================================================${PLAIN}"

# --- 1. 系统更新 (解决 SSH 配置弹窗与无人值守问题) ---
echo -e "\n${YELLOW}[1/6] 正在静默更新系统包...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive
# 使用 -o Dpkg::Options::="--force-confold" 解决你遇到的 sshd_config 弹窗
apt-get -o Dpkg::Options::="--force-confold" upgrade -y
apt-get install -y vim git socat tar net-tools ufw nginx

# --- 2. 安装 Docker 运行环境 ---
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
read -p "请输入要绑定的域名 (例: dashboard.example.com): " DOMAIN
read -p "请输入面板内部运行端口 (默认 8008): " NZ_PORT
NZ_PORT=${NZ_PORT:-8008}
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

# --- 5. Nginx 反代配置 (遵循 V1 官方文档) ---
echo -e "\n${YELLOW}[5/6] 正在配置 Nginx 反向代理...${PLAIN}"
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

    # gRPC 通信
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$remote_addr;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        grpc_pass grpc://dashboard_backend;
    }

    # WebSocket
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://dashboard_backend;
    }

    # Web 界面主体
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

nginx -t && systemctl restart nginx

# --- 6. 安全加固：屏蔽后端端口直连 ---
echo -e "\n${YELLOW}[安全加固] 正在通过 UFW 屏蔽外部对 $NZ_PORT 端口的访问...${PLAIN}"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny $NZ_PORT/tcp
echo "y" | ufw enable

# --- 7. 最终信息输出 (备忘录) ---
echo -e "\n${GREEN}======================================================${PLAIN}"
echo -e "${GREEN}            ✅ 系统环境与 Nginx 反代配置完成！          ${PLAIN}"
echo -e "${GREEN}======================================================${PLAIN}"
echo -e "${BLUE}1. Docker 状态:${PLAIN}  $(systemctl is-active docker)"
echo -e "${BLUE}2. 访问域名:${PLAIN}    ${CYAN}https://$DOMAIN${PLAIN}"
echo -e "${BLUE}3. 面板后端端口:${PLAIN} ${PURPLE}$NZ_PORT${PLAIN} ${RED}(已屏蔽，禁止外部直连)${PLAIN}"
echo -e "${BLUE}4. 已装依赖:${PLAIN}    ${GREEN}curl, unzip, xz-utils, nginx, ufw${PLAIN}"
echo -e "${GREEN}------------------------------------------------------${PLAIN}"
echo -e "${YELLOW}👉 下一步操作指令 (安装面板):${PLAIN}"
echo -e "${WHITE}curl -L https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh -o nezha.sh && chmod +x nezha.sh && sudo ./nezha.sh${PLAIN}"
echo -e ""
echo -e "${YELLOW}👉 面板安装关键注意点:${PLAIN}"
echo -e "   - 提示 ${CYAN}Dashboard 端口${PLAIN} 时，务必输入: ${PURPLE}$NZ_PORT${PLAIN}"
echo -e "   - 回调地址: ${CYAN}https://$DOMAIN/oauth2/callback${PLAIN}"
echo -e ""
echo -e "${YELLOW}👉 Agent (落地鸡) 连接指南:${PLAIN}"
echo -e "   - 地址填: ${CYAN}$DOMAIN${PLAIN} | 端口填: ${GREEN}443${PLAIN} | 开启 SSL${PLAIN}"
echo -e "${GREEN}======================================================${PLAIN}"
