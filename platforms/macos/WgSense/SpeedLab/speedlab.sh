# WgSense 测速台 · 执行端脚本（busybox ash 与 macOS sh 通用）。
#
# App 经 stdin 下发（本机 /bin/sh -s，远端 ssh … sh -s），参数是开头的一串变量赋值。
# 每个事件一行，以 @ 开头的 JSON；其余输出一律忽略。
#
#   MODE=probe          能力探测：系统、工具、默认网卡与协商速率、DNS 是否被劫持、WG peer
#   MODE=http           公网测速：空载延迟 → 选源 → 下行 → 上行（速率读网卡计数器）
#   MODE=iperf          iperf3 客户端：空载延迟 → 下行(-R) → 上行
#   MODE=iperf-server   在本机起一次性 iperf3 服务端（端口被占自动顺延），输出实际端口
#   MODE=iperf-stop     停掉上面起的服务端，删除临时部署的 iperf3
#
# PATHMODE=direct 绑物理网卡 + 真 DNS 逐跳解析（绕开隧道、代理与 fake-ip）；system = 系统默认路由与 DNS。
set -u
: "${MODE:=probe}" "${PATHMODE:=direct}" "${DUR:=10}" "${DIRS:=dl ul}" "${DNS:=223.5.5.5}"
: "${DL_URLS:=}" "${UL_URLS:=}" "${DL_THREADS:=12}" "${UL_THREADS:=4}" "${PING_HOST:=}"
: "${IPERF_HOST:=}" "${IPERF_PORT:=5201}" "${IPERF_P:=4}" "${IPERF_BIN:=}" "${DEPLOYED:=}" "${TICK:=0.25}"
UA="Mozilla/5.0 (Macintosh) WgSense-SpeedLab"
OS=$(uname -s)
WORK=/tmp/wgsense-speed.$$
LOCK=/tmp/wgsense-speed.lock
PIDS=""

emit() { printf '@%s\n' "$1"; }
jstr() { printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
info() { emit "{\"ev\":\"info\",\"k\":\"$1\",\"v\":\"$(jstr "$2")\"}"; }
fail() { emit "{\"ev\":\"err\",\"msg\":\"$(jstr "$1")\"}"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
bg() { PIDS="$PIDS $!"; }

cleanup() {
	for p in $PIDS; do kill "$p" 2>/dev/null; done
	rm -rf "$WORK"
	[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
}

lock() {
	if ! mkdir "$LOCK" 2>/dev/null; then
		old=$(cat "$LOCK/pid" 2>/dev/null)
		if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then fail "这台机器上已有一个测速在运行"; fi
		rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || fail "无法加锁 $LOCK"
	fi
	echo $$ > "$LOCK/pid"
	trap cleanup EXIT
	trap 'exit 1' INT TERM HUP PIPE
	mkdir -p "$WORK"
	pick_nap
	# 看门狗：App 掉线、SSH 断开也一定收尾。
	( sleep $((DUR * 2 + 60)); kill -TERM $$ ) >/dev/null 2>&1 </dev/null & bg
}

# ---------- 网络基础 ----------

now() {
	if [ -r /proc/uptime ]; then cut -d' ' -f1 /proc/uptime
	elif [ -x /usr/bin/perl ]; then /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time'
	else date +%s; fi
}

# 亚秒级等待：采样每秒 4 次。busybox 的 sleep 不认小数，依次退到 OpenWrt 自带的 ucode / lua；都没有就每秒一次。
pick_nap() {
	if sleep 0.01 2>/dev/null; then NAP=sleep
	elif has ucode && ucode -e 'sleep(1)' >/dev/null 2>&1; then NAP=ucode
	elif has lua && lua -e 'require "nixio"' >/dev/null 2>&1; then NAP=lua
	else NAP=none; TICK=1; fi
	MS=$(awk -v t="$TICK" 'BEGIN { printf "%d", t * 1000 }')
	info tick "$TICK"
}
nap() {
	case $NAP in
	sleep) sleep "$TICK" ;;
	ucode) ucode -e "sleep($MS)" ;;
	lua) lua -e "require('nixio').nanosleep(0, $MS * 1000000)" ;;
	*) sleep 1 ;;
	esac
}

routeif() {
	if [ "$OS" = Darwin ]; then route -n get "$1" 2>/dev/null | awk '/interface:/{print $2; exit}'
	else ip route get "$1" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'; fi
}

defif() {
	if [ "$OS" = Darwin ]; then route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
	else ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'; fi
}

