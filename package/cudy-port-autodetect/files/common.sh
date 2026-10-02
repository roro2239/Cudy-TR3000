#!/bin/sh

RUN_DIR=/var/run/cudy-port-autodetect
BACKUP_DIR=/etc/cudy-port-autodetect
LIB_DIR=/usr/libexec/cudy-port-autodetect
BRIDGE=br-lan
SELECTED=
SELECTED_KEY=
PROBE_PID=

log() {
	logger -t cudy-port-autodetect "$*"
	printf '%s\n' "$*" >&2
}

port_interface() {
	case "$1" in eth0) echo wan ;; eth1) echo wan2 ;; *) return 1 ;; esac
}

port_ipv6_interface() {
	case "$1" in eth0) echo wan6 ;; eth1) echo wan2_6 ;; *) return 1 ;; esac
}

ipv4_valid() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{ for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || length($i)>3 || $i>255) exit 1 }
	'
}

# 不把与管理网段重叠的上级网络桥入 LAN，也不能用猜测的掩码接受租约。
lease_safe() {
	local lease_ip="$1" lease_mask="$2" gateway="$3" lan_ip="$4" lan_mask="$5"
	ipv4_valid "$lease_ip" && ipv4_valid "$lease_mask" && ipv4_valid "$gateway" \
		&& ipv4_valid "$lan_ip" && ipv4_valid "$lan_mask" || return 1
	awk -v ip="$lease_ip" -v mask="$lease_mask" -v gw="$gateway" \
		-v lan="$lan_ip" -v lanmask="$lan_mask" 'BEGIN {
		if (prefix(mask)<1 || prefix(lanmask)<1) exit 1
		i=number(ip); g=number(gw); l=number(lan)
		if (i==0 || g==0 || i==g || i>=3758096384 || g>=3758096384) exit 1
		a=2^(32-prefix(mask)); b=2^(32-prefix(lanmask))
		start=int(i/a)*a; end=start+a-1
		ls=int(l/b)*b; le=ls+b-1
		if ((a>2 && (i==start || i==end)) || (start<=le && ls<=end)) exit 1
	}
	function number(s, parts,n,j,v) {
		n=split(s,parts,"."); v=0
		for(j=1;j<=n;j++) v=v*256+parts[j]
		return v
	}
	function prefix(s, parts,n,j,v,p,partial) {
		n=split(s,parts,"."); p=0; partial=0
		for(j=1;j<=n;j++) {
			v=parts[j]+0
			if(partial && v!=0) return -1
			if(v==255) p+=8
			else {
				partial=1
				if(v==254) p+=7; else if(v==252) p+=6
				else if(v==248) p+=5; else if(v==240) p+=4
				else if(v==224) p+=3; else if(v==192) p+=2
				else if(v==128) p+=1; else if(v!=0) return -1
			}
		}
		return p
	}'
}

find_bridge() {
	local name
	config_get name "$1" name
	[ "$name" != "$BRIDGE" ] || BRIDGE_SECTION="$1"
	return 0
}

find_wan_zone() {
	local name
	config_get name "$1" name
	[ "$name" != wan ] || WAN_ZONE="$1"
	return 0
}

rollback_initialization() {
	local restored=1
	uci revert network || restored=0
	uci revert firewall || restored=0
	cp -p "$BACKUP_DIR/network.backup" /etc/config/network || restored=0
	cp -p "$BACKUP_DIR/firewall.backup" /etc/config/firewall || restored=0
	rm -f "$BACKUP_DIR/configured.sha256" || restored=0
	if [ "$restored" = 1 ]; then
		log '初始化失败，已恢复原配置。'
	else
		log "初始化失败，自动回滚也失败；请检查 $BACKUP_DIR 中的原配置备份。"
		return 1
	fi
}

