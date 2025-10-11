#!/bin/bash

# --- V2B-X 证书目标路径 ---
CERT_DIR="/etc/V2bX"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"

# --- 检查 acme.sh 是否安装，并自动安装 ---
# 首先检查 acme.sh 是否已安装
if ! command -v acme.sh &> /dev/null
then
    echo "--- 未检测到 acme.sh，正在自动安装... ---"
    
    # 执行安装命令
    curl https://get.acme.sh | sh
    
    # 检查安装是否成功
    if [ $? -ne 0 ]; then
        echo "--- 错误：acme.sh 自动安装失败！请检查网络或权限。脚本终止。---"
        exit 1
    fi
    
    # 尝试加载安装后的配置（仅作尝试，主要依赖后面的绝对路径调用）
    source ~/.bashrc &> /dev/null
    source ~/.profile &> /dev/null
    
    echo "--- acme.sh 安装完成。将继续证书申请流程。---"
fi

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
# 使用 < /dev/tty 确保即使脚本通过管道运行，也能从终端接收输入
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

# 使用 ACME_BIN 绝对路径执行命令，移除 --force 以便续期
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

# 确保目标目录存在
mkdir -p "$CERT_DIR"

# 安装证书
"$ACME_BIN" --install-cert \
  -d "$DOMAIN_NAME" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd  "echo V2B-X: 证书已安装，请手动重启 Xray/V2Ray 服务以使证书生效！"

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
echo "请确保 Xray/V2Ray 服务能读取这些文件（尤其注意私钥的权限）。"
echo "最后，请手动重启 Xray/V2Ray 服务！"

exit 0
