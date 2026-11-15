#!/usr/bin/env bash
# ============================================================================
# sb-lite.sh — 精简版 sing-box 一键部署脚本（VPS 版）
#
# 咱自己的仓库：https://github.com/wrny7/sing-box-lite
# 架构参考 eooce/Sing-box（nginx 长随机路径订阅 + Argo 隧道 + 分体配置），
# 再综合 hallteacher/sb-smjm 的优点（管理菜单、一键自愈、固定隧道、
# 状态页二维码、测试与抗封锁说明）；代码全部自己写，只留自己用的协议，
# 安全默认值写死。
#
# 协议（五协议同开）：
#   VLESS-Reality-Vision / VMess-WS（走 Argo 隧道）/
#   Hysteria2 / TUIC v5 / AnyTLS
# 订阅：nginx 在 45616 端口，只认一条 48 位随机路径，其余全部 404，
#   首页不写地址，根目录不放订阅副本。
#
# 用法（需 root）：
#   bash sb-lite.sh                 # 交互式管理菜单（终端里）
#   bash sb-lite.sh install         # 交互式安装（括号里是默认值，回车即用）
#   bash sb-lite.sh install --yes   # 全自动安装，全部走默认值
#   bash sb-lite.sh status          # 看节点、订阅、运行状态（带二维码）
#   bash sb-lite.sh update          # 更新 sing-box 内核到锁定版本
#   bash sb-lite.sh regen           # 重新生成全部密码/密钥（订阅随之变）
#   bash sb-lite.sh heal            # 一键自愈：重起服务、刷新 Argo、重建订阅
#   bash sb-lite.sh direct          # 拆掉 Argo，VMess 改公网直连
#   bash sb-lite.sh argo            # 开 Argo（临时隧道；带 ARGO_AUTH 则用固定隧道）
#   bash sb-lite.sh config          # 单独改端口 / SNI / 节点名
#   bash sb-lite.sh upgrade         # 更新本脚本到 GitHub 最新版
#   bash sb-lite.sh argo-guard      # 刷新 Argo 域名到订阅（供 cron 每 5 分钟跑）
#   bash sb-lite.sh uninstall       # 卸载（二次确认）
#   bash sb-lite.sh version         # 看脚本版本
# 短参数：-i 安装 / -c 状态 / -r 刷新 Argo / -u 卸载 / -h 帮助
#
# 环境变量可覆盖默认值（安装时也可直接改 state.env 再跑 regen）：
#   SB_LITE_DIR / NODE_ADDR / NODE_NAME / REALITY_SNI / VMESS_DIRECT
#   PORT        # 基数端口（NAT 机用）：VLESS=PORT，VMess=PORT+1，
#               #   HY2=PORT+2，TUIC=PORT+3，AnyTLS=PORT+4，订阅=PORT+5；
#               #   单独设的 PORT_* 优先于 PORT 派生
#   PORT_VLESS / PORT_VMESS / PORT_VMESS_DIRECT / PORT_HY2 /
#   PORT_TUIC / PORT_ANYTLS / PORT_SUB
#   CFIP / CFPORT   # Argo 节点优选 IP/端口（默认走隧道域名:443）
#   ARGO_DOMAIN / ARGO_AUTH  # 固定隧道：域名 + Token 或 JSON 凭证
#   NEZHA_SERVER / NEZHA_KEY / NEZHA_TLS  # 哪吒探针（可选，不设就不装）
# ============================================================================
set -uo pipefail

SB_LITE_VERSION="1.1.2"
SB_VERSION="1.14.3"                       # 锁定的 sing-box 版本
SB_SHA256="e2bdf179c15a3652955dc44867e33ca0965c9c9b91b34267dcc5a5d639a5feee"                 # sing-box 安装包 SHA256（实测值）
CF_VERSION="2026.11.0"                    # 锁定的 cloudflared 版本
CF_SHA256="51f7c68b57ed7269164075d7e789efce5b59355982f06392deeb037d982a51fd"                 # cloudflared SHA256（实测值）
NZ_VERSION="v2.4.0"                       # 锁定的哪吒 agent 版本（可选功能）
NZ_SHA256_AMD64="0071f57e4dd42bd91adfdfb84291a1ebbc8b45c67f3511987e5982bea5eade7f"
NZ_SHA256_ARM64="c9e0a4e0dfa64b6f4759c80502607aab77274711a350cb208011f21df1b52a79"
UPGRADE_URL="https://raw.githubusercontent.com/wrny7/sing-box-lite/%E4%B8%BB%E8%A6%81%E7%9A%84/sb-lite.sh"

SB_DIR="${SB_LITE_DIR:-/etc/sb-lite}"
SB_BIN="${SB_LITE_BIN:-/usr/local/bin/sing-box}"
CF_BIN="${SB_LITE_CF_BIN:-/usr/local/bin/cloudflared}"
STATE_FILE="$SB_DIR/state.env"
CONF_DIR="$SB_DIR/conf"
WEB_DIR="$SB_DIR/web"

NODE_ADDR="${NODE_ADDR:-}"
PORT_VLESS="${PORT_VLESS:-443}"
PORT_VMESS="${PORT_VMESS:-8001}"
PORT_VMESS_DIRECT="${PORT_VMESS_DIRECT:-8080}"
PORT_HY2="${PORT_HY2:-8443}"
PORT_TUIC="${PORT_TUIC:-8444}"
PORT_ANYTLS="${PORT_ANYTLS:-8445}"
PORT_SUB="${PORT_SUB:-45616}"
REALITY_SNI="${REALITY_SNI:-www.yahoo.com}"
VMESS_DIRECT="${VMESS_DIRECT:-n}"
NODE_NAME="${NODE_NAME:-sb-lite}"

# 扩展变量（全部可选，不设就不用）
PORT="${PORT:-}"                 # 基数端口：只设这一个，六个端口按顺序派生
CFIP="${CFIP:-}"                 # Argo 节点优选 IP/域名（默认走隧道域名）
CFPORT="${CFPORT:-}"             # Argo 节点优选端口（默认 443）
ARGO_DOMAIN="${ARGO_DOMAIN:-}"   # 固定隧道域名（临时隧道时自动填）
ARGO_AUTH="${ARGO_AUTH:-}"       # 固定隧道凭证：Token 或 JSON（不设=临时隧道）
NEZHA_SERVER="${NEZHA_SERVER:-}" # 哪吒服务端 host:port（不设=不装探针）
NEZHA_KEY="${NEZHA_KEY:-}"       # 哪吒客户端密钥
NEZHA_TLS="${NEZHA_TLS:-}"       # 哪吒是否 TLS（留空按端口自动判断）

