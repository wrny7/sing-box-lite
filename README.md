# sing-box-lite

给自己用的精简版 sing-box 一键部署脚本。参考 eooce/Sing-box 的架构（nginx 长随机路径订阅 + Argo 隧道只给 VMess + 分体 JSON 配置），代码全部自己写，不复制任何一家。

只给以后装机 / 重装用，不动现役机器。

## 一次装好五个协议

| 协议 | 端口 | 说明 |
|---|---|---|
| VLESS + Reality Vision | 443 | 直连，伪装域名默认 www.yahoo.com |
| VMess + WS | 8001 | 默认走 Cloudflare Argo 隧道，只监听 127.0.0.1；`VMESS_DIRECT=y` 时改公网直连 8080 |
| Hysteria2 | 8443 UDP | |
| TUIC v5 | 8444 UDP | |
| AnyTLS | 8445 | |

订阅走 nginx，端口默认 45616。

## 安全默认值（写死的，不靠用户记得改）

- 订阅只认一条 48 位随机路径 `/<token>/sub`（另有 `/<token>/sub.txt` 同款），其余路径一律 404；根路径没有首页，直接 404；根目录不放订阅副本。
- 订阅路径是 exact location，不是目录 alias，`/token/state.env` 这种读法不存在。
- 全部密钥、密码、UUID、Reality 密钥对、自签证书都只存 `$SB_DIR/state.env`（600），重装、换机可以沿用；config.json 类文件 600；sub.txt 640 属组 www-data（nginx 要读）；key.pem 600、cert.pem 644。
- 公网 IP 探测顺序：AWS IMDSv2 → api.ipify.org → ifconfig.me；拿到私网段一律作废，绝不把 172.x 写进节点。
- sing-box 锁定 1.14.3、cloudflared 锁定 2026.11.0，只从官方 GitHub release 下载，SHA256 对不上直接退出。

## 安装

要求：Debian 12/13，root，systemd（没有 systemd 时用 nohup + crontab @reboot 兜底）。

```bash
curl -fsSL -o sb-lite.sh https://raw.githubusercontent.com/wrny7/sing-box-lite/main/sb-lite.sh
chmod +x sb-lite.sh
./sb-lite.sh install          # 交互式
./sb-lite.sh install --yes    # 全自动
```

装完打印五条节点链接和订阅地址，只显示这一次，自己存好。

## 管理命令

```bash
sb-lite status      # 状态、订阅地址、监听端口
sb-lite update      # 更新 sing-box 内核（锁定版本）
sb-lite regen       # 重新生成全部密码/密钥（旧节点全部失效）
sb-lite argo-guard  # 刷新 Argo 域名（cron 每 5 分钟跑）
sb-lite uninstall   # 卸载（二次确认）
sb-lite version     # 版本
```

## 环境变量（不设就用默认值）

| 变量 | 默认 | 说明 |
|---|---|---|
| `SB_LITE_DIR` | /etc/sb-lite | 安装目录 |
| `NODE_ADDR` | 自动探测 | 节点地址（公网 IP） |
| `NODE_NAME` | sb-lite | 节点名前缀 |
| `REALITY_SNI` | www.yahoo.com | Reality 伪装域名 |
| `VMESS_DIRECT` | n | y=VMess 公网直连 8080，n=走 Argo 隧道 |
| `PORT_VLESS` / `PORT_VMESS` / `PORT_HY2` / `PORT_TUIC` / `PORT_ANYTLS` / `PORT_SUB` | 443 / 8001 / 8443 / 8444 / 8445 / 45616 | 各协议端口；`PORT_VMESS_DIRECT`（8080）只在直连时用 |
| `SB_LITE_BIN` / `SB_LITE_CF_BIN` | /usr/local/bin/sing-box / /usr/local/bin/cloudflared | 二进制路径 |

## 文件

- `sb-lite.sh` — 唯一的脚本，全部功能都在里面。
- 安装后：`/etc/sb-lite/`（state.env、conf/、nodes.txt、sub.txt、argo.log）、`/usr/local/bin/sb-lite`（快捷命令）、`/etc/nginx/conf.d/sb-lite.conf`、systemd 单元 `sb-lite.service` / `sb-lite-argo.service`。

## 注意

- 订阅地址里的 token 是随机生成的，换机器、重装、regen 都会变，旧地址直接失效。
- Argo 域名会变，`argo-guard` 每 5 分钟检查一次，变了就同步重建订阅。
- 面板脚本自带更新会覆盖改动，更新前先看一眼改了什么。
