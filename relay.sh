#!/bin/bash

# ====================================================
# 项目名称：通用 IPTables 端口转发脚本
# 适用场景：机场中转机 (中转机) -> 落地机 (落地机)
# 脚本功能：自动安装环境、开启内核转发、配置 TCP/UDP 转发
# ====================================================

# 确保以 root 权限运行
[[ $EUID -ne 0 ]] && echo "错误：请使用 root 用户运行此脚本！" && exit 1

# 1. 环境准备与组件安装
echo "------------------------------------------------"
echo "[1/4] 正在准备运行环境..."
apt update -y && apt install -y iptables iptables-persistent

# 2. 开启 Linux 内核转发 (必须开启，否则流量无法通过入口机转出)
echo "[2/4] 正在开启 IPv4 转发功能..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
# 使内核参数立即生效
sysctl -p > /dev/null

# 3. 交互式获取转发参数
echo "------------------------------------------------"
read -p "请输入 本机（中转机）转发端口: " LOCAL_PORT
read -p "请输入 落地机（目标机）实际IP: " REMOTE_IP
read -p "请输入 落地机（目标机）服务端口: " REMOTE_PORT
echo "------------------------------------------------"

# 4. 配置 IPTables 规则逻辑
echo "[3/4] 正在配置流量转发规则..."

# 【清理规则】防止重复运行脚本导致规则堆叠
iptables -t nat -D PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT" 2>/dev/null
iptables -t nat -D PREROUTING -p udp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT" 2>/dev/null

# 【核心规则1】DNAT：将进入本机的流量目标地址改写为落地机 IP
iptables -t nat -A PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT"
iptables -t nat -A PREROUTING -p udp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT"

# 【核心规则2】SNAT (MASQUERADE)：改写源地址，确保落地机回包经过中转机，防止连接断开
iptables -t nat -A POSTROUTING -p tcp -d "$REMOTE_IP" --dport "$REMOTE_PORT" -j MASQUERADE
iptables -t nat -A POSTROUTING -p udp -d "$REMOTE_IP" --dport "$REMOTE_PORT" -j MASQUERADE

# 5. 持久化保存 (防止服务器重启后规则消失)
echo "[4/4] 正在保存规则，防止重启失效..."
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    # 兼容没有 persistent 工具的情况
    iptables-save > /etc/iptables/rules.v4
fi

echo "================================================"
echo "✅ 转发配置成功！"
echo "本地端口: $LOCAL_PORT  --->  远程目标: $REMOTE_IP:$REMOTE_PORT"
echo "提示：请检查云服务商安全组，放行 TCP/UDP 的 $LOCAL_PORT 端口"
echo "================================================"
