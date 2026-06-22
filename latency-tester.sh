#!/usr/bin/env bash
# 网络延迟测试工具 (纯 Bash 版 - 精确模式)
#
# 设计目标: 尽量减少"测量方法本身"带来的误差，得到更接近真实网络延迟的结果。
#
# 关键改动 (相比上一版):
#   1. 优先使用系统自带的 ping (ICMP)。ping 的时间戳是内核态打的，
#      几乎不受用户态进程调度/CPU抢占影响，比"应用层模拟TCP连接"准确得多。
#   2. 默认串行执行 (一个测完再测下一个)，避免19个目标同时起进程互相抢CPU，
#      导致延迟被"调度排队时间"拉高、结果失真。
#   3. 每个目标测 N 次取中位数 (而不是平均数)，过滤掉偶发的抖动尖刺。
#   4. 如果 ping 被防火墙/ICMP限制屏蔽 (无法连通)，自动回退到 TCP 连接测试
#      (用 /dev/tcp)，保证目标仍然能测出一个延迟参考值。
#
# 依赖: ping (iputils, 大多数 Linux 默认自带), getent, bash 内置 /dev/tcp
# 无需 root，无需 curl
#
# 用法:
#   ./latency_test.sh                # 默认: 每个目标 ping 5 次，串行
#   ./latency_test.sh -c 8            # 每个目标测 8 次
#   ./latency_test.sh -t 2            # 单次超时秒数
#   ./latency_test.sh -p 4            # 允许4个并发 (默认1=串行，更准但更慢)

set -uo pipefail

COUNT=5
TIMEOUT=2
PARALLEL=1

while getopts "c:t:p:" opt; do
  case $opt in
    c) COUNT="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    p) PARALLEL="$OPTARG" ;;
    *) echo "用法: $0 [-c 次数] [-t 超时秒数] [-p 并发数]"; exit 1 ;;
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
trap 'rm -f "$TMPFILE" "${TMPFILE}.final"' EXIT

HAS_PING=0
if command -v ping >/dev/null 2>&1; then
  HAS_PING=1
fi

resolve_ip() {
  local domain="$1"
  if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$domain"
    return
  fi
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}'
}

# 用 ICMP ping 测试，返回 "avg_ms|loss_pct"，失败则 avg_ms 为空
icmp_ping_test() {
  local ip="$1" count="$2" timeout="$3"
  local out
  out=$(ping -c "$count" -W "$timeout" -i 0.3 "$ip" 2>/dev/null)
  if [[ -z "$out" ]]; then
    echo "|100"
    return
  fi
  local avg loss
  avg=$(echo "$out" | grep -oE '= [0-9.]+/[0-9.]+/[0-9.]+' | sed 's/^= //' | awk -F'/' '{print $2}')
  loss=$(echo "$out" | grep -oE '[0-9]+% packet loss' | grep -oE '[0-9]+' | head -1)
  [[ -z "$loss" ]] && loss=100
  echo "${avg}|${loss}"
}

# 用纯 TCP 连接做单次测试 (ping 不可用/被墙时的备用方案)
tcp_ping_once() {
  local ip="$1" port="$2" timeout="$3"
  local start end elapsed_ms
  start=$(date +%s%N)
  if timeout "$timeout" bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null; then
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    echo "$elapsed_ms"
  else
    echo ""
  fi
}

tcp_fallback_test() {
  local ip="$1" port="$2" count="$3" timeout="$4"
  local success=0
  local samples=()
  for ((i=0; i<count; i++)); do
    local ms
    ms=$(tcp_ping_once "$ip" "$port" "$timeout")
    if [[ -n "$ms" ]]; then
      success=$((success+1))
      samples+=("$ms")
    fi
  done
  local loss
  loss=$(awk -v c="$count" -v s="$success" 'BEGIN{printf "%.0f", (c-s)/c*100}')
  if (( success == 0 )); then
    echo "|100"
    return
  fi
  # 取中位数
  local sorted median
  sorted=$(printf '%s\n' "${samples[@]}" | sort -n)
  median=$(echo "$sorted" | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  echo "${median}|${loss}"
}

test_target() {
  local name="$1" domain="$2" port="$3"
  local ip ver
  ip=$(resolve_ip "$domain")
  if [[ -n "$ip" ]]; then ver="IPv4"; else ver="N/A"; fi

  local result avg loss method=""
  if [[ -z "$ip" ]]; then
    avg=""; loss=100
  elif (( HAS_PING )); then
    result=$(icmp_ping_test "$ip" "$COUNT" "$TIMEOUT")
    avg="${result%%|*}"
    loss="${result##*|}"
    method="ICMP"
    # 如果 ping 完全不通 (可能被防火墙拦截ICMP), 自动回退到TCP
    if [[ -z "$avg" || "$loss" == "100" ]]; then
      result=$(tcp_fallback_test "$ip" "$port" "$COUNT" "$TIMEOUT")
      avg="${result%%|*}"
      loss="${result##*|}"
      method="TCP"
    fi
  else
    result=$(tcp_fallback_test "$ip" "$port" "$COUNT" "$TIMEOUT")
    avg="${result%%|*}"
    loss="${result##*|}"
    method="TCP"
  fi

  echo "${name}|${domain}|${ip:-解析失败}|${ver}|${avg}|${loss}|${method}" >> "$TMPFILE"
}

echo "🚀 开始延迟测试 (串行=更准确，并发数=${PARALLEL})..."
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
WIDTH=105
printf '%s\n' "$(printf '═%.0s' $(seq 1 $WIDTH))"
printf "%-4s %-14s %-28s %8s %6s %-8s %-16s %-6s %-5s\n" "排名" "服务" "域名" "延迟" "丢包率" "状态" "IPv4地址" "版本" "方式"
printf '%s\n' "$(printf '═%.0s' $(seq 1 $WIDTH))"

awk -F'|' '{ if ($5=="") print 999999"|"$0; else print $5"|"$0 }' "$TMPFILE" \
  | sort -t'|' -k1,1n \
  | cut -d'|' -f2- > "${TMPFILE}.final"

rank=0
while IFS='|' read -r name domain ip ver latency loss method; do
  rank=$((rank+1))
  if [[ -n "$latency" ]]; then
    latency_str="${latency}ms"
  else
    latency_str="超时"
  fi
  status=$(status_for "$latency" "$loss")
  printf "%-4s %-14s %-28s %8s %5s%% %-8s %-16s %-6s %-5s\n" \
    "$rank" "$name" "$domain" "$latency_str" "$loss" "$status" "$ip" "$ver" "$method"
done < "${TMPFILE}.final"

printf '%s\n' "$(printf '═%.0s' $(seq 1 $WIDTH))"

if (( ! HAS_PING )); then
  echo "提示: 本机未检测到 ping 命令，全部使用 TCP 连接方式测试。"
fi