configure_network() (
	set -e
	. /lib/functions.sh || exit 1
	local board bridge_ports device iface six metric
	board=$(cat /tmp/sysinfo/board_name)
	case "$board" in
		cudy,tr3000-v1|cudy,tr3000-v1-256mb|cudy,tr3000-v1-ubootmod) ;;
		*) log '此插件仅支持 Cudy TR3000 v1 的两种构建目标。'; exit 1 ;;
	esac
	[ ! -f "$BACKUP_DIR/configured.sha256" ] || exit 0
	[ -z "$(uci changes network)$(uci changes firewall)" ] || {
		log '存在未保存的网络或防火墙修改，拒绝覆盖；请先处理这些修改。'
		exit 1
	}
	[ "$(uci -q get network.lan.device)" = "$BRIDGE" ] \
		&& [ "$(uci -q get network.lan.proto)" = static ] \
		&& [ "$(uci -q get network.wan.proto)" = dhcp ] || {
		log '需要现有静态 LAN 和 DHCP 上网配置，当前配置不符合自动识别条件。'
		exit 1
	}
	[ -z "$(uci -q get network.wan2 || true)" ] \
		&& [ -z "$(uci -q get network.wan2_6 || true)" ] || {
		log 'wan2 或 wan2_6 已被其他配置使用，拒绝接管。'; exit 1
	}
	BRIDGE_SECTION= WAN_ZONE=
	config_load network || exit 1
	config_foreach find_bridge device || exit 1
	config_load firewall || exit 1
	config_foreach find_wan_zone zone || exit 1
	[ -n "$BRIDGE_SECTION" ] && [ -n "$WAN_ZONE" ] || {
		log '未找到内网桥或 WAN 防火墙区域。'; exit 1
	}
	umask 077
	mkdir -p "$BACKUP_DIR" || exit 1
	# 重试初始化不能覆盖最初的备份。
	[ -f "$BACKUP_DIR/network.backup" ] || cp -p /etc/config/network "$BACKUP_DIR/network.backup" || exit 1
	[ -f "$BACKUP_DIR/firewall.backup" ] || cp -p /etc/config/firewall "$BACKUP_DIR/firewall.backup" || exit 1
	trap rollback_initialization EXIT
	bridge_ports=$(uci -q get "network.$BRIDGE_SECTION.ports" || true)
	for device in eth0 eth1; do
		case " $bridge_ports " in
			*" $device "*) uci del_list "network.$BRIDGE_SECTION.ports=$device" || exit 1 ;;
		esac
	done
	uci set "network.$BRIDGE_SECTION.bridge_empty=1" || exit 1
	for device in eth0 eth1; do
		iface=$(port_interface "$device")
		six=$(port_ipv6_interface "$device")
		metric=10
		[ "$device" = eth0 ] || metric=20
		uci set "network.$iface=interface" || exit 1
		uci set "network.$iface.device=$device" || exit 1
		uci set "network.$iface.proto=dhcp" || exit 1
		uci set "network.$iface.auto=0" || exit 1
		uci set "network.$iface.metric=$metric" || exit 1
		uci set "network.$iface.ipv6=0" || exit 1
		uci set "network.$six=interface" || exit 1
		uci set "network.$six.device=$device" || exit 1
		uci set "network.$six.proto=dhcpv6" || exit 1
		uci set "network.$six.auto=0" || exit 1
		uci set "network.$six.metric=$metric" || exit 1
		uci -q del_list "firewall.$WAN_ZONE.network=$iface" || true
		uci -q del_list "firewall.$WAN_ZONE.network=$six" || true
		uci add_list "firewall.$WAN_ZONE.network=$iface" || exit 1
		uci add_list "firewall.$WAN_ZONE.network=$six" || exit 1
	done
	uci commit network || exit 1
	uci commit firewall || exit 1
	sha256sum /etc/config/network /etc/config/firewall > "$BACKUP_DIR/configured.sha256" || exit 1
	trap - EXIT
	if ubus list network >/dev/null 2>&1; then
		/etc/init.d/network reload || { log '配置已保存，但网络重新加载失败。'; exit 1; }
		/etc/init.d/firewall reload || { log '配置已保存，但防火墙重新加载失败。'; exit 1; }
	fi
	log '网口自动识别已初始化，原网络和防火墙配置已备份。'
)

restore_network() {
	[ -f "$BACKUP_DIR/configured.sha256" ] || { log '没有可恢复的初始化备份。'; return 1; }
	[ -z "$(uci changes network)$(uci changes firewall)" ] || {
		log '存在未保存的网络或防火墙修改，拒绝恢复覆盖。'; return 1
	}
	sha256sum -c "$BACKUP_DIR/configured.sha256" >/dev/null 2>&1 || {
		log '初始化后网络或防火墙配置发生了修改，拒绝覆盖；请手动比较备份。'
		return 1
	}
	/etc/init.d/cudy-port-autodetect stop || return 1
	/etc/init.d/cudy-port-autodetect disable || return 1
	cp -p "$BACKUP_DIR/network.backup" /etc/config/network \
		&& cp -p "$BACKUP_DIR/firewall.backup" /etc/config/firewall || return 1
	uci set cudy-port-autodetect.main.enabled=0 || return 1
	uci commit cudy-port-autodetect || return 1
	rm "$BACKUP_DIR/configured.sha256" || return 1
	/etc/init.d/network reload && /etc/init.d/firewall reload || return 1
	log '已停用自动识别并恢复安装前的网络配置。'
}