# 网卡累计字节："rx tx"
ctr() {
	if [ -r "/sys/class/net/$1/statistics/rx_bytes" ]; then
		echo "$(cat "/sys/class/net/$1/statistics/rx_bytes") $(cat "/sys/class/net/$1/statistics/tx_bytes")"
	else
		netstat -ibn -I "$1" 2>/dev/null | awk '/<Link#/ { if (NF >= 11) print $7, $10; else print $6, $9; exit }'
	fi
}

mtuof() {
	if [ -r "/sys/class/net/$1/mtu" ]; then cat "/sys/class/net/$1/mtu"
	else ifconfig "$1" 2>/dev/null | sed -n 's/.*mtu \([0-9]*\).*/\1/p' | head -1; fi
}

# 承载虚拟口（pppoe 等）的物理口
lowerif() {
	i=$1
	case $i in
	ppp*|pppoe*)
		line=$(ps w 2>/dev/null | grep "[p]ppd.*$i" | head -1)
		[ -z "$line" ] && line=$(ps ax -o args 2>/dev/null | grep "[p]ppd.*$i" | head -1)
		nic=$(printf '%s' "$line" | sed -n 's/.*nic-\([^ ]*\).*/\1/p')
		if [ -z "$nic" ] && has uci; then
			ipp=$(printf '%s' "$line" | sed -n 's/.*ipparam \([^ ]*\).*/\1/p')
			[ -n "$ipp" ] && nic=$(uci -q get "network.$ipp.device" || uci -q get "network.$ipp.ifname")
		fi
		echo "${nic:-$i}" ;;
	*) echo "$i" ;;
	esac
}

# 协商速率 "Mbps 双工"，读不到为空
linkspeed() {
	i=$1
	# 网桥、隧道之类的虚拟口没有真实协商速率
	[ -d "/sys/class/net/$i/bridge" ] && return 0
	if [ -r "/sys/class/net/$i/speed" ]; then
		s=$(cat "/sys/class/net/$i/speed" 2>/dev/null)
		[ -n "$s" ] && [ "$s" -gt 0 ] 2>/dev/null && { echo "$s $(cat "/sys/class/net/$i/duplex" 2>/dev/null)"; return; }
	fi
	if [ "$OS" = Darwin ]; then
		ifconfig "$i" 2>/dev/null | sed -n 's/.*media:.*(\([0-9]*\)\(base\|Gbase\)[^ <]* *<*\([a-z-]*\).*/\1 \3/p' | head -1
	fi
}

resolve() {
	if has dig; then
		dig +short +time=2 +tries=1 @"$DNS" "$1" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1
	else
		nslookup "$1" "$DNS" 2>/dev/null | awk '/answer|^Name:/ { f = 1 } f && /^Address/ { a = $NF; if (a !~ /:/ && a !~ /#/) { print a; exit } }'
	fi
}

# 某个 URL 的 curl 寻址参数（direct：绑网卡 + 真 DNS）
hostof() { printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#'; }
portof() {
	p=$(printf '%s' "$1" | sed -nE 's#^[a-zA-Z]+://[^/:]+:([0-9]+).*#\1#p')
	[ -n "$p" ] && { echo "$p"; return; }
	case $1 in https*) echo 443 ;; *) echo 80 ;; esac
}
addr() {
	[ "$PATHMODE" = direct ] || return 0
	h=$(hostof "$1"); ip=$(resolve "$h")
	[ -n "$ip" ] || return 1
	echo "--interface $IF --resolve $h:$(portof "$1"):$ip"
}

# 手动逐跳跟随跳转（每一跳都用真 DNS 解析），输出最终可下载的 URL
final_url() {
	u=$1; n=0
	while [ $n -lt 5 ]; do
		a=$(addr "$u") || return 1
		out=$(curl -s -o /dev/null -m 8 -A "$UA" $a -r 0-0 -w '%{http_code} %{redirect_url}' "$u" 2>/dev/null)
		code=${out%% *}; red=${out#* }
		case $code in
		2*) echo "$u"; return 0 ;;
		3*) [ -n "$red" ] && [ "$red" != "$out" ] || return 1; u=$red; n=$((n + 1)) ;;
		*) return 1 ;;
		esac
	done
	return 1
}

# ---------- 延迟 ----------

ping_start() {
	[ -n "$1" ] || return 0
	b=""
	if [ "$PATHMODE" = direct ]; then
		if [ "$OS" = Darwin ]; then b="-b $IF"; else b="-I $IF"; fi
	fi
	ping $b "$1" > "$WORK/ping" 2>/dev/null </dev/null & bg
}
lastrtt() { tail -n 1 "$WORK/ping" 2>/dev/null | sed -n 's/.*time[=<]\([0-9.]*\).*/\1/p'; }

