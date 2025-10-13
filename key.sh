#!/bin/bash

# --- V2B-X 证书目标路径 ---
CERT_DIR="/etc/V2bX"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"

# --- 检查 acme.sh 是否安装，并自动安装 ---
# ... (acme.sh 安装与检查代码不变) ...

# 确定 acme.sh 的 home 目录（通常为 $HOME/.acme.sh，对于 root 就是 /root/.acme.sh）
ACME_HOME="$HOME/.acme.sh"

# 确定 acme.sh 可执行文件的实际路径
# 优先使用 PATH 中的命令；如果找不到，则回退到默认安装路径
ACME_BIN=$(command -v acme.sh 2>/dev/null || echo "$ACME_HOME/acme.sh")

if [ ! -f "$ACME_BIN" ]; then
    echo "--- 致命错误：acme.sh 可执行文件未找到 ($ACME_BIN)。请手动检查安装。脚本终止。---"
    exit 1
fi

echo "--- acme.sh 路径已确定: $ACME_BIN ---"

# --- 接收用户输入 ---
echo "--- V2B-X 证书申请脚本 (Cloudflare DNS 模式) ---"
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

# --- 申请证书 (使用 Let's Encrypt DNS 验证) ---
echo "--- 正在使用 Cloudflare DNS 验证模式申请证书 ---"

"$ACME_BIN" --issue \
  -d "$DOMAIN_NAME" \
  --dns dns_cf \
  --server letsencrypt

if [ $? -ne 0 ]; then
    echo "--- 错误：证书颁发失败！ ---"
    echo "请检查您的域名、Cloudflare 密钥和 DNS 设置是否正确。"
    unset CF_Email; unset CF_Key
    exit 1
fi

# --- 安装证书到指定路径 ---
echo "--- 证书颁发成功，正在安装到 $CERT_DIR ---"

mkdir -p "$CERT_DIR"

# 🌟 重点修改：加入 V2bX 服务名尝试重启
# 尝试重启 xray, 如果失败则尝试重启 v2ray, 如果再失败则尝试重启 v2bx
"$ACME_BIN" --install-cert \
  -d "$DOMAIN_NAME" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd  "systemctl restart xray || systemctl restart v2ray || systemctl restart v2bx || echo '警告：未能自动重启 V2bX 服务，请手动检查。'"

if [ $? -ne 0 ]; then
    echo "--- 警告：证书安装过程可能出现问题 ---"
    unset CF_Email; unset CF_Key
    exit 1
fi

# --- 清理环境变量 ---
unset CF_Email
unset CF_Key

echo "--- 证书申请与安装成功！ ---"
echo "证书文件路径: $CERT_FILE"
echo "私钥文件路径: $KEY_FILE"
echo "✅ 证书已配置为自动续签，并在续签成功后，自动重启 V2bX 服务！"
echo "请确保 Xray/V2Ray 服务能读取这些文件（尤其注意私钥的权限）。"
echo "首次运行后，请手动重启一次 V2bX 服务以加载新证书！"

exit 0
