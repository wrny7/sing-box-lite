#!/usr/bin/env bash
# sb-lite 测试套件（B 的做法：本地逻辑测试，不需要 VPS）
# 用法：bash tests/run_tests.sh
#   需要 sing-box 二进制才能跑配置校验那几项；没有就跳过（SB_LITE_BIN 指定路径）。
#   其余纯逻辑测试任何时候都能跑。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/sb-lite.sh"
TEST_TMP="$(mktemp -d)"
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS + 1)); printf '  ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip %s\n' "$1"; }
check() { # $1=描述 $2=命令（eval）
  if eval "$2" >/dev/null 2>&1; then ok "$1"; else fail "$1"; fi
}

echo "== 1. 语法 =="
check "sb-lite.sh bash -n 通过" "bash -n '$SCRIPT'"
check "run_tests.sh bash -n 通过" "bash -n '$0'"

echo "== 2. 随机数 / 编解码 =="
export SB_LITE_NO_MAIN=1
export SB_LITE_DIR="$TEST_TMP/sb"
export SB_LITE_BIN="${SB_LITE_BIN:-/usr/local/bin/sing-box}"
export SB_LITE_CF_BIN="${SB_LITE_CF_BIN:-/usr/local/bin/cloudflared}"
# shellcheck disable=SC1090
source "$SCRIPT"

check "rand_hex 8字节=16字符" '[ "$(rand_hex 8 | wc -c)" = "16" ]'
check "rand_hex 24字节=48字符（订阅 token 长度）" '[ "$(rand_hex 24 | wc -c)" = "48" ]'
check "rand_uuid 形如 xxxx-xxxx" 'rand_uuid | grep -qE "^[0-9a-f-]{36}$"'
check "b64 编解码往返" '[ "$(printf "hello" | b64 | base64 -d 2>/dev/null)" = "hello" ]'

echo "== 3. PORT 基数派生（A 的做法） =="
# 直接跑派生逻辑：PORT=3000 时六个端口按顺序来
(
  PORT=3000
  PORT_VLESS=443; PORT_VMESS=8001; PORT_VMESS_DIRECT=8080
  PORT_HY2=8443; PORT_TUIC=8444; PORT_ANYTLS=8445; PORT_SUB=45616
  [ "$PORT_VLESS" = "443" ]   && PORT_VLESS="$PORT"
  [ "$PORT_VMESS" = "8001" ]  && PORT_VMESS="$((PORT + 1))"
  [ "$PORT_VMESS_DIRECT" = "8080" ] && PORT_VMESS_DIRECT="$((PORT + 1))"
  [ "$PORT_HY2" = "8443" ]    && PORT_HY2="$((PORT + 2))"
  [ "$PORT_TUIC" = "8444" ]   && PORT_TUIC="$((PORT + 3))"
  [ "$PORT_ANYTLS" = "8445" ] && PORT_ANYTLS="$((PORT + 4))"
  [ "$PORT_SUB" = "45616" ]   && PORT_SUB="$((PORT + 5))"
  [ "$PORT_VLESS" = "3000" ] && [ "$PORT_VMESS" = "3001" ] \
    && [ "$PORT_HY2" = "3002" ] && [ "$PORT_TUIC" = "3003" ] \
    && [ "$PORT_ANYTLS" = "3004" ] && [ "$PORT_SUB" = "3005" ] \
    && [ "$PORT_VMESS_DIRECT" = "3001" ]
) && ok "PORT=3000 派生 3000-3005" || fail "PORT=3000 派生 3000-3005"
(
  PORT=3000; PORT_VLESS=8443   # 单独设过的优先，不被 PORT 覆盖
  [ "$PORT_VLESS" = "443" ] && PORT_VLESS="$PORT"
  [ "$PORT_VLESS" = "8443" ]
) && ok "单独设的 PORT_VLESS 优先于 PORT" || fail "单独设的 PORT_VLESS 优先于 PORT"

echo "== 4. Argo 域名解析（只认带连字符的真域名） =="
mkdir -p "$SB_DIR"
cat > "$SB_DIR/argo.log" <<'EOF'
2026-11-15T09:27:34Z INF Requesting new quick Tunnel on trycloudflare.com...
failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": tls: first record does not look like a TLS handshake
2026-11-15T09:30:02Z INF |  https://sunny-meadow-4821-quick-fox.trycloudflare.com has been started |
EOF
check "抓到真域名，不抓 api.trycloudflare.com" '[ "$(argo_log_domain)" = "sunny-meadow-4821-quick-fox.trycloudflare.com" ]'
printf 'failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel"\n' > "$SB_DIR/argo.log"
check "只有 api 地址时返回空" '[ -z "$(argo_log_domain)" ]'

