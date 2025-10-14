#!/bin/bash

# --- V2B-X 证书目标路径 ---
CERT_DIR="/etc/V2bX"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"

# 确定 acme.sh 的 home 目录（通常为 $HOME/.acme.sh）
ACME_HOME="$HOME/.acme.sh"

# -----------------------------------------------------
# --- 步骤 1: 检查 acme.sh 是否安装，并自动安装 ---
# -----------------------------------------------------

# 尝试在 PATH 或默认位置寻找 acme.sh
ACME_BIN=$(command -v acme.sh 2>/dev/null || echo "$ACME_HOME/acme.sh")

if [ ! -f "$ACME_BIN" ]; then
    echo "--- 检测到 acme.sh 未安装，正在尝试自动安装 ---"
    
    # 使用 curl 下载并执行 acme.sh 安装脚本
    if curl -sS https://get.acme.sh | sh -s -- install; then
        echo "--- acme.sh 自动安装成功！ ---"
        # 重新设置可执行文件的路径
        ACME_BIN="$ACME_HOME/acme.sh"
        # 重新加载配置，确保在当前 shell 中可用 (重要)
        source "$HOME/.bashrc" >/dev/null 2>&1
    else
        echo "--- 致命错误：acme.sh 自动安装失败。请检查网络连接。脚本终止。---"
        exit 1
    fi
fi

echo "--- acme.sh 路径已确定: $ACME_BIN ---"

# -----------------------------------------------------
# --- 步骤 2: 接收用户输入 ---
# -----------------------------------------------------
echo "--- V2B-X 正式证书申请脚本 (Cloudflare DNS 模式) ---"

# 移除 Staging 选项，直接使用正式环境
CA_SERVER="--server letsencrypt"

read -p "请输入您的 SNI 域名 : " DOMAIN_NAME </dev/tty
read -p "请输入您的 Cloudflare 账号邮箱: " CF_EMAIL </dev/tty
read -p "请输入您的 Cloudflare Global API Key: " CF_KEY </dev/tty

# 检查输入是否为空
if [ -z "$DOMAIN_NAME" ] || [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
    echo "错误：域名、邮箱或 API 密钥不能为空。脚本终止。"
    exit 1
fi

# --- 设置环境变量 ---
export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# -----------------------------------------------------
# --- 步骤 3: 申请证书 (使用 Cloudflare DNS 验证) ---
# -----------------------------------------------------
echo "--- 正在使用 Let's Encrypt 正式环境申请证书 ---"

"$ACME_BIN" --issue \
  -d "$DOMAIN_NAME" \
  --dns dns_cf \
  $CA_SERVER \
  --log

if [ $? -ne 0 ]; then
    echo "--- 错误：证书颁发失败！ ---"
    echo "请检查您的域名、Cloudflare 密钥和 DNS 设置是否正确。"
    echo "🔔 注意：如果您遇到速率限制错误，请等待一周后再重试。"
    unset CF_Email; unset CF_Key
    exit 1
fi

# -----------------------------------------------------
# --- 步骤 4: 安装证书到指定路径 ---
# -----------------------------------------------------
echo "--- 证书颁发成功，正在安装到 $CERT_DIR ---"

mkdir -p "$CERT_DIR"

# 自动续签后的重启命令，依次尝试 Xray, V2Ray, V2bX
RELOAD_CMD="systemctl restart xray || systemctl restart v2ray || systemctl restart v2bx || echo '警告：未能自动重启 V2bX 服务，请手动检查。'"

"$ACME_BIN" --install-cert \
  -d "$DOMAIN_NAME" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "$RELOAD_CMD"

if [ $? -ne 0 ]; then
    echo "--- 警告：证书安装过程可能出现问题 ---"
    unset CF_Email; unset CF_Key
    exit 1
fi

# -----------------------------------------------------
# --- 步骤 5: 清理与完成 ---
# -----------------------------------------------------
unset CF_Email
unset CF_Key

echo "--- 证书申请与安装成功！ ---"
echo "证书文件路径: $CERT_FILE"
echo "私钥文件路径: $KEY_FILE"
echo "✅ 证书已配置为自动续签，并在续签成功后，自动重启 V2bX 服务！"
echo "🎉 恭喜！您已成功安装正式证书。"
echo "首次运行后，请手动重启一次 V2bX 服务以加载新证书！"

exit 0
