#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 权限运行"
  exit 1
fi#!/bin/bash
# ==============================================================================
# V2bX + Nginx + Cloudflare DNS 一键部署脚本（终结版）
#
# 架构说明：
#   客户端 :443
#     └─ Nginx stream ssl 终结 TLS（握手特征完全是 Nginx）
#          └─ proxy_protocol → V2bX :1024（收明文 Trojan）
#               └─ EnableFallback → 回落到真实 Web :8080（由 V2bX 处理）
#
# 与旧版的核心区别：
#   ✅ TLS 由 Nginx 终结，GFW 主动探测拿到的是标准 Nginx 指纹
#   ✅ 回落由 V2bX FallBackConfigs 处理，Nginx 不再负责回落逻辑
#   ✅ proxy_protocol 固定开启，V2bX 获取真实客户端 IP
#   ✅ Nginx http 块承载真实伪装站（响应头/时序与正常建站一致）
#   ✅ worker_rlimit_nofile 置于顶层正确位置
#   ✅ 证书路径冲突检测
#   ✅ Nginx 官方源安装（gpg 签名验证）
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── 权限检查 ──────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 权限运行" >&2
  exit 1
fi

# ── 常量定义 ──────────────────────────────────────────────────────────────────
CERT_DIR="/etc/V2bX"
ACME_HOME="$HOME/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"
TROJAN_PORT=1024       # V2bX 监听端口（仅 127.0.0.1，接收 Nginx 转发的明文）
FALLBACK_PORT=8080     # 伪装站 HTTP 端口（仅 127.0.0.1，由 V2bX 回落触达）
NGINX_CONF="/etc/nginx/nginx.conf"

echo "=== V2bX + Nginx + Cloudflare DNS 一键部署（终结版）==="

# ── 交互输入 ──────────────────────────────────────────────────────────────────
read -rp "请输入域名 (example.com): "          DOMAIN
read -rp "请输入 Cloudflare 邮箱: "            CF_EMAIL
read -rp "请输入 Cloudflare Global API Key: "  CF_KEY