# PORT 基数派生：只在对应 PORT_* 还是默认值时才派生，单独设过的优先。
if [ -n "$PORT" ]; then
  [ "$PORT_VLESS" = "443" ]   && PORT_VLESS="$PORT"
  [ "$PORT_VMESS" = "8001" ]  && PORT_VMESS="$((PORT + 1))"
  [ "$PORT_VMESS_DIRECT" = "8080" ] && PORT_VMESS_DIRECT="$((PORT + 1))"
  [ "$PORT_HY2" = "8443" ]    && PORT_HY2="$((PORT + 2))"
  [ "$PORT_TUIC" = "8444" ]   && PORT_TUIC="$((PORT + 3))"
  [ "$PORT_ANYTLS" = "8445" ] && PORT_ANYTLS="$((PORT + 4))"
  [ "$PORT_SUB" = "45616" ]   && PORT_SUB="$((PORT + 5))"
fi

# ---------------- 基础工具 ----------------
info()  { printf '[+] %s\n' "$*"; }
warn()  { printf '[!] %s\n' "$*" >&2; }
die()   { printf '[x] %s\n' "$*" >&2; exit 1; }

rand_hex()  { # $1=字节数 -> 十六进制串
  head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
}
rand_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || \
      head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}
b64() { base64 -w0 2>/dev/null || base64; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺命令 $1，请先装好（curl / tar / openssl / python3 / nginx）"
}

# ---------------- 公网 IP 探测 ----------------
# 云主机网卡上只有内网 IP，必须先问元数据服务，再问公共接口，
# 拿不到就让用户手填，绝不把 172.x 写进节点。
detect_public_ip() {
  local ip=""
  # AWS IMDSv2
  local tok
  tok=$(curl -fsS -m 3 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    'http://169.254.169.254/latest/api/token' 2>/dev/null || true)
  if [ -n "$tok" ]; then
    ip=$(curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $tok" \
      'http://169.254.169.254/latest/meta-data/public-ipv4' 2>/dev/null || true)
  fi
  # 公共接口兜底
  if [ -z "$ip" ]; then
    ip=$(curl -fsS -m 5 'https://api.ipify.org' 2>/dev/null || true)
  fi
  if [ -z "$ip" ]; then
    ip=$(curl -fsS -m 5 'https://ifconfig.me/ip' 2>/dev/null || true)
  fi
  # 拒绝私网段
  case "$ip" in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*|127.*|"") ip="" ;;
  esac
  printf '%s' "$ip"
}

# ---------------- 端口占用检查 ----------------
# 注意：不检查 PORT_SUB，那是 nginx 的订阅端口，本来就占着，
# write_nginx 里直接 reload，不用它空出来。
check_ports_free() {
  local p used=""
  for p in "$PORT_VLESS" "$PORT_VMESS" "$PORT_HY2" "$PORT_TUIC" "$PORT_ANYTLS"; do
    if ss -tln 2>/dev/null | grep -q ":$p " || ss -uln 2>/dev/null | grep -q ":$p "; then
      used="$used $p"
    fi
  done
  [ -z "$used" ] || die "端口被占用：$used，请先停掉占用进程或改端口"
}

# ---------------- 下载并校验 ----------------
# 只从官方 release 拉二进制，SHA256 对不上就直接退出，绝不将就。
download_verified() { # $1=url $2=期望sha256 $3=输出路径
  local url="$1" want="$2" out="$3"
  info "下载 $url"
  curl -fL --retry 2 --connect-timeout 10 -o "$out" "$url" \
    || die "下载失败：$url"
  local got
  got=$(sha256sum "$out" | awk '{print $1}')
  [ "$got" = "$want" ] || die "SHA256 不符：$out（可能被篡改或版本不对），已停止"
}

