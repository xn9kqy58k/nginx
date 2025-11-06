#!/bin/bash
# =========================================================
#  V2node SSL 证书自动申请与安装脚本（Cloudflare DNS 模式）
#  采用 Cloudflare API Token 认证，更安全。
# =========================================================

# --- 证书目标路径和 ACME 配置 ---
CERT_DIR="/etc/v2node"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"
ACME_HOME="$HOME/.acme.sh"
SERVICE_NAME="v2node"  
CA_SERVER="--server letsencrypt"

# --- 清理可能残留的 ACME 环境变量 ---
unset CF_Email CF_Key CF_Token CF_Account_ID

# -----------------------------------------------------
# 步骤 1: 检查 acme.sh 是否已安装，否则自动安装
# -----------------------------------------------------
ACME_BIN=$(command -v acme.sh 2>/dev/null || echo "$ACME_HOME/acme.sh")

if [ ! -f "$ACME_BIN" ]; then
    echo "--- 未检测到 acme.sh，正在自动安装 ---"
    
    # 尝试 Gitee 镜像加速安装，如果失败则回退到官方源
    if curl -sS https://gitee.com/neilpang/acme.sh/raw/master/acme.sh | sh -s -- install; then
        echo "--- acme.sh (Gitee 镜像) 安装成功 ---"
    elif curl -sS https://get.acme.sh | sh -s -- install; then
        echo "--- acme.sh (官方源) 安装成功 ---"
    else
        echo "❌ acme.sh 安装失败，请检查网络！"
        exit 1
    fi

    ACME_BIN="$ACME_HOME/acme.sh"
fi

echo "--- acme.sh 路径: $ACME_BIN ---"

# -----------------------------------------------------
# 步骤 2: 输入 Cloudflare DNS 信息
# -----------------------------------------------------
echo "--- SSL 证书申请程序 ---"

# 使用 /dev/tty 确保在 SSH 或脚本中都能正确交互式输入
read -p "请输入您的 SNI 域名: " DOMAIN_NAME </dev/tty
read -p "请输入您的 Cloudflare 账号邮箱: " CF_EMAIL </dev/tty
# 新增: 提示使用更安全的 API Token
echo "⚠️ 建议使用仅有 'Zone/DNS/Edit' 权限的 API Token 代替 Global Key"
read -p "请输入您的 Cloudflare API Token: " -s CF_TOKEN </dev/tty
echo # 确保 API Token 输入后换行
read -p "请输入您的 Cloudflare Account ID: " CF_ACCOUNT_ID </dev/tty


# 检查输入是否为空
if [ -z "$DOMAIN_NAME" ] || [ -z "$CF_EMAIL" ] || [ -z "$CF_TOKEN" ] || [ -z "$CF_ACCOUNT_ID" ]; then
    echo "❌ 域名、邮箱、API Token 或 Account ID 不能为空！"
    exit 1
fi

# 导出 Cloudflare DNS 验证所需的环境变量
export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"
export CF_Account_ID="$CF_ACCOUNT_ID"

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
    echo "❌ 证书申请失败，请检查输入信息、域名解析或 API Token 权限。"
    unset CF_Email CF_Token CF_Account_ID
    exit 1
fi

# -----------------------------------------------------
# 步骤 4: 安装证书并配置自动续签
# -----------------------------------------------------
echo "--- 证书申请成功，正在安装到 $CERT_DIR ---"
mkdir -p "$CERT_DIR"

RELOAD_CMD="systemctl restart $SERVICE_NAME || echo '⚠️ 未能自动重启 $SERVICE_NAME，请手动检查服务状态。'"

"$ACME_BIN" --install-cert \
  -d "$DOMAIN_NAME" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "$RELOAD_CMD"

# -----------------------------------------------------
# 步骤 5: 完成清理与提示
# -----------------------------------------------------
unset CF_Email CF_Token CF_Account_ID

echo "✅ 证书申请与安装成功！"
echo "证书路径: $CERT_FILE"
echo "私钥路径: $KEY_FILE"
echo "✅ 系统已配置自动续签，并在续签成功后自动重启 $SERVICE_NAME 服务。"
echo "------------------------------------------------------"
echo "完成！"

exit 0