if [ -z "$DOMAIN" ] || [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
  echo "❌ 输入不能为空" >&2
  exit 1
fi

WWW_DIR="/var/www/$DOMAIN"

# ── 端口占用检测 ───────────────────────────────────────────────────────────────
for PORT in 443 "$TROJAN_PORT" "$FALLBACK_PORT"; do
  if ss -tlnp | awk '{print $4}' | grep -q ":${PORT}$"; then
    echo "❌ 端口 $PORT 已被占用，请先释放后再运行" >&2
    exit 1
  fi
done

# ── 证书路径冲突检测 ───────────────────────────────────────────────────────────
SKIP_CERT=false
if [ -f "$CERT_FILE" ] || [ -f "$KEY_FILE" ]; then
  echo "⚠️  检测到已有证书文件："
  [ -f "$CERT_FILE" ] && echo "    $CERT_FILE"
  [ -f "$KEY_FILE"  ] && echo "    $KEY_FILE"
  read -rp "是否覆盖重新申请？[y/N]: " OVERWRITE
  [[ "${OVERWRITE,,}" == "y" ]] && SKIP_CERT=false || SKIP_CERT=true
  [ "$SKIP_CERT" = true ] && echo "ℹ️  跳过证书申请，使用现有证书继续部署。"
fi

# ── 安装依赖 ──────────────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y curl wget gnupg2 lsb-release \
  software-properties-common apt-transport-https ca-certificates

# ── 安装 acme.sh ──────────────────────────────────────────────────────────────
if [ ! -f "$ACME_BIN" ]; then
  echo "📦 正在安装 acme.sh ..."
  curl -fsSL https://get.acme.sh | sh -s -- install --home "$ACME_HOME"
fi
echo "✅ acme.sh: $ACME_BIN"

# ── 申请证书 ──────────────────────────────────────────────────────────────────
if [ "$SKIP_CERT" = false ]; then
  echo "📜 正在申请证书（Let's Encrypt）..."
  export CF_Email="$CF_EMAIL"
  export CF_Key="$CF_KEY"

  "$ACME_BIN" --issue \
    -d "$DOMAIN" \
    --dns dns_cf \
    --server letsencrypt \
    --home "$ACME_HOME" \
    --log

  unset CF_Email CF_Key   # 申请完立即清除

  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"

  "$ACME_BIN" --install-cert -d "$DOMAIN" \
    --home "$ACME_HOME" \
    --key-file       "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd      "nginx -s reload || true"

  chmod 600 "$KEY_FILE" "$CERT_FILE"
else
  unset CF_Email CF_Key 2>/dev/null || true
fi

# ── 安装官方 Nginx（含 stream + ssl 模块）────────────────────────────────────
install_nginx_official() {
  local CODENAME
  CODENAME=$(lsb_release -cs)
  curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor > /usr/share/keyrings/nginx-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/debian $CODENAME nginx" \
    > /etc/apt/sources.list.d/nginx.list
  apt-get update -y
  apt-get install -y nginx
}

NGINX_OK=true
command -v nginx &>/dev/null || NGINX_OK=false
if [ "$NGINX_OK" = true ]; then
  nginx -V 2>&1 | grep -q -- '--with-stream_ssl_module' || NGINX_OK=false
fi
if [ "$NGINX_OK" = false ]; then
  echo "⚙️  安装官方 Nginx（含 stream_ssl 模块）..."
  install_nginx_official
fi

# ── 创建伪装站（真实 HTTP 站，由 V2bX 回落触达）──────────────────────────────
mkdir -p "$WWW_DIR"
if ! curl -fsSL \
  https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html \
  -o "$WWW_DIR/index.html" 2>/dev/null; then
  cat > "$WWW_DIR/index.html" <<HTML
<!DOCTYPE html>
<html><head><title>Welcome</title></head>
<body><h1>Welcome to $DOMAIN</h1></body></html>
HTML
fi
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# ── 生成 Nginx 配置 ────────────────────────────────────────────────────────────
#
# 架构：
#   stream 块：443 ssl 终结 TLS → proxy_protocol → V2bX :TROJAN_PORT
#   http   块：:FALLBACK_PORT 承载真实伪装站（仅本地，由 V2bX fallback 触达）
#
# 为什么 http 块的伪装站只监听本地：
#   正常用户访问 443 → Nginx stream 解 TLS → 转 V2bX
#   V2bX 判断是普通 HTTP 请求 → fallback 到 127.0.0.1:FALLBACK_PORT
#   伪装站对外不可直连，防止指纹对比
#
cat > "$NGINX_CONF" <<NGINX
# ── 顶层 ──────────────────────────────────────────────────────────────────────
user www-data;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 65536;   # 必须在顶层 main context

events {
    worker_connections 4096;
    multi_accept on;
}

# ── HTTP 层：伪装站（仅本地，由 V2bX fallback 到达）──────────────────────────
http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile     on;
    tcp_nopush   on;
    tcp_nodelay  on;
    keepalive_timeout 65;
    server_tokens off;

    server {
        # 仅监听本地，防止绕过 stream 层直连
        listen 127.0.0.1:${FALLBACK_PORT};
        server_name ${DOMAIN};
        root  ${WWW_DIR};
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html;
        }

        # 注意：此处不设 allow/deny，因为流量来源已是 V2bX 本地转发
        # 若需额外保护可加：allow 127.0.0.1; deny all;
    }
}

