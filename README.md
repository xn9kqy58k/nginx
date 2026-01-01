## ws一键

```bash
bash <(curl -fsSL https://github.com/xn9kqy58k/nginx/raw/main/ws.sh)


```
## key一键

```bash
bash <(curl -fsSL https://github.com/xn9kqy58k/nginx/raw/main/key.sh)


```
## grpc一键

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
## tcp一键部署

```bash
bash <(curl -fsSL https://github.com/xn9kqy58k/nginx/raw/main/ngtcp.sh) </dev/tty
```
```bash
            "NodeType": "trojan",
      "Timeout": 30,
      "ListenIP": "127.0.0.1",
      "SendIP": "0.0.0.0",
      "DeviceOnlineMinTraffic": 64,
      "MinReportTraffic": 0,
      "EnableProxyProtocol": true,
      "EnableUot": true,
      "EnableTFO": true,
      "DNSType": "UseIPv4",
      "CertConfig": {
        "CertMode": "none",
        "RejectUnknownSni": true,
        "CertDomain": "example.com",
        "CertFile": "/etc/V2bX/fullchain.cer",
        "KeyFile": "/etc/V2bX/cert.key",
        "Email": "v2bx@github.com",
        "Provider": "cloudflare",
        "DNSEnv": {
          "EnvName": "env1"
        }
      },
      "EnableFallback": true,
      "FallBackConfigs": [
        {
          "Dest": "127.0.0.1:8443",
          "ProxyProtocolVer": 1
        }
      ]
    }
  ]
}




