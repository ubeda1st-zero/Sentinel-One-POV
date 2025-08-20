#!/bin/bash

set -euo pipefail
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
OUTPUT_FILE="./sentinelone_k8s_summary_$TIMESTAMP.json"

echo "[*] Searching for SentinelOne Pods in Kubernetes..."

PODS=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | grep -E 's1-(agent|helper)')
if [[ -z "$PODS" ]]; then
  echo "[!] No SentinelOne pods found."
  exit 1
fi

echo
echo "[+] SentinelOne Pods found:"
for POD in $PODS; do
  echo "  • [$POD]"
done

echo
echo "[+] Inspecting SentinelOne-related processes in filtered pods:"
echo

SUMMARY_JSON="{\"timestamp\":\"$TIMESTAMP\",\"pods\":["

FIRST_POD=true
for FULLPOD in $PODS; do
  NAMESPACE=$(cut -d '/' -f1 <<< "$FULLPOD")
  POD=$(cut -d '/' -f2 <<< "$FULLPOD")

  echo "  • [$FULLPOD] SentinelOne Processes:"
  POD_JSON="{\"namespace\":\"$NAMESPACE\",\"pod\":\"$POD\",\"processes\":["
  PROCESSES=$(kubectl exec -n "$NAMESPACE" "$POD" -- ps auxww | grep -E 's1-|sentinel' | grep -v grep || true)

  if [[ -n "$PROCESSES" ]]; then
    while IFS= read -r LINE; do
      echo "    $LINE"
      LINE_ESCAPED=$(jq -Rn --arg line "$LINE" '$line')
      POD_JSON+="$LINE_ESCAPED,"
    done <<< "$PROCESSES"
    POD_JSON="${POD_JSON%,}"  # Remove trailing comma
  else
    echo "    [No SentinelOne-related processes found]"
  fi

  POD_JSON+="]}"
  if [ "$FIRST_POD" = true ]; then
    FIRST_POD=false
  else
    SUMMARY_JSON+=","
  fi
  SUMMARY_JSON+="$POD_JSON"
  echo
done
SUMMARY_JSON+="],"

# Detect console URL from helper log
echo "[+] Attempting to detect SentinelOne Console URL from s1-helper logs..."

HELPER_POD=""
NAMESPACE_FILTER=""
for FULLPOD in $PODS; do
  if [[ "$FULLPOD" == */s1-helper-* ]]; then
    NAMESPACE_FILTER=$(cut -d '/' -f1 <<< "$FULLPOD")
    HELPER_POD=$(cut -d '/' -f2 <<< "$FULLPOD")
    break
  fi
done

console_url=""
if [[ -n "$HELPER_POD" ]]; then
  if kubectl exec -n "$NAMESPACE_FILTER" "$HELPER_POD" -- test -f /s1-helper/log/helper.log 2>/dev/null; then
    console_url=$(kubectl exec -n "$NAMESPACE_FILTER" "$HELPER_POD" -- grep -aEo 'https://[a-zA-Z0-9.-]+\.sentinelone\.net' /s1-helper/log/helper.log 2>/dev/null | sort -u | head -n1 || true)
  else
    echo "  [!] helper.log not found in pod $HELPER_POD"
  fi
else
  echo "  [!] s1-helper pod not found"
fi

if [[ -z "$console_url" ]]; then
  echo "  [ERROR] Could not detect SentinelOne Console URL. Aborting."
  exit 1
fi

SUMMARY_JSON+="\"console_url\":\"$console_url\""

# Test connectivity
echo "  [-] Testing connectivity to $console_url..."

if curl -s --connect-timeout 5 "$console_url" > /dev/null; then
  echo "  • Connectivity Test: [OK]"
  SUMMARY_JSON+=",\"connectivity\":\"ok\""
else
  echo "  • Connectivity Test: [FAILED]"
  SUMMARY_JSON+=",\"connectivity\":\"failed\""
fi

SUMMARY_JSON+="}"

echo
echo "[INFO] JSON saved to: $OUTPUT_FILE"
echo "$SUMMARY_JSON" | jq '.' > "$OUTPUT_FILE"