# ── Stream 层：TLS 终结 → proxy_protocol → V2bX ──────────────────────────────
stream {
    log_format stream_log '\$remote_addr [\$time_local] \$protocol '
                          '\$status \$bytes_sent \$bytes_received \$session_time';
    access_log /var/log/nginx/stream.log stream_log;

    server {
        listen 443 ssl reuseport;

        # TLS 在此终结，GFW 主动探测拿到的是标准 Nginx TLS 握手指纹
        ssl_certificate     ${CERT_FILE};
        ssl_certificate_key ${KEY_FILE};
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         EECDH+AESGCM:EECDH+CHACHA20:!aNULL:!MD5:!DSS;
        ssl_prefer_server_ciphers on;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;
        ssl_session_tickets off;

        # OCSP Stapling（减少客户端验证延迟）
        ssl_stapling        on;
        ssl_stapling_verify on;
        resolver            1.1.1.1 8.8.8.8 valid=300s;
        resolver_timeout    5s;

        proxy_timeout         300s;
        proxy_connect_timeout 10s;

        # proxy_protocol 开启：V2bX 端需设 EnableProxyProtocol: true
        # 作用：将真实客户端 IP 传递给 V2bX，用于审计/限速
        proxy_protocol on;

        proxy_pass 127.0.0.1:${TROJAN_PORT};
    }
}
NGINX

# ── 验证并启动 Nginx ──────────────────────────────────────────────────────────
nginx -t
systemctl enable nginx
systemctl restart nginx

# ── 自动续签（systemd timer）─────────────────────────────────────────────────
# acme.sh 会在 ~/.acme.sh/ 下缓存 CF 凭据，续签无需再次输入
cat > /etc/systemd/system/acme-renew.service <<SERVICE
[Unit]
Description=acme.sh certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=${ACME_BIN} --cron --home ${ACME_HOME} --reloadcmd "nginx -s reload"
SERVICE

cat > /etc/systemd/system/acme-renew.timer <<TIMER
[Unit]
Description=Daily acme.sh renewal at 03:00

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now acme-renew.timer

# ── 输出 V2bX 配置参考 ────────────────────────────────────────────────────────
echo ""
echo "✅ Nginx 部署完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  域名        : $DOMAIN"
echo "  证书        : $CERT_FILE"
echo "  私钥        : $KEY_FILE"
echo "  伪装站      : $WWW_DIR"
echo "  Nginx 配置  : $NGINX_CONF"
echo "  自动续签    : 每天 03:00（systemd timer）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  📋 V2bX ControllerConfig 关键配置（请对照修改）："
echo ""
echo "    ListenIP: 127.0.0.1"
echo "    EnableProxyProtocol: true   # 接收 Nginx 传来的真实 IP"
echo "    EnableFallback: true        # 开启回落"
echo "    FallBackConfigs:"
echo "      - SNI: $DOMAIN"
echo "        Dest: 127.0.0.1:$FALLBACK_PORT  # 回落到本地伪装站"
echo "        ProxyProtocolVer: 0"
echo "    CertConfig:"
echo "      CertMode: none            # TLS 已由 Nginx 处理，V2bX 不再需要证书"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ⚠️  注意：回落站点必须是 HTTP/1.1，不能是 HTTP/2"
echo "       （Nginx 中若有 h2 站点会导致全局变成 h2，Trojan 回落失败）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CERT_DIR="/etc/V2bX"
ACME_HOME="$HOME/.acme.sh"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/cert.key"
FALLBACK_PORT=8443
TROJAN_PORT=1024

echo "=== V2bX + Nginx + Cloudflare DNS 一键部署 ==="

read -p "请输入域名 (example.com): " DOMAIN
read -p "请输入 Cloudflare 邮箱: " CF_EMAIL
read -p "请输入 Cloudflare Global API Key: " CF_KEY