load_port() {
	ROLE=unknown LAST_CARRIER=0 GENERATION=0 STREAK=0 HEALTH=waiting FAILS=0 PASSES=0
	IPV4= GATEWAY= LAST_HEALTH=0 RETRY_AT=0 SETTLE_UNTIL=0
	[ -r "$RUN_DIR/$1.state" ] || return 0
	{
		read -r ROLE; read -r LAST_CARRIER; read -r GENERATION; read -r STREAK
		read -r HEALTH; read -r FAILS; read -r PASSES; read -r IPV4; read -r GATEWAY
		read -r LAST_HEALTH; read -r RETRY_AT; read -r SETTLE_UNTIL
	} < "$RUN_DIR/$1.state"
}

save_port() {
	printf '%s\n' "$ROLE" "$LAST_CARRIER" "$GENERATION" "$STREAK" "$HEALTH" \
		"$FAILS" "$PASSES" "$IPV4" "$GATEWAY" "$LAST_HEALTH" "$RETRY_AT" "$SETTLE_UNTIL" \
		> "$RUN_DIR/$1.state.tmp" && mv "$RUN_DIR/$1.state.tmp" "$RUN_DIR/$1.state"
}

carrier() {
	cat "/sys/class/net/$1/carrier" 2>/dev/null || echo 0
}

generation() {
	cat "/sys/class/net/$1/carrier_changes" 2>/dev/null || echo 0
}

master() {
	local path
	path=$(readlink "/sys/class/net/$1/master") || return 0
	printf '%s\n' "${path##*/}"
}

stop_wan() {
	ifdown "$(port_interface "$1")" && ifdown "$(port_ipv6_interface "$1")"
}

detach_port() {
	[ -z "$(master "$1")" ] || ip link set dev "$1" nomaster
}

probe_port() {
	local device="$1" ticks=0 result
	PROBE_IP= PROBE_MASK= PROBE_GATEWAY= PROBE_ROUTES=
	rm -f "$RUN_DIR/$device.lease"
	CUDY_PROBE_DIR="$RUN_DIR" udhcpc -f -n -q -i "$device" -t 3 -T 2 \
		-s "$LIB_DIR/lease" > "$RUN_DIR/$device.probe.log" 2>&1 &
	PROBE_PID=$!
	while kill -0 "$PROBE_PID" 2>/dev/null && [ "$ticks" -lt 8 ]; do
		sleep 1
		ticks=$((ticks+1))
	done
	if kill -0 "$PROBE_PID" 2>/dev/null; then kill -TERM "$PROBE_PID"; fi
	wait "$PROBE_PID"
	result=$?
	PROBE_PID=
	if [ ! -r "$RUN_DIR/$device.lease" ]; then
		grep -q 'broadcasting discover\|sending discover' "$RUN_DIR/$device.probe.log" || return 3
		return 1
	fi
	{
		read -r PROBE_IP; read -r PROBE_MASK; read -r PROBE_GATEWAY; read -r PROBE_ROUTES
	} < "$RUN_DIR/$device.lease"
	# RFC 3442 的默认路由优先于 DHCP Router 选项。
	PROBE_GATEWAY=$(printf '%s\n' "$PROBE_ROUTES" | awk '{for(i=1;i<NF;i+=2) if($i=="0.0.0.0/0") {print $(i+1); exit}}')
	if [ -z "$PROBE_GATEWAY" ]; then
		PROBE_GATEWAY=$(sed -n '3p' "$RUN_DIR/$device.lease")
		PROBE_GATEWAY=${PROBE_GATEWAY%% *}
	fi
	[ "$result" -eq 0 ] && lease_safe "$PROBE_IP" "$PROBE_MASK" "$PROBE_GATEWAY" \
		"$(uci -q get network.lan.ipaddr)" "$(uci -q get network.lan.netmask)" || return 2
}