install_sing_box() {
  if [ -x "$SB_BIN" ] && [ "$("$SB_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" = "$SB_VERSION" ]; then
    info "sing-box $SB_VERSION 已在，无需重装"
    return 0
  fi
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  local tmp; tmp=$(mktemp -d)
  local tgz="$tmp/sing-box.tar.gz"
  download_verified \
    "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${arch}.tar.gz" \
    "$SB_SHA256" "$tgz"
  tar -xzf "$tgz" -C "$tmp" || die "解包失败"
  mkdir -p "$(dirname "$SB_BIN")"
  install -m 755 "$tmp/sing-box-${SB_VERSION}-linux-${arch}/sing-box" "$SB_BIN" \
    || die "安装 sing-box 失败"
  rm -rf "$tmp"
  info "sing-box $SB_VERSION 已装到 $SB_BIN"
}

install_cloudflared() {
  [ -x "$CF_BIN" ] && { info "cloudflared 已在"; return 0; }
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  local tmp; tmp=$(mktemp -d)
  local bin="$tmp/cloudflared"
  download_verified \
    "https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-${arch}" \
    "$CF_SHA256" "$bin"
  mkdir -p "$(dirname "$CF_BIN")"
  install -m 755 "$bin" "$CF_BIN" || die "安装 cloudflared 失败"
  rm -rf "$tmp"
  info "cloudflared $CF_VERSION 已装到 $CF_BIN"
}

install_deps() {
  need_cmd curl; need_cmd tar; need_cmd openssl; need_cmd python3; need_cmd ss
  if ! command -v nginx >/dev/null 2>&1; then
    info "装 nginx（订阅服务用）"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx \
        || die "nginx 安装失败"
    else
      die "没找到 nginx，请先手动装好"
    fi
  fi
  # cron：Argo 域名巡检（argo-guard）和无 systemd 时的开机自启都靠它；
  # AWS 的 Debian 镜像出厂就不带 cron，不装的话巡检会静默失效。
  if ! command -v crontab >/dev/null 2>&1; then
    info "装 cron（定时巡检用）"
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron \
        || die "cron 安装失败"
    else
      die "没找到 cron，请先手动装好"
    fi
  fi
  # 订阅二维码用（装不上也不影响节点，status 里直接跳过）
  if ! command -v qrencode >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode 2>/dev/null || true
  fi
}

# ---------------- 状态（全部密钥只存 state.env，600） ----------------
# state.env 里有什么：UUID、各协议密码、Reality 密钥对、订阅 token、
# VMess 路径、Argo 域名、端口、节点地址。重装、换机都能沿用。
load_state() {
  [ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

save_state() {
  mkdir -p "$SB_DIR"
  cat > "$STATE_FILE" <<EOF
NODE_ADDR=$NODE_ADDR
NODE_NAME=$NODE_NAME
PORT_VLESS=$PORT_VLESS
PORT_VMESS=$PORT_VMESS
PORT_VMESS_DIRECT=$PORT_VMESS_DIRECT
PORT_HY2=$PORT_HY2
PORT_TUIC=$PORT_TUIC
PORT_ANYTLS=$PORT_ANYTLS
PORT_SUB=$PORT_SUB
REALITY_SNI=$REALITY_SNI
VMESS_DIRECT=$VMESS_DIRECT
UUID=$UUID
HY2_PASS=$HY2_PASS
TUIC_PASS=$TUIC_PASS
ANYTLS_PASS=$ANYTLS_PASS
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_SHORT_ID=$REALITY_SHORT_ID
VMESS_PATH=$VMESS_PATH
SUB_TOKEN=$SUB_TOKEN
ARGO_DOMAIN=$ARGO_DOMAIN
CFIP=$CFIP
CFPORT=$CFPORT
NEZHA_SERVER=$NEZHA_SERVER
NEZHA_KEY=$NEZHA_KEY
NEZHA_TLS=$NEZHA_TLS
EOF
  # ARGO_AUTH 可能是 JSON（含引号/空格），必须 shell 转义后存，否则 source 会炸
  printf 'ARGO_AUTH=%q\n' "$ARGO_AUTH" >> "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

gen_secrets() {
  mkdir -p "$SB_DIR" "$CONF_DIR"
  UUID="${UUID:-$(rand_uuid)}"
  HY2_PASS="${HY2_PASS:-$(rand_hex 16)}"
  TUIC_PASS="${TUIC_PASS:-$(rand_hex 16)}"
  ANYTLS_PASS="${ANYTLS_PASS:-$(rand_hex 16)}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(rand_hex 4)}"
  VMESS_PATH="${VMESS_PATH:-/vmess-$(rand_hex 4)}"
  SUB_TOKEN="${SUB_TOKEN:-$(rand_hex 24)}"   # 48 位十六进制，只认这一条路径
  ARGO_DOMAIN="${ARGO_DOMAIN:-}"
  if [ -z "${REALITY_PRIV:-}" ] || [ -z "${REALITY_PUB:-}" ]; then
    local kp
    kp=$("$SB_BIN" generate reality-keypair 2>/dev/null) \
      || die "生成 Reality 密钥失败"
    REALITY_PRIV=$(printf '%s' "$kp" | grep -i 'private' | awk '{print $NF}')
    REALITY_PUB=$(printf '%s' "$kp" | grep -i 'public' | awk '{print $NF}')
    [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ] \
      || die "Reality 密钥解析失败"
  fi
  if [ ! -f "$SB_DIR/cert.pem" ] || [ ! -f "$SB_DIR/key.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$SB_DIR/key.pem" \
      -out "$SB_DIR/cert.pem" -days 3650 -nodes \
      -subj "/CN=$REALITY_SNI" 2>/dev/null \
      || die "生成自签证书失败"
  fi
  chmod 600 "$SB_DIR/key.pem"
  chmod 644 "$SB_DIR/cert.pem"
}

# ---------------- 写配置（分体 JSON，eooce 式布局） ----------------
write_config() {
  mkdir -p "$CONF_DIR"
  local vmess_listen="127.0.0.1"
  local vmess_port="$PORT_VMESS"
  if [ "$VMESS_DIRECT" = "y" ]; then
    vmess_listen="0.0.0.0"
    vmess_port="$PORT_VMESS_DIRECT"
  fi
  cat > "$CONF_DIR/log.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true }
}
EOF
  cat > "$CONF_DIR/inbounds.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless", "tag": "vless-in",
      "listen": "0.0.0.0", "listen_port": $PORT_VLESS,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true, "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_SNI", "server_port": 443 },
          "private_key": "$REALITY_PRIV",
          "short_id": ["$REALITY_SHORT_ID"]
        }
      }
    },
    {
      "type": "vmess", "tag": "vmess-in",
      "listen": "$vmess_listen", "listen_port": $vmess_port,
      "users": [{ "uuid": "$UUID", "alterId": 0 }],
      "transport": { "type": "ws", "path": "$VMESS_PATH" }
    },
    {
      "type": "hysteria2", "tag": "hy2-in",
      "listen": "0.0.0.0", "listen_port": $PORT_HY2,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": {
        "enabled": true,
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/key.pem"
      }
    },
    {
      "type": "tuic", "tag": "tuic-in",
      "listen": "0.0.0.0", "listen_port": $PORT_TUIC,
      "users": [{ "uuid": "$UUID", "password": "$TUIC_PASS" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/key.pem"
      }
    },
    {
      "type": "anytls", "tag": "anytls-in",
      "listen": "0.0.0.0", "listen_port": $PORT_ANYTLS,
      "users": [{ "password": "$ANYTLS_PASS" }],
      "tls": {
        "enabled": true,
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/key.pem"
      }
    }
  ]
}
EOF
  cat > "$CONF_DIR/outbounds.json" <<EOF
{
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
  cat > "$CONF_DIR/route.json" <<EOF
{
  "route": { "final": "direct" }
}
EOF
  chmod 600 "$CONF_DIR"/*.json
  "$SB_BIN" check -C "$CONF_DIR" >/dev/null 2>&1 \
    || die "配置校验失败，请检查 $CONF_DIR"
  info "配置已生成并校验通过"
}

# ---------------- 节点链接 + 订阅 ----------------
vmess_addr() {
  if [ "$VMESS_DIRECT" = "y" ]; then
    printf '%s' "$NODE_ADDR"
  else
    printf '%s' "${ARGO_DOMAIN:-$NODE_ADDR}"
  fi
}

build_links() {
  local vmess_host vmess_port vmess_tls vmess_sni=""
  if [ "$VMESS_DIRECT" = "y" ]; then
    vmess_host="$NODE_ADDR"; vmess_port="$PORT_VMESS_DIRECT"; vmess_tls=""
  else
    # Argo 模式：CFIP/CFPORT 是优选（A 的做法），host 字段写隧道域名当 SNI；
    # 不设优选时直接走隧道域名:443。
    vmess_host="${CFIP:-${ARGO_DOMAIN:-$NODE_ADDR}}"
    vmess_port="${CFPORT:-443}"
    vmess_tls="tls"
    [ -n "$CFIP" ] && [ -n "$ARGO_DOMAIN" ] && vmess_sni="$ARGO_DOMAIN"
  fi
  local vmess_json
  vmess_json=$(printf '{"v":"2","ps":"%s-vmess","add":"%s","port":"%s","id":"%s","aid":"0","net":"ws","type":"none","host":"%s","path":"%s","tls":"%s"}' \
    "$NODE_NAME" "$vmess_host" "$vmess_port" "$UUID" "$vmess_sni" "$VMESS_PATH" "$vmess_tls")
  {
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-vless\n' \
      "$UUID" "$NODE_ADDR" "$PORT_VLESS" "$REALITY_SNI" "$REALITY_PUB" "$REALITY_SHORT_ID" "$NODE_NAME"
    printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | b64)"
    printf 'hysteria2://%s@%s:%s?sni=%s&insecure=1#%s-hy2\n' \
      "$HY2_PASS" "$NODE_ADDR" "$PORT_HY2" "$REALITY_SNI" "$NODE_NAME"
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=1#%s-tuic\n' \
      "$UUID" "$TUIC_PASS" "$NODE_ADDR" "$PORT_TUIC" "$REALITY_SNI" "$NODE_NAME"
    printf 'anytls://%s@%s:%s?sni=%s&insecure=1#%s-anytls\n' \
      "$ANYTLS_PASS" "$NODE_ADDR" "$PORT_ANYTLS" "$REALITY_SNI" "$NODE_NAME"
  } > "$SB_DIR/nodes.txt"
  b64 < "$SB_DIR/nodes.txt" > "$SB_DIR/sub.txt"
  chmod 600 "$SB_DIR/nodes.txt"
  chmod 640 "$SB_DIR/sub.txt"
  chgrp www-data "$SB_DIR/sub.txt" 2>/dev/null || true
  # nginx 以 www-data 跑，必须能进目录（umask 再严也不能挡住它）
  chmod 755 "$SB_DIR"
}

sub_url() {
  printf 'http://%s:%s/%s/sub' "$NODE_ADDR" "$PORT_SUB" "$SUB_TOKEN"
}

# ---------------- nginx 订阅服务 ----------------
# 只认一条长随机路径，其余全部 404；首页不写地址；不用目录 alias，
# 绝不让 /token/ 后面跟别的文件名被读出来。
write_nginx() {
  local conf="/etc/nginx/conf.d/sb-lite.conf"
  mkdir -p /etc/nginx/conf.d
  cat > "$conf" <<EOF
server {
    listen $PORT_SUB;
    listen [::]:$PORT_SUB;
    server_name _;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /$SUB_TOKEN/sub {
        alias $SB_DIR/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location = /$SUB_TOKEN/sub.txt {
        alias $SB_DIR/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location / { return 404; }

    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
  chmod 600 "$conf"
  nginx -t >/dev/null 2>&1 || die "nginx 配置校验失败"
  if has_systemd; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx \
      || die "nginx 重载失败"
  else
    nginx -s reload 2>/dev/null || nginx || die "nginx 启动失败"
  fi
  info "订阅服务已起：$(sub_url)"
}

# ---------------- Argo 隧道（只给 VMess 用） ----------------
has_systemd() { [ -d /run/systemd/system ]; }

argo_log_domain() {
  # 只认真正分配的隧道域名（形如 word-word-word-word.trycloudflare.com，
  # 一定带连字符）；api.trycloudflare.com 只是请求接口，不能当节点地址。
  grep -oE 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com' "$SB_DIR/argo.log" 2>/dev/null \
    | tail -n1 | sed 's#https://##'
}

# 组装 cloudflared 启动参数（全局 ARGO_ARGV 数组 + ARGO_CMDLINE 字符串）：
#   ARGO_AUTH 为空 → 临时隧道（免域名，域名从日志里抓）
#   ARGO_AUTH 是 Token → 固定隧道（域名由 ARGO_DOMAIN 指定，CF 后台配好指向）
#   ARGO_AUTH 是 JSON → 固定隧道（写 argo.json，用 TunnelID 启动）
argo_build_args() {
  if [ -n "$ARGO_AUTH" ]; then
    case "$ARGO_AUTH" in
      '{'*)
        printf '%s' "$ARGO_AUTH" > "$SB_DIR/argo.json"
        chmod 600 "$SB_DIR/argo.json"
        local tid
        tid=$(printf '%s' "$ARGO_AUTH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["TunnelID"])' 2>/dev/null || true)
        [ -n "$tid" ] || die "ARGO_AUTH 的 JSON 里没有 TunnelID"
        ARGO_ARGV=(tunnel --credentials-file "$SB_DIR/argo.json" run "$tid")
        ;;
      *)
        ARGO_ARGV=(tunnel run --token "$ARGO_AUTH")
        ;;
    esac
  else
    ARGO_ARGV=(tunnel --url "http://127.0.0.1:$PORT_VMESS" --no-autoupdate --edge-ip-version auto --protocol http2)
  fi
  ARGO_CMDLINE="$CF_BIN ${ARGO_ARGV[*]}"
}

start_argo() {
  [ "$VMESS_DIRECT" = "y" ] && return 0
  install_cloudflared
  stop_argo 2>/dev/null || true
  argo_build_args
  if [ -n "$ARGO_AUTH" ]; then
    # 固定隧道：域名不会变，CF 后台里已经指好了，不用等日志抓域名
    [ -n "$ARGO_DOMAIN" ] || die "固定隧道要填 ARGO_DOMAIN（CF 后台里绑的那个域名）"
    if has_systemd; then
      cat > /etc/systemd/system/sb-lite-argo.service <<EOF
[Unit]
Description=cloudflared Argo tunnel for sb-lite VMess
After=network.target

[Service]
ExecStart=$ARGO_CMDLINE
Restart=on-failure
RestartSec=5
StandardOutput=append:$SB_DIR/argo.log
StandardError=append:$SB_DIR/argo.log

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable --now sb-lite-argo.service \
        || die "Argo 固定隧道启动失败"
    else
      nohup "$CF_BIN" "${ARGO_ARGV[@]}" > "$SB_DIR/argo.log" 2>&1 &
      echo $! > "$SB_DIR/argo.pid"
    fi
    save_state
    info "Argo 固定隧道已起：$ARGO_DOMAIN"
    return 0
  fi
  if has_systemd; then
    cat > /etc/systemd/system/sb-lite-argo.service <<EOF
[Unit]
Description=cloudflared Argo tunnel for sb-lite VMess
After=network.target

[Service]
ExecStart=$ARGO_CMDLINE
Restart=on-failure
RestartSec=5
StandardOutput=append:$SB_DIR/argo.log
StandardError=append:$SB_DIR/argo.log

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sb-lite-argo.service \
      || die "Argo 隧道启动失败"
  else
    nohup "$CF_BIN" "${ARGO_ARGV[@]}" > "$SB_DIR/argo.log" 2>&1 &
    echo $! > "$SB_DIR/argo.pid"
  fi
  info "等 Argo 隧道分配域名…"
  local i
  for i in $(seq 1 30); do
    sleep 2
    local d; d=$(argo_log_domain)
    if [ -n "$d" ]; then
      ARGO_DOMAIN="$d"
      save_state
      info "Argo 域名：$d"
      return 0
    fi
  done
  warn "Argo 域名 60 秒没拿到，VMess 节点先用直连地址，稍后跑 sb-lite argo-guard 刷新"
  ARGO_DOMAIN=""
  save_state
}

stop_argo() {
  if has_systemd; then
    systemctl stop sb-lite-argo.service 2>/dev/null || true
  elif [ -f "$SB_DIR/argo.pid" ]; then
    kill "$(cat "$SB_DIR/argo.pid")" 2>/dev/null || true
    rm -f "$SB_DIR/argo.pid"
  fi
  # 只杀我们自己的隧道进程，别碰机器上别的 cloudflared
  if [ -n "${ARGO_AUTH:-}" ]; then
    case "$ARGO_AUTH" in
      '{'*) pkill -f "$SB_DIR/argo.json" 2>/dev/null || true ;;
      *)    pkill -f "$CF_BIN tunnel run --token" 2>/dev/null || true ;;
    esac
  else
    pkill -f "cloudflared tunnel --url http://127.0.0.1:$PORT_VMESS" 2>/dev/null || true
  fi
}

# cron 每 5 分钟跑：隧道重启换域名后，把新域名同步回订阅。
argo_guard() {
  load_state
  [ "$VMESS_DIRECT" = "y" ] && return 0
  [ -n "$ARGO_AUTH" ] && return 0   # 固定隧道域名不会变，不用巡检
  local d; d=$(argo_log_domain)
  if [ -n "$d" ] && [ "$d" != "${ARGO_DOMAIN:-}" ]; then
    ARGO_DOMAIN="$d"
    save_state
    build_links
    info "Argo 域名已变，新订阅已生成：$d"
  fi
}

# ---------------- 哪吒探针（可选，A 的功能） ----------------
# 只在 NEZHA_SERVER 和 NEZHA_KEY 都给了时才装；不设就完全不碰。
# v1 形态：NEZHA_SERVER 写 host:port，NEZHA_KEY 是客户端密钥。
NZ_BIN="${NZ_BIN:-/usr/local/bin/nezha-agent}"

install_nezha() {
  [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ] || return 0
  if [ -x "$NZ_BIN" ]; then
    info "哪吒 agent 已在"
    return 0
  fi
  local arch sha
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64"; sha="$NZ_SHA256_AMD64" ;;
    aarch64|arm64) arch="arm64"; sha="$NZ_SHA256_ARM64" ;;
    *) warn "不支持的架构，哪吒探针跳过：$(uname -m)"; return 0 ;;
  esac
  local tmp; tmp=$(mktemp -d)
  local zip="$tmp/nezha-agent.zip"
  download_verified \
    "https://github.com/nezhahq/agent/releases/download/${NZ_VERSION}/nezha-agent_linux_${arch}.zip" \
    "$sha" "$zip"
  python3 -c "import zipfile; zipfile.ZipFile('$zip').extract('nezha-agent', '$tmp')" \
    || { warn "哪吒 agent 解包失败，跳过探针"; rm -rf "$tmp"; return 0; }
  mkdir -p "$(dirname "$NZ_BIN")"
  install -m 755 "$tmp/nezha-agent" "$NZ_BIN" || { warn "哪吒 agent 安装失败，跳过探针"; rm -rf "$tmp"; return 0; }
  rm -rf "$tmp"
  info "哪吒 agent $NZ_VERSION 已装"
}

start_nezha() {
  [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ] || return 0
  [ -x "$NZ_BIN" ] || return 0
  # 端口在 443/8443/2096/2087/2083/2053 其中之一时自动开 TLS（A 的规则），
  # NEZHA_TLS 显式给了就按它来。
  local tls_flag=""
  local port="${NEZHA_SERVER##*:}"
  local use_tls="${NEZHA_TLS:-}"
  if [ -z "$use_tls" ]; then
    case "$port" in
      443|8443|2096|2087|2083|2053) use_tls="y" ;;
      *) use_tls="n" ;;
    esac
  fi
  [ "$use_tls" = "y" ] && tls_flag="--tls"
  if has_systemd; then
    cat > /etc/systemd/system/sb-lite-nezha.service <<EOF
[Unit]
Description=Nezha agent for sb-lite
After=network.target

[Service]
ExecStart=$NZ_BIN --server $NEZHA_SERVER --client-secret $NEZHA_KEY $tls_flag
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sb-lite-nezha.service 2>/dev/null \
      || warn "哪吒 agent 启动失败（探针不影响节点）"
  else
    pkill -f "$NZ_BIN --server $NEZHA_SERVER" 2>/dev/null || true
    nohup "$NZ_BIN" --server "$NEZHA_SERVER" --client-secret "$NEZHA_KEY" $tls_flag \
      > "$SB_DIR/nezha.log" 2>&1 &
    echo $! > "$SB_DIR/nezha.pid"
  fi
  info "哪吒探针已起：$NEZHA_SERVER"
}

stop_nezha() {
  if has_systemd; then
    systemctl stop sb-lite-nezha.service 2>/dev/null || true
  elif [ -f "$SB_DIR/nezha.pid" ]; then
    kill "$(cat "$SB_DIR/nezha.pid")" 2>/dev/null || true
    rm -f "$SB_DIR/nezha.pid"
  fi
}

# ---------------- systemd 服务 ----------------
write_systemd() {
  cat > /etc/systemd/system/sb-lite.service <<EOF
[Unit]
Description=sing-box (sb-lite)
After=network.target

[Service]
ExecStart=$SB_BIN run -C $CONF_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sb-lite.service || die "sing-box 启动失败"
  info "sing-box 已启动"
}

start_nosystemd() {
  pkill -f "$SB_BIN run -C $CONF_DIR" 2>/dev/null || true
  nohup "$SB_BIN" run -C "$CONF_DIR" > "$SB_DIR/singbox.log" 2>&1 &
  echo $! > "$SB_DIR/singbox.pid"
  sleep 2
  kill -0 "$(cat "$SB_DIR/singbox.pid")" 2>/dev/null || die "sing-box 启动失败"
  info "sing-box 已启动（nohup 模式）"
  # 开机自启 + 保活
  local cron_entry="@reboot $SB_BIN run -C $CONF_DIR > $SB_DIR/singbox.log 2>&1 &"
  (crontab -l 2>/dev/null | grep -v "sb-lite" ; printf '%s\n' "$cron_entry") | crontab - 2>/dev/null || true
}

# ---------------- 服务启停 ----------------
stop_services() {
  if has_systemd; then
    systemctl stop sb-lite.service sb-lite-argo.service 2>/dev/null || true
  fi
  pkill -f "$SB_BIN run -C $CONF_DIR" 2>/dev/null || true
  stop_argo 2>/dev/null || true
  sleep 1
}

# ---------------- 命令 ----------------
cmd_install() {
  local auto="n"
  [ "${1:-}" = "--yes" ] && auto="y"
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  install_deps
  load_state
  stop_services

  if [ -z "$NODE_ADDR" ]; then
    NODE_ADDR=$(detect_public_ip)
  fi
  if [ "$auto" != "y" ]; then
    printf '节点地址（公网 IP）[%s]: ' "$NODE_ADDR"
    read -r ans; [ -n "$ans" ] && NODE_ADDR="$ans"
    printf 'Reality 伪装域名 [%s]: ' "$REALITY_SNI"
    read -r ans; [ -n "$ans" ] && REALITY_SNI="$ans"
    printf 'VMess 走 Argo 隧道吗（y=隧道，n=直连 8080）[%s]: ' "$([ "$VMESS_DIRECT" = "y" ] && printf 'n' || printf 'y')"
    read -r ans
    case "$ans" in
      y|Y) VMESS_DIRECT="n" ;;
      n|N) VMESS_DIRECT="y" ;;
    esac
    if [ "$VMESS_DIRECT" != "y" ]; then
      printf 'Argo 固定隧道凭证（Token 或 JSON，留空=临时隧道）[%s]: ' "${ARGO_AUTH:-空}"
      read -r ans; [ -n "$ans" ] && ARGO_AUTH="$ans"
      if [ -n "$ARGO_AUTH" ]; then
        printf '固定隧道域名（CF 后台绑的那个）[%s]: ' "${ARGO_DOMAIN:-}"
        read -r ans; [ -n "$ans" ] && ARGO_DOMAIN="$ans"
      fi
      printf 'Argo 优选 IP（CFIP，留空=走隧道域名）[%s]: ' "${CFIP:-空}"
      read -r ans; [ -n "$ans" ] && CFIP="$ans"
      printf 'Argo 优选端口（CFPORT，默认 443）[%s]: ' "${CFPORT:-443}"
      read -r ans; [ -n "$ans" ] && CFPORT="$ans"
    fi
    printf '节点名前缀 [%s]: ' "$NODE_NAME"
    read -r ans; [ -n "$ans" ] && NODE_NAME="$ans"
    printf '哪吒服务端（host:port，留空=不装探针）[%s]: ' "${NEZHA_SERVER:-空}"
    read -r ans; [ -n "$ans" ] && NEZHA_SERVER="$ans"
    if [ -n "$NEZHA_SERVER" ]; then
      printf '哪吒客户端密钥 [%s]: ' "${NEZHA_KEY:-}"
      read -r ans; [ -n "$ans" ] && NEZHA_KEY="$ans"
    fi
  fi
  [ -n "$NODE_ADDR" ] || die "拿不到公网 IP，请用 NODE_ADDR=你的IP 再跑"
  check_ports_free

  install_sing_box
  gen_secrets
  save_state
  write_config
  start_argo
  build_links
  write_nginx
  if has_systemd; then
    write_systemd
  else
    start_nosystemd
  fi
  install_nezha
  start_nezha

  # 把脚本本体存一份，注册快捷命令
  # 注意：bash <(curl ...) 安装时 $0 是管道，cp 出来是空文件（实测 0 字节），
  # 必须校验，坏了就从仓库重新拉一份。
  cp "$0" "$SB_DIR/sb-lite.sh" 2>/dev/null || true
  if [ ! -s "$SB_DIR/sb-lite.sh" ] || ! grep -q 'SB_LITE_VERSION=' "$SB_DIR/sb-lite.sh" 2>/dev/null; then
    info "从仓库拉一份脚本本体存着"
    curl -fL --retry 2 --connect-timeout 10 -o "$SB_DIR/sb-lite.sh" "$UPGRADE_URL" \
      || warn "脚本本体没存下来，快捷命令不可用（节点不受影响）"
  fi
  chmod 755 "$SB_DIR/sb-lite.sh" 2>/dev/null || true
  ln -sf "$SB_DIR/sb-lite.sh" /usr/local/bin/sb-lite 2>/dev/null || true
  install_guard_cron

  echo
  info "装好了，节点如下（只显示这一次，自己存好）："
  cat "$SB_DIR/nodes.txt"
  echo
  info "订阅地址：$(sub_url)"
  info "管理命令：sb-lite status / update / regen / uninstall"
}

cmd_status() {
  load_state
  echo "sing-box：$(has_systemd && (systemctl is-active sb-lite.service 2>/dev/null || echo stopped) || (pgrep -f "$SB_BIN run" >/dev/null && echo running || echo stopped))"
  if [ "$VMESS_DIRECT" = "y" ]; then
    echo "Argo：未启用（VMess 直连）"
  elif [ -n "$ARGO_AUTH" ]; then
    echo "Argo：固定隧道 ${ARGO_DOMAIN:-未设置域名}"
  else
    echo "Argo：临时隧道 ${ARGO_DOMAIN:-未分配}"
  fi
  [ -n "$CFIP" ] && echo "Argo 优选：$CFIP:${CFPORT:-443}"
  if [ -n "$NEZHA_SERVER" ]; then
    echo "哪吒：$NEZHA_SERVER（$(has_systemd && (systemctl is-active sb-lite-nezha.service 2>/dev/null || echo stopped) || (pgrep -f "$NZ_BIN" >/dev/null && echo running || echo stopped))）"
  fi
  echo "订阅：$(sub_url)"
  echo "节点数：$(wc -l < "$SB_DIR/nodes.txt" 2>/dev/null || echo 0)"
  ss -tln 2>/dev/null | grep -E ":($PORT_VLESS|$PORT_SUB) " | awk '{print "监听：", $4}'
  if command -v qrencode >/dev/null 2>&1; then
    echo "订阅二维码（手机扫码即用）："
    qrencode -t ANSIUTF8 -m 1 "$(sub_url)" 2>/dev/null || true
  fi
}

cmd_update() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  load_state
  install_sing_box
  stop_services
  if has_systemd; then
    systemctl start sb-lite.service || die "sing-box 启动失败"
    [ "$VMESS_DIRECT" = "y" ] || systemctl start sb-lite-argo.service 2>/dev/null || true
  else
    start_nosystemd
    [ "$VMESS_DIRECT" = "y" ] || start_argo
  fi
  info "sing-box 已更新到 $SB_VERSION"
}

cmd_regen() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  load_state
  printf '重新生成全部密码/密钥，旧节点全部失效，确定？[y/N] '
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "已取消"
  unset UUID HY2_PASS TUIC_PASS ANYTLS_PASS REALITY_PRIV REALITY_PUB \
    REALITY_SHORT_ID VMESS_PATH SUB_TOKEN
  stop_services
  gen_secrets
  save_state
  write_config
  start_argo
  build_links
  write_nginx
  if has_systemd; then
    systemctl start sb-lite.service || die "sing-box 启动失败"
  else
    start_nosystemd
  fi
  info "已重新生成，订阅地址变了：$(sub_url)"
}

cmd_uninstall() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  load_state
  printf '卸载会删掉 %s 和订阅，确定？[y/N] ' "$SB_DIR"
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "已取消"
  stop_services
  stop_nezha
  if has_systemd; then
    systemctl disable --now sb-lite.service sb-lite-argo.service sb-lite-nezha.service 2>/dev/null || true
    rm -f /etc/systemd/system/sb-lite.service /etc/systemd/system/sb-lite-argo.service /etc/systemd/system/sb-lite-nezha.service
    systemctl daemon-reload
  fi
  rm -f /etc/nginx/conf.d/sb-lite.conf
  nginx -t >/dev/null 2>&1 && (has_systemd && systemctl reload nginx || nginx -s reload 2>/dev/null || true)
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "sb-lite argo-guard" | grep -vF "$SB_BIN run") | crontab - 2>/dev/null || true
  fi
  rm -rf "$SB_DIR"
  rm -f /usr/local/bin/sb-lite "$NZ_BIN"
  info "已卸载"
}

# ---------------- 新增命令（1.1.0，综合 A 和 B） ----------------
restart_singbox() {
  if has_systemd; then
    systemctl restart sb-lite.service || die "sing-box 重启失败"
  else
    start_nosystemd
  fi
  info "sing-box 已重启"
}

# Argo 域名巡检 cron（v1.0 漏装了：没它，临时隧道换域名后订阅不会自动更新）
install_guard_cron() {
  command -v crontab >/dev/null 2>&1 || return 0
  local entry="*/5 * * * * SB_LITE_DIR=$SB_DIR /usr/local/bin/sb-lite argo-guard >/dev/null 2>&1"
  (crontab -l 2>/dev/null | grep -v "sb-lite argo-guard"; printf '%s\n' "$entry") | crontab - 2>/dev/null || true
}