# ---------- 采样：每秒一条，速率来自网卡计数器 ----------

# 采样：$2 秒，每 TICK 一条；速率按实际流逝时间算，等待有抖动也不失真
sample() {
	ph=$1; n=$(awk -v d="$2" -v t="$TICK" 'BEGIN { printf "%d", d / t }')
	prev=$(ctr "$CIF"); pt=$(now); i=0
	while [ $i -lt "$n" ]; do
		nap
		cur=$(ctr "$CIF"); ct=$(now); r=$(lastrtt)
		# 先赋值再输出：macOS 自带 bash 3.2 在 "$( … )" 里解析单引号内的 \" 有缺陷
		line=$(echo "$prev $cur $pt $ct" | awk -v ph="$ph" -v r="$r" '{
			dt = $6 - $5; if (dt <= 0) dt = 1
			printf "{\"ev\":\"s\",\"ph\":\"%s\",\"rx\":%.1f,\"tx\":%.1f,\"rtt\":%s}", ph, ($3 - $1) * 8 / dt / 1e6, ($4 - $2) * 8 / dt / 1e6, (r == "" ? "null" : r)
		}')
		emit "$line"
		prev=$cur; pt=$ct; i=$((i + 1))
	done
}

phase() { emit "{\"ev\":\"phase\",\"ph\":\"$1\"}"; }

# ---------- 公网 HTTP ----------

# 下载线程：到点前反复拉同一个文件。
# CDN 每次跳转可能分到不同节点，有的节点会卡死：连续 2 秒低于 1 MB/s 就断开，从原始地址重新跳转换节点。
dl_thread() {
	orig=$1; end=$2; n=$3
	while :; do
		left=$((end - $(date +%s))); [ $left -gt 0 ] || break
		url=$(final_url "$orig") || { sleep 1; continue; }
		a=$(addr "$url") || { sleep 1; continue; }
		left=$((end - $(date +%s))); [ $left -gt 0 ] || break
		curl -s -o /dev/null -A "$UA" -m "$left" --speed-limit 1048576 --speed-time 2 $a "$url" 2>/dev/null
		reconn dl "$n" $?
	done
}

# 连接中途断开（卡死被掐断 / 出错）且时间未到 = 一次重连；正常下完文件再开不算
reconn() {
	[ "$3" -eq 0 ] && return 0
	[ $((end - $(date +%s))) -gt 1 ] || return 0
	emit "{\"ev\":\"conn\",\"ph\":\"$1\",\"n\":$2,\"rc\":$3}"
}

# 上传线程：单条长连接，从 /dev/zero 直推，不反复建连（建连空档会让曲线下沉）
ul_thread() {
	url=$1; end=$2; n=$3; a=$(addr "$url") || return
	while :; do
		left=$((end - $(date +%s))); [ $left -gt 0 ] || break
		dd if=/dev/zero bs=1048576 count=8192 2>/dev/null | curl -s -o /dev/null -A "$UA" -m "$left" $a \
			-X POST -T - -H "Content-Length: 8589934592" -H "Transfer-Encoding:" -H "Content-Type: application/octet-stream" \
			"$url" 2>/dev/null
		reconn ul "$n" $?
	done
}

# 并行试每个源：3 条连接跑 3 秒，速度相加（单连接 2 秒还没爬到速度，会误判慢源）。输出 "Mbps url"
pick_dl() {
	k=0
	for u in $DL_URLS; do
		k=$((k + 1))
		( f=$(final_url "$u") || { echo "0 $u" > "$WORK/dl.$k"; exit 0; }
		  a=$(addr "$f") || { echo "0 $u" > "$WORK/dl.$k"; exit 0; }
		  for j in 1 2 3; do curl -s -o /dev/null -A "$UA" -m 3 $a -w '%{speed_download}\n' "$f" 2>/dev/null > "$WORK/p.$k.$j" & done
		  wait
		  cat "$WORK"/p.$k.* | awk -v u="$u" '{ s += $1 } END { printf "%.0f %s\n", s * 8 / 1e6, u }' > "$WORK/dl.$k" ) </dev/null &
	done
	wait
	# 比最快的源慢 4 倍以上的不要：线程平分到慢源上会把总速拖下来
	cat "$WORK"/dl.* 2>/dev/null | awk '$1 > 0' | sort -rn | awk 'NR == 1 { best = $1 } $1 * 4 >= best' | head -3
}

