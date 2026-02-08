#!/bin/bash
#
#
#	OpenUptime Server Monitoring Agent — macOS
#	Forked from HetrixTools macOS Agent v2.0.0
#	https://github.com/openuptime
#
#
#		DISCLAIMER OF WARRANTY
#
#	The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind,
#	including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement.
#	OpenUptime makes no warranty that the Software is free of defects or is suitable for any particular purpose.
#	In no event shall OpenUptime be responsible for loss or damages arising from the installation or use of the Software,
#	including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including,
#	without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses.
#	The entire risk as to the quality and performance of the Software is borne by you, the user.
#
#		END OF DISCLAIMER OF WARRANTY

# Set PATH/Locale
export LC_NUMERIC="C"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin
ScriptPath=$(dirname "${BASH_SOURCE[0]}")

# Agent Version (do not change)
Version="2.0.0"

# Load configuration file
if [ -f "$ScriptPath"/openuptime.cfg ]
then
	. "$ScriptPath"/openuptime.cfg
else
	echo "Error: Configuration file not found at $ScriptPath/openuptime.cfg"
	exit 1
fi

# Script start time
ScriptStartTime=$(date +[%Y-%m-%d\ %T)

##############################################################################
# Helper: key-value store using temp files (bash 3.2 has no associative arrays)
##############################################################################
KV_DIR=$(mktemp -d /tmp/openuptime_kv.XXXXXX)
trap "rm -rf '$KV_DIR'" EXIT

kv_set() { # usage: kv_set namespace key value
	local ns="$1" key="$2" val="$3"
	mkdir -p "$KV_DIR/$ns"
	printf '%s' "$val" > "$KV_DIR/$ns/$key"
}
kv_get() { # usage: kv_get namespace key [default]
	local ns="$1" key="$2" default="${3:-0}"
	if [ -f "$KV_DIR/$ns/$key" ]; then
		cat "$KV_DIR/$ns/$key"
	else
		echo "$default"
	fi
}

# Service status function
servicestatus() {
	if (( $(ps -ef | grep -E "[\/\ ]$1([^\/]|$)" | grep -v "grep" | wc -l) > 0 ))
	then
		echo "1"
	else
		if launchctl list 2>/dev/null | grep -qi "$1"
		then
			echo "1"
		else
			echo "0"
		fi
	fi
}

# Function used to perform outgoing PING tests
pingstatus() {
	local TargetName=$1
	local PingTarget=$2
	if ! echo "$TargetName" | grep -qE '^[A-Za-z0-9._-]+$'; then
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Invalid PING target name value" >> "$ScriptPath"/debug.log; fi
		exit 1
	fi
	if ! echo "$PingTarget" | grep -qE '^[A-Za-z0-9.:_-]+$'; then
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Invalid PING target value" >> "$ScriptPath"/debug.log; fi
		exit 1
	fi
	PING_OUTPUT=$(ping "$PingTarget" -c "$OutgoingPingsCount" 2>/dev/null)
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T])PING_OUTPUT:\n$PING_OUTPUT" >> "$ScriptPath"/debug.log; fi
	PACKET_LOSS=$(echo "$PING_OUTPUT" | grep -o '[0-9.]*% packet loss' | cut -d'%' -f1)
	if [ -z "$PACKET_LOSS" ]; then
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Unable to extract packet loss" >> "$ScriptPath"/debug.log; fi
		exit 1
	fi
	RTT_LINE=$(echo "$PING_OUTPUT" | grep 'round-trip min/avg/max')
	if [ -n "$RTT_LINE" ]; then
		AVG_RTT=$(echo "$RTT_LINE" | awk -F'/' '{print $5}')
		AVG_RTT=$(echo | awk "{print $AVG_RTT * 1000}" | awk '{printf "%18.0f",$1}' | xargs)
	else
		AVG_RTT="0"
	fi
	echo "$TargetName,$PingTarget,$PACKET_LOSS,$AVG_RTT;" >> "$ScriptPath"/ping.txt
}

# Check if the agent needs to run Outgoing PING tests
if [ "$1" == "ping" ]
then
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Starting PING: $2 ($3) $OutgoingPingsCount times" >> "$ScriptPath"/debug.log; fi
	pingstatus "$2" "$3"
	exit 1
fi

# Clear debug.log every day at midnight
if [ -z "$(date +%H | sed 's/^0*//')" ] && [ -z "$(date +%M | sed 's/^0*//')" ] && [ -f "$ScriptPath"/debug.log ]
then
	rm -f "$ScriptPath"/debug.log
fi

# Start timers
START=$(date +%s)
tTIMEDIFF=0

# Get current minute
M=$(date +%M | sed 's/^0*//')
if [ -z "$M" ]; then
	M=0
	if [ -f "$ScriptPath"/openuptime_cron.log ]; then
		rm -f "$ScriptPath"/openuptime_cron.log
	fi
fi

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Starting OpenUptime Agent v$Version (macOS)" >> "$ScriptPath"/debug.log; fi

# Kill any lingering agent processes
OUProcesses=$(pgrep -f openuptime_agent.sh | wc -l | xargs)
if [ -z "$OUProcesses" ]; then OUProcesses=0; fi
if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Found $OUProcesses agent processes" >> "$ScriptPath"/debug.log; fi

if [ "$OUProcesses" -ge 50 ]; then
	pgrep -f openuptime_agent.sh | xargs kill -9
fi
if [ "$OUProcesses" -ge 10 ]; then
	for PID in $(pgrep -f openuptime_agent.sh); do
		PID_TIME=$(ps -p "$PID" -oetime= 2>/dev/null | tr '-' ':' | awk -F: '{total=0; m=1;} {for (i=0; i < NF; i++) {total += $(NF-i)*m; m *= i >= 2 ? 24 : 60 }} {print total}')
		if [ -n "$PID_TIME" ] && [ "$PID_TIME" -ge 90 ]; then
			kill -9 "$PID" 2>/dev/null
		fi
	done
fi