# B 的一键自愈：重起服务、刷新 Argo、重建订阅
cmd_heal() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  load_state
  stop_services
  write_config
  start_argo
  build_links
  write_nginx
  restart_singbox
  install_guard_cron
  start_nezha
  info "自愈完成，订阅已更新：$(sub_url)"
}

# B 的拆 Argo：VMess 改公网直连
cmd_direct() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  load_state
  VMESS_DIRECT="y"
  save_state
  stop_argo
  write_config
  build_links
  write_nginx
  restart_singbox
  info "已拆掉 Argo，VMess 改直连：$NODE_ADDR:$PORT_VMESS_DIRECT"
}

# 开 Argo：不带凭证=临时隧道；带 ARGO_AUTH=固定隧道
cmd_argo() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  local env_auth="$ARGO_AUTH" env_domain="$ARGO_DOMAIN"
  local env_cfip="$CFIP" env_cfport="$CFPORT"
  load_state
  [ -n "$env_auth" ] && ARGO_AUTH="$env_auth"
  [ -n "$env_domain" ] && ARGO_DOMAIN="$env_domain"
  [ -n "$env_cfip" ] && CFIP="$env_cfip"
  [ -n "$env_cfport" ] && CFPORT="$env_cfport"
  [ "${1:-}" = "--temp" ] && ARGO_AUTH=""
  VMESS_DIRECT="n"
  if [ -z "$ARGO_AUTH" ]; then
    printf '固定隧道凭证（Token 或 JSON，留空=临时隧道）: '
    read -r ans; [ -n "$ans" ] && ARGO_AUTH="$ans"
  fi
  if [ -n "$ARGO_AUTH" ] && [ -z "$ARGO_DOMAIN" ]; then
    printf '固定隧道域名（CF 后台绑的那个）: '
    read -r ans; [ -n "$ans" ] && ARGO_DOMAIN="$ans"
    [ -n "$ARGO_DOMAIN" ] || die "固定隧道要填域名"
  fi
  save_state
  start_argo
  build_links
  write_nginx
  restart_singbox
  install_guard_cron
  info "Argo 已开，VMess 走隧道，订阅已更新"
}

