#!/bin/bash
# =========================================================
#  V2node SSL 证书自动申请与安装脚本（Cloudflare DNS 模式）
#  此版本增强了 acme.sh 安装容错和 API Key 静默输入功能。
# =========================================================

# --- 证书目标路径和 ACME 配置 ---
CERT_DIR="/etc/v2node"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"
ACME_HOME="$HOME/.acme.sh"

# --- 服务名称定义 ---
# 请根据您实际运行的服务名调整，例如 V2bX 或 v2node
SERVICE_NAME="v2node" 

# -----------------------------------------------------
# 步骤 1: 检查 acme.sh 是否已安装，否则自动安装
# -----------------------------------------------------
ACME_BIN=$(command -v acme.sh 2>/dev/null || echo "$ACME_HOME/acme.sh")

if [ ! -f "$ACME_BIN" ]; then
    echo "--- 未检测到 acme.sh，正在自动安装 ---"
    
    # 优化：尝试 Gitee 镜像加速安装，如果失败则回退到官方源
    if curl -sS https://gitee.com/neilpang/acme.sh/raw/master/acme.sh | sh -s -- install; then
        echo "--- acme.sh (Gitee 镜像) 安装成功 ---"
    elif curl -sS https://get.acme.sh | sh -s -- install; then
        echo "--- acme.sh (官方源) 安装成功 ---"
    else
        echo "❌ acme.sh 安装失败，请检查网络（特别是 Let's Encrypt CA 服务器连接）！"
        exit 1
    fi

    ACME_BIN="$ACME_HOME/acme.sh"
    # 加载 acme.sh 环境变量
    source "$HOME/.bashrc" >/dev/null 2>&1
    source "$HOME/.acme.sh/acme.sh.env" >/dev/null 2>&1
fi

echo "--- acme.sh 路径: $ACME_BIN ---"

# -----------------------------------------------------
# 步骤 2: 输入 Cloudflare DNS 信息
# -----------------------------------------------------
echo "--- SSL 证书申请程序 ---"

CA_SERVER="--server letsencrypt"

read -p "请输入您的 SNI 域名: " DOMAIN_NAME </dev/tty
read -p "请输入您的 Cloudflare 账号邮箱: " CF_EMAIL </dev/tty
# 优化：使用 -s 参数，防止 API Key 在终端显示 (静默输入)
read -p "请输入您的 Cloudflare Global API Key: " -s CF_KEY </dev/tty
echo # 确保 API Key 输入后换行

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
    echo "❌ 证书申请失败，请检查域名解析、Cloudflare API Key 权限，或尝试手动修复 hosts 文件。"
    unset CF_Email; unset CF_Key
    exit 1
fi

# -----------------------------------------------------
# 步骤 4: 安装证书并配置自动续签
# -----------------------------------------------------
echo "--- 证书申请成功，正在安装到 $CERT_DIR ---"
mkdir -p "$CERT_DIR"

# 使用 SERVICE_NAME 变量
RELOAD_CMD="systemctl restart $SERVICE_NAME || echo '⚠️ 未能自动重启 $SERVICE_NAME，请手动检查服务状态。'"

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
echo "✅ 系统已配置自动续签，并在续签成功后自动重启 $SERVICE_NAME 服务。"
echo "🎉 请检查您的 $SERVICE_NAME 服务是否已加载新证书并监听 443 端口。"
echo "------------------------------------------------------"
echo "完成！"

exit 0
