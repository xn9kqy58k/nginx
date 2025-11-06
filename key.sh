#!/bin/bash
# =========================================================
#  V2node SSL 自动申请 + 自动续签脚本（Cloudflare Global API Key）
# =========================================================

set -euo pipefail

# --- 基础配置 ---
CERT_DIR="/etc/v2node"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"
ACME_HOME="$HOME/.acme.sh"
SERVICE_NAME="v2node"
CA_SERVER="--server letsencrypt"
CRON_SCHEDULE="0 3 1 * *"  # 每月1号凌晨3点

unset CF_Email CF_Key

echo "========================================================="
echo "🔐 V2node SSL 自动申请与自动续签脚本"
echo "========================================================="

# -----------------------------------------------------
# 步骤 1: 检查并安装 acme.sh
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
# 步骤 2: 输入 Cloudflare 账号信息
# -----------------------------------------------------
read -rp "请输入您的 SNI 域名: " DOMAIN_NAME
read -rp "请输入您的 Cloudflare 邮箱: " CF_EMAIL
read -rsp "请输入您的 Cloudflare Global API Key: " CF_KEY
echo

if [ -z "$DOMAIN_NAME" ] || [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
    echo "❌ 域名、邮箱或 API Key 不能为空！"
    exit 1
fi

export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# -----------------------------------------------------
# 步骤 3: 申请 SSL 证书
# -----------------------------------------------------
echo "--- 🌐 正在申请 SSL 证书（Cloudflare DNS 验证） ---"

if ! "$ACME_BIN" --home "$ACME_HOME" --issue \
    -d "$DOMAIN_NAME" \
    --dns dns_cf \
    $CA_SERVER \
    --log; then
    echo "❌ 证书申请失败，请检查 Cloudflare Key 或域名解析"
    exit 1
fi

# -----------------------------------------------------
# 步骤 4: 安装证书 + 重启服务
# -----------------------------------------------------
mkdir -p "$CERT_DIR"
RELOAD_CMD="systemctl restart ${SERVICE_NAME} || echo '⚠️ 未能自动重启 ${SERVICE_NAME}'"

"$ACME_BIN" --home "$ACME_HOME" --install-cert \
  -d "$DOMAIN_NAME" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "$RELOAD_CMD"

# -----------------------------------------------------
# 步骤 5: 配置每月自动续签
# -----------------------------------------------------
(crontab -l 2>/dev/null | grep -v "$ACME_BIN" || true) | crontab -

CRON_LINE="$CRON_SCHEDULE CF_Email=$CF_EMAIL CF_Key=$CF_KEY $ACME_BIN --cron --home $ACME_HOME > /tmp/v2node-renew.log 2>&1 && systemctl restart $SERVICE_NAME"

(
  crontab -l 2>/dev/null
  echo "$CRON_LINE"
) | crontab -

echo "--- ✅ 已添加 crontab 任务：$CRON_SCHEDULE ---"
echo "--- 自动续签后将自动重启服务：$SERVICE_NAME ---"

# -----------------------------------------------------
# 步骤 6: 完成
# -----------------------------------------------------
unset CF_Email CF_Key

echo "========================================================="
echo "✅ SSL 证书申请与安装成功！"
echo "证书路径: $CERT_FILE"
echo "私钥路径: $KEY_FILE"
echo "系统已配置自动续签（每月检测一次）"
echo "续签后将自动重启服务：$SERVICE_NAME"
echo "========================================================="
exit 0


