#!/bin/bash
# =========================================================
#  V2node SSL 自动申请与自动续签脚本（Cloudflare DNS 模式）
#  默认使用 Cloudflare Global API Key 认证
#  作者: 老板的终极懒人版
# =========================================================

set -euo pipefail

# --- 基础配置 ---
CERT_DIR="/etc/v2node"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"
ACME_HOME="$HOME/.acme.sh"
SERVICE_NAME="v2node"
CA_SERVER="--server letsencrypt"
CRON_SCHEDULE="0 3 1 * *"  # 每月1号凌晨3点自动检测续签

# --- 清理旧变量 ---
unset CF_Email CF_Key

echo "========================================================="
echo "🔐 V2node SSL 自动申请与自动续签脚本"
echo "========================================================="

# -----------------------------------------------------
# 步骤 1: 检查 acme.sh
# -----------------------------------------------------
if [ ! -x "$ACME_HOME/acme.sh" ]; then
    echo "--- 未检测到 acme.sh，正在自动安装 ---"
    curl -sS https://get.acme.sh | sh -s -- --install-home "$ACME_HOME" || {
        echo "❌ acme.sh 安装失败，请检查网络连接！"
        exit 1
    }
fi

ACME_BIN="$ACME_HOME/acme.sh"
export PATH="$ACME_HOME:$PATH"
echo "--- ✅ acme.sh 已就绪: $ACME_BIN ---"

# -----------------------------------------------------
# 步骤 2: 获取 Cloudflare Global API Key 信息
# -----------------------------------------------------
DOMAIN_NAME=${DOMAIN_NAME:-""}
CF_EMAIL=${CF_EMAIL:-""}
CF_KEY=${CF_KEY:-""}

if [ -z "$DOMAIN_NAME" ]; then
  read -p "请输入您的 SNI 域名: " DOMAIN_NAME </dev/tty
fi

if [ -z "$CF_EMAIL" ]; then
  read -p "请输入您的 Cloudflare 账号邮箱: " CF_EMAIL </dev/tty
fi

if [ -z "$CF_KEY" ]; then
  read -p "请输入您的 Cloudflare Global API Key: " -s CF_KEY </dev/tty
  echo
fi

if [ -z "$DOMAIN_NAME" ] || [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
    echo "❌ 域名、邮箱或 API Key 不能为空！"
    exit 1
fi

export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# -----------------------------------------------------
# 步骤 3: 申请证书
# -----------------------------------------------------
echo "--- 🌐 正在申请 SSL 证书（Cloudflare DNS 验证） ---"

"$ACME_BIN" --home "$ACME_HOME" --issue \
  -d "$DOMAIN_NAME" \
  --dns dns_cf \
  $CA_SERVER \
  --log

echo "--- ✅ 证书申请成功 ---"

# -----------------------------------------------------
# 步骤 4: 安装证书并配置自动重启
# -----------------------------------------------------
echo "--- 正在安装证书到 $CERT_DIR ---"
mkdir -p "$CERT_DIR"

RELOAD_CMD="systemctl restart ${SERVICE_NAME} || echo '⚠️ 未能自动重启 ${SERVICE_NAME}，请手动检查服务状态。'"

"$ACME_BIN" --home "$ACME_HOME" --install-cert \
  -d "$DOMAIN_NAME" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "$RELOAD_CMD"

# -----------------------------------------------------
# 步骤 5: 配置自动续签（每月检测一次）
# -----------------------------------------------------
echo "--- 🕒 配置自动续签计划任务（每月检测一次） ---"

# 删除旧计划
(crontab -l 2>/dev/null | grep -v "$ACME_BIN" || true) | crontab -

# 添加新任务
(
  crontab -l 2>/dev/null
  echo "$CRON_SCHEDULE CF_Email=$CF_EMAIL CF_Key=$CF_KEY $ACME_BIN --cron --home $ACME_HOME > /dev/null && systemctl restart $SERVICE_NAME"
) | crontab -

echo "--- ✅ 已添加 crontab 任务：$CRON_SCHEDULE ---"
echo "--- 自动续签后将自动重启服务：$SERVICE_NAME ---"

# -----------------------------------------------------
# 步骤 6: 清理与总结
# -----------------------------------------------------
unset CF_Email CF_Key

echo "========================================================="
echo "✅ 初次证书申请与安装完成！"
echo "证书路径: $CERT_FILE"
echo "私钥路径: $KEY_FILE"
echo "系统已配置自动续签（每月检测一次）"
echo "续签后将自动重启服务：$SERVICE_NAME"
echo "========================================================="
exit 0