classify_port() {
	local device="$1" result before
	before=$(generation "$device")
	probe_port "$device"
	result=$?
	if [ "$(carrier "$device")" != 1 ] || [ "$(generation "$device")" != "$before" ]; then
		ROLE=unknown HEALTH=waiting IPV4= GATEWAY= STREAK=0 SETTLE_UNTIL=$((NOW+2))
		log "$device 在检测期间发生插拔，等待稳定后重新识别。"
		return 0
	fi
	IPV4= GATEWAY= FAILS=0 PASSES=0 LAST_HEALTH=0
	case "$result" in
		0)
			if ifup "$(port_interface "$device")"; then
				ROLE=wan HEALTH=waiting
				log "$device 已识别为 WAN，交由网络服务获取地址。"
			else ROLE=error; log "$device 启动 WAN 失败。"; fi
			;;
		1)
			if ip link set dev "$device" master "$BRIDGE"; then
				ROLE=lan HEALTH=local
				log "$device 未检测到上级 DHCP，已加入 LAN。"
			else ROLE=error; log "$device 加入内网桥失败。"; fi
			;;
		2)
			ROLE=conflict HEALTH=invalid
			log "$device 的 DHCP 租约无效、没有默认网关或与内网重叠，已隔离；详见 $RUN_DIR/$device.probe.log。"
			;;
		*)
			ROLE=error HEALTH=probe_error
			log "$device 的 DHCP 探测执行失败，已隔离；详见 $RUN_DIR/$device.probe.log。"
			;;
	esac
	RETRY_AT=$((NOW+30)) SETTLE_UNTIL=$((NOW+5))
	GENERATION=$(generation "$device") LAST_CARRIER=$(carrier "$device")
}

refresh_wan() {
	local device="$1" status previous="$HEALTH" up prefix mask
	status=$(ubus call "network.interface.$(port_interface "$device")" status) || {
		IPV4= GATEWAY= HEALTH=waiting; return 1
	}
	up=$(jsonfilter -s "$status" -e '@.up')
	IPV4=$(jsonfilter -s "$status" -e '@["ipv4-address"][0].address')
	GATEWAY=$(ip -4 route show default dev "$device" proto static | awk '{for(i=1;i<NF;i++) if($i=="via") {print $(i+1); exit}}')
	if [ "$up" != true ] || ! ipv4_valid "$IPV4" || ! ipv4_valid "$GATEWAY"; then
		IPV4= GATEWAY= HEALTH=waiting
		if [ "$NOW" -ge "$RETRY_AT" ]; then
			log "$device 尚未获得有效上级地址，重新识别网口。"
			stop_wan "$device" && detach_port "$device" && ip link set dev "$device" up \
				&& classify_port "$device" || { ROLE=error; RETRY_AT=$((NOW+30)); }
		fi
		return 0
	fi
	prefix=$(jsonfilter -s "$status" -e '@["ipv4-address"][0].mask')
	mask=$(awk -v p="$prefix" 'BEGIN {
		if(p !~ /^[0-9]+$/ || p<1 || p>32) exit 1
		for(i=0;i<4;i++) { bits=p-i*8; if(bits<0) bits=0; if(bits>8) bits=8;
			printf "%s%d", i?".":"", 256-2^(8-bits) }
	}')
	if ! lease_safe "$IPV4" "$mask" "$GATEWAY" \
		"$(uci -q get network.lan.ipaddr)" "$(uci -q get network.lan.netmask)"; then
		log "$device 实际获取的 DHCP 地址无效或与内网重叠，停止该出口。"
		stop_wan "$device" || { log "$device 停止无效出口失败。"; return 1; }
		ROLE=conflict HEALTH=invalid IPV4= GATEWAY= RETRY_AT=$((NOW+30))
		return 0
	fi
	if [ "$NOW" -lt "$((LAST_HEALTH+10))" ]; then return 0; fi
	LAST_HEALTH=$NOW
	# 绑定物理接口，不能让备用出口的成功响应掩盖被测出口的故障。
	if ping -I "$device" -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 \
		|| ping -I "$device" -c 1 -W 2 119.29.29.29 >/dev/null 2>&1; then
		FAILS=0 PASSES=$((PASSES+1))
		if [ "$HEALTH" != down ] || [ "$PASSES" -ge 2 ]; then HEALTH=up; fi
	else
		PASSES=0 FAILS=$((FAILS+1))
		[ "$HEALTH" != waiting ] || HEALTH=checking
		[ "$FAILS" -lt 3 ] || HEALTH=down
	fi
	[ "$previous" = "$HEALTH" ] || log "$device 的出口检测状态变为 $HEALTH。"
}

