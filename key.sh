#!/bin/bash
# =========================================================
#  v2node Let's Encrypt 证书自动申请与安装脚本（Cloudflare DNS 模式）
# =========================================================

# --- 证书目标路径 ---
CERT_DIR="/etc/v2node"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"

# --- acme.sh 位置 ---
ACME_HOME="$HOME/.acme.sh"

# -----------------------------------------------------
# 步骤 1: 检查 acme.sh 是否已安装，否则自动安装
# -----------------------------------------------------
ACME_BIN=$(command -v acme.sh 2>/dev/null || echo "$ACME_HOME/acme.sh")

if [ ! -f "$ACME_BIN" ]; then
    echo "--- 未检测到 acme.sh，正在自动安装 ---"
    if curl -sS https://get.acme.sh | sh -s -- install; then
        echo "--- acme.sh 安装成功 ---"
        ACME_BIN="$ACME_HOME/acme.sh"
        source "$HOME/.bashrc" >/dev/null 2>&1
    else
        echo "❌ acme.sh 安装失败，请检查网络或代理设置。"
        exit 1
    fi
fi

echo "--- acme.sh 路径: $ACME_BIN ---"

# -----------------------------------------------------
# 步骤 2: 输入 Cloudflare DNS 信息
# -----------------------------------------------------
echo "--- v2node SSL 证书申请程序（使用 Let's Encrypt 正式环境） ---"

CA_SERVER="--server letsencrypt"

read -p "请输入您的 SNI 域名 : " DOMAIN_NAME </dev/tty
read -p "请输入您的 Cloudflare 账号邮箱: " CF_EMAIL </dev/tty
read -p "请输入您的 Cloudflare Global API Key: " CF_KEY </dev/tty

if [ -z "$DOMAIN_NAME" ] || [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
    echo "❌ 域名、邮箱或 API Key 不能为空！"
    exit 1
fi

export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# -----------------------------------------------------
# 步骤 3: 使用 Cloudflare DNS 验证申请证书
# -----------------------------------------------------
echo "--- 正在申请证书（DNS 验证模式） ---"

"$ACME_BIN" --issue \
  -d "$DOMAIN_NAME" \
  --dns dns_cf \
  $CA_SERVER \
  --log

if [ $? -ne 0 ]; then
    echo "❌ 证书申请失败，请检查域名解析或 Cloudflare API Key 设置。"
    unset CF_Email; unset CF_Key
    exit 1
fi

# -----------------------------------------------------
# 步骤 4: 安装证书并配置自动续签
# -----------------------------------------------------
echo "--- 证书申请成功，正在安装到 $CERT_DIR ---"
mkdir -p "$CERT_DIR"

RELOAD_CMD="systemctl restart v2node || echo '⚠️ 未能自动重启 v2node，请手动检查服务状态。'"

"$ACME_BIN" --install-cert \
  -d "$DOMAIN_NAME" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "$RELOAD_CMD"

if [ $? -ne 0 ]; then
    echo "⚠️ 证书安装过程中出现问题，请手动检查。"
    unset CF_Email; unset CF_Key
    exit 1
fi

# -----------------------------------------------------
# 步骤 5: 完成清理与提示
# -----------------------------------------------------
unset CF_Email
unset CF_Key

echo "✅ 证书申请与安装成功！"
echo "证书路径: $CERT_FILE"
echo "私钥路径: $KEY_FILE"
echo "✅ 系统已配置自动续签，并在续签成功后自动重启 v2node 服务。"
echo "🎉 请手动执行以下命令，确保 v2node 加载新证书："
echo "   systemctl restart v2node"
echo "------------------------------------------------------"
echo "完成！"

exit 0
