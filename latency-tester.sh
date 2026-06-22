#!/usr/bin/env bash
# 网络延迟测试工具 (纯 Bash 版)
# 依赖: curl, getent (glibc 自带), 无需 root, 无需额外安装
#
# 用法:
#   ./latency_test.sh
#   ./latency_test.sh -c 5      # 每个目标测 5 次取平均
#   ./latency_test.sh -t 2      # 单次超时秒数(默认2)

set -uo pipefail

COUNT=3
TIMEOUT=2

while getopts "c:t:" opt; do
  case $opt in
    c) COUNT="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    *) echo "用法: $0 [-c 次数] [-t 超时秒数]"; exit 1 ;;
  esac
done

# 目标列表: "显示名称|域名|端口"
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
  "Telegram|149.154.167.50|443"
)

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE" "${TMPFILE}.sorted" "${TMPFILE}.final"' EXIT

resolve_ip() {
  local domain="$1"
  if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$domain"
    return
  fi
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}'
}

tcp_ping_once() {
  local ip="$1" port="$2" timeout="$3"
  local t
  t=$(curl -s -o /dev/null --connect-timeout "$timeout" \
        -w '%{time_connect}' \
        "https://${ip}:${port}/" 2>/dev/null)
  if [[ -z "$t" || "$t" == "0.000000" ]]; then
    echo ""
    return
  fi
  awk -v t="$t" 'BEGIN{printf "%.1f", t*1000}'
}

test_target() {
  local name="$1" domain="$2" port="$3"
  local ip ver
  ip=$(resolve_ip "$domain")
  if [[ -n "$ip" ]]; then ver="IPv4"; else ver="N/A"; fi

  local success=0 sum=0
  for ((i=0; i<COUNT; i++)); do
    if [[ -n "$ip" ]]; then
      local ms
      ms=$(tcp_ping_once "$ip" "$port" "$TIMEOUT")
      if [[ -n "$ms" ]]; then
        success=$((success+1))
        sum=$(awk -v s="$sum" -v m="$ms" 'BEGIN{printf "%.1f", s+m}')
      fi
    fi
  done

  local loss avg
  loss=$(awk -v c="$COUNT" -v s="$success" 'BEGIN{printf "%.0f", (c-s)/c*100}')
  if (( success > 0 )); then
    avg=$(awk -v s="$sum" -v n="$success" 'BEGIN{printf "%.1f", s/n}')
  else
    avg=""
  fi

  echo "${name}|${domain}|${ip:-解析失败}|${ver}|${avg}|${loss}" >> "$TMPFILE"
}

echo "🚀 开始延迟测试..."
START=$(date +%s)

PIDS=()
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r name domain port <<< "$entry"
  test_target "$name" "$domain" "$port" &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do
  wait "$pid"
done

END=$(date +%s)
ELAPSED=$((END-START))

status_for() {
  local latency="$1" loss="$2"
  if [[ -z "$latency" || "$loss" -ge 100 ]]; then
    echo "✗ 超时"
  elif (( loss > 50 )); then
    echo "✗ 异常"
  elif awk -v l="$latency" 'BEGIN{exit !(l<50)}'; then
    echo "✓ 优秀"
  elif awk -v l="$latency" 'BEGIN{exit !(l<100)}'; then
    echo "◆ 良好"
  elif awk -v l="$latency" 'BEGIN{exit !(l<200)}'; then
    echo "▲ 较差"
  else
    echo "✗ 异常"
  fi
}

echo "📊 测试完成！ 总时间: ${ELAPSED}秒"
echo "📋 延迟测试结果表格:"
WIDTH=99
printf '%s\n' "$(printf '═%.0s' $(seq 1 $WIDTH))"
printf "%-4s %-14s %-28s %8s %6s %-8s %-16s %-6s\n" "排名" "服务" "域名" "延迟" "丢包率" "状态" "IPv4地址" "版本"
printf '%s\n' "$(printf '═%.0s' $(seq 1 $WIDTH))"

awk -F'|' '{ if ($5=="") print 999999"|"$0; else print $5"|"$0 }' "$TMPFILE" \
  | sort -t'|' -k1,1n \
  | cut -d'|' -f2- > "${TMPFILE}.final"

rank=0
while IFS='|' read -r name domain ip ver latency loss; do
  rank=$((rank+1))
  if [[ -n "$latency" ]]; then
    latency_str="${latency}ms"
  else
    latency_str="超时"
  fi
  status=$(status_for "$latency" "$loss")
  printf "%-4s %-14s %-28s %8s %5s%% %-8s %-16s %-6s\n" \
    "$rank" "$name" "$domain" "$latency_str" "$loss" "$status" "$ip" "$ver"
done < "${TMPFILE}.final"

printf '%s\n' "$(printf '═%.0s' $(seq 1 $WIDTH))"
