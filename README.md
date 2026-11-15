# sing-box-lite

给自己用的精简版 sing-box 一键部署脚本。架构参考 eooce/Sing-box（nginx 长随机路径订阅 + Argo 隧道只给 VMess + 分体 JSON 配置），再综合 hallteacher/sb-smjm 的优点（管理菜单、一键自愈、固定隧道、状态页二维码、测试与抗封锁说明）。代码全部自己写，不复制任何一家。

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
- sing-box 锁定 1.14.3、cloudflared 锁定 2026.11.0、哪吒 agent 锁定 v2.4.0，只从官方 GitHub release 下载，SHA256 对不上直接退出。

## 安装

要求：Debian 12/13，root，systemd（没有 systemd 时用 nohup + crontab @reboot 兜底）。

```bash
# 新系统没有 curl 时先装上（B 的做法），其余依赖由脚本内部补装
command -v curl >/dev/null 2>&1 || { if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl; elif command -v dnf >/dev/null 2>&1; then dnf install -y curl; elif command -v yum >/dev/null 2>&1; then yum install -y curl; elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl; fi; }
bash <(curl -Ls https://raw.githubusercontent.com/wrny7/sing-box-lite/%E4%B8%BB%E8%A6%81%E7%9A%84/sb-lite.sh)
```

> 注意：当前默认分支叫 `主要的`（建仓页面是中文，分支名被本地化了），所以上面链接里是 URL 编码后的分支名。等真实测试通过后改成 `main`，链接就换回 `/main/`。

装完打印五条节点链接和订阅地址，只显示这一次，自己存好。

## 管理命令

不带参数直接进管理菜单（终端里）：

```bash
sb-lite                  # 交互式管理菜单
sb-lite install [--yes]  # 安装（交互式 / 全自动）
sb-lite status           # 状态、订阅地址、监听端口、订阅二维码
sb-lite update           # 更新 sing-box 内核（锁定版本）
sb-lite regen            # 重新生成全部密码/密钥（旧节点全部失效）
sb-lite heal             # 一键自愈：重起服务、刷新 Argo、重建订阅
sb-lite direct           # 拆掉 Argo，VMess 改公网直连
sb-lite argo [--temp]    # 开 Argo（临时隧道；带凭证则用固定隧道）
sb-lite config           # 单独改端口 / SNI / 节点名
sb-lite upgrade          # 更新本脚本到 GitHub 最新版
sb-lite argo-guard       # 刷新 Argo 域名（cron 每 5 分钟跑）
sb-lite uninstall        # 卸载（二次确认）
sb-lite version          # 版本
```

短参数：`-i` 安装 / `-c` 状态 / `-r` 刷新 Argo / `-u` 卸载 / `-h` 帮助。

## 环境变量（不设就用默认值）

| 变量 | 默认 | 说明 |
|---|---|---|
| `SB_LITE_DIR` | /etc/sb-lite | 安装目录 |
| `NODE_ADDR` | 自动探测 | 节点地址（公网 IP） |
| `NODE_NAME` | sb-lite | 节点名前缀 |
| `REALITY_SNI` | www.yahoo.com | Reality 伪装域名 |
| `VMESS_DIRECT` | n | y=VMess 公网直连，n=走 Argo 隧道 |
| `PORT` | 空 | 基数端口（NAT 机用）：VLESS=PORT，VMess=PORT+1，HY2=PORT+2，TUIC=PORT+3，AnyTLS=PORT+4，订阅=PORT+5；单独设的 `PORT_*` 优先 |
| `PORT_VLESS` / `PORT_VMESS` / `PORT_HY2` / `PORT_TUIC` / `PORT_ANYTLS` / `PORT_SUB` | 443 / 8001 / 8443 / 8444 / 8445 / 45616 | 各协议端口；`PORT_VMESS_DIRECT`（8080）只在直连时用 |
| `CFIP` / `CFPORT` | 空 / 443 | Argo 节点优选 IP/端口（默认走隧道域名:443；设了优选就用优选 IP，host 字段写隧道域名当 SNI） |
| `ARGO_DOMAIN` / `ARGO_AUTH` | 空 | 固定隧道：域名 + Token 或 JSON 凭证（不设=临时隧道） |
| `NEZHA_SERVER` / `NEZHA_KEY` / `NEZHA_TLS` | 空 | 哪吒探针 v1（可选）：服务端 host:port、客户端密钥；TLS 留空按端口自动判断 |
| `CHAT_ID` / `BOT_TOKEN` | 空 | Telegram 通知（可选）：装完把订阅地址发到指定聊天 |
| `SB_LITE_BIN` / `SB_LITE_CF_BIN` / `NZ_BIN` | /usr/local/bin/sing-box / cloudflared / nezha-agent | 二进制路径 |

## Argo 隧道

VMess 默认走 Cloudflare Argo 隧道，只监听 127.0.0.1，真实 IP 不暴露。两种模式：

