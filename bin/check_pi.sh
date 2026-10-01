#!/usr/bin/env bash

# Define target endpoint
TARGET_HOST="rfstag.com"

# Section Header Helper Function
print_header() {
    printf "%s\n" "==============================================="
    printf "  %-43s  \n" "$1"
    printf "%s\n" "==============================================="
}

# 1. HARDWARE & OS SUMMARY
print_header "REMOTE RASPBERRY PI SUMMARY"

HOST_NAME=$(hostname)
CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S %Z")
printf "Hostname       : %s\n" "${HOST_NAME:-Unknown}"
printf "Report Date    : %s\n" "$CURRENT_DATE"

HW_MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || cat /proc/device-tree/model 2>/dev/null)
printf "Hardware Model : %s\n" "${HW_MODEL:-Unknown Raspberry Pi}"

OS_VER=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
printf "OS Version     : %s\n" "${OS_VER:-Unknown Linux OS}"

ARCH_BITS=$(getconf LONG_BIT)
printf "Kernel & Arch  : %s (%s-bit)\n" "$(uname -r)" "$ARCH_BITS"

TOTAL_MEM=$(free -h | awk '/^Mem:/ {print $2}')
USED_MEM=$(free -h | awk '/^Mem:/ {print $3}')
MEM_PCT=$(free | awk '/^Mem:/ {printf "%.1f", $3/$2 * 100}')
printf "Memory Size    : %s\n" "$TOTAL_MEM"
printf "RAM Usage      : %s / %s (%s%%)\n" "$USED_MEM" "$TOTAL_MEM" "$MEM_PCT"

DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_PCT=$(df -h / | awk 'NR==2 {print $5}')
printf "Disk Usage (/) : %s / %s (%s used)\n" "$DISK_USED" "$DISK_TOTAL" "$DISK_PCT"

# 2. NETWORK IDENTIFICATION (IP & MAC ADDRESSES)
print_header "NETWORK IDENTIFICATION (IP & MAC)"

# Detect active interfaces excluding loopback and docker
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^lo$|^docker|^veth')

if [ -n "$INTERFACES" ]; then
    for IFACE in $INTERFACES; do
        MAC_ADDR=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)
        IP_ADDRS=$(ip -o -4 addr show "$IFACE" 2>/dev/null | awk '{print $4}' | paste -sd ", " -)

        if [ -n "$IP_ADDRS" ]; then
            printf "Interface (%-4s): %-18s | MAC: %s\n" "$IFACE" "$IP_ADDRS" "${MAC_ADDR:-Unknown}"
        else
            printf "Interface (%-4s): DISCONNECTED         | MAC: %s\n" "$IFACE" "${MAC_ADDR:-Unknown}"
        fi
    done
else
    printf "Local Interfaces: None Detected\n"
fi

# Fetch Public IP
PUB_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || curl -s --max-time 3 https://ifconfig.me 2>/dev/null)
printf "Public IP      : %s\n" "${PUB_IP:-Unable to reach IP lookup service}"

# 3. THERMAL & POWER STATUS
print_header "THERMAL & POWER STATUS"

if command -v vcgencmd >/dev/null 2>&1; then
    CPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2)
elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    RAW_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
    CPU_TEMP="$(awk -v t="$RAW_TEMP" 'BEGIN {printf "%.1f\x27C", t/1000}')"
else
    CPU_TEMP="Unknown"
fi
printf "SoC Temperature: %s\n" "${CPU_TEMP:-Unknown}"