# Outgoing PING (background)
if [ -n "$OutgoingPings" ]; then
	OLD_IFS="$IFS"
	IFS='|'
	for i in $OutgoingPings; do
		IFS=',' read TargetName TargetIP <<< "$i"
		bash "$ScriptPath"/openuptime_agent.sh ping "$TargetName" "$TargetIP" &
	done
	IFS="$OLD_IFS"
fi

# Network interfaces
if [ -n "$NetworkInterfaces" ]; then
	OLD_IFS="$IFS"; IFS=','; NetworkInterfacesArray=($NetworkInterfaces); IFS="$OLD_IFS"
else
	NetworkInterfacesArray=()
	for iface in $(networksetup -listallhardwareports 2>/dev/null | grep "^Device:" | awk '{print $2}'); do
		if ifconfig "$iface" 2>/dev/null | grep -q "status: active"; then
			NetworkInterfacesArray+=("$iface")
		fi
	done
	# Fallback
	if [ ${#NetworkInterfacesArray[@]} -eq 0 ]; then
		for iface in $(ifconfig -lu 2>/dev/null | tr ' ' '\n' | grep -E '^en[0-9]+$'); do
			if ifconfig "$iface" 2>/dev/null | grep -q "inet "; then
				NetworkInterfacesArray+=("$iface")
			fi
		done
	fi
fi
if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Network Interfaces: ${NetworkInterfacesArray[*]}" >> "$ScriptPath"/debug.log; fi

# Initial network usage
for NIC in "${NetworkInterfacesArray[@]}"; do
	NETSTAT_LINE=$(netstat -ibI "$NIC" 2>/dev/null | grep -w "$NIC" | grep -v "Link#" | head -1)
	if [ -z "$NETSTAT_LINE" ]; then
		NETSTAT_LINE=$(netstat -ibI "$NIC" 2>/dev/null | tail -1)
	fi
	init_rx=$(echo "$NETSTAT_LINE" | awk '{print $7}')
	init_tx=$(echo "$NETSTAT_LINE" | awk '{print $10}')
	kv_set "aRX" "$NIC" "${init_rx:-0}"
	kv_set "aTX" "$NIC" "${init_tx:-0}"
	kv_set "tRX" "$NIC" "0"
	kv_set "tTX" "$NIC" "0"
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Network Interface $NIC RX: ${init_rx:-0} TX: ${init_tx:-0}" >> "$ScriptPath"/debug.log; fi
done

# Auto-detect listening ports
if [ -z "${ConnectionPorts// }" ]; then
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Detecting external connection ports" >> "$ScriptPath"/debug.log; fi
	AutoDetectedPorts=$(lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null | awk 'NR>1 {print $9}' | grep -oE '[0-9]+$' | sort -n | uniq | head -30 | tr '\n' ',' | sed 's/,$//')
	if [ -n "$AutoDetectedPorts" ]; then
		ConnectionPorts="$AutoDetectedPorts"
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Auto detected connection ports: $ConnectionPorts" >> "$ScriptPath"/debug.log; fi
	fi
fi

# Port connections init
ConnectionPortsArray=()
if [ -n "$ConnectionPorts" ]; then
	OLD_IFS="$IFS"; IFS=','; ConnectionPortsArray=($ConnectionPorts); IFS="$OLD_IFS"
	for cPort in "${ConnectionPortsArray[@]}"; do
		kv_set "conn" "$cPort" "0"
	done
fi

# Check Services (initial)
CheckServicesArray=()
if [ -n "$CheckServices" ]; then
	OLD_IFS="$IFS"; IFS=','; CheckServicesArray=($CheckServices); IFS="$OLD_IFS"
	for svc in "${CheckServicesArray[@]}"; do
		val=$(servicestatus "$svc")
		kv_set "srvcs" "$svc" "$val"
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Service $svc status: $val" >> "$ScriptPath"/debug.log; fi
	done
fi

# Calculate how many data sample loops
RunTimes=$(echo | awk "{print int(60 / $CollectEveryXSeconds)}")
if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Collecting data for $RunTimes loops" >> "$ScriptPath"/debug.log; fi

# Initialize totals
tCPU=0
tCPUus=0
tCPUsy=0
tRAM=0
tRAMSwap=0
tloadavg1=0
tloadavg5=0
tloadavg15=0

# Get total physical RAM in bytes
TOTAL_RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null)
PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null)
if [ -z "$PAGE_SIZE" ] || [ "$PAGE_SIZE" -eq 0 ] 2>/dev/null; then PAGE_SIZE=16384; fi

# Initial disk IOPS snapshot (per-disk via ioreg)
IOPS_DISK_LIST=""
IOPS_TIME_START=$(date +%s)
ioreg -c IOBlockStorageDriver -r -l -d 3 2>/dev/null | awk '
/IOBlockStorageDriver/{stats_r=""; stats_w=""; bsd=""}
/"Statistics"/{
    r=$0; sub(/.*"Bytes \(Read\)"=/, "", r); sub(/[,}].*/, "", r); stats_r=r
    w=$0; sub(/.*"Bytes \(Write\)"=/, "", w); sub(/[,}].*/, "", w); stats_w=w
}
/"BSD Name" = "disk[0-9]+"/{
    b=$0; sub(/.*"BSD Name" = "/, "", b); sub(/".*/, "", b); bsd=b
    if(bsd != "" && stats_r != "") print bsd ":" stats_r ":" stats_w
}
' | while IFS=: read disk rd wr; do
	kv_set "iops_r" "$disk" "${rd:-0}"
	kv_set "iops_w" "$disk" "${wr:-0}"
	echo "$disk"
done > "$KV_DIR/iops_disklist"
IOPS_DISK_LIST=$(cat "$KV_DIR/iops_disklist" 2>/dev/null | tr '\n' ' ')

# Build physical-disk-to-mount mapping via diskutil list
for disk in $IOPS_DISK_LIST; do
	kv_set "iops_mnt" "$disk" "/"