- **临时隧道**（默认）：免域名，域名从日志里抓，重启会换。`argo-guard` 每 5 分钟巡检，换了就同步重建订阅，客户端重新拉一次订阅即可。
- **固定隧道**：在 Cloudflare 后台（Zero Trust → Networks → Tunnels）建隧道，把域名指向 `http://127.0.0.1:<VMess端口>`，把 Token（或 JSON 凭证）填进 `ARGO_AUTH`、域名填进 `ARGO_DOMAIN`。域名永远不变，订阅永远有效。

`sb-lite direct` 拆掉 Argo 改直连，`sb-lite argo` 再开回来；`sb-lite heal` 一键自愈（隧道挂了、域名变了都适用）。

## 抗封锁说明

一句话：脚本给的是「合格的伪装」，不是「免死金牌」。封不封取决于「协议伪装 + IP 质量 + 流量特征」三者组合，脚本只解决第一项。

| 协议 | 抗封锁原理 | 强度 | 风险点 |
|---|---|---|---|
| **VLESS-Reality** | 偷真实网站的 TLS 握手，被主动探测时返回真实站点证书 | ⭐⭐⭐⭐⭐ | 默认偷 `www.yahoo.com`，全网共用同一 SNI 反而成了特征；机房 IP 被标记照样废 |
| **AnyTLS** | 流量长得像普通 HTTPS，设计目标就是对标 Reality 抗主动探测 | ⭐⭐⭐⭐ | 生态新、特征库没经过大规模实战；本脚本用自签证书 |
| **Hysteria2** | 基于 QUIC，伪装成 HTTP/3 | ⭐⭐⭐⭐ | 走 UDP，运营商 QoS 常限速/丢弃 UDP；自签证书 |
| **TUIC v5** | 同 Hysteria2，QUIC 系 | ⭐⭐⭐⭐ | 同上（UDP + 自签证书） |
| **VMess-WS** | 走 WebSocket，套 Argo/CDN 后出口是 Cloudflare 的 IP | ⭐⭐⭐½ | 明文 WS：Argo 正常时只听 127.0.0.1 没问题；没装 Argo 或 Argo 启动失败，就是公网裸奔 |

想更稳：换掉默认 Reality SNI（`sb-lite config` 里改，挑个同区流行站）；VMess 一定套 Argo（明文 WS 是最薄弱的一环）；订阅 token 是 48 位随机串，别换成短的；单机别 24 小时满速跑。

## 文件

- `sb-lite.sh` — 唯一的脚本，全部功能都在里面。
- `tests/run_tests.sh` — 本地测试套件（语法、随机数、端口派生、Argo 域名解析、state 存取、配置校验、链接生成、CFIP 优选、非交互调用）。
- 安装后：`/etc/sb-lite/`（state.env、conf/、nodes.txt、sub.txt、argo.log、argo.json）、`/usr/local/bin/sb-lite`（快捷命令）、`/etc/nginx/conf.d/sb-lite.conf`、systemd 单元 `sb-lite.service` / `sb-lite-argo.service` / `sb-lite-nezha.service`（装了探针才有）、cron 里 `*/5 * * * * sb-lite argo-guard`。

## 测试

```bash
bash tests/run_tests.sh   # 30 项：语法、随机数、端口派生、Argo 解析、state 存取、
                          # 配置校验、链接生成、CFIP 优选、非交互调用
```

配置校验那几项需要 sing-box 二进制（没有就跳过）：`SB_LITE_BIN=/path/to/sing-box bash tests/run_tests.sh`。

## 注意

- 订阅地址里的 token 是随机生成的，换机器、重装、regen 都会变，旧地址直接失效。
- Argo 临时隧道域名会变，`argo-guard` 每 5 分钟检查一次，变了就同步重建订阅；客户端把「自动更新订阅」设为每小时，基本无感。
- 临时隧道刚装好 60 秒内没拿到域名时，VMess 节点先用优选 IP / 直连地址占位（连不上），等 `argo-guard` 拿到域名就自动修好。
- 面板脚本自带更新会覆盖改动，更新前先看一眼改了什么。

## 不做的事（有意没抄的）

- **Serv00 / 游戏机版**：VPS 专用，共享主机和游戏机托管是另一套东西，不往一个脚本里塞。
- **单协议一键脚本**：lite 一次装五个协议，拆单协议是另一个产品形态。
- **订阅上传到汇聚订阅器**：订阅走自己 IP 的本地 nginx，不依赖第三方聚合站。
- **VMess-WS-TLS 自有证书模式**：VLESS-Reality + VMess-Argo 已经覆盖了 TLS 场景，再加一个 inbound 是冗余。
- **默认解锁 GPT / 奈飞**：那不是配置技巧能做到的，要 WARP 或特殊出口；不写做不到的承诺。
- **订阅服务 python fallback**：nginx 是设计的一部分；python http.server 做不到 exact-location 的 token 路径校验（那正是悉尼那台 8199 泄露的根源）。
- **FreeBSD**：Debian 12/13 专用。
