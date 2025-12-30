#!/bin/bash

# ====================================================
# Nginx 一键反向代理魔改脚本 (ping0.cc 专用)
# ====================================================

# 配置变量 - 你可以在这里修改你的域名
MY_DOMAIN="ping0.cc"
UPSTREAM_URL="http://ping0.ipyard.com/"
UPSTREAM_HOST="ping0.ipyard.com"

# 1. 更新系统并安装 Nginx
echo "正在安装 Nginx..."
sudo apt update && sudo apt install -y nginx curl

# 2. 确认 Nginx 是否支持 sub_filter 模块
if ! nginx -V 2>&1 | grep -q "with-http_sub_module"; then
    echo "错误: 当前 Nginx 版本不支持 sub_filter 模块，请手动编译安装。"
    exit 1
fi

# 3. 编写 Nginx 配置文件
echo "正在配置 Nginx 站点..."
cat <<EOF | sudo tee /etc/nginx/sites-available/ping0_proxy
server {
    listen 80;
    server_name $MY_DOMAIN;

    # 禁用上游压缩，确保 sub_filter 能够处理 HTML
    proxy_set_header Accept-Encoding "";

    location / {
        proxy_pass $UPSTREAM_URL;
        proxy_set_header Host $UPSTREAM_HOST;
        
        # 传递真实 IP
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header REMOTE-HOST \$remote_addr;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # --- 内容替换规则 ---
        # 1. 替换文字内容
        sub_filter '广播 IP' '原生 IP';
        
        # 2. 替换颜色 (从橙色变为绿色)
        sub_filter 'rgb(255, 170, 0)' 'limegreen';
        
        # 3. 替换域名，防止点击链接跳回原站
        sub_filter '$UPSTREAM_HOST' '$MY_DOMAIN';
        
        sub_filter_once off;

        # 隐藏后端特征
        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;
    }

    # 静态资源优化
    location ~* \.(gif|png|jpg|css|js|woff|woff2)$ {
        proxy_pass $UPSTREAM_URL;
        proxy_set_header Host $UPSTREAM_HOST;
        expires 7d;
        add_header Cache-Control "public";
    }
}
EOF

# 4. 启用配置并测试
echo "激活配置文件..."
sudo ln -sf /etc/nginx/sites-available/ping0_proxy /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

echo "检查 Nginx 语法..."
if sudo nginx -t; then
    echo "语法检查通过，正在重启 Nginx..."
    sudo systemctl restart nginx
    echo "------------------------------------------------"
    echo "恭喜！配置已完成。"
    echo "您的站点: http://$MY_DOMAIN"
    echo "请确保您的域名已解析到此服务器 IP。"
    echo "------------------------------------------------"
else
    echo "Nginx 语法检查失败，请检查配置。"
    exit 1
fi