port_tick() {
	local device="$1" link counter
	load_port "$device"
	if [ ! -d "/sys/class/net/$device" ]; then
		[ "$ROLE" = error ] || log "$device 不存在，无法自动识别。"
		ROLE=error HEALTH=missing IPV4= GATEWAY=
		save_port "$device"; return 0
	fi
	if ! ip link show dev "$device" | grep -q '<[^>]*UP[,>]'; then
		if [ "$NOW" -lt "$RETRY_AT" ]; then return 0; fi
		if ! ip link set dev "$device" up > "$RUN_DIR/$device.link.log" 2>&1; then
			[ "$ROLE" = error ] || log "$device 无法启用，请检查 PHY/内核日志；详见 $RUN_DIR/$device.link.log。"
			ROLE=error HEALTH=driver_error IPV4= GATEWAY= RETRY_AT=$((NOW+30))
			save_port "$device"; return 0
		fi
	fi
	link=$(carrier "$device") counter=$(generation "$device")
	if [ "$NOW" -lt "$SETTLE_UNTIL" ] && [ "$LAST_CARRIER" = "$link" ] \
		&& [ "$GENERATION" = "$counter" ]; then
		save_port "$device"; return 0
	fi
	if [ "$link" != 1 ]; then
		if [ "$ROLE" != down ]; then
			stop_wan "$device" && detach_port "$device" || { log "$device 下线隔离失败。"; return 1; }
			[ "$ROLE" = unknown ] || log "$device 网线已断开。"
		fi
		ROLE=down HEALTH=disconnected IPV4= GATEWAY= STREAK=0
	elif [ "$LAST_CARRIER" != 1 ] || [ "$GENERATION" != "$counter" ]; then
		stop_wan "$device" && detach_port "$device" && ip link set dev "$device" up || {
			log "$device 重新检测前隔离失败。"; return 1
		}
		ROLE=unknown HEALTH=waiting IPV4= GATEWAY= STREAK=1
		link=$(carrier "$device") counter=$(generation "$device")
	elif [ "$ROLE" = unknown ]; then
		STREAK=$((STREAK+1))
		[ "$STREAK" -lt 2 ] || classify_port "$device"
	elif [ "$ROLE" = lan ]; then
		[ "$(master "$device")" = "$BRIDGE" ] || ip link set dev "$device" master "$BRIDGE" || {
			log "$device 恢复 LAN 桥接失败。"; return 1
		}
	elif [ "$ROLE" = wan ]; then
		refresh_wan "$device" || log "$device 的网络状态读取失败。"
	elif [ "$NOW" -ge "$RETRY_AT" ]; then
		detach_port "$device" && classify_port "$device"
	fi
	LAST_CARRIER=$link
	# classify_port 的启停操作可能改变链路代数，以操作后的值为准。
	GENERATION=$(generation "$device")
	save_port "$device"
}

choose_port() {
	local device first= current=
	for device in eth0 eth1; do
		load_port "$device"
		[ "$ROLE" = wan ] && [ "$(carrier "$device")" = 1 ] \
			&& ipv4_valid "$IPV4" && ipv4_valid "$GATEWAY" || continue
		if [ "$HEALTH" = up ]; then echo "$device"; return 0; fi
		[ -n "$first" ] || first=$device
		[ "$SELECTED" != "$device" ] || current=$device
	done
	# ICMP 被上级过滤时保留可用租约，但状态仍标明检测失败。
	printf '%s\n' "${current:-$first}"
}

metric_five_routes() {
	# ip route show 的 metric 参数并不筛选输出，需要显式检查每条路由。
	ip -N -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="metric" && $(i+1)==5) print}'
}

owned_route() {
	metric_five_routes | awk '{for(i=1;i<NF;i++) if($i=="proto" && $(i+1)==242) print}'
}

remove_owned_route() {
	[ -z "$(owned_route)" ] || ip -4 route del default proto 242 metric 5
}

