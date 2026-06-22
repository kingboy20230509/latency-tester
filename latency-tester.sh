#!/usr/bin/env bash
# 网络延迟测试工具 (纯 Bash 版 - 真实体感模式)
#
# 设计目标: 测的是"你真实访问一个网站时，从发起请求到拿到完整响应"的总耗时，
# 而不是 ping 那种只测网络层往返的"理论值"。这更贴近你用服务器实际访问/
# 调用这些服务时能感知到的延迟。
#
# 用 curl 发起真实 HTTPS 请求，拆分各阶段耗时:
#   DNS解析 -> TCP连接 -> TLS握手 -> 首字节(TTFB) -> 总耗时
# 表格主指标用 time_total (总耗时)，这是最接近"点一下要等多久"的体感数字。
#
# 默认串行执行 + 多次采样取中位数，避免并发抢CPU导致结果失真。
#
# 依赖: curl (绝大多数 Linux 默认自带，如未安装: apt install curl)
#
# 用法:
#   ./latency_test.sh                # 默认: 每个目标测 5 次，串行
#   ./latency_test.sh -c 8            # 每个目标测 8 次
#   ./latency_test.sh -t 5            # 单次超时秒数(默认5，HTTPS比ping慢，超时要给够)
#   ./latency_test.sh -p 4            # 允许4个并发 (默认1=串行，更准但更慢)

set -uo pipefail

COUNT=5
TIMEOUT=5
PARALLEL=1

while getopts "c:t:p:" opt; do
  case $opt in
    c) COUNT="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    p) PARALLEL="$OPTARG" ;;
    *) echo "用法: $0 [-c 次数] [-t 超时秒数] [-p 并发数]"; exit 1 ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "错误: 未检测到 curl，请先安装: apt install -y curl"
  exit 1
fi

# 目标列表: "显示名称|域名|端口"  (Telegram 走的是 MTProto 协议而非 HTTPS，
# curl 无法正常请求，这里换成一个真实支持 HTTPS 的 Telegram 域名)
TARGETS=(
  "X|x.com|443"
  "Apple|apple.com|443"
  "Disney|disneyplus.com|443"
  "Instagram|instagram.com|443"
  "ChatGPT|openai.com|443"
  "Google|google.com|443"
  "Claude|claude.ai|443"
  "Facebook|facebook.com|443"
  "AWS|aws.amazon.com|443"
  "YouTube|youtube.com|443"
  "OneDrive|onedrive.live.com|443"
  "Twitch|twitch.tv|443"
  "Microsoft|m365.cloud.microsoft|443"
  "TikTok|tiktok.com|443"
  "Steam|steampowered.com|443"
  "Netflix|fast.com|443"
  "GitHub|github.com|443"
  "NodeSeek|nodeseek.com|443"
  "Telegram|web.telegram.org|443"
)

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE" "${TMPFILE}.final"' EXIT

resolve_ip() {
  local domain="$1"
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}'
}

# 用 curl 发一次真实 HTTPS 请求，返回 "总耗时ms|TTFB毫秒"，失败返回空
https_request_once() {
  local domain="$1" timeout="$2"
  local out
  out=$(curl -s -o /dev/null --connect-timeout "$timeout" --max-time "$timeout" \
        -w '%{time_total} %{time_starttransfer}' \
        "https://${domain}/" 2>/dev/null)
  if [[ -z "$out" ]]; then
    echo ""
    return
  fi
  local total ttfb
  total=$(echo "$out" | awk '{print $1}')
  ttfb=$(echo "$out" | awk '{print $2}')
  if [[ -z "$total" || "$total" == "0.000000" ]]; then
    echo ""
    return
  fi
  # 转成毫秒
  awk -v t="$total" 'BEGIN{printf "%.1f", t*1000}'
}

test_target() {
  local name="$1" domain="$2" port="$3"
  local ip
  ip=$(resolve_ip "$domain")

  local success=0
  local samples=()
  for ((i=0; i<COUNT; i++)); do
    local ms
    ms=$(https_request_once "$domain" "$TIMEOUT")
    if [[ -n "$ms" ]]; then
      success=$((success+1))
      samples+=("$ms")
    fi
  done

  local loss median
  loss=$(awk -v c="$COUNT" -v s="$success" 'BEGIN{printf "%.0f", (c-s)/c*100}')
  if (( success == 0 )); then
    median=""
  else
    median=$(printf '%s\n' "${samples[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  fi

  echo "${name}|${domain}|${ip:-解析失败}|${median}|${loss}" >> "$TMPFILE"
}

echo "🚀 开始延迟测试 (真实HTTPS请求耗时，串行=更准确，并发数=${PARALLEL})..."
START=$(date +%s)

if (( PARALLEL <= 1 )); then
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r name domain port <<< "$entry"
    test_target "$name" "$domain" "$port"
  done
else
  running=0
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r name domain port <<< "$entry"
    test_target "$name" "$domain" "$port" &
    running=$((running+1))
    if (( running >= PARALLEL )); then
      wait -n
      running=$((running-1))
    fi
  done
  wait
fi

END=$(date +%s)
ELAPSED=$((END-START))

status_for() {
  local latency="$1" loss="$2"
  if [[ -z "$latency" || "$loss" -ge 100 ]]; then
    echo "✗ 超时"
  elif (( loss > 50 )); then
    echo "✗ 异常"
  elif awk -v l="$latency" 'BEGIN{exit !(l<200)}'; then
    echo "✓ 优秀"
  elif awk -v l="$latency" 'BEGIN{exit !(l<500)}'; then
    echo "◆ 良好"
  elif awk -v l="$latency" 'BEGIN{exit !(l<1000)}'; then
    echo "▲ 较差"
  else
    echo "✗ 异常"
  fi
}

echo "📊 测试完成！ 总时间: ${ELAPSED}秒"
echo "📋 真实HTTPS访问耗时表格 (含DNS+TCP+TLS+首字节，更贴近真实体感):"
WIDTH=95
printf '%s\n' "$(printf '═%.0s' $(seq 1 $WIDTH))"
printf "%-4s %-14s %-28s %10s %6s %-8s %-16s\n" "排名" "服务" "域名" "总耗时" "丢包率" "状态" "IPv4地址"
printf '%s\n' "$(printf '═%.0s' $(seq 1 $WIDTH))"

awk -F'|' '{ if ($4=="") print 999999"|"$0; else print $4"|"$0 }' "$TMPFILE" \
  | sort -t'|' -k1,1n \
  | cut -d'|' -f2- > "${TMPFILE}.final"

rank=0
while IFS='|' read -r name domain ip latency loss; do
  rank=$((rank+1))
  if [[ -n "$latency" ]]; then
    latency_str="${latency}ms"
  else
    latency_str="超时"
  fi
  status=$(status_for "$latency" "$loss")
  printf "%-4s %-14s %-28s %10s %5s%% %-8s %-16s\n" \
    "$rank" "$name" "$domain" "$latency_str" "$loss" "$status" "$ip"
done < "${TMPFILE}.final"

printf '%s\n' "$(printf '═%.0s' $(seq 1 $WIDTH))"
echo "说明: 此处的耗时包含 DNS解析+TCP连接+TLS握手+服务器响应首字节 的完整过程，"
echo "      代表真实发起一次HTTPS请求到收到响应所需的时间，比单纯ping更贴近实际体感。"
