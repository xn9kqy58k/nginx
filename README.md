## tcp一键部署

```bash
bash <(curl -fsSL https://github.com/xn9kqy58k/nginx/raw/main/ngtcp.sh) </dev/tty
```
```bash
 "FallBackConfigs": [
        {
          "Dest": "127.0.0.1:8443",
          "ProxyProtocolVer": 0
        }
      ]
    }
  ]
}
}}

```
## grpc一键部署

```bash
bash <(curl -fsSL https://github.com/xn9kqy58k/nginx/raw/main/ng.sh) </dev/tty


```
# 检查 Nginx 配置语法
```bash
nginx -t
```
# 重启 Nginx 应用新配置
```bash
systemctl restart nginx
```