done
# Parse df mounts and trace each back to its physical disk
while read -r dev mnt; do
	base=$(echo "$dev" | sed 's|/dev/||; s/s[0-9].*//')
	phys=$(diskutil info "$base" 2>/dev/null | grep "Physical Store" | awk '{print $NF}' | sed 's/s[0-9].*//')
	if [ -z "$phys" ]; then
		phys="$base"
	fi
	case "$mnt" in
		/|/Volumes/*)
			kv_set "iops_mnt" "$phys" "$mnt"
			;;
	esac
done <<< "$(df -l 2>/dev/null | awk 'NR>1 && /\/dev\/disk/{print $1, $NF}')"

if [ "$DEBUG" -eq 1 ]; then
	for disk in $IOPS_DISK_LIST; do
		dr=$(kv_get "iops_r" "$disk" 0)
		dw=$(kv_get "iops_w" "$disk" 0)
		dm=$(kv_get "iops_mnt" "$disk" "/")
		echo -e "$ScriptStartTime-$(date +%T]) IOPS start: $disk ($dm) Read=$dr Write=$dw" >> "$ScriptPath"/debug.log
	done
fi

# Collect data loop
X=0
for i in $(seq "$RunTimes"); do
	X=$((X + 1))

	# CPU usage via top
	TOP_OUTPUT=$(top -l 2 -n 0 -s "$CollectEveryXSeconds" 2>/dev/null | grep "CPU usage" | tail -1)
	CPU_USER=$(echo "$TOP_OUTPUT" | awk -F'[:,]' '{print $2}' | grep -oE '[0-9]+\.[0-9]+')
	CPU_SYS=$(echo "$TOP_OUTPUT" | awk -F'[:,]' '{print $3}' | grep -oE '[0-9]+\.[0-9]+')
	CPU_IDLE=$(echo "$TOP_OUTPUT" | awk -F'[:,]' '{print $4}' | grep -oE '[0-9]+\.[0-9]+')

	if [ -n "$CPU_IDLE" ]; then
		CPU=$(echo | awk "{print 100 - $CPU_IDLE}")
	else
		CPU=0
	fi
	tCPU=$(echo | awk "{print $tCPU + $CPU}")
	tCPUus=$(echo | awk "{print $tCPUus + ${CPU_USER:-0}}")
	tCPUsy=$(echo | awk "{print $tCPUsy + ${CPU_SYS:-0}}")

	# CPU Load averages
	loadavg=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | xargs)
	la1=$(echo "$loadavg" | awk '{print $1}')
	la5=$(echo "$loadavg" | awk '{print $2}')
	la15=$(echo "$loadavg" | awk '{print $3}')
	tloadavg1=$(echo | awk "{print $tloadavg1 + ${la1:-0}}")
	tloadavg5=$(echo | awk "{print $tloadavg5 + ${la5:-0}}")
	tloadavg15=$(echo | awk "{print $tloadavg15 + ${la15:-0}}")

	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) CPU: $CPU User: ${CPU_USER:-0} Sys: ${CPU_SYS:-0} Load: ${la1:-0} ${la5:-0} ${la15:-0}" >> "$ScriptPath"/debug.log; fi

	# RAM usage via vm_stat
	VMSTAT_OUTPUT=$(vm_stat 2>/dev/null)
	PAGES_ACTIVE=$(echo "$VMSTAT_OUTPUT" | grep "Pages active:" | awk '{print $3}' | tr -d '.')
	PAGES_WIRED=$(echo "$VMSTAT_OUTPUT" | grep "Pages wired down:" | awk '{print $4}' | tr -d '.')
	PAGES_COMPRESSED=$(echo "$VMSTAT_OUTPUT" | grep "Pages occupied by compressor:" | awk '{print $5}' | tr -d '.')
	PAGES_ACTIVE=${PAGES_ACTIVE:-0}
	PAGES_WIRED=${PAGES_WIRED:-0}
	PAGES_COMPRESSED=${PAGES_COMPRESSED:-0}

	USED_PAGES=$((PAGES_ACTIVE + PAGES_WIRED + PAGES_COMPRESSED))
	TOTAL_PAGES=$((TOTAL_RAM_BYTES / PAGE_SIZE))

	if [ "$TOTAL_PAGES" -gt 0 ]; then
		RAM=$(echo | awk "{print $USED_PAGES * 100 / $TOTAL_PAGES}")
	else
		RAM=0
	fi
	tRAM=$(echo | awk "{print $tRAM + $RAM}")

	# Swap usage
	SWAP_INFO=$(sysctl -n vm.swapusage 2>/dev/null)
	SWAP_TOTAL=$(echo "$SWAP_INFO" | grep -oE 'total = [0-9.]+[A-Z]' | grep -oE '[0-9.]+')
	SWAP_USED=$(echo "$SWAP_INFO" | grep -oE 'used = [0-9.]+[A-Z]' | grep -oE '[0-9.]+')
	if [ -n "$SWAP_TOTAL" ] && [ "$(echo "$SWAP_TOTAL" | awk '{print ($1 > 0)}')" = "1" ]; then
		RAMSwap=$(echo | awk "{print ${SWAP_USED:-0} * 100 / $SWAP_TOTAL}")
	else
		RAMSwap=0
	fi
	tRAMSwap=$(echo | awk "{print $tRAMSwap + $RAMSwap}")

	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) RAM: $RAM Swap: $RAMSwap" >> "$ScriptPath"/debug.log; fi

	# Network usage
	END=$(date +%s)
	TIMEDIFF=$((END - START))
	if [ "$TIMEDIFF" -le 0 ]; then TIMEDIFF=1; fi
	tTIMEDIFF=$((tTIMEDIFF + TIMEDIFF))
	START=$END

	for NIC in "${NetworkInterfacesArray[@]}"; do
		NETSTAT_LINE=$(netstat -ibI "$NIC" 2>/dev/null | grep -w "$NIC" | grep -v "Link#" | head -1)
		if [ -z "$NETSTAT_LINE" ]; then
			NETSTAT_LINE=$(netstat -ibI "$NIC" 2>/dev/null | tail -1)
		fi
		CURR_RX=$(echo "$NETSTAT_LINE" | awk '{print $7}')
		CURR_TX=$(echo "$NETSTAT_LINE" | awk '{print $10}')
		CURR_RX=${CURR_RX:-0}
		CURR_TX=${CURR_TX:-0}

		PREV_RX=$(kv_get "aRX" "$NIC" 0)
		PREV_TX=$(kv_get "aTX" "$NIC" 0)
		PREV_TRX=$(kv_get "tRX" "$NIC" 0)
		PREV_TTX=$(kv_get "tTX" "$NIC" 0)

		RX=$(echo | awk "{print ($CURR_RX - $PREV_RX) / $TIMEDIFF}" | awk '{printf "%18.0f",$1}' | xargs)
		TX=$(echo | awk "{print ($CURR_TX - $PREV_TX) / $TIMEDIFF}" | awk '{printf "%18.0f",$1}' | xargs)

		kv_set "aRX" "$NIC" "$CURR_RX"
		kv_set "aTX" "$NIC" "$CURR_TX"
		kv_set "tRX" "$NIC" "$(echo | awk "{print $PREV_TRX + $RX}" | awk '{printf "%18.0f",$1}' | xargs)"
		kv_set "tTX" "$NIC" "$(echo | awk "{print $PREV_TTX + $TX}" | awk '{printf "%18.0f",$1}' | xargs)"
	done

	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Network loop $X done" >> "$ScriptPath"/debug.log; fi

	# Port connections
	if [ ${#ConnectionPortsArray[@]} -gt 0 ]; then
		for cPort in "${ConnectionPortsArray[@]}"; do
			CONN_COUNT=$(lsof -iTCP:"$cPort" -sTCP:ESTABLISHED -nP 2>/dev/null | grep -v "^COMMAND" | wc -l | xargs)
			prev=$(kv_get "conn" "$cPort" 0)
			kv_set "conn" "$cPort" "$(echo | awk "{print $prev + $CONN_COUNT}")"
		done
	fi

	# Check if minute changed
	MM=$(date +%M | sed 's/^0*//')
	if [ -z "$MM" ]; then MM=0; fi
	if [ "$MM" -ne "$M" ]; then
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Minute changed, ending loop" >> "$ScriptPath"/debug.log; fi
		break
	fi