# B 的菜单 3：单独改端口 / SNI / 节点名，改完自动重启并刷新订阅
cmd_config() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  load_state
  # 先记下改之前的端口：只检查改动过的端口，没动的本来就被自己的 sing-box 占着，
  # 不停服务直接查会误报。首尾都留空格，最后一项也要能匹配上。
  local old_ports=" $PORT_VLESS $PORT_VMESS $PORT_HY2 $PORT_TUIC $PORT_ANYTLS "
  printf '节点地址（公网 IP）[%s]: ' "$NODE_ADDR"
  read -r ans; [ -n "$ans" ] && NODE_ADDR="$ans"
  printf '节点名前缀 [%s]: ' "$NODE_NAME"
  read -r ans; [ -n "$ans" ] && NODE_NAME="$ans"
  printf 'Reality 伪装域名 [%s]: ' "$REALITY_SNI"
  read -r ans; [ -n "$ans" ] && REALITY_SNI="$ans"
  printf 'VLESS 端口 [%s]: ' "$PORT_VLESS"
  read -r ans; [ -n "$ans" ] && PORT_VLESS="$ans"
  printf 'VMess 端口 [%s]: ' "$PORT_VMESS"
  read -r ans; [ -n "$ans" ] && PORT_VMESS="$ans"
  printf 'VMess 直连端口 [%s]: ' "$PORT_VMESS_DIRECT"
  read -r ans; [ -n "$ans" ] && PORT_VMESS_DIRECT="$ans"
  printf 'Hysteria2 端口 [%s]: ' "$PORT_HY2"
  read -r ans; [ -n "$ans" ] && PORT_HY2="$ans"
  printf 'TUIC 端口 [%s]: ' "$PORT_TUIC"
  read -r ans; [ -n "$ans" ] && PORT_TUIC="$ans"
  printf 'AnyTLS 端口 [%s]: ' "$PORT_ANYTLS"
  read -r ans; [ -n "$ans" ] && PORT_ANYTLS="$ans"
  printf '订阅端口 [%s]: ' "$PORT_SUB"
  read -r ans; [ -n "$ans" ] && PORT_SUB="$ans"
  save_state
  local p
  for p in "$PORT_VLESS" "$PORT_VMESS" "$PORT_HY2" "$PORT_TUIC" "$PORT_ANYTLS"; do
    case "$old_ports" in *" $p "*) continue ;; esac
    if ss -tln 2>/dev/null | grep -q ":$p " || ss -uln 2>/dev/null | grep -q ":$p "; then
      die "端口 $p 被占用，请先停掉占用进程或改端口"
    fi
  done
  write_config
  build_links
  write_nginx
  restart_singbox
  info "配置已更新，订阅已刷新：$(sub_url)"
}