if command -v vcgencmd >/dev/null 2>&1; then
    THROTTLED_HEX=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    if [ -n "$THROTTLED_HEX" ]; then
        VAL=$((THROTTLED_HEX))
        FLAGS=()
        (( (VAL & 0x1) != 0 )) && FLAGS+=("ACTIVE: Undervoltage detected")
        (( (VAL & 0x2) != 0 )) && FLAGS+=("ACTIVE: ARM frequency capped")
        (( (VAL & 0x4) != 0 )) && FLAGS+=("ACTIVE: Currently Throttled (Overheating)")
        (( (VAL & 0x8) != 0 )) && FLAGS+=("ACTIVE: Soft temp limit active")
        (( (VAL & 0x10000) != 0 )) && FLAGS+=("HISTORICAL: Undervoltage occurred")
        (( (VAL & 0x20000) != 0 )) && FLAGS+=("HISTORICAL: ARM frequency capping occurred")
        (( (VAL & 0x40000) != 0 )) && FLAGS+=("HISTORICAL: Throttling occurred (Overheated in past)")
        (( (VAL & 0x80000) != 0 )) && FLAGS+=("HISTORICAL: Soft temp limit occurred")

        if [ ${#FLAGS[@]} -eq 0 ]; then
            printf "Hardware Flags : OK (0x0)\n"
        else
            printf "Hardware Flags : WARNING (%s)\n" "$THROTTLED_HEX"
            for flag in "${FLAGS[@]}"; do
                printf "  - %s\n" "$flag"
            done
        fi
    fi
fi

# Kernel Log Audit for Dates & Durations
printf "\n--- Throttling Event Log (Kernel History) ---\n"
EVENT_FOUND=0
LOG_DATA=""
if command -v journalctl >/dev/null 2>&1; then
    LOG_DATA=$(journalctl -k -g "thermal|throttling|undervoltage" --o short-iso 2>/dev/null)
elif [ -f /var/log/kern.log ]; then
    LOG_DATA=$(grep -i -E "thermal|throttling|undervoltage" /var/log/kern.log 2>/dev/null)
fi

if [ -n "$LOG_DATA" ]; then
    START_TS=0
    while IFS= read -r line; do
        ISO_DATE=$(echo "$line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')
        if echo "$line" | grep -q -i -E "above temperature limit|critical temperature|throttling"; then
            EVENT_FOUND=1
            [ -n "$ISO_DATE" ] && START_TS=$(date -d "$ISO_DATE" +%s 2>/dev/null || echo 0)
            printf " [EVENT STARTED] %s | %s\n" "${ISO_DATE:-Unknown Date}" "$(echo "$line" | cut -d' ' -f5-)"
        elif echo "$line" | grep -q -i -E "below temperature limit|normal temperature"; then
            DURATION_STR="Unknown Duration"
            if [ "$START_TS" -gt 0 ] && [ -n "$ISO_DATE" ]; then
                END_TS=$(date -d "$ISO_DATE" +%s 2>/dev/null || echo 0)
                if [ "$END_TS" -ge "$START_TS" ]; then
                    DIFF=$((END_TS - START_TS))
                    DURATION_STR="$((DIFF / 60))m $((DIFF % 60))s"
                fi
            fi
            printf " [EVENT CLEARED] %s | Duration: %s\n" "${ISO_DATE:-Unknown Date}" "$DURATION_STR"
            START_TS=0
        fi
    done <<< "$LOG_DATA"
fi

[ "$EVENT_FOUND" -eq 0 ] && printf "No historical thermal throttling events logged in system kernel logs.\n"

# 4. HARDWARE PERIPHERALS & DISPLAYS
print_header "HARDWARE PERIPHERALS & DISPLAYS"

# USB NFC Reader Check
if command -v lsusb >/dev/null 2>&1; then
    NFC_DEV=$(lsusb | grep -i -E "sony|pasori|nfc|felica|054c:|303a:4007|072f:2401|walletmate|acs")
    if [ -n "$NFC_DEV" ]; then
        printf "NFC Reader     : CONNECTED\n"
        printf "Device Info    : %s\n" "$NFC_DEV"
    else
        printf "NFC Reader     : NOT DETECTED (No Sony/NFC device in lsusb)\n"
    fi
else
    printf "USB Status     : 'lsusb' command not available\n"
fi

# HDMI Display Detection (DRM + VideoCore Fallbacks)
HDMI_CONNECTED=0
for status_file in /sys/class/drm/card*-HDMI-*/status; do
    if [ -f "$status_file" ]; then
        STATUS=$(cat "$status_file" 2>/dev/null)
        PORT_NAME=$(echo "$status_file" | awk -F'/' '{print $(NF-1)}' | sed 's/card[0-9]*-//')

        if [ "$STATUS" = "connected" ]; then
            HDMI_CONNECTED=1
            MODES_FILE="$(dirname "$status_file")/modes"
            RES="Unknown Resolution"
            [ -f "$MODES_FILE" ] && RES=$(head -n 1 "$MODES_FILE" 2>/dev/null)
            printf "HDMI Port (%s): CONNECTED (%s)\n" "$PORT_NAME" "${RES:-Active}"
        fi
    fi
done

# Fallback to VideoCore Tools (Legacy Pi 3 / FKMS Driver)
if [ "$HDMI_CONNECTED" -eq 0 ]; then
    if command -v tvservice >/dev/null 2>&1; then
        TVS_STATUS=$(tvservice -s 2>/dev/null)
        if echo "$TVS_STATUS" | grep -q -E "HDMI|DVI"; then
            HDMI_CONNECTED=1
            RES_INFO=$(echo "$TVS_STATUS" | grep -oE '[0-9]+x[0-9]+ @ [0-9\.]+Hz')
            printf "HDMI Display   : CONNECTED via tvservice (%s)\n" "${RES_INFO:-Active}"
        fi
    elif command -v vcgencmd >/dev/null 2>&1; then
        DISP_PWR=$(vcgencmd display_power 2>/dev/null | cut -d= -f2)
        if [ "$DISP_PWR" = "1" ]; then
            HDMI_CONNECTED=1
            printf "HDMI Display   : POWERED ON (vcgencmd display_power=1)\n"
        fi
    fi
fi

[ "$HDMI_CONNECTED" -eq 0 ] && printf "HDMI Display   : DISCONNECTED / Headless Mode\n"

# 5. AUDIO CONFIGURATION & ROUTING
print_header "AUDIO CONFIGURATION & ROUTING"

AUDIO_DEST="Unknown"
AUDIO_SINK_NAME="Unknown"
AUDIO_VOL="Unknown"

# Method 1: Check PipeWire (Bookworm default)
if command -v wpctl >/dev/null 2>&1 && wpctl status >/dev/null 2>&1; then
    SINK_RAW=$(wpctl status 2>/dev/null | grep -A 5 "Sinks:" | grep "\*")
    AUDIO_SINK_NAME=$(echo "$SINK_RAW" | sed -E 's/.*\* +[0-9]+\. //; s/ +\[vol.*//')

    if echo "$AUDIO_SINK_NAME" | grep -i -q "hdmi"; then
        AUDIO_DEST="HDMI Output"
    elif echo "$AUDIO_SINK_NAME" | grep -i -E "headphone|analog|jack" ; then
        AUDIO_DEST="3.5mm Headphone Jack"
    else
        AUDIO_DEST="$AUDIO_SINK_NAME"
    fi

    VOL_RAW=$(wpctl get-volume @DEFAULT_SINK@ 2>/dev/null)
    if [ -n "$VOL_RAW" ]; then
        VOL_NUM=$(echo "$VOL_RAW" | awk '{print $2}')
        VOL_PCT=$(awk -v v="$VOL_NUM" 'BEGIN {printf "%.0f%%", v * 100}')
        AUDIO_VOL="$VOL_PCT"
        echo "$VOL_RAW" | grep -q "MUTED" && AUDIO_VOL="$VOL_PCT [MUTED]"
    fi

# Method 2: Check PulseAudio (Bullseye default)
elif command -v pactl >/dev/null 2>&1 && pactl get-default-sink >/dev/null 2>&1; then
    SINK_RAW=$(pactl get-default-sink 2>/dev/null)
    AUDIO_SINK_NAME="$SINK_RAW"
    if echo "$SINK_RAW" | grep -i -q "hdmi"; then
        AUDIO_DEST="HDMI Output"
    elif echo "$SINK_RAW" | grep -i -E "analog|headphone"; then
        AUDIO_DEST="3.5mm Headphone Jack"
    fi
    AUDIO_VOL=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oE '[0-9]+%' | head -n 1)

# Method 3: Expanded Fallback to ALSA (amixer / apass / Pi 3 Legacy)
elif command -v amixer >/dev/null 2>&1; then
    VOL_MATCH=$(amixer sget Master 2>/dev/null || amixer sget Headphone 2>/dev/null || amixer sget PCM 2>/dev/null || amixer sget HDMI 2>/dev/null)
    AUDIO_VOL=$(echo "$VOL_MATCH" | grep -oE '\[[0-9]+%\]' | head -n 1 | tr -d '[]')

    ROUTE=$(amixer cget numid=3 2>/dev/null | grep -oE 'values=[0-2]' | cut -d= -f2)
    case "$ROUTE" in
        1)
            AUDIO_DEST="3.5mm Headphone Jack"
            AUDIO_SINK_NAME="bcm2835 Headphone / ALSA"
            ;;
        2)
            AUDIO_DEST="HDMI Output"
            AUDIO_SINK_NAME="bcm2835 HDMI / ALSA"
            ;;
        0)
            AUDIO_DEST="Auto-detect"
            AUDIO_SINK_NAME="bcm2835 Auto-route"
            ;;
        *)
            SINK_DEV=$(aplay -l 2>/dev/null | grep -i "card" | head -n 1)
            if [ -n "$SINK_DEV" ]; then
                AUDIO_SINK_NAME=$(echo "$SINK_DEV" | cut -d: -f2 | cut -d[ -f1 | xargs)
                if echo "$SINK_DEV" | grep -q -i "hdmi"; then
                    AUDIO_DEST="HDMI Output"
                else
                    AUDIO_DEST="Analog / Onboard Jack"
                fi
            fi
            ;;
    esac
fi

printf "Audio Routed To: %s\n" "${AUDIO_DEST:-Not Configured / Idle}"
printf "Active Device  : %s\n" "${AUDIO_SINK_NAME:-No Active Sound Card}"
printf "Volume Level   : %s\n" "${AUDIO_VOL:-Unknown}"

# 6. NETWORK LATENCY METRICS
print_header "NETWORK LATENCY METRICS"

TCP_LATENCY=$(nc -zv -w 3 "$TARGET_HOST" 443 2>&1 | grep -oE '[0-9]+\.[0-9]+ ms')
if [ -z "$TCP_LATENCY" ]; then
    TCP_LATENCY=$(curl -o /dev/null -s -w "%{time_connect}s" "https://$TARGET_HOST" 2>/dev/null)
fi
printf "TCP (Port 443) : Connected (%s)\n" "$TCP_LATENCY"

HTTP_STATS=$(curl -o /dev/null -s -w "HTTP Code: %{http_code} | DNS: %{time_namelookup}s | Connect: %{time_connect}s | TLS: %{time_appconnect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s" "https://$TARGET_HOST" 2>/dev/null)

if [ -n "$HTTP_STATS" ]; then
    printf "HTTPS Metrics  : %s\n" "$HTTP_STATS"
else
    printf "HTTPS Metrics  : Connection Failed\n"
fi

printf "%s\n" "==============================================="


sudo systemctl list-units --type=service --state=running
systemctl status --no-pager sony-reader "vtapreader@*" acrreader pcscd launch_kiosk2 newt rfstunnel