if [ -z "$DOMAIN" ] || [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
  echo "❌ 输入不能为空"
  exit 1
fi

# 安装依赖
apt update -y
apt install -y curl wget gnupg2 lsb-release software-properties-common apt-transport-https ca-certificates

# --- 检查并安装 acme.sh ---
ACME_BIN=$(command -v acme.sh 2>/dev/null || echo "$ACME_HOME/acme.sh")
if [ ! -f "$ACME_BIN" ]; then
  echo "📦 正在安装 acme.sh ..."
  curl -sS https://get.acme.sh | sh -s -- install
  source ~/.bashrc >/dev/null 2>&1 || true
  ACME_BIN="$ACME_HOME/acme.sh"
fi
echo "✅ acme.sh 路径: $ACME_BIN"

# --- 设置环境变量 ---
export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"

# --- 申请证书 ---
echo "📜 正在申请证书（Let's Encrypt 正式环境）..."
"$ACME_BIN" --issue -d "$DOMAIN" --dns dns_cf --server letsencrypt --log

mkdir -p "$CERT_DIR"
"$ACME_BIN" --install-cert -d "$DOMAIN" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE" \
  --reloadcmd "nginx -s reload || true"

unset CF_Email; unset CF_Key

# --- 安装官方 Nginx（带 stream 模块） ---
if ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
  echo "⚙️ 当前 Nginx 不支持 stream，安装官方版本..."
  codename=$(lsb_release -cs)
  echo "deb http://nginx.org/packages/debian $codename nginx" > /etc/apt/sources.list.d/nginx.list
  curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add -
  apt update -y
  apt install -y nginx
fi

# --- 创建伪装页 ---
WWW_DIR="/var/www/$DOMAIN"
mkdir -p "$WWW_DIR"
if ! curl -fsSL https://raw.githubusercontent.com/xn9kqy58k/nginx/main/index.html -o "$WWW_DIR/index.html"; then
  echo "<h1>Hello from internal fallback on $DOMAIN</h1>" > "$WWW_DIR/index.html"
fi
chown -R www-data:www-data "$WWW_DIR"
chmod -R 755 "$WWW_DIR"

# --- 生成 Nginx 配置 ---
NGINX_CONF="/etc/nginx/nginx.conf"
cat > "$NGINX_CONF" <<NGINX
user  www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
}

worker_rlimit_nofile 65536;

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 65;

    server_tokens off;

    server {
        listen 127.0.0.1:${FALLBACK_PORT};
        server_name localhost;
        root ${WWW_DIR};
        index index.html;
        location / {
            try_files \$uri /index.html;
            allow 127.0.0.1;
            deny all;
        }
    }
}

stream {
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'EECDH+AESGCM:EECDH+CHACHA20:!aNULL:!MD5:!DSS';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    server {
        listen 443 ssl reuseport proxy_protocol;
        proxy_timeout 300s;

        ssl_certificate ${CERT_FILE};
        ssl_certificate_key ${KEY_FILE};

        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 1.1.1.1 8.8.8.8 valid=300s;
        resolver_timeout 5s;

        proxy_pass 127.0.0.1:${TROJAN_PORT};
    }
}
NGINX

# --- 启动 Nginx ---
nginx -t
systemctl enable nginx
systemctl restart nginx

# --- 自动续签 ---
cat > /etc/systemd/system/acme-renew.service <<SERVICE
[Unit]
Description=acme.sh Renew Certificates and Reload Nginx
After=network-online.target

[Service]
Type=oneshot
ExecStart=${ACME_BIN} --cron --home ${ACME_HOME} --reloadcmd "nginx -s reload"
SERVICE

cat > /etc/systemd/system/acme-renew.timer <<TIMER
[Unit]
Description=Run acme.sh renew daily

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now acme-renew.timer

# --- 完成提示 ---
echo "✅ 部署完成！"
echo "域名: $DOMAIN"
echo "证书路径: $CERT_FILE"
echo "私钥路径: $KEY_FILE"
echo "伪装页路径: $WWW_DIR/index.html"
echo "Nginx 配置: $NGINX_CONF"
echo "自动续签: 每天凌晨 3 点"
echo "Trojan 服务请监听 127.0.0.1:${TROJAN_PORT}"
echo "本地回落端口: ${FALLBACK_PORT}"