# B 的脚本自更新：拉 GitHub 最新版，配置和订阅不受影响
cmd_upgrade() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  [ -d "$SB_DIR" ] || die "还没安装，先跑 install"
  local tmp; tmp=$(mktemp)
  curl -fL --retry 2 --connect-timeout 10 -o "$tmp" "$UPGRADE_URL" \
    || die "下载最新脚本失败"
  grep -q 'SB_LITE_VERSION=' "$tmp" || die "下载的文件不是 sb-lite 脚本"
  bash -n "$tmp" || die "新版脚本语法检查失败"
  local new_ver
  new_ver=$(grep -oE 'SB_LITE_VERSION="[0-9.]+"' "$tmp" | head -1 | cut -d'"' -f2)
  if [ "$new_ver" = "$SB_LITE_VERSION" ]; then
    info "已经是最新版 $SB_LITE_VERSION"
    rm -f "$tmp"
    return 0
  fi
  cp "$tmp" "$SB_DIR/sb-lite.sh" || die "更新失败"
  chmod 755 "$SB_DIR/sb-lite.sh"
  ln -sf "$SB_DIR/sb-lite.sh" /usr/local/bin/sb-lite 2>/dev/null || true
  rm -f "$tmp"
  info "已更新到 $new_ver（配置和订阅不受影响）"
}