pick_ul() {
	k=0
	for u in $UL_URLS; do
		k=$((k + 1))
		( a=$(addr "$u") || { echo "0 $u" > "$WORK/ul.$k"; exit 0; }
		  s=$(dd if=/dev/zero bs=1048576 count=64 2>/dev/null | curl -s -o /dev/null -A "$UA" -m 2 $a -X POST -T - \
			-H "Content-Length: 67108864" -H "Transfer-Encoding:" -w '%{speed_upload}' "$u" 2>/dev/null)
		  echo "$s $u" | awk '{ printf "%.0f %s\n", $1 * 8 / 1e6, $2 }' > "$WORK/ul.$k" ) </dev/null &
	done
	wait
	cat "$WORK"/ul.* 2>/dev/null | awk '$1 > 0' | sort -rn | awk 'NR == 1 { best = $1 } $1 * 4 >= best' | head -2
}

run_http() {
	has curl || fail "执行端没有 curl"
	IF=$(defif); [ -n "$IF" ] || fail "找不到默认网卡"
	PHY=$(lowerif "$IF")
	info iface "$IF"; info phy "$PHY"; info link "$(linkspeed "$PHY")"; info mtu "$(mtuof "$IF")"
	if [ "$PATHMODE" = direct ]; then
		CIF=$IF
		curl -s -o /dev/null -m 4 --interface "$IF" "http://$DNS/" 2>/dev/null
		[ $? -eq 7 ] && fail "无法绑定 $IF 直连：系统路由被隧道全局接管（本机直连需要网卡专属路由）"
	else
		CIF=$(routeif "$DNS"); [ -n "$CIF" ] || CIF=$IF
	fi
	info count "$CIF"
	ea=$(addr "https://myip.ipip.net/") && info exit "$(curl -s -m 5 -A "$UA" $ea https://myip.ipip.net/ 2>/dev/null)"

	ping_start "${PING_HOST:-$DNS}"
	phase idle; sample idle 3

	phase pick
	dls=$(pick_dl); uls=$(pick_ul)
	info dl_sources "$(echo "$dls" | awk 'NF { printf "%s%s %s", (n++ ? " | " : ""), $2, $1 }')"
	info ul_sources "$(echo "$uls" | awk 'NF { printf "%s%s %s", (n++ ? " | " : ""), $2, $1 }')"
	# 每个候选源的试跑结果：入选 keep，其余 drop
	for d in dl ul; do
		[ $d = dl ] && kept=$dls || kept=$uls
		cat "$WORK"/$d.* 2>/dev/null | while read -r mb u; do
			k=false; echo "$kept" | awk -v u="$u" '$2 == u { f = 1 } END { exit !f }' && k=true
			emit "{\"ev\":\"src\",\"ph\":\"$d\",\"v\":\"$(jstr "$u")\",\"rx\":$mb,\"keep\":$k}"
		done
	done
	first=$(echo "$dls" | awk 'NR == 1 { print $2 }')
	[ -n "$first" ] && info src_ip "$(resolve "$(hostof "$first")")"

	ran=0
	for d in $DIRS; do
		case $d in
		dl)
			[ -n "$dls" ] || { emit '{"ev":"skip","ph":"dl"}'; continue; }
			ran=1
			set -- $(echo "$dls" | awk '{ print $2 }')
			end=$(( $(date +%s) + DUR + 1 )); t=0
			while [ $t -lt "$DL_THREADS" ]; do
				eval "u=\${$(( t % $# + 1 ))}"
				dl_thread "$u" "$end" "$t" </dev/null & bg
				t=$((t + 1))
			done
			phase dl; sample dl "$DUR" ;;
		ul)
			[ -n "$uls" ] || { emit '{"ev":"skip","ph":"ul"}'; continue; }
			ran=1
			set -- $(echo "$uls" | awk '{ print $2 }')
			end=$(( $(date +%s) + DUR + 1 )); t=0
			while [ $t -lt "$UL_THREADS" ]; do
				eval "u=\${$(( t % $# + 1 ))}"
				ul_thread "$u" "$end" "$t" </dev/null & bg
				t=$((t + 1))
			done
			phase ul; sample ul "$DUR" ;;
		esac
		sleep 1
	done
	[ "$ran" = 1 ] || fail "所有测速源都不可用"
}

# ---------- iperf3 ----------

iperf_bin() { if [ -n "$IPERF_BIN" ]; then echo "$IPERF_BIN"; elif has iperf3; then echo iperf3; fi; }

