bash <(cat <<'EOF'
set -e

echo "==> 1. 备份 gai.conf"
cp /etc/gai.conf /etc/gai.conf.bak.$(date +%s) 2>/dev/null || true

echo "==> 2. 设置系统优先 IPv4"
if grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
  sed -i 's/^precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
else
  echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
fi

echo "==> 3. 设置 apt 强制 IPv4"
mkdir -p /etc/apt/apt.conf.d
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

echo "==> 4. 临时禁用 IPv6"
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null || true

echo "==> 5. 永久禁用 IPv6"
sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf

cat >> /etc/sysctl.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL

sysctl -p >/dev/null || true

echo "==> 6. 重启代理相关服务"
for svc in v2node xray V2bX v2bx xrayr XrayR; do
  if systemctl list-unit-files | grep -q "^${svc}.service"; then
    echo "重启服务: $svc"
    systemctl restart "$svc" || true
  fi
done

echo "==> 7. 测试 IPv4 出站"
curl -4 -I https://www.google.com --connect-timeout 8 | head -n 5 || true

echo
echo "==> 8. 测试 IPv6 出站，禁用后失败是正常的"
curl -6 -I https://www.google.com --connect-timeout 5 || true

echo
echo "==> 完成"
echo "当前建议：v2node/Xray 配置里最好仍然把 freedom 出站设置为 domainStrategy: UseIPv4"
EOF
)