select_route() {
	local device key other route
	device=$(choose_port)
	if [ -z "$device" ]; then
		remove_owned_route || return 1
		if [ -n "$SELECTED" ]; then
			ifdown "$(port_ipv6_interface "$SELECTED")" || return 1
			log '当前没有获得有效上级地址的出口。'
		fi
		SELECTED= SELECTED_KEY=
		return 0
	fi
	load_port "$device"
	key="$device:$IPV4:$GATEWAY"
	if [ "$SELECTED_KEY" = "$key" ] && [ -n "$(owned_route)" ]; then return 0; fi
	route=$(metric_five_routes)
	[ -z "$route" ] || [ "$route" = "$(owned_route)" ] || {
		log '已有其他服务使用 metric=5 的默认路由，拒绝覆盖。'; return 1
	}
	ip -4 route replace default via "$GATEWAY" dev "$device" src "$IPV4" proto 242 metric 5 || {
		log "$device 安装首选默认路由失败。"; return 1
	}
	[ "$SELECTED" = "$device" ] || log "当前首选出口切换为 $device，连通性检测状态为 $HEALTH。"
	SELECTED=$device SELECTED_KEY=
	for other in eth0 eth1; do
		[ "$other" = "$device" ] || ifdown "$(port_ipv6_interface "$other")" || return 1
	done
	ifup "$(port_ipv6_interface "$device")" || { log "$device 启动 IPv6 失败。"; return 1; }
	SELECTED_KEY=$key
}

write_status() {
	local device
	json_init
	json_add_string selected "$SELECTED"
	json_add_int uptime "$NOW"
	json_add_object ports
	for device in eth0 eth1; do
		load_port "$device"
		json_add_object "$device"
		json_add_string role "$ROLE"
		json_add_string health "$HEALTH"
		json_add_string ipv4 "$IPV4"
		json_add_string gateway "$GATEWAY"
		json_add_boolean carrier "$(carrier "$device")"
		json_close_object
	done
	json_close_object
	json_dump > "$RUN_DIR/status.json.tmp" && mv "$RUN_DIR/status.json.tmp" "$RUN_DIR/status.json"
}

cleanup_daemon() {
	trap - EXIT INT TERM
	if [ -n "$PROBE_PID" ]; then kill -TERM "$PROBE_PID" 2>/dev/null || true; wait "$PROBE_PID" 2>/dev/null || true; fi
	remove_owned_route || log '停止服务时清理首选路由失败。'
	rm -f "$RUN_DIR/status.json"
	log '自动识别服务已停止；接口地址继续由网络服务管理。'
}

run_daemon() {
	local tool device iface six uptime rest
	[ -f "$BACKUP_DIR/configured.sha256" ] || { log '尚未初始化，请运行 configure。'; return 1; }
	for tool in ip jsonfilter udhcpc ping flock ubus uci logger; do
		command -v "$tool" >/dev/null || { log "缺少必需命令：$tool"; return 1; }
	done
	for device in eth0 eth1; do
		iface=$(port_interface "$device")
		six=$(port_ipv6_interface "$device")
		[ "$(uci -q get "network.$iface.device")" = "$device" ] \
			&& [ "$(uci -q get "network.$iface.proto")" = dhcp ] \
			&& [ "$(uci -q get "network.$iface.auto")" = 0 ] \
			&& [ "$(uci -q get "network.$six.device")" = "$device" ] \
			&& [ "$(uci -q get "network.$six.proto")" = dhcpv6 ] \
			&& [ "$(uci -q get "network.$six.auto")" = 0 ] || {
			log "$iface 配置与自动识别服务冲突，停止接管。"; return 1
		}
	done
	. /usr/share/libubox/jshn.sh || return 1
	umask 077
	mkdir -p "$RUN_DIR" || return 1
	exec 9> "$RUN_DIR/lock"
	flock -n 9 || { log '自动识别服务已经运行。'; return 1; }
	trap 'cleanup_daemon; exit 0' INT TERM
	trap cleanup_daemon EXIT
	log '自动识别服务启动：支持 WAN 与 LAN、双 WAN 主备和双 LAN。'
	while :; do
		read -r uptime rest < /proc/uptime
		NOW=${uptime%%.*}
		if [ -d "/sys/class/net/$BRIDGE" ]; then
			for device in eth0 eth1; do port_tick "$device" || log "$device 本轮处理失败。"; done
			select_route || log '首选出口更新失败，保留明确错误状态。'
			write_status || log '状态文件更新失败。'
		fi
		sleep 1
	done
}