done

# Check if system requires reboot (not available on macOS)
RequiresReboot=0

# Operating System — plain string, no base64
OS_NAME=$(sw_vers -productName 2>/dev/null)
OS_VER=$(sw_vers -productVersion 2>/dev/null)
OS="$OS_NAME $OS_VER"

# Kernel — plain string
Kernel=$(uname -r)

# Hostname — plain string
Hostname=$(uname -n)

# Uptime
BOOT_TIME=$(sysctl -n kern.boottime 2>/dev/null | awk -F'sec = ' '{print $2}' | awk -F',' '{print $1}')
CURRENT_TIME=$(date +%s)
if [ -n "$BOOT_TIME" ]; then
	Uptime=$((CURRENT_TIME - BOOT_TIME))
else
	Uptime=0
fi

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Hostname: $Hostname Uptime: $Uptime" >> "$ScriptPath"/debug.log; fi

# CPU model — plain string, no base64
CPUModel=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
if [ -z "$CPUModel" ]; then
	CPUModel=$(sysctl -n hw.model 2>/dev/null)
fi

# CPU info
CPUSockets=$(sysctl -n hw.packages 2>/dev/null || echo "1")
CPUCores=$(sysctl -n hw.physicalcpu 2>/dev/null || echo "1")
CPUThreads=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "1")

# CPU clock speed (MHz)
CPUSpeed=$(sysctl -n hw.cpufrequency 2>/dev/null)
if [ -n "$CPUSpeed" ] && [ "$CPUSpeed" -gt 0 ] 2>/dev/null; then
	CPUSpeed=$((CPUSpeed / 1000000))
else
	# Try system_profiler for Intel Macs
	CPUSpeed=$(system_profiler SPHardwareDataType 2>/dev/null | grep -i "Processor Speed" | head -1 | grep -oE '[0-9.]+\s*GHz' | grep -oE '[0-9.]+' | awk '{printf "%d", $1 * 1000}')
	# Apple Silicon: get max P-cluster frequency from powermetrics
	if [ -z "$CPUSpeed" ] || [ "$CPUSpeed" -eq 0 ] 2>/dev/null; then
		if command -v powermetrics > /dev/null 2>&1; then
			CPUSpeed=$(powermetrics --samplers cpu_power -i 1 -n 1 2>/dev/null | grep "P-Cluster HW active residency" | grep -oE '[0-9]+ MHz' | tail -1 | grep -oE '[0-9]+')
		fi
	fi
	if [ -z "$CPUSpeed" ]; then CPUSpeed=0; fi
fi

# Averages
CPU=$(echo | awk "{print $tCPU / $X}")
CPUus=$(echo | awk "{print $tCPUus / $X}")
CPUsy=$(echo | awk "{print $tCPUsy / $X}")
CPUwa=0  # IO wait is not available on macOS
CPUst=0  # Steal time is not available on macOS
loadavg1=$(echo | awk "{print $tloadavg1 / $X}")
loadavg5=$(echo | awk "{print $tloadavg5 / $X}")
loadavg15=$(echo | awk "{print $tloadavg15 / $X}")

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) CPU: $CPU Cores: $CPUCores Threads: $CPUThreads Speed: $CPUSpeed" >> "$ScriptPath"/debug.log; fi

# RAM size (in KB)
RAMSize=$((TOTAL_RAM_BYTES / 1024))
RAM=$(echo | awk "{print $tRAM / $X}")

