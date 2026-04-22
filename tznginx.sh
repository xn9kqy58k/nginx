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
echo -e "${YELLOW}正在检查并补齐基础工具 (curl, unzip, net-tools...)${PLAIN}"
apt-get update
apt-get install -y curl wget sudo unzip xz-utils net-tools ufw nginx

echo -e "${CYAN}======================================================${PLAIN}"
echo -e "${CYAN}     哪吒监控 (V1) 终极版全自动化部署脚本 (CDN优化)     ${PLAIN}"
echo -e "${CYAN}======================================================${PLAIN}"

# --- 1. 系统更新 (解决静默安装问题) ---
echo -e "\n${YELLOW}[1/6] 正在静默更新系统包...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive
apt-get -o Dpkg::Options::="--force-confold" upgrade -y

# --- 2. 安装 Docker 环境 ---
echo -e "\n${YELLOW}[2/6] 正在安装 Docker 环境...${PLAIN}"
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
read -p "请输入要绑定的域名 (例: tz.strawberrygummy.com): " DOMAIN
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

# --- 5. Nginx 终极版配置 (核心优化点) ---
echo -e "\n${YELLOW}[5/6] 正在写入深度优化的 Nginx 配置...${PLAIN}"
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

    # SSL 安全增强
    ssl_stapling on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # 核心：Cloudflare 真实 IP 处理 (修复 520/521)
    underscores_in_headers on;
    set_real_ip_from 0.0.0.0/0; 
    real_ip_header CF-Connecting-IP;

    # 核心：缓冲区扩容
    client_max_body_size 50m;
    client_header_buffer_size 16k;
    large_client_header_buffers 4 32k;

    # 1. gRPC 探针通信优化
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$http_cf_connecting_ip;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        grpc_buffer_size 4m;
        grpc_pass grpc://dashboard_backend;
    }

    # 2. WebSocket 彻底修复版 (解决自动刷新)
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$http_cf_connecting_ip;
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 必须强制 HTTP 1.1 以适配 CDN
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://dashboard_backend;
    }

    # 3. Web 界面与 API 加固
    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$http_cf_connecting_ip;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        
        proxy_read_timeout 3600s;
        proxy_pass http://dashboard_backend;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

# 重启 Nginx
nginx -t && systemctl restart nginx

# --- 6. 防火墙严格放行 ---
echo -e "\n${YELLOW}[6/6] 正在配置安全防火墙规则...${PLAIN}"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny $NZ_PORT/tcp
echo "y" | ufw enable

# --- 7. 终极信息总结 ---
echo -e "\n${GREEN}======================================================${PLAIN}"
echo -e "${GREEN}           ✅ 哪吒监控 (V1) 终极部署环境完成！          ${PLAIN}"
echo -e "${GREEN}======================================================${PLAIN}"
echo -e "${BLUE}1. 访问域名:${PLAIN}   ${CYAN}https://$DOMAIN${PLAIN}"
echo -e "${BLUE}2. Nginx 状态:${PLAIN} ${GREEN}Running (已开启 HTTP/2, TLS 1.3)${PLAIN}"
echo -e "${BLUE}3. 真实 IP:${PLAIN}    ${GREEN}已开启 (适配 Cloudflare)${PLAIN}"
echo -e "${BLUE}4. 自动刷新修复:${PLAIN} ${GREEN}已启用 WebSocket 专项优化${PLAIN}"
echo -e "------------------------------------------------------"
echo -e "${RED}⚠️ 重要收尾操作 (必做):${PLAIN}"
echo -e "${WHITE}1. 请确保 Cloudflare SSL 设置为: ${YELLOW}Full (strict)${PLAIN}"
echo -e "${WHITE}2. 面板安装后，请在设置中将 [数据统计周期] 改为 ${YELLOW}1 ${WHITE}秒。${PLAIN}"
echo -e "${WHITE}3. 下一步执行面板安装指令:${PLAIN}"
echo -e "${PURPLE}curl -L https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh -o nezha.sh && chmod +x nezha.sh && sudo ./nezha.sh${PLAIN}"
echo -e "${GREEN}======================================================${PLAIN}"