run_iperf() {
	B=$(iperf_bin); [ -n "$B" ] || fail "执行端没有 iperf3"
	[ -n "$IPERF_HOST" ] || fail "没有指定 iperf3 对端"
	IF=$(routeif "$IPERF_HOST"); CIF=${IF:-$(defif)}
	PATHMODE=system
	info iface "$CIF"; info link "$(linkspeed "$(lowerif "$CIF")")"; info mtu "$(mtuof "$CIF")"
	ping_start "$IPERF_HOST"
	phase idle; sample idle 3
	for d in $DIRS; do
		r=""; [ "$d" = dl ] && r=-R
		phase "$d"
		"$B" -c "$IPERF_HOST" -p "$IPERF_PORT" -P "$IPERF_P" -t "$DUR" -i "$TICK" -f m --forceflush $r 2>&1 </dev/null | while read -r line; do
			case $line in
			*error*|*Error*) emit "{\"ev\":\"err\",\"msg\":\"$(jstr "$line")\"}" ;;
			*sender*|*receiver*) ;;
			*Mbits/sec*)
				if [ "$IPERF_P" -gt 1 ]; then case $line in "[SUM]"*) ;; *) continue ;; esac; fi
				v=$(echo "$line" | awk '{ for (i = 2; i <= NF; i++) if ($i == "Mbits/sec") { print $(i - 1); exit } }')
				r2=$(lastrtt)
				if [ "$d" = dl ]; then
					emit "{\"ev\":\"s\",\"ph\":\"dl\",\"rx\":${v:-0},\"tx\":0,\"rtt\":${r2:-null}}"
				else
					emit "{\"ev\":\"s\",\"ph\":\"ul\",\"rx\":0,\"tx\":${v:-0},\"rtt\":${r2:-null}}"
				fi ;;
			esac
		done
		sleep 1
	done
}

iperf_server() {
	B=$(iperf_bin); [ -n "$B" ] || fail "对端没有 iperf3"
	p=$IPERF_PORT; last=$((IPERF_PORT + 9))
	while [ $p -le $last ]; do
		pf=/tmp/wgsense-iperf.$p.pid
		rm -f "$pf"
		"$B" -s -p "$p" -D -I "$pf" >/dev/null 2>&1 </dev/null
		sleep 1
		pid=$(cat "$pf" 2>/dev/null)
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			# 一次性：最多存活 10 分钟，App 忘了停也会自己退出
			( sleep 600; kill "$pid" 2>/dev/null; rm -f "$pf" ) >/dev/null 2>&1 </dev/null &
			info port "$p"; info version "$("$B" --version 2>/dev/null | head -1)"
			return 0
		fi
		p=$((p + 1))
	done
	fail "iperf3 服务端起不来（$IPERF_PORT-$last 端口都不可用）"
}

iperf_stop() {
	for pf in /tmp/wgsense-iperf.*.pid; do
		[ -f "$pf" ] || continue
		kill "$(cat "$pf")" 2>/dev/null; rm -f "$pf"
	done
	[ -n "$DEPLOYED" ] && rm -f "$DEPLOYED"
	info stopped 1
}

# ---------- 能力探测 ----------

probe() {
	info os "$OS"; info arch "$(uname -m)"
	for t in curl iperf3 ping uci wg; do has $t && info "has_$t" 1; done
	has iperf3 && info iperf3 "$(iperf3 --version 2>/dev/null | head -1)"
	IF=$(defif); info iface "$IF"; PHY=$(lowerif "$IF"); info phy "$PHY"; info link "$(linkspeed "$PHY")"
	sys=$(nslookup www.baidu.com 2>/dev/null | awk '/answer|^Name:/ { f = 1 } f && /^Address/ { a = $NF; if (a !~ /:/ && a !~ /#/) { print a; exit } }')
	case $sys in 198.18.*|198.19.*) info fakeip 1 ;; esac
	# WG peer（OpenWrt：uci 里的 wireguard_* 段；描述作名字，/32 地址作目标）
	if has uci; then
		uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=wireguard_\(.*\)$/\1 \2/p' | while read -r s ifc; do
			ip=$(uci -q get "network.$s.allowed_ips" | tr ' ' '\n' | sed -n "s#^'\{0,1\}\([0-9.]*\)/32'\{0,1\}\$#\1#p" | head -1)
			[ -n "$ip" ] || continue
			name=$(uci -q get "network.$s.description"); name=${name:-${s#wg_}}
			emit "{\"ev\":\"peer\",\"name\":\"$(jstr "$name")\",\"ip\":\"$ip\",\"iface\":\"$ifc\"}"
		done
	fi
}

case $MODE in
probe) probe ;;
http) lock; run_http ;;
iperf) lock; run_iperf ;;
iperf-server) iperf_server ;;
iperf-stop) iperf_stop ;;
*) fail "未知模式 $MODE" ;;
esac
emit '{"ev":"end"}'