# Swap
RAMSwapSize_raw=$(sysctl -n vm.swapusage 2>/dev/null | grep -oE 'total = [0-9.]+[A-Z]')
SWAP_NUM=$(echo "$RAMSwapSize_raw" | grep -oE '[0-9.]+')
SWAP_UNIT=$(echo "$RAMSwapSize_raw" | grep -oE '[A-Z]$')
case "$SWAP_UNIT" in
	G) RAMSwapSize=$(echo "$SWAP_NUM" | awk '{printf "%.0f", $1 * 1024 * 1024}') ;;
	M) RAMSwapSize=$(echo "$SWAP_NUM" | awk '{printf "%.0f", $1 * 1024}') ;;
	K) RAMSwapSize=$(echo "$SWAP_NUM" | awk '{printf "%.0f", $1}') ;;
	*) RAMSwapSize=0 ;;
esac
if [ "$RAMSwapSize" -gt 0 ] 2>/dev/null; then
	RAMSwap=$(echo | awk "{print $tRAMSwap / $X}")
else
	RAMSwap=0
fi
RAMBuff=0   # Buffers not available on macOS
RAMCache=0  # Cache not available on macOS

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) RAM Size: $RAMSize Usage: $RAM Swap Size: $RAMSwapSize Swap: $RAMSwap" >> "$ScriptPath"/debug.log; fi

# Disks usage — build JSON array
DISKS_JSON="["
DISKS_FIRST=1
if [ -n "$(df -T -b 2>/dev/null)" ]; then
	while IFS= read -r line; do
		mount_point=$(echo "$line" | awk '{for(i=9;i<=NF;i++) printf "%s"(i<NF?" ":""), $i; print ""}')
		fs_type=$(echo "$line" | awk '{print $2}')
		total_size=$(echo "$line" | awk '{print $3}')
		used_size=$(echo "$line" | awk '{print $4}')
		avail_size=$(echo "$line" | awk '{print $5}')
		if [ -n "$mount_point" ] && [ -n "$total_size" ]; then
			if [ "$DISKS_FIRST" -eq 0 ]; then DISKS_JSON="$DISKS_JSON,"; fi
			DISKS_JSON="$DISKS_JSON{\"mount\":\"$mount_point\",\"fsType\":\"$fs_type\",\"total\":$total_size,\"used\":$used_size,\"available\":$avail_size}"
			DISKS_FIRST=0
		fi
	done <<< "$(df -T -b 2>/dev/null | sed 1d | grep -v -E 'devfs|tmpfs|map |/System/Volumes/')"
else
	while IFS= read -r line; do
		mount_point=$(echo "$line" | awk '{for(i=6;i<=NF;i++) printf "%s"(i<NF?" ":""), $i; print ""}')
		total_size=$(echo "$line" | awk '{print $2 * 512}')
		used_size=$(echo "$line" | awk '{print $3 * 512}')
		avail_size=$(echo "$line" | awk '{print $4 * 512}')
		# Detect filesystem type from mount point
		fs_type=$(mount 2>/dev/null | grep " on $mount_point " | awk -F'[()]' '{print $2}' | awk -F',' '{print $1}')
		fs_type=${fs_type:-apfs}
		if [ -n "$mount_point" ] && [ -n "$total_size" ]; then
			if [ "$DISKS_FIRST" -eq 0 ]; then DISKS_JSON="$DISKS_JSON,"; fi
			DISKS_JSON="$DISKS_JSON{\"mount\":\"$mount_point\",\"fsType\":\"$fs_type\",\"total\":$total_size,\"used\":$used_size,\"available\":$avail_size}"
			DISKS_FIRST=0
		fi
	done <<< "$(df -b 2>/dev/null | sed 1d | grep -v -E 'devfs|tmpfs|map |/System/Volumes/')"
fi
DISKS_JSON="$DISKS_JSON]"

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) DISKs: $DISKS_JSON" >> "$ScriptPath"/debug.log; fi

# Disk inodes — build JSON array
INODES_JSON="["
INODES_FIRST=1
while IFS= read -r line; do
	mount_point=$(echo "$line" | awk '{for(i=9;i<=NF;i++) printf "%s"(i<NF?" ":""), $i; print ""}')
	iused=$(echo "$line" | awk '{print $6}')
	ifree=$(echo "$line" | awk '{print $7}')
	itotal=$((iused + ifree))
	if [ -n "$mount_point" ]; then
		if [ "$INODES_FIRST" -eq 0 ]; then INODES_JSON="$INODES_JSON,"; fi
		INODES_JSON="$INODES_JSON{\"mount\":\"$mount_point\",\"total\":$itotal,\"used\":$iused,\"available\":$ifree}"
		INODES_FIRST=0
	fi
done <<< "$(df -i 2>/dev/null | sed 1d | grep -v -E 'devfs|tmpfs|map |/System/Volumes/')"
INODES_JSON="$INODES_JSON]"

# Disk IOPS — build JSON array
IOPS_JSON="["
IOPS_FIRST=1
IOPS_TIME_END=$(date +%s)
IOPS_TIME_DIFF=$((IOPS_TIME_END - IOPS_TIME_START))
if [ "$IOPS_TIME_DIFF" -le 0 ]; then IOPS_TIME_DIFF=1; fi

ioreg -c IOBlockStorageDriver -r -l -d 3 2>/dev/null | awk '
/IOBlockStorageDriver/{stats_r=""; stats_w=""; bsd=""}
/"Statistics"/{
    r=$0; sub(/.*"Bytes \(Read\)"=/, "", r); sub(/[,}].*/, "", r); stats_r=r
    w=$0; sub(/.*"Bytes \(Write\)"=/, "", w); sub(/[,}].*/, "", w); stats_w=w
}
/"BSD Name" = "disk[0-9]+"/{
    b=$0; sub(/.*"BSD Name" = "/, "", b); sub(/".*/, "", b); bsd=b
    if(bsd != "" && stats_r != "") print bsd ":" stats_r ":" stats_w
}
' | while IFS=: read disk rd_end wr_end; do
	rd_start=$(kv_get "iops_r" "$disk" 0)
	wr_start=$(kv_get "iops_w" "$disk" 0)
	mnt=$(kv_get "iops_mnt" "$disk" "/")
	rd_bps=$(echo | awk "{print (${rd_end:-0} - ${rd_start:-0}) / $IOPS_TIME_DIFF}" | awk '{printf "%18.0f",$1}' | xargs)
	wr_bps=$(echo | awk "{print (${wr_end:-0} - ${wr_start:-0}) / $IOPS_TIME_DIFF}" | awk '{printf "%18.0f",$1}' | xargs)
	echo "{\"disk\":\"$mnt\",\"readBps\":$rd_bps,\"writeBps\":$wr_bps}"
	if [ "$DEBUG" -eq 1 ]; then
		echo -e "$ScriptStartTime-$(date +%T]) IOPS end: $disk ($mnt) ReadBps=$rd_bps WriteBps=$wr_bps" >> "$ScriptPath"/debug.log
	fi