# B 的管理菜单
cmd_menu() {
  while true; do
    echo
    echo "sb-lite $SB_LITE_VERSION — 管理菜单"
    echo "  1) 一键安装          2) 查看节点/订阅/状态"
    echo "  3) 改配置（端口/SNI/节点名）  4) 重启 sing-box"
    echo "  5) 停止 sing-box      6) 开 Argo 临时隧道"
    echo "  7) 开 Argo 固定隧道    8) 拆 Argo 改直连"
    echo "  9) 更新 sing-box 内核  10) 一键自愈"
    echo "  11) 更新本脚本       12) 卸载"
    echo "  0) 退出"
    printf '选一个 [0-12]: '
    read -r ans || return 0
    case "$ans" in
      1)  cmd_install ;;
      2)  cmd_status ;;
      3)  cmd_config ;;
      4)  restart_singbox ;;
      5)  stop_services; info "sing-box 已停" ;;
      6)  cmd_argo --temp ;;
      7)  cmd_argo ;;
      8)  cmd_direct ;;
      9)  cmd_update ;;
      10) cmd_heal ;;
      11) cmd_upgrade ;;
      12) cmd_uninstall ;;
      0)  return 0 ;;
      *)  echo "没这个选项" ;;
    esac
  done
}

usage() {
  cat <<EOF
sb-lite $SB_LITE_VERSION — 精简版 sing-box 一键部署
用法（不带参数进管理菜单）：
  sb-lite install [--yes]   安装（交互式 / 全自动）
  sb-lite status            看状态（含订阅二维码）
  sb-lite update            更新 sing-box 内核
  sb-lite regen             重新生成密码/密钥
  sb-lite heal              一键自愈：重起服务、刷新 Argo、重建订阅
  sb-lite direct            拆掉 Argo，VMess 改公网直连
  sb-lite argo [--temp]     开 Argo（临时隧道；带凭证则用固定隧道）
  sb-lite config            单独改端口 / SNI / 节点名
  sb-lite upgrade           更新本脚本到 GitHub 最新版
  sb-lite argo-guard        刷新 Argo 域名（cron 用）
  sb-lite uninstall         卸载
  sb-lite version           版本
短参数：-i 安装 / -c 状态 / -r 刷新 Argo / -u 卸载 / -h 帮助
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    install|--install)    shift; cmd_install "$@" ;;
    status|--status)      cmd_status ;;
    update|--update)      cmd_update ;;
    regen)                cmd_regen ;;
    heal|--heal)          cmd_heal ;;
    direct|--direct)      cmd_direct ;;
    argo|--argo)          shift; cmd_argo "$@" ;;
    config|--config)      cmd_config ;;
    upgrade|--upgrade)    cmd_upgrade ;;
    menu|--menu)          cmd_menu ;;
    argo-guard)           argo_guard ;;
    uninstall|--uninstall) cmd_uninstall ;;
    version|--version|-v) echo "sb-lite $SB_LITE_VERSION (sing-box $SB_VERSION)" ;;
    help|--help|-h)       usage ;;
    -i)                   cmd_install --yes ;;
    -c)                   cmd_status ;;
    -r)                   argo_guard ;;
    -u)                   cmd_uninstall ;;
    "")                   if [ -t 0 ]; then cmd_menu; else usage; echo; cmd_status; fi ;;
    *)                    die "未知命令：$cmd"; usage ;;
  esac
}

if [ "${SB_LITE_NO_MAIN:-}" != "1" ]; then
  main "$@"
fi
