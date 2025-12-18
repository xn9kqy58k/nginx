#!/bin/bash
set -euo pipefail

echo "========================================================="
echo "🔐 V2bX SSL 自动申请与自动续签脚本（超稳兼容版）"
echo "========================================================="

# -----------------------------
# 基本路径（固定不跟随 HOME）
# -----------------------------
ACME_HOME="/root/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"

# 已将路径修改为 V2bX
CERT_DIR="/etc/V2bX"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"

# 已将服务名修改为 V2bX
SERVICE_NAME="V2bX"
CA_SERVER="--server letsencrypt"
CRON_SCHEDULE="0 3 1 * *"

mkdir -p "$CERT_DIR"

# ---------------------------------------------------------
# Step 1：检测并安装 cron
# ---------------------------------------------------------
install_cron() {
    if command -v crond >/dev/null 2>&1; then
        return
    elif command -v cron >/dev/null 2>&1; then
        return
    fi

    echo "--- ⚙️ 正在安装 cron ---"

    if command -v apt >/dev/null 2>&1; then
        apt update -y && apt install -y cron
    elif command -v yum >/dev/null 2>&1; then
        yum install -y cronie
        systemctl enable crond
        systemctl start crond
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache dcron
        rc-update add dcron
        service dcron start
    else
        echo "❌ 无法自动安装 cron，请手动安装！"
        exit 1
    fi
}

install_cron

# ---------------------------------------------------------
# Step 2：安装 acme.sh
# ---------------------------------------------------------
if [ ! -x "$ACME_BIN" ]; then
    echo "--- ⬇️ acme.sh 未检测到，正在安装 ---"

    curl -sS https://get.acme.sh | sh || {
        echo "❌ acme.sh 安装失败，请检查网络"
        exit 1
    }

    if [ ! -x "$ACME_BIN" ]; then
        echo "❌ acme.sh 安装似乎失败，路径不存在：$ACME_BIN"
        exit 1
    fi
fi

echo "--- ✅ acme.sh 已就绪：$ACME_BIN ---"

# ---------------------------------------------------------
# Step 3：读取 Cloudflare 信息
# ---------------------------------------------------------
read -rp "请输入您的 SNI 域名: " DOMAIN_NAME
read -rp "请输入您的 Cloudflare 邮箱: " CF_EMAIL
read -rsp "请输入您的 Cloudflare Global API Key: " CF_KEY
echo

if [[ -z "$DOMAIN_NAME" || -z "$CF_EMAIL" || -z "$CF_KEY" ]]; then
    echo "❌ 域名 / 邮箱 / API Key 不能为空！"
    exit 1
fi

export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# ---------------------------------------------------------
# Step 4：确保 dns_cf 插件已安装
# ---------------------------------------------------------
if ! grep -q "dns_cf" "$ACME_HOME/dnsapi/dns_cf.sh"; then
    echo "❌ 未找到 Cloudflare DNS 插件！acme.sh 可能安装不完整"
    exit 1
fi

# ---------------------------------------------------------
# Step 5：申请证书
# ---------------------------------------------------------
echo "--- 🌐 正在申请 SSL 证书（Cloudflare DNS 验证） ---"

# 注册账户以确保 Let's Encrypt 成功率
"$ACME_BIN" --register-account -m "$CF_EMAIL" $CA_SERVER --home "$ACME_HOME" || true

if ! "$ACME_BIN" --home "$ACME_HOME" \
    --issue -d "$DOMAIN_NAME" \
    --dns dns_cf \
    $CA_SERVER --log; then

    echo "❌ 证书申请失败，请检查 CF API Key 或域名归属。"
    exit 1
fi

# ---------------------------------------------------------
# Step 6：安装证书
# ---------------------------------------------------------
RELOAD_CMD=""

if command -v systemctl >/dev/null 2>&1; then
    RELOAD_CMD="systemctl restart $SERVICE_NAME"
elif command -v service >/dev/null 2>&1; then
    RELOAD_CMD="service $SERVICE_NAME restart"
else
    RELOAD_CMD="echo '⚠️ 当前系统不支持自动重启服务，请手动处理！'"
fi

echo "--- 💿 正在安装证书到 $CERT_DIR ---"

"$ACME_BIN" --home "$ACME_HOME" --install-cert \
    -d "$DOMAIN_NAME" \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd "$RELOAD_CMD"

# ---------------------------------------------------------
# Step 7：设置 cron 自动续签
# ---------------------------------------------------------
echo "--- ⏱️ 正在配置 crontab 自动续签 ---"

(crontab -l 2>/dev/null | grep -v "$ACME_BIN" || true) | crontab -

(
    crontab -l 2>/dev/null
    echo "$CRON_SCHEDULE \"$ACME_BIN\" --cron --home \"$ACME_HOME\" > /tmp/V2bX-renew.log 2>&1"
) | crontab -

# ---------------------------------------------------------
# 完成
# ---------------------------------------------------------
unset CF_Email CF_Key

echo "========================================================="
echo "🎉 证书申请成功！"
echo "证书路径: $CERT_FILE"
echo "私钥路径: $KEY_FILE"
echo "自动续签任务已设置（每月 1 号执行一次）"
echo "证书续签后将执行：$RELOAD_CMD"
echo "========================================================="
exit 0