echo "== 5. state.env 存取（含 JSON 的 ARGO_AUTH） =="
NODE_ADDR="1.2.3.4"; NODE_NAME="test"; PORT_VLESS=443; PORT_VMESS=8001
PORT_VMESS_DIRECT=8080; PORT_HY2=8443; PORT_TUIC=8444; PORT_ANYTLS=8445
PORT_SUB=45616; REALITY_SNI="www.yahoo.com"; VMESS_DIRECT="n"
UUID="11111111-2222-3333-4444-555555555555"; HY2_PASS="aabbccdd"
TUIC_PASS="eeff0011"; ANYTLS_PASS="22334455"; REALITY_PRIV=""; REALITY_PUB=""
REALITY_SHORT_ID="aabbccdd"; VMESS_PATH="/vmess-1234abcd"
# REALITY 密钥留空，让第 6 节的 gen_secrets 用 sing-box 真生成（假值过不了 check）
SUB_TOKEN="00112233445566778899aabbccddeeff0011223344556677"; ARGO_DOMAIN=""
ARGO_AUTH='{"AccountTag":"123","TunnelSecret":"abc","TunnelID":"tid-1"}'
CFIP=""; CFPORT=""; NEZHA_SERVER=""; NEZHA_KEY=""; NEZHA_TLS=""
CHAT_ID=""; BOT_TOKEN=""
save_state
# 换一组值再 load，看能不能原样回来（重点是 JSON 里的引号不能炸 source）
ARGO_AUTH=""; UUID=""; SUB_TOKEN=""
load_state
check "UUID 存取往返" '[ "$UUID" = "11111111-2222-3333-4444-555555555555" ]'
check "SUB_TOKEN 48 位存取往返" '[ "$SUB_TOKEN" = "00112233445566778899aabbccddeeff0011223344556677" ]'
check "ARGO_AUTH JSON 存取往返" '[ "$ARGO_AUTH" = "{\"AccountTag\":\"123\",\"TunnelSecret\":\"abc\",\"TunnelID\":\"tid-1\"}" ]'
check "state.env 权限 600" '[ "$(stat -c %a "$STATE_FILE")" = "600" ]'

echo "== 6. 节点链接与订阅 =="
mkdir -p "$CONF_DIR"
if [ -x "$SB_BIN" ]; then
  gen_secrets
  save_state
  write_config
  check "配置校验通过（sing-box check）" "true"
  build_links
  check "nodes.txt 5 条" '[ "$(wc -l < "$SB_DIR/nodes.txt")" = "5" ]'
  check "sub.txt 解开 5 条" '[ "$(base64 -d "$SB_DIR/sub.txt" 2>/dev/null | wc -l)" = "5" ]'
  check "sub.txt 640 属组 www-data 或 root" '[ "$(stat -c %a "$SB_DIR/sub.txt")" = "640" ]'
  check "nodes.txt 600" '[ "$(stat -c %a "$SB_DIR/nodes.txt")" = "600" ]'
  check "订阅地址格式" 'sub_url | grep -qE "^http://1\.2\.3\.4:45616/[0-9a-f]{48}/sub$"'
  # CFIP/CFPORT 优选：vmess 节点的 add/port/host 要按优选走
  ARGO_DOMAIN="sunny-meadow-4821-quick-fox.trycloudflare.com"
  CFIP="104.18.1.1"; CFPORT="8443"
  build_links
  VMESS_B64=$(grep '^vmess://' "$SB_DIR/nodes.txt" | sed 's/^vmess:\/\///')
  VMESS_JSON=$(printf '%s' "$VMESS_B64" | base64 -d 2>/dev/null)
  check "CFIP 时 vmess add=优选 IP" 'printf "%s" "$VMESS_JSON" | grep -q "\"add\":\"104.18.1.1\""'
  check "CFPORT 时 vmess port=优选端口" 'printf "%s" "$VMESS_JSON" | grep -q "\"port\":\"8443\""'
  check "CFIP 时 vmess host=隧道域名（SNI）" 'printf "%s" "$VMESS_JSON" | grep -q "\"host\":\"sunny-meadow-4821-quick-fox.trycloudflare.com\""'
  CFIP=""; CFPORT=""
  build_links
  VMESS_B64=$(grep '^vmess://' "$SB_DIR/nodes.txt" | sed 's/^vmess:\/\///')
  VMESS_JSON=$(printf '%s' "$VMESS_B64" | base64 -d 2>/dev/null)
  check "不设优选时 vmess add=隧道域名" 'printf "%s" "$VMESS_JSON" | grep -q "\"add\":\"sunny-meadow-4821-quick-fox.trycloudflare.com\""'
  check "不设优选时 vmess port=443 tls" 'printf "%s" "$VMESS_JSON" | grep -q "\"port\":\"443\""'
else
  skip "配置/链接测试（没有 sing-box 二进制，用 SB_LITE_BIN 指定）"
  skip "CFIP/CFPORT 优选测试（同上）"
fi

echo "== 7. 非交互调用 =="
check "--help 退出 0" "SB_LITE_NO_MAIN= bash '$SCRIPT' --help"
check "菜单里按 0 退出" "printf '0\n' | SB_LITE_NO_MAIN= bash '$SCRIPT' menu"
check "version 输出版本号" "SB_LITE_NO_MAIN= bash '$SCRIPT' version | grep -q 'sb-lite 1.1.0'"
check "未知命令报错" "! SB_LITE_NO_MAIN= bash '$SCRIPT' nosuchcmd 2>/dev/null"

echo "== 8. 升级地址 =="
check "UPGRADE_URL 指向本仓库" 'printf "%s" "$UPGRADE_URL" | grep -q "raw.githubusercontent.com/wrny7/sing-box-lite"'

rm -rf "$TEST_TMP"
echo
echo "通过 $PASS，失败 $FAIL，跳过 $SKIP"
[ "$FAIL" = "0" ] || exit 1
