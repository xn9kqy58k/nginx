#!/bin/bash

# ====================================================
# 项目名称：专业级 IPTables 自动化端口转发工具 (v2.0)
# 适用场景：机场中转、跨境加速、动态 IP 落地转发
# 主要优化：支持域名解析、TCP/IP 栈优化、精准规则清理
# ====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 1. 环境准备与系统优化
echo -e "${GREEN}[1/5] 正在安装必要组件并优化系统内核...${PLAIN}"
apt update -y && apt install -y iptables iptables-persistent dnsutils curl

# 开启内核转发并优化 TCP 栈（提升高并发下的稳定性）
cat > /etc/sysctl.d/99-relay-optimize.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_fastopen=3
net.core.somaxconn=1024
EOF
sysctl -p /etc/sysctl.d/99-relay-optimize.conf > /dev/null

# 2. 交互式获取参数
echo -e "${YELLOW}------------------------------------------------${PLAIN}"
read -p "请输入 本机（中转机）监听端口: " LOCAL_PORT
read -p "请输入 落地机 域名或IP: " REMOTE_ADDR
read -p "请输入 落地机 目标端口: " REMOTE_PORT
echo -e "${YELLOW}------------------------------------------------${PLAIN}"

# 3. 智能域名解析
echo -e "${GREEN}[2/5] 正在解析目标地址...${PLAIN}"
# 优先解析 IPv4
REMOTE_IP=$(dig +short A $REMOTE_ADDR | tail -n1)

# 校验解析结果
if [[ -z "$REMOTE_IP" ]]; then
    if [[ "$REMOTE_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        REMOTE_IP=$REMOTE_ADDR
    else
        echo -e "${RED}错误：无法解析域名 $REMOTE_ADDR，请检查输入！${PLAIN}"
        exit 1
    fi
fi
echo -e "${GREEN}解析成功：目标 IP 为 $REMOTE_IP${PLAIN}"

# 4. 精准规则清理（防止残留）
echo -e "${GREEN}[3/5] 正在清理旧规则以防冲突...${PLAIN}"
# 清理所有与该本地端口相关的 PREROUTING 和 POSTROUTING 规则
iptables -t nat -S PREROUTING | grep "\-\-dport $LOCAL_PORT " | sed 's/-A/iptables -t nat -D/' | bash 2>/dev/null
iptables -t nat -S POSTROUTING | grep "$REMOTE_IP" | grep "$REMOTE_PORT" | sed 's/-A/iptables -t nat -D/' | bash 2>/dev/null

# 5. 注入核心转发规则
echo -e "${GREEN}[4/5] 正在配置新的转发规则...${PLAIN}"

# DNAT: 入口流量重定向
iptables -t nat -A PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT"
iptables -t nat -A PREROUTING -p udp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT"

# SNAT: 出口流量伪装 (MASQUERADE)
iptables -t nat -A POSTROUTING -p tcp -d "$REMOTE_IP" --dport "$REMOTE_PORT" -j MASQUERADE
iptables -t nat -A POSTROUTING -p udp -d "$REMOTE_IP" --dport "$REMOTE_PORT" -j MASQUERADE

# 6. 持久化与生效
echo -e "${GREEN}[5/5] 正在保存配置并应用...${PLAIN}"
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save > /dev/null
else
    mkdir -p /etc/iptables/
    iptables-save > /etc/iptables/rules.v4
fi

echo -e "${YELLOW}================================================${PLAIN}"
echo -e "${GREEN}✅ 转发配置圆满完成！${PLAIN}"
echo -e "本机入口: ${YELLOW}0.0.0.0:$LOCAL_PORT${PLAIN}"
echo -e "最终落地: ${YELLOW}$REMOTE_IP:$REMOTE_PORT ($REMOTE_ADDR)${PLAIN}"
echo -e "协议支持: ${GREEN}TCP + UDP${PLAIN}"
echo -e "${YELLOW}================================================${PLAIN}"
echo -e "温馨提示：如果连接不通，请务必在服务商后台防火墙放行 $LOCAL_PORT 端口。"