done > "$KV_DIR/iops_result"
# Build JSON array from results
while IFS= read -r entry; do
	if [ -n "$entry" ]; then
		if [ "$IOPS_FIRST" -eq 0 ]; then IOPS_JSON="$IOPS_JSON,"; fi
		IOPS_JSON="$IOPS_JSON$entry"
		IOPS_FIRST=0
	fi
done < "$KV_DIR/iops_result"
IOPS_JSON="$IOPS_JSON]"

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Inodes: $INODES_JSON IOPS: $IOPS_JSON" >> "$ScriptPath"/debug.log; fi

# Network final — build JSON arrays
NICS_JSON="["
IPv4_JSON="["
IPv6_JSON="["
NIC_FIRST=1
for NIC in "${NetworkInterfacesArray[@]}"; do
	nic_rx=$(kv_get "tRX" "$NIC" 0)
	nic_tx=$(kv_get "tTX" "$NIC" 0)
	RX=$(echo | awk "{print $nic_rx / $X}" | awk '{printf "%18.0f",$1}' | xargs)
	TX=$(echo | awk "{print $nic_tx / $X}" | awk '{printf "%18.0f",$1}' | xargs)
	if [ "$NIC_FIRST" -eq 0 ]; then NICS_JSON="$NICS_JSON,"; IPv4_JSON="$IPv4_JSON,"; IPv6_JSON="$IPv6_JSON,"; fi
	NICS_JSON="$NICS_JSON{\"interface\":\"$NIC\",\"rxBps\":$RX,\"txBps\":$TX}"
	# IPv4 addresses
	NIC_IPv4=$(ifconfig "$NIC" 2>/dev/null | grep "inet " | awk '{print $2}' | xargs)
	NIC_IPv4_JSON=""
	for addr in $NIC_IPv4; do
		if [ -n "$NIC_IPv4_JSON" ]; then NIC_IPv4_JSON="$NIC_IPv4_JSON,"; fi
		NIC_IPv4_JSON="$NIC_IPv4_JSON\"$addr\""
	done
	IPv4_JSON="$IPv4_JSON{\"interface\":\"$NIC\",\"addresses\":[$NIC_IPv4_JSON]}"
	# IPv6 addresses (non-link-local only)
	NIC_IPv6=$(ifconfig "$NIC" 2>/dev/null | grep "inet6 " | grep -v "fe80" | awk '{print $2}' | sed 's/%.*//g' | xargs)
	NIC_IPv6_JSON=""
	for addr in $NIC_IPv6; do
		if [ -n "$NIC_IPv6_JSON" ]; then NIC_IPv6_JSON="$NIC_IPv6_JSON,"; fi
		NIC_IPv6_JSON="$NIC_IPv6_JSON\"$addr\""
	done
	IPv6_JSON="$IPv6_JSON{\"interface\":\"$NIC\",\"addresses\":[$NIC_IPv6_JSON]}"
	NIC_FIRST=0
done
NICS_JSON="$NICS_JSON]"
IPv4_JSON="$IPv4_JSON]"
IPv6_JSON="$IPv6_JSON]"

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Network: $NICS_JSON IPv4: $IPv4_JSON IPv6: $IPv6_JSON" >> "$ScriptPath"/debug.log; fi

