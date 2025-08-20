#!/bin/bash

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_PREFIX="[$TIMESTAMP]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_JSON="$SCRIPT_DIR/sentinelone_summary_${TIMESTAMP}.json"

echo "$LOG_PREFIX [*] Checking SentinelOne services and processes on macOS..."

# === System Extensions ===
EXTENSIONS=$(systemextensionsctl list | grep -i sentinel)
if [ -n "$EXTENSIONS" ]; then
    echo -e "\n[+] SentinelOne System Extensions Found:"
    echo "$EXTENSIONS" | while read -r line; do
        echo "  • $line"
    done
else
    echo -e "\n[!] No SentinelOne System Extensions Found."
fi

# === LaunchDaemons/LaunchAgents ===
PLISTS=$(find /Library/Launch* /System/Library/Launch* -name '*sentinel*.plist' 2>/dev/null)
if [ -n "$PLISTS" ]; then
    echo -e "\n[+] SentinelOne LaunchDaemons/LaunchAgents Found:"
    echo "$PLISTS" | xargs -n1 basename | sort | uniq | while read -r plist; do
        echo "  • $plist"
    done
else
    echo -e "\n[!] No SentinelOne LaunchDaemons or LaunchAgents found."
fi

# === Process Summary ===
echo -e "\n[+] Process Resource Usage Summary:\n"
printf "%-30s %-10s %-10s %-10s\n" "ProcessName" "Instances" "AvgCPU%" "AvgMem%"

JSON="{\n  \"timestamp\": \"$TIMESTAMP\",\n  \"processes\": [\n"
FIRST=1
FULL_PATHS=()

PROCESSES=$(ps aux | grep -i sentinel | grep -v grep | awk '{print $11}' | sort | uniq)

for PROC in $PROCESSES; do
    PROC_NAME=$(basename "$PROC")
    PIDS=$(pgrep -f "$PROC")
    COUNT=0
    CPU_TOTAL=0
    MEM_TOTAL=0

    for PID in $PIDS; do
        STATS=$(ps -p "$PID" -o %cpu=,%mem= | tail -1)
        CPU=$(echo "$STATS" | awk '{print $1}')
        MEM=$(echo "$STATS" | awk '{print $2}')
        CPU_TOTAL=$(echo "$CPU_TOTAL + $CPU" | bc)
        MEM_TOTAL=$(echo "$MEM_TOTAL + $MEM" | bc)
        COUNT=$((COUNT + 1))
    done

    if [ "$COUNT" -gt 0 ]; then
        AVG_CPU=$(echo "scale=2; $CPU_TOTAL / $COUNT" | bc)
        AVG_MEM=$(echo "scale=2; $MEM_TOTAL / $COUNT" | bc)
    else
        AVG_CPU=0
        AVG_MEM=0
    fi

    printf "%-30s %-10s %-10s %-10s\n" "$PROC_NAME" "$COUNT" "$AVG_CPU" "$AVG_MEM"

    if [ "$FIRST" -eq 1 ]; then
        FIRST=0
    else
        JSON="$JSON,\n"
    fi
    JSON="$JSON    {\"process\": \"$PROC_NAME\", \"instances\": $COUNT, \"avg_cpu\": $AVG_CPU, \"avg_mem\": $AVG_MEM}"

    FULL_PATHS+=("$PROC_NAME|$PROC")
done

JSON="$JSON\n  ],\n"

# === Full Executable Paths ===
if [ "${#FULL_PATHS[@]}" -gt 0 ]; then
    echo -e "\n[+] Full Executable Paths Found:"
    for ENTRY in "${FULL_PATHS[@]}"; do
        NAME=$(echo "$ENTRY" | cut -d'|' -f1)
        PATHVAL=$(echo "$ENTRY" | cut -d'|' -f2)
        echo "  • $NAME => $PATHVAL"
    done
fi

# === Process Tree ===
echo -e "\n[+] SentinelOne Process Tree (via ps):"
ps -axo pid,ppid,command | grep -i sentinel | grep -v grep | while read -r PID PPID_VAR CMD; do
    echo "  • PID $PID ($CMD) <- Parent PID $PPID_VAR"
done

# === Console Connectivity Check ===
echo -e "\n[+] Validating connectivity to SentinelOne Console Endpoint:"

# Extract last console URL from logs (most recent console assignment)
PORTAL=$(grep -h "Update console URL to new value" /Library/Sentinel/_sentinel/agent-ui/ui-log-* 2>/dev/null | \
         tail -1 | grep -Eo 'https://[a-zA-Z0-9.-]+\.sentinelone\.net')

# Fallback if not found
if [ -z "$PORTAL" ]; then
    PORTAL="https://console.sentinelone.net"
fi

DOMAIN=$(echo "$PORTAL" | awk -F/ '{print $3}')
echo "  • Detected Portal: $PORTAL"

echo -n "  • Testing connectivity to $DOMAIN... "
if curl --connect-timeout 3 -s "$PORTAL" > /dev/null; then
    echo "[OK]"
    CONSOLE_STATUS="reachable"
else
    echo "[FAIL]"
    CONSOLE_STATUS="unreachable"
fi

# === Final JSON Section ===
JSON="$JSON  \"console_connectivity\": {\n    \"portal\": \"$PORTAL\",\n    \"status\": \"$CONSOLE_STATUS\"\n  }\n}"

# === Save JSON Output ===
echo -e "\n[INFO] JSON saved to: $OUTPUT_JSON"
echo -e "$JSON" > "$OUTPUT_JSON"