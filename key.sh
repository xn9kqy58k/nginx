#!/bin/bash

# --- V2B-X 证书目标路径 ---
CERT_DIR="/etc/V2bX"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"

# --- 检查 acme.sh 是否安装，并自动安装 ---
if ! command -v acme.sh &> /dev/null
then
    echo "--- 未检测到 acme.sh，正在自动安装... ---"
    # 执行安装命令
    curl https://get.acme.sh | sh

    # 检查安装是否成功
    if [ $? -ne 0 ]; then
        echo "--- 错误：acme.sh 自动安装失败！请检查网络或权限。---"
        exit 1
    fi

    # 尝试加载安装后的配置（通常会写入到 ~/.bashrc 或 ~/.profile）
    # 注意：在非交互式脚本中，source 可能只对当前子 shell 有效，
    # 但由于 acme.sh 安装后通常会创建一个 ~/.acme.sh 目录，我们可以直接调用其内部脚本。
    PROFILE_FILE="$HOME/.bashrc"
    [ -f "$HOME/.zshrc" ] && PROFILE_FILE="$HOME/.zshrc"
    [ -f "$HOME/.profile" ] && PROFILE_FILE="$HOME/.profile"
    
    # 尝试 source 配置，让 acme.sh 命令在当前 shell 生效
    if [ -f "$PROFILE_FILE" ]; then
        # 尝试加载配置
        source "$PROFILE_FILE" &> /dev/null
    fi
    
    # 再次检查 acme.sh 是否可用
    if ! command -v acme.sh &> /dev/null; then
        echo "--- 警告：acme.sh 命令路径未自动加载。将尝试使用硬编码路径。---"
    fi
fi

# 确定 acme.sh 的 home 目录（通常为 /root/.acme.sh）
ACME_HOME="$HOME/.acme.sh"
export ACME_HOME

# 确定 acme.sh 可执行文件的路径
ACME_BIN=$(command -v acme.sh || echo "$ACME_HOME/acme.sh")
if [ ! -f "$ACME_BIN" ]; then
    echo "--- 致命错误：acme.sh 未找到，无法继续。请手动检查安装。---"
    exit 1
fi
echo "--- acme.sh 路径: $ACME_BIN ---"


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

# 尝试颁发证书 (移除 --force，避免浪费额度，让 acme.sh 自动判断是否续期)
"$ACME_BIN" --issue \
  -d "$DOMAIN_NAME" \
  --dns dns_cf \
  --server letsencrypt

if [ $? -ne 0 ]; then
    echo "--- 错误：证书颁发失败！ ---"
    echo "请检查您的域名、Cloudflare 密钥和 DNS 设置是否正确。"
    # 清理环境变量
    unset CF_Email
    unset CF_Key
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
    # 清理环境变量
    unset CF_Email
    unset CF_Key
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