# Port connections — build JSON array
CONN_JSON="["
CONN_FIRST=1
if [ ${#ConnectionPortsArray[@]} -gt 0 ]; then
	for cPort in "${ConnectionPortsArray[@]}"; do
		cval=$(kv_get "conn" "$cPort" 0)
		CON=$(echo | awk "{print $cval / $X}" | awk '{printf "%18.0f",$1}' | xargs)
		if [ "$CONN_FIRST" -eq 0 ]; then CONN_JSON="$CONN_JSON,"; fi
		CONN_JSON="$CONN_JSON{\"port\":$cPort,\"connections\":$CON}"
		CONN_FIRST=0
	done
fi
CONN_JSON="$CONN_JSON]"

# Temperature — build JSON array
TEMP_JSON="["
TEMP_FIRST=1
if [ "$(id -u)" -eq 0 ]; then
	# Intel Macs: try powermetrics smc sampler for CPU die temperature
	if command -v "powermetrics" > /dev/null 2>&1; then
		TEMP_RAW=$(powermetrics --samplers smc -i 1 -n 1 2>/dev/null | grep "CPU die temperature" | grep -oE '[0-9.]+')
		if [ -n "$TEMP_RAW" ]; then
			TEMP_VAL=$(echo "$TEMP_RAW" | awk '{printf "%18.0f", $1 * 1000}' | xargs)
			if [ "$TEMP_FIRST" -eq 0 ]; then TEMP_JSON="$TEMP_JSON,"; fi
			TEMP_JSON="$TEMP_JSON{\"name\":\"CPU_die\",\"millidegrees\":$TEMP_VAL}"
			TEMP_FIRST=0
		fi
	fi
	# Apple Silicon / fallback: get SSD temperature from smartctl (NVMe SMART)
	if [ "$TEMP_FIRST" -eq 1 ] && command -v "smartctl" > /dev/null 2>&1; then
		for disk in $(diskutil list 2>/dev/null | grep "^/dev/disk[0-9]" | grep "physical" | awk '{print $1}' | sort -u); do
			SSD_TEMP=$(smartctl -A "$disk" 2>/dev/null | grep "^Temperature:" | grep -oE '[0-9]+')
			if [ -n "$SSD_TEMP" ]; then
				SSD_TEMP_MILLI=$((SSD_TEMP * 1000))
				if [ "$TEMP_FIRST" -eq 0 ]; then TEMP_JSON="$TEMP_JSON,"; fi
				TEMP_JSON="$TEMP_JSON{\"name\":\"Core_Average\",\"millidegrees\":$SSD_TEMP_MILLI}"
				TEMP_FIRST=0
			fi
		done
	fi
fi
TEMP_JSON="$TEMP_JSON]"

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Temperature: $TEMP_JSON" >> "$ScriptPath"/debug.log; fi

# Services — build JSON array
SRVCS_JSON="["
SRVCS_FIRST=1
if [ ${#CheckServicesArray[@]} -gt 0 ]; then
	for svc in "${CheckServicesArray[@]}"; do
		svc_status=$(kv_get "srvcs" "$svc" 0)
		# Re-check
		svc_status=$((svc_status + $(servicestatus "$svc")))
		if [ "$svc_status" -eq 0 ]; then
			svc_running="false"
		else
			svc_running="true"
		fi
		if [ "$SRVCS_FIRST" -eq 0 ]; then SRVCS_JSON="$SRVCS_JSON,"; fi
		SRVCS_JSON="$SRVCS_JSON{\"name\":\"$svc\",\"running\":$svc_running}"
		SRVCS_FIRST=0
	done
fi
SRVCS_JSON="$SRVCS_JSON]"

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Services: $SRVCS_JSON" >> "$ScriptPath"/debug.log; fi

# RAID — placeholder (AppleRAID not implemented yet)
RAID_JSON="[]"

# Drive Health — build JSON array
DH_JSON="["
DH_FIRST=1
if [ "${CheckDriveHealth:-0}" -gt 0 ]; then
	if command -v "smartctl" > /dev/null 2>&1; then
		for disk in $(diskutil list 2>/dev/null | grep "^/dev/disk[0-9]" | grep "physical\|external" | awk '{print $1}' | sort -u); do
			DHealth=$(smartctl -A "$disk" 2>/dev/null)
			if [ -n "$DHealth" ] && echo "$DHealth" | grep -q -E 'Attribute|SMART'; then
				DHHealth=$(smartctl -H "$disk" 2>/dev/null)
				health_result=$(echo "$DHHealth" | grep -i "SMART overall-health" | awk -F': ' '{print $2}' | xargs)
				if [ -z "$health_result" ]; then health_result="UNKNOWN"; fi
				DInfo=$(smartctl -i "$disk" 2>/dev/null)
				DModel=$(echo "$DInfo" | grep -i -E "Device Model:|Model Number:|Product:" | head -1 | awk -F':' '{print $2}' | xargs)
				DSerial=$(echo "$DInfo" | grep -i "Serial Number:" | head -1 | awk -F':' '{print $2}' | xargs)
				diskname=${disk##*/}
				if [ "$DH_FIRST" -eq 0 ]; then DH_JSON="$DH_JSON,"; fi
				DH_JSON="$DH_JSON{\"type\":\"smart\",\"device\":\"$diskname\",\"health\":\"$health_result\",\"model\":\"$DModel\",\"serial\":\"$DSerial\"}"
				DH_FIRST=0
			fi
		done
	fi
fi
DH_JSON="$DH_JSON]"

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) DriveHealth: $DH_JSON" >> "$ScriptPath"/debug.log; fi

# Running Processes — keep as plain text (can be large)
RPS=""
if [ "${RunningProcesses:-0}" -gt 0 ]; then
	RPS=$(ps -Ao pid,ppid,uid,user,pcpu,pmem,etime,comm 2>/dev/null | tail -n +2)
fi

# Custom Variables — parse JSON file directly
CV_JSON="{}"
if [ -n "$CustomVars" ]; then
	if [ -s "$ScriptPath"/"$CustomVars" ]; then
		CV_JSON=$(< "$ScriptPath"/"$CustomVars")
	fi
fi

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) CV: $CV_JSON" >> "$ScriptPath"/debug.log; fi

# Outgoing PING — build JSON array
OPING_JSON="["
OPING_FIRST=1
if [ -n "$OutgoingPings" ]; then
	wait
	if [ -f "$ScriptPath"/ping.txt ]; then
		while IFS=';' read -r entry; do
			if [ -z "$entry" ]; then continue; fi
			IFS=',' read -r p_name p_target p_loss p_rtt <<< "$entry"
			if [ -n "$p_name" ] && [ -n "$p_target" ]; then
				if [ "$OPING_FIRST" -eq 0 ]; then OPING_JSON="$OPING_JSON,"; fi
				OPING_JSON="$OPING_JSON{\"name\":\"$p_name\",\"target\":\"$p_target\",\"packetLoss\":$p_loss,\"avgRttMicros\":$p_rtt}"
				OPING_FIRST=0
			fi
		done < <(grep -v '^$' "$ScriptPath"/ping.txt | tr -d '\n' | sed 's/;/;\n/g')
		rm -f "$ScriptPath"/ping.txt
	fi
fi
OPING_JSON="$OPING_JSON]"

if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) OPING: $OPING_JSON" >> "$ScriptPath"/debug.log; fi

# Current timestamp in ISO 8601 format
Timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Escape special JSON characters in string fields
json_escape() {
	local str="$1"
	str="${str//\\/\\\\}"
	str="${str//\"/\\\"}"
	str="${str//$'\n'/\\n}"
	str="${str//$'\r'/\\r}"
	str="${str//$'\t'/\\t}"
	printf '%s' "$str"
}

# Build the JSON payload — plain JSON, no compression, no base64 encoding
# Uses structured arrays for per-mount/per-NIC/per-device data
json='{'
json="$json\"serverUuid\":\"$OPENUPTIME_SERVER_UUID\""
json="$json,\"timestamp\":\"$Timestamp\""
json="$json,\"cpu\":$CPU"
json="$json,\"cpuIoWait\":$CPUwa"
json="$json,\"cpuSteal\":$CPUst"
json="$json,\"cpuUser\":$CPUus"
json="$json,\"cpuSystem\":$CPUsy"
json="$json,\"cpuModel\":\"$(json_escape "$CPUModel")\""
json="$json,\"cpuSockets\":$CPUSockets"
json="$json,\"cpuCores\":$CPUCores"
json="$json,\"cpuThreads\":$CPUThreads"
json="$json,\"cpuSpeed\":$CPUSpeed"
json="$json,\"loadAvg1\":$loadavg1"
json="$json,\"loadAvg5\":$loadavg5"
json="$json,\"loadAvg15\":$loadavg15"
json="$json,\"ramTotal\":$RAMSize"
json="$json,\"ramUsage\":$RAM"
json="$json,\"ramSwapTotal\":$RAMSwapSize"
json="$json,\"ramSwapUsage\":$RAMSwap"
json="$json,\"ramBuffers\":$RAMBuff"
json="$json,\"ramCache\":$RAMCache"
json="$json,\"disks\":$DISKS_JSON"
json="$json,\"inodes\":$INODES_JSON"
json="$json,\"diskIops\":$IOPS_JSON"
json="$json,\"nics\":$NICS_JSON"
json="$json,\"ipv4\":$IPv4_JSON"
json="$json,\"ipv6\":$IPv6_JSON"
json="$json,\"hostname\":\"$(json_escape "$Hostname")\""
json="$json,\"os\":\"$(json_escape "$OS")\""
json="$json,\"kernel\":\"$(json_escape "$Kernel")\""
json="$json,\"uptime\":$Uptime"
json="$json,\"requiresReboot\":false"

# Optional fields — only include if data is present
if [ "$TEMP_JSON" != "[]" ]; then
	json="$json,\"temperature\":$TEMP_JSON"
fi
if [ "$SRVCS_JSON" != "[]" ]; then
	json="$json,\"services\":$SRVCS_JSON"
fi
if [ "$RAID_JSON" != "[]" ]; then
	json="$json,\"raid\":$RAID_JSON"
fi
if [ "$DH_JSON" != "[]" ]; then
	json="$json,\"driveHealth\":$DH_JSON"
fi
if [ "$CONN_JSON" != "[]" ]; then
	json="$json,\"portConnections\":$CONN_JSON"
fi
if [ -n "$RPS" ]; then
	json="$json,\"processes\":\"$(json_escape "$RPS")\""
fi
if [ "$CV_JSON" != "{}" ]; then
	json="$json,\"customVars\":$CV_JSON"
fi
if [ "$OPING_JSON" != "[]" ]; then
	json="$json,\"pingResults\":$OPING_JSON"
fi

json="$json}"

if [ "$DEBUG" -eq 1 ]; then
	echo -e "$ScriptStartTime-$(date +%T]) JSON payload:\n$json" >> "$ScriptPath"/debug.log
fi

# Secured Connection
if [ "${SecuredConnection:-1}" -gt 0 ]; then
	CurlSecure=""
else
	CurlSecure="--insecure"
fi

# POST metrics to the OpenUptime API with exponential backoff retry
# Retry delays: 5s, 15s, 45s (3 retries max)
RETRY_DELAYS=(5 15 45)
MAX_RETRIES=3
POST_SUCCESS=0

for attempt in $(seq 0 $MAX_RETRIES); do
	if [ "$attempt" -gt 0 ]; then
		delay=${RETRY_DELAYS[$((attempt - 1))]}
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Retry attempt $attempt/$MAX_RETRIES after ${delay}s delay" >> "$ScriptPath"/debug.log; fi
		sleep "$delay"
	fi

	if [ "$DEBUG" -eq 1 ]; then
		echo -e "$ScriptStartTime-$(date +%T]) Posting data (attempt $((attempt + 1)))" >> "$ScriptPath"/debug.log
		HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
			-X POST \
			-H "Content-Type: application/json" \
			-H "Authorization: Bearer $OPENUPTIME_API_KEY" \
			--max-time 30 \
			$CurlSecure \
			-d "$json" \
			"${OPENUPTIME_REPORTING_URL}/api/metrics" 2>> "$ScriptPath"/debug.log)
		echo -e "$ScriptStartTime-$(date +%T]) HTTP response code: $HTTP_CODE" >> "$ScriptPath"/debug.log
	else
		HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
			-X POST \
			-H "Content-Type: application/json" \
			-H "Authorization: Bearer $OPENUPTIME_API_KEY" \
			--max-time 30 \
			$CurlSecure \
			-d "$json" \
			"${OPENUPTIME_REPORTING_URL}/api/metrics" 2>/dev/null)
	fi

	# Success on 2xx response
	if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
		POST_SUCCESS=1
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Data posted successfully (HTTP $HTTP_CODE)" >> "$ScriptPath"/debug.log; fi
		break
	fi

	# Don't retry on client errors (4xx) — these won't succeed on retry
	if [[ "$HTTP_CODE" =~ ^4[0-9][0-9]$ ]]; then
		if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) Client error (HTTP $HTTP_CODE), not retrying" >> "$ScriptPath"/debug.log; fi
		break
	fi
done

if [ "$POST_SUCCESS" -eq 0 ]; then
	if [ "$DEBUG" -eq 1 ]; then echo -e "$ScriptStartTime-$(date +%T]) ERROR: Failed to post metrics after $MAX_RETRIES retries (last HTTP code: $HTTP_CODE)" >> "$ScriptPath"/debug.log; fi
	echo "$ScriptStartTime-$(date +%T]) ERROR: Failed to post metrics to ${OPENUPTIME_REPORTING_URL}/api/metrics (HTTP $HTTP_CODE)" >> "$ScriptPath"/openuptime_agent.log
fi